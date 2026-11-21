package com.mansfera.lynxreminders.triggers

import android.Manifest
import android.annotation.SuppressLint
import android.app.AppOpsManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.mansfera.lynxreminders.LynxApp
import com.mansfera.lynxreminders.R
import com.mansfera.lynxreminders.core.ContextEvent
import com.mansfera.lynxreminders.core.TriggerMatching
import com.mansfera.lynxreminders.data.DeviceStore
import com.mansfera.lynxreminders.data.LocalStore
import com.mansfera.lynxreminders.notify.Channels
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

object Perms {
    fun has(context: Context, p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
    fun fineLocation(c: Context) = has(c, Manifest.permission.ACCESS_FINE_LOCATION)
    fun backgroundLocation(c: Context) = has(c, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    fun bluetooth(c: Context) = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || has(c, Manifest.permission.BLUETOOTH_CONNECT)
    fun notifications(c: Context) = Build.VERSION.SDK_INT < 33 || has(c, Manifest.permission.POST_NOTIFICATIONS)

    @Suppress("DEPRECATION")
    fun usageAccess(c: Context): Boolean {
        val ops = c.getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= 29) ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), c.packageName)
        else ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), c.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }
}

/** Keeps device-side trigger machinery in line with the local store (SPEC §6). */
class TriggerManager(private val context: Context, private val store: LocalStore, private val device: DeviceStore) {
    private val geo by lazy { LocationServices.getGeofencingClient(context) }

    private fun geofencePending(): PendingIntent = PendingIntent.getBroadcast(
        context, 7, Intent(context, GeofenceReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE, // mutable: Play Services adds the event
    )

    fun refresh(fromBackground: Boolean = false) {
        refreshGeofences()
        refreshAppWatcher(fromBackground)
    }

    @SuppressLint("MissingPermission")
    fun refreshGeofences() {
        val rows = store.value.liveReminders()
        if (!Perms.fineLocation(context) || !Perms.backgroundLocation(context)) return
        val selected = TriggerMatching.geofenceSelection(rows, MAX_GEOFENCES, null, null)
        // Signature includes the region so an edited radius/position re-registers
        val ids = selected.map { r -> r.location!!.let { "${r.id}:${it.lat}:${it.lon}:${it.radius}:${it.on}" } }.toSet()
        if (ids == device.value.registeredGeofences) return
        try {
            geo.removeGeofences(geofencePending()).addOnCompleteListener {
                if (selected.isEmpty()) { device.edit { it.copy(registeredGeofences = emptySet()) }; return@addOnCompleteListener }
                val fences = selected.map { r ->
                    val l = r.location!!
                    Geofence.Builder()
                        .setRequestId(r.id)
                        .setCircularRegion(l.lat, l.lon, l.radius.toFloat().coerceIn(100f, 2000f))
                        .setExpirationDuration(Geofence.NEVER_EXPIRE)
                        .setTransitionTypes(if (l.on == "leave") Geofence.GEOFENCE_TRANSITION_EXIT else Geofence.GEOFENCE_TRANSITION_ENTER)
                        .build()
                }
                // No initial trigger: being inside already is not an "arrive"
                val req = GeofencingRequest.Builder().setInitialTrigger(0).addGeofences(fences).build()
                geo.addGeofences(req, geofencePending())
                    .addOnSuccessListener { device.edit { it.copy(registeredGeofences = ids) } }
                    .addOnFailureListener { e -> Log.w("Lynx", "geofences not added", e) }
            }
        } catch (e: Exception) {
            Log.w("Lynx", "geofencing unavailable", e)
        }
    }

    fun hasAppTriggers() = store.value.liveReminders().any { it.isOpen && it.appTrigger != null }

    fun refreshAppWatcher(fromBackground: Boolean) {
        val want = hasAppTriggers() && Perms.usageAccess(context)
        val i = Intent(context, AppWatchService::class.java)
        try {
            if (want) ContextCompat.startForegroundService(context, i) else context.stopService(i)
        } catch (e: Exception) {
            // Background FGS start restrictions: the app start / boot path will start it next time
            Log.w("Lynx", "app watcher not started (background=$fromBackground)", e)
        }
    }

    companion object {
        /** Play Services allows 100 geofences per app. */
        const val MAX_GEOFENCES = 100
    }
}

class GeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val ev = GeofencingEvent.fromIntent(intent) ?: return
        if (ev.hasError()) return
        val entered = ev.geofenceTransition == Geofence.GEOFENCE_TRANSITION_ENTER
        val g = (context.applicationContext as LynxApp).graph
        val pr = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                for (f in ev.triggeringGeofences.orEmpty()) {
                    g.firer.handle(ContextEvent.Location(f.requestId, entered)) { r ->
                        val name = r.location?.name ?: "location"
                        if (entered) "Arrived at $name" else "Left $name"
                    }
                }
            } finally {
                pr.finish()
            }
        }
    }
}

