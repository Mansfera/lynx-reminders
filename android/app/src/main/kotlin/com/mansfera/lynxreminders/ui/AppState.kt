package com.mansfera.lynxreminders.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mansfera.lynxreminders.LynxApp
import com.mansfera.lynxreminders.core.ListRow
import com.mansfera.lynxreminders.core.QuickAddAI
import com.mansfera.lynxreminders.core.QuickAddParser
import com.mansfera.lynxreminders.core.QuickAddResult
import com.mansfera.lynxreminders.core.SmartList
import com.mansfera.lynxreminders.remote.ClaudeException
import com.mansfera.lynxreminders.remote.PasskeyCancelled
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId

sealed interface Route {
    data object Home : Route
    data class Smart(val kind: SmartList) : Route
    data class ListR(val id: String) : Route
    /** [id] of an existing reminder, or a new draft in [listId] (optionally a subtask of [parentId]). */
    data class Editor(val id: String?, val listId: String? = null, val parentId: String? = null, val key: Long = System.nanoTime()) : Route
    data class ListEdit(val id: String?) : Route
    data class Share(val listId: String? = null, val reminderId: String? = null) : Route
    data object Account : Route
    data object Auth : Route
    data object Welcome : Route
    data object Search : Route
}

/** How the back stack last changed: picks the screen transition (Motion.kt). */
enum class Nav { Push, Pop, Reset }

class AppVM(app: Application) : AndroidViewModel(app) {
    val g = (app as LynxApp).graph
    val db = g.store.state
    val device = g.device.state
    val account = g.sync.account
    val syncStatus = g.sync.status
    val repo get() = g.repo

    /** Wall clock for overdue state and the day ruler, ticking every 30 s. */
    private val _now = MutableStateFlow(Instant.now())
    val now: StateFlow<Instant> = _now.asStateFlow()

    val stack = mutableStateListOf<Route>()

    init {
        stack.add(if (g.device.value.settings.welcomeDone || g.store.value.userId != null) Route.Home else Route.Welcome)
        viewModelScope.launch {
            while (true) {
                delay(30_000); _now.value = Instant.now()
            }
        }
    }

    fun tick() { _now.value = Instant.now() }

    /** The quick-add line AI is reading right now (SPEC §7a), or null. */
    var claudeReading by mutableStateOf<String?>(null)
        private set

    /**
     * Reads a quick-add line with Claude or Gemini Nano; on any failure the local parser's reading is used and
     * [onDone] gets a short reason to show.
     */
    fun readWithAI(reader: QuickAddAI.Reader, text: String, lists: List<ListRow>, onDone: (QuickAddResult, String?) -> Unit) {
        claudeReading = text
        viewModelScope.launch {
            val zone = ZoneId.systemDefault()
            val (q, error) = try {
                when (reader) {
                    QuickAddAI.Reader.CLAUDE -> g.claude.read(text, g.device.value.settings.claudeModel, lists, Instant.now(), zone)
                    QuickAddAI.Reader.DEVICE -> g.onDevice.read(text, lists, Instant.now(), zone)
                } to null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                QuickAddParser.parse(text, Instant.now(), zone, lists) to (if (e is ClaudeException || e is IllegalStateException) e.message else friendlyError(e))
            }
            claudeReading = null
            onDone(q, error)
        }
    }

    var lastNav by mutableStateOf(Nav.Reset)
        private set

    val top: Route get() = stack.last()
    fun push(r: Route) { lastNav = Nav.Push; stack.add(r) }
    fun pop(): Boolean = if (stack.size > 1) { lastNav = Nav.Pop; stack.removeAt(stack.lastIndex); true } else false
    fun reset(r: Route) { lastNav = Nav.Reset; stack.clear(); stack.add(r) }

    /** Runs an account/network action, reporting a short error message. */
    fun run(onError: (String) -> Unit = {}, onDone: () -> Unit = {}, block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block(); onDone()
            } catch (e: PasskeyCancelled) {
                onError("") // the user closed the passkey sheet: nothing to show
            } catch (e: Exception) {
                onError(friendlyError(e))
            }
        }
    }

    companion object {
        /** The Activity behind a Compose context (Credential Manager needs one to show its sheet). */
        tailrec fun activityOf(ctx: android.content.Context): android.app.Activity = when (ctx) {
            is android.app.Activity -> ctx
            is android.content.ContextWrapper -> activityOf(ctx.baseContext)
            else -> error("No activity")
        }

        fun friendlyError(e: Exception): String {
            val m = e.message ?: e.javaClass.simpleName
            return when {
                m.contains("Invalid login", true) -> "Wrong email or password."
                m.contains("already registered", true) -> "That email already has an account. Sign in instead."
                m.contains("Password should be", true) -> "Use at least 6 characters for the password."
                m.contains("expired", true) || m.contains("invalid", true) && m.contains("otp", true) -> "That code is wrong or expired."
                m.contains("Unable to resolve", true) || m.contains("Failed to connect", true) || m.contains("timeout", true) || m.contains("ConnectException", true) ->
                    "Can't reach the server. Check the connection and try again."
                else -> m.lineSequence().first().take(140)
            }
        }
    }
}
