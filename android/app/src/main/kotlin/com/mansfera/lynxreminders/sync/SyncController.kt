package com.mansfera.lynxreminders.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.mansfera.lynxreminders.LynxApp
import com.mansfera.lynxreminders.core.LOCAL_USER_ID
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.SyncEngine
import com.mansfera.lynxreminders.core.SyncState
import com.mansfera.lynxreminders.core.adoptedBy
import com.mansfera.lynxreminders.data.LocalStore
import com.mansfera.lynxreminders.remote.Passkeys
import com.mansfera.lynxreminders.remote.SupabaseRemote
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.OtpType
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.providers.builtin.OTP
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Instant
import java.util.concurrent.TimeUnit

data class SyncStatus(val running: Boolean = false, val error: String? = null, val lastSyncAt: Instant? = null)

/** Session as the UI needs it. [needsSignIn]: the account is still on this device but the session expired. */
data class AccountState(val userId: String? = null, val email: String? = null, val ready: Boolean = false, val needsSignIn: Boolean = false) {
    val signedIn get() = userId != null && !needsSignIn
}

/**
 * Accounts (SPEC §9) and the sync loop (SPEC §4): debounced runs after edits (1 s) and realtime
 * events (500 ms), manifest on launch/reconnect, WorkManager every 15 min as a backstop.
 */