class BluetoothReceiver : BroadcastReceiver() {
    @SuppressLint("MissingPermission")
    override fun onReceive(context: Context, intent: Intent) {
        val connected = when (intent.action) {
            BluetoothDevice.ACTION_ACL_CONNECTED -> true
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> false
            else -> return
        }
        val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        val name = try { if (Perms.bluetooth(context)) dev?.name else null } catch (_: SecurityException) { null }
        val g = (context.applicationContext as LynxApp).graph
        val pr = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                g.firer.handle(ContextEvent.Bluetooth(name, dev?.address, connected)) { r ->
                    val n = r.bluetooth?.name ?: name ?: "device"
                    if (connected) "Connected to $n" else "Disconnected from $n"
                }
            } finally {
                pr.finish()
            }
        }
    }
}

/** Paired devices for the picker (§6.3). */
object BluetoothDevices {
    data class Bonded(val name: String, val address: String)

    @SuppressLint("MissingPermission")
    fun bonded(context: Context): List<Bonded> {
        if (!Perms.bluetooth(context)) return emptyList()
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return emptyList()
        return try {
            adapter.bondedDevices.orEmpty().map { Bonded(it.name ?: it.address, it.address) }.sortedBy { it.name.lowercase() }
        } catch (_: SecurityException) {
            emptyList()
        }
    }
}

/** Launchable apps for the picker (§6.4). */
object LaunchableApps {
    data class App(val label: String, val packageName: String)

    fun list(context: Context): List<App> {
        val pm = context.packageManager
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(i, 0)
            .map { App(it.loadLabel(pm).toString(), it.activityInfo.packageName) }
            .filter { it.packageName != context.packageName }
            .distinctBy { it.packageName }
            .sortedBy { it.label.lowercase() }
    }

    fun label(context: Context, pkg: String): String? = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        null
    }
}

/**
 * "App opened" triggers: polls UsageStatsManager.queryEvents every 3 s while reminders with app
 * triggers exist. Foreground service (specialUse) with a minimum-importance notification.
 */
class AppWatchService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n: Notification = NotificationCompat.Builder(this, Channels.WATCH)
            .setSmallIcon(R.drawable.ic_stat_etherlynx)
            .setContentTitle("Watching for app triggers")
            .setContentText("Reminders fire when you open the apps you picked")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .build()
        try {
            ServiceCompat.startForeground(this, 42, n, if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
        } catch (e: Exception) {
            Log.w("Lynx", "cannot start app watcher", e); stopSelf(); return START_NOT_STICKY
        }
        if (job == null) job = scope.launch { poll() }
        return START_STICKY
    }

    private suspend fun poll() {
        val g = (applicationContext as LynxApp).graph
        val usm = getSystemService(UsageStatsManager::class.java)
        var last = System.currentTimeMillis()
        var lastPkg: String? = null
        while (scope.isActive) {
            delay(3_000)
            if (!g.triggers.hasAppTriggers() || !Perms.usageAccess(this)) { stopSelf(); return }
            val now = System.currentTimeMillis()
            val events = usm.queryEvents(last, now)
            last = now
            val e = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(e)
                if (e.eventType != UsageEvents.Event.ACTIVITY_RESUMED) continue
                val pkg = e.packageName
                if (pkg == lastPkg || pkg == packageName) continue
                lastPkg = pkg
                val label = LaunchableApps.label(this, pkg)
                g.firer.handle(ContextEvent.AppOpened(pkg, label)) { r -> "Opened ${r.appTrigger?.name ?: label ?: pkg}" }
            }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
