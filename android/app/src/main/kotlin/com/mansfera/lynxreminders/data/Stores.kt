package com.mansfera.lynxreminders.data

import com.mansfera.lynxreminders.core.QuickAddAI
import android.util.Log
import com.mansfera.lynxreminders.core.DbStore
import com.mansfera.lynxreminders.core.InstantS
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.LynxJson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.File

/**
 * A JSON file in filesDir exposed as a StateFlow. Writes are debounced (300 ms) and atomic
 * (temp file + rename), so a crash mid-write never leaves a torn file.
 */
@OptIn(FlowPreview::class)
open class JsonFileState<T>(
    private val file: File,
    private val serializer: KSerializer<T>,
    default: () -> T,
    scope: CoroutineScope,
) {
    private val lock = Any()
    private val _state = MutableStateFlow(load() ?: default())
    val state: StateFlow<T> = _state.asStateFlow()
    val value: T get() = _state.value

    init {
        _state.drop(1).debounce(300).onEach { write(it) }.launchIn(CoroutineScope(scope.coroutineContext + Dispatchers.IO))
    }

    private fun load(): T? = try {
        if (file.exists()) LynxJson.decodeFromString(serializer, file.readText()) else null
    } catch (e: Exception) {
        Log.e("Lynx", "Could not read ${file.name}; keeping a copy and starting fresh", e)
        file.copyTo(File(file.parentFile, file.name + ".corrupt"), overwrite = true)
        null
    }

    /** Atomic read-modify-write. The transform must be pure. */
    fun edit(transform: (T) -> T): T = synchronized(lock) {
        val next = transform(_state.value)
        _state.value = next
        next
    }

    /** Writes now (used by broadcast receivers before the process may be killed). */
    fun flush() = write(_state.value)

    @Synchronized
    private fun write(v: T) {
        try {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(LynxJson.encodeToString(serializer, v))
            if (!tmp.renameTo(file)) {
                file.delete(); tmp.renameTo(file)
            }
        } catch (e: Exception) {
            Log.e("Lynx", "Could not write ${file.name}", e)
        }
    }
}

class LocalStore(file: File, scope: CoroutineScope) :
    JsonFileState<LocalDb>(file, LocalDb.serializer(), { LocalDb() }, scope), DbStore {
    override val current: LocalDb get() = value
    override suspend fun update(transform: (LocalDb) -> LocalDb) { edit(transform) }
}

/** User settings (SPEC §10). Local to the device. */
@Serializable
data class Settings(
    @SerialName("all_day_alert_time") val allDayAlertTime: String = "09:00",
    @SerialName("default_early_alert") val defaultEarlyAlert: Int? = null,
    @SerialName("default_snooze") val defaultSnooze: Int = 10,
    @SerialName("show_completed") val showCompleted: Boolean = false,
    @SerialName("default_list_id") val defaultListId: String? = null,
    @SerialName("welcome_done") val welcomeDone: Boolean = false,
    /** Quick add is read by AI (Claude or the on-device model) when one is ready. The field's label toggles it. */
    @SerialName("ai_reads_quick_add") val aiReadsQuickAdd: Boolean = true,
    /** Which AI reads quick add when both are ready: "claude" or "device" ([QuickAddAI.Reader]). */
    @SerialName("quick_add_reader") val quickAddReader: String = "claude",
    /** The Claude model that reads quick add (an API model id). */
    @SerialName("claude_model") val claudeModel: String = QuickAddAI.DEFAULT_MODEL,
)

/** Local-only state that must never sync (SPEC §4): snoozes, cooldowns, scheduled ids. */
@Serializable
data class DeviceState(
    val settings: Settings = Settings(),
    /** reminder id → snoozed until */
    val snoozes: Map<String, InstantS> = emptyMap(),
    /** reminder id → last context trigger fire (drives the nag after a context alert) */
    @SerialName("context_fired") val contextFired: Map<String, InstantS> = emptyMap(),
    /** "<reminder id>|<kind>" → last fire, for the 15 min cooldown */
    val cooldowns: Map<String, InstantS> = emptyMap(),
    /** notification ids currently scheduled with AlarmManager */
    @SerialName("scheduled_alarms") val scheduledAlarms: Set<String> = emptySet(),
    @SerialName("registered_geofences") val registeredGeofences: Set<String> = emptySet(),
)

class DeviceStore(file: File, scope: CoroutineScope) :
    JsonFileState<DeviceState>(file, DeviceState.serializer(), { DeviceState() }, scope)
