package com.mansfera.lynxreminders

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.mansfera.lynxreminders.data.DeviceStore
import com.mansfera.lynxreminders.data.LocalStore
import com.mansfera.lynxreminders.data.Repository
import com.mansfera.lynxreminders.remote.ClaudeService
import com.mansfera.lynxreminders.remote.OnDeviceAI
import com.mansfera.lynxreminders.notify.AlarmScheduler
import com.mansfera.lynxreminders.notify.Channels
import com.mansfera.lynxreminders.notify.ContextFirer
import com.mansfera.lynxreminders.remote.Supa
import com.mansfera.lynxreminders.sync.SyncController
import com.mansfera.lynxreminders.triggers.TriggerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/** Process-wide objects. Receivers, workers and the UI all share this one in-memory store. */
class AppGraph(app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val store = LocalStore(File(app.filesDir, "lynx-db.json"), scope)
    val device = DeviceStore(File(app.filesDir, "device-state.json"), scope)
    val alarms = AlarmScheduler(app, store, device)
    val triggers = TriggerManager(app, store, device)
    val firer = ContextFirer(app, store, device, alarms)
    val client = Supa.create(app)
    val sync = SyncController(app, client, store, scope) { changed -> if (changed) rebuildDeviceSide() }
    val repo = Repository(store, device) { onLocalChange() }
    val claude = ClaudeService(app)
    val onDevice = OnDeviceAI(scope)

    private var rebuildJob: Job? = null

    /** After an edit: rebuild alerts/triggers (debounced 300 ms) and schedule a sync (1 s). */
    private fun onLocalChange() {
        rebuildDeviceSide()
        sync.scheduleSync(1000)
    }

    @OptIn(FlowPreview::class)
    fun rebuildDeviceSide() {
        rebuildJob?.cancel()
        rebuildJob = scope.launch {
            delay(300)
            alarms.reschedule()
            triggers.refresh()
        }
    }
}

class LynxApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        Channels.create(this)
        graph = AppGraph(this)
        graph.sync.start()
        graph.rebuildDeviceSide()
        // Rebuild alerts every time the app becomes active (SPEC §5.5)
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                graph.rebuildDeviceSide()
                graph.sync.scheduleSync(300)
            }
        })
    }
}
