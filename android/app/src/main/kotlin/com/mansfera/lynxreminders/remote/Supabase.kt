package com.mansfera.lynxreminders.remote

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import com.mansfera.lynxreminders.BuildConfig
import com.mansfera.lynxreminders.core.InviteRow
import com.mansfera.lynxreminders.core.ListRow
import com.mansfera.lynxreminders.core.LynxJson
import com.mansfera.lynxreminders.core.ManifestEntry
import com.mansfera.lynxreminders.core.MemberRow
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.RemoteException
import com.mansfera.lynxreminders.core.RemoteStore
import com.mansfera.lynxreminders.core.ShareResult
import com.mansfera.lynxreminders.core.ShareRow
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.serializer.KotlinXSerializer
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The auth session, encrypted with an AES-GCM key that lives in the Android Keystore
 * (never leaves the device; excluded from backups). SPEC §9.
 */
class SecureSessionManager(context: Context) : SessionManager {
    private val file = File(context.filesDir, "session.bin")
    private val alias = "com.mansfera.lynxreminders.session"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override suspend fun saveSession(session: UserSession) {
        val plain = LynxJson.encodeToString(UserSession.serializer(), session).toByteArray()
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val out = c.iv + c.doFinal(plain)
        val tmp = File(file.parentFile, "session.bin.tmp")
        tmp.writeBytes(byteArrayOf(c.iv.size.toByte()) + out)
        tmp.renameTo(file)
    }

    // The library calls loadSessionOrNull(), which treats an exception as "no session".
    override suspend fun loadSession(): UserSession = loadOrNull() ?: throw IllegalStateException("No stored session")

    private fun loadOrNull(): UserSession? = try {
        if (!file.exists()) null else {
            val bytes = file.readBytes()
            val ivLen = bytes[0].toInt()
            val iv = bytes.copyOfRange(1, 1 + ivLen)
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv)) }
            val plain = c.doFinal(bytes.copyOfRange(1 + ivLen, bytes.size))
            LynxJson.decodeFromString(UserSession.serializer(), String(plain))
        }
    } catch (e: Exception) {
        Log.w("Lynx", "Session unreadable; signing out", e)
        null
    }

    override suspend fun deleteSession() {
        file.delete()
    }
}

object Supa {
    fun create(context: Context): SupabaseClient = createSupabaseClient(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY) {
        httpEngine = OkHttp.create()
        defaultSerializer = KotlinXSerializer(LynxJson)
        install(Auth) {
            sessionManager = SecureSessionManager(context.applicationContext)
            alwaysAutoRefresh = true
            enableLifecycleCallbacks = true
        }
        install(Postgrest)
        install(Realtime)
    }
}

/** Maps supabase-kt failures to [RemoteException] so the sync engine can see RLS rejections. */
internal suspend fun <T> remote(block: suspend () -> T): T = try {
    block()
} catch (e: PostgrestRestException) {
    throw RemoteException(e.statusCode, e.code, e.message)
} catch (e: RestException) {
    throw RemoteException(e.statusCode, null, e.message)
}

/** PostgREST access with the semantics of SPEC §4. */
class SupabaseRemote(private val client: SupabaseClient) : RemoteStore {
    private val pg get() = client.postgrest

    private fun <T> decode(ser: KSerializer<T>, data: String): List<T> = LynxJson.decodeFromString(ListSerializer(ser), data)

    override suspend fun pullLists(afterVersion: Long, limit: Int) = remote {
        decode(ListRow.serializer(), pg.from("lists").select {
            filter { gt("version", afterVersion) }
            order("version", Order.ASCENDING)
            limit(limit.toLong())
        }.data)
    }

    override suspend fun pullReminders(afterVersion: Long, limit: Int) = remote {
        decode(ReminderRow.serializer(), pg.from("reminders").select {
            filter { gt("version", afterVersion) }
            order("version", Order.ASCENDING)
            limit(limit.toLong())
        }.data)
    }

    override suspend fun listsByIds(ids: List<String>) = remote {
        if (ids.isEmpty()) emptyList() else decode(ListRow.serializer(), pg.from("lists").select { filter { isIn("id", ids) } }.data)
    }

    override suspend fun remindersByIds(ids: List<String>) = remote {
        if (ids.isEmpty()) emptyList() else decode(ReminderRow.serializer(), pg.from("reminders").select { filter { isIn("id", ids) } }.data)
    }

    override suspend fun members() = remote {
        decode(MemberRow.serializer(), pg.from("list_members").select(Columns.raw("*,profile:profiles(*)")).data)
    }

    override suspend fun shares() = remote {
        decode(ShareRow.serializer(), pg.from("reminder_shares").select(Columns.raw("*,profile:profiles(*)")).data)
    }

    override suspend fun invites() = remote { decode(InviteRow.serializer(), pg.from("invites").select().data) }

    override suspend fun manifest() = remote { decode(ManifestEntry.serializer(), pg.rpc("sync_manifest").data) }

    /** Rows without the server-assigned `version`; every column is present so PostgREST sees one shape. */
    private fun <T> payload(ser: KSerializer<T>, rows: List<T>) = JsonArray(rows.map { r ->
        JsonObject(LynxJson.encodeToJsonElement(ser, r).jsonObject - "version")
    })

    override suspend fun upsertLists(rows: List<ListRow>) = remote {
        decode(ListRow.serializer(), pg.from("lists").upsert(payload(ListRow.serializer(), rows)) {
            onConflict = "id"
            select()
        }.data)
    }

    override suspend fun upsertReminders(rows: List<ReminderRow>) = remote {
        decode(ReminderRow.serializer(), pg.from("reminders").upsert(payload(ReminderRow.serializer(), rows)) {
            onConflict = "id"
            select()
        }.data)
    }

    // ---------- sharing RPCs (SPEC §3) ----------

    suspend fun shareList(listId: String, email: String): ShareResult = remote {
        LynxJson.decodeFromString(ShareResult.serializer(), pg.rpc("share_list", buildJsonObject { put("p_list", listId); put("p_email", email.trim().lowercase()) }).data)
    }

    suspend fun unshareList(listId: String, userId: String) = remote {
        pg.rpc("unshare_list", buildJsonObject { put("p_list", listId); put("p_user", userId) }); Unit
    }

    suspend fun leaveList(listId: String) = remote { pg.rpc("leave_list", buildJsonObject { put("p_list", listId) }); Unit }

    suspend fun shareReminder(reminderId: String, email: String): ShareResult = remote {
        LynxJson.decodeFromString(ShareResult.serializer(), pg.rpc("share_reminder", buildJsonObject { put("p_reminder", reminderId); put("p_email", email.trim().lowercase()) }).data)
    }

    suspend fun unshareReminder(reminderId: String, userId: String) = remote {
        pg.rpc("unshare_reminder", buildJsonObject { put("p_reminder", reminderId); put("p_user", userId) }); Unit
    }

    suspend fun cancelInvite(inviteId: String) = remote { pg.rpc("cancel_invite", buildJsonObject { put("p_invite", inviteId) }); Unit }

    suspend fun deleteAccount() = remote { pg.rpc("delete_account"); Unit }

    suspend fun updateDisplayName(userId: String, name: String) = remote {
        pg.from("profiles").update(buildJsonObject { put("display_name", name) }) { filter { eq("id", userId) } }; Unit
    }
}