class SyncController(
    private val context: Context,
    private val client: SupabaseClient,
    private val store: LocalStore,
    private val scope: CoroutineScope,
    private val onSynced: (changed: Boolean) -> Unit,
) {
    val remote = SupabaseRemote(client)
    val passkeys = Passkeys(client)
    private val engine = SyncEngine(remote, store)
    private val _status = MutableStateFlow(SyncStatus(lastSyncAt = store.value.sync.lastSyncAt))
    val status: StateFlow<SyncStatus> = _status.asStateFlow()
    private val _account = MutableStateFlow(AccountState(store.value.userId, store.value.email))
    val account: StateFlow<AccountState> = _account.asStateFlow()

    private var pending: Job? = null
    private var pendingForce = false
    private val runLock = Mutex()
    private var channel: RealtimeChannel? = null
    private var realtimeJob: Job? = null

    fun start() {
        client.auth.sessionStatus.onEach { s ->
            when (s) {
                is SessionStatus.Authenticated -> {
                    val user = s.session.user
                    val id = user?.id ?: return@onEach
                    if (store.value.userId != id) store.edit { it.adoptedBy(id, user.email) }
                    _account.value = AccountState(id, user.email ?: store.value.email, ready = true)
                    subscribeRealtime()
                    scheduleSync(0, forceManifest = true)
                }
                is SessionStatus.NotAuthenticated -> {
                    val keptUser = store.value.userId
                    _account.value = AccountState(keptUser, store.value.email, ready = true, needsSignIn = keptUser != null)
                    unsubscribeRealtime()
                }
                is SessionStatus.RefreshFailure -> {
                    // Offline: keep working locally, try again later
                    _account.value = _account.value.copy(ready = true)
                }
                is SessionStatus.Initializing -> Unit
            }
        }.launchIn(scope)

        val cm = context.getSystemService(ConnectivityManager::class.java)
        try {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = scheduleSync(500)
            })
        } catch (e: Exception) {
            Log.w("Lynx", "network callback", e)
        }
        schedulePeriodic(context)
    }

    // ---------- sync ----------

    fun scheduleSync(delayMs: Long = 1000, forceManifest: Boolean = false) {
        if (!_account.value.signedIn && store.value.userId == null) return
        if (forceManifest) pendingForce = true
        pending?.cancel()
        // Only the wait is cancellable; a run that has started finishes (runs queue on runLock)
        pending = scope.launch {
            delay(delayMs)
            scope.launch { syncNow() }
        }
    }

    suspend fun syncNow(forceManifest: Boolean = false): Boolean = runLock.withLock {
        if (!_account.value.signedIn) return false
        val force = forceManifest || pendingForce
        pendingForce = false
        _status.value = _status.value.copy(running = true)
        return try {
            val rep = withTimeoutOrNull(60_000) { engine.sync(forceManifest = force) }
            _status.value = SyncStatus(false, if (rep == null) "Sync timed out" else null, store.value.sync.lastSyncAt)
            onSynced(rep?.changed ?: false)
            rep != null
        } catch (e: kotlinx.coroutines.CancellationException) {
            _status.value = _status.value.copy(running = false)
            throw e
        } catch (e: Exception) {
            Log.w("Lynx", "sync failed", e)
            _status.value = SyncStatus(false, friendly(e), store.value.sync.lastSyncAt)
            if (force) pendingForce = true
            false
        }
    }

    private fun subscribeRealtime() {
        if (channel != null) return
        realtimeJob = scope.launch {
            try {
                val ch = client.channel("lynx-sync")
                channel = ch
                for (table in listOf("lists", "reminders", "list_members", "reminder_shares")) {
                    ch.postgresChangeFlow<PostgresAction>(schema = "public") { this.table = table }
                        .onEach { scheduleSync(500) }
                        .launchIn(this)
                }
                var wasSubscribed = false
                ch.status.onEach { st ->
                    if (st == RealtimeChannel.Status.SUBSCRIBED) {
                        // A (re)connect may have missed events: run the manifest step
                        if (wasSubscribed) scheduleSync(500, forceManifest = true)
                        wasSubscribed = true
                    }
                }.launchIn(this)
                ch.subscribe()
            } catch (e: Exception) {
                Log.w("Lynx", "realtime unavailable", e)
                channel = null
            }
        }
    }

    private fun unsubscribeRealtime() {
        val ch = channel ?: return
        channel = null
        realtimeJob?.cancel()
        scope.launch { try { client.realtime.removeChannel(ch) } catch (_: Exception) {} }
    }

    // ---------- accounts ----------

    suspend fun signIn(email: String, password: String) {
        client.auth.signInWith(Email) { this.email = email.trim(); this.password = password }
    }

    /** True when the account is signed in right away; false when the server emailed a code to confirm
     *  the address first (finish with [verifyCode], which confirms the sign-up and signs in). */
    suspend fun signUp(email: String, password: String): Boolean {
        client.auth.signUpWith(Email) { this.email = email.trim(); this.password = password }
        return client.auth.currentSessionOrNull() != null
    }

    suspend fun sendCode(email: String) {
        client.auth.signInWith(OTP) { this.email = email.trim(); createUser = true }
    }

    suspend fun verifyCode(email: String, code: String) {
        client.auth.verifyEmailOtp(type = OtpType.Email.EMAIL, email = email.trim(), token = code.trim())
    }

    /** Sign out: [keepLocal] keeps the data as a local-only copy; otherwise the device is cleared. */
    suspend fun signOut(keepLocal: Boolean) {
        try { syncNow() } catch (_: Exception) {}
        unsubscribeRealtime()
        try { client.auth.signOut() } catch (e: Exception) { Log.w("Lynx", "sign out offline", e); client.auth.clearSession() }
        store.edit { if (keepLocal) it.toLocalCopy() else LocalDb() }
        _account.value = AccountState(ready = true)
        _status.value = SyncStatus()
        onSynced(true)
    }

    suspend fun deleteAccount() {
        remote.deleteAccount()
        unsubscribeRealtime()
        try { client.auth.clearSession() } catch (_: Exception) {}
        store.edit { LocalDb() }
        _account.value = AccountState(ready = true)
        onSynced(true)
    }

    private fun friendly(e: Exception): String {
        val m = e.message ?: e.javaClass.simpleName
        return when {
            m.contains("Unable to resolve", true) || m.contains("Failed to connect", true) || m.contains("timeout", true) -> "Offline · changes are saved on this device"
            else -> m.lineSequence().first().take(120)
        }
    }

    companion object {
        fun schedulePeriodic(context: Context) {
            val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork("lynx-sync", ExistingPeriodicWorkPolicy.KEEP, req)
        }

        /** From a receiver (process may die): let WorkManager run the sync once there is network. */
        fun enqueueOnce(context: Context) {
            val req = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setInitialDelay(2, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("lynx-sync-once", ExistingWorkPolicy.REPLACE, req)
        }
    }
}

/** Local-only copy after signing out with "Keep a local copy": rows become mine and unsynced. */
fun LocalDb.toLocalCopy(): LocalDb {
    val me = userId
    return LocalDb(
        lists = lists.filterValues { !it.isDeleted }.mapValues { (_, l) -> l.copy(ownerId = if (l.ownerId == me) LOCAL_USER_ID else l.ownerId, version = 0) },
        reminders = reminders.filterValues { !it.isDeleted }.mapValues { (_, r) ->
            r.copy(createdBy = if (r.createdBy == me) LOCAL_USER_ID else r.createdBy, assigneeId = if (r.assigneeId == me) LOCAL_USER_ID else r.assigneeId, version = 0)
        },
        sync = SyncState(),
    )
}

class SyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val g = (applicationContext as LynxApp).graph
        g.sync.awaitReady()
        return if (!g.sync.account.value.signedIn || g.sync.syncNow()) Result.success() else Result.retry()
    }
}

/** Waits (briefly) until the stored session has been loaded. */
suspend fun SyncController.awaitReady() {
    withTimeoutOrNull(5_000) { while (!account.value.ready) delay(50) }
}
