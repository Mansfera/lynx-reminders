package com.mansfera.lynxreminders.remote

import android.util.Log
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import com.mansfera.lynxreminders.core.ListRow
import com.mansfera.lynxreminders.core.QuickAddAI
import com.mansfera.lynxreminders.core.QuickAddResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId

/**
 * Quick add read by Gemini Nano on the phone (SPEC §7a), through ML Kit's Prompt API and AICore: free, private,
 * no key. Only some phones have it; [status] says whether this one does.
 */
class OnDeviceAI(private val scope: CoroutineScope) {
    enum class Status(val label: String) {
        CHECKING("Checking…"),
        AVAILABLE("Ready"),
        DOWNLOADABLE("Ready to download"),
        DOWNLOADING("Downloading…"),
        UNAVAILABLE("Not on this phone");

        /** Worth showing in Settings: usable now, or after a download. */
        val shown get() = this == AVAILABLE || this == DOWNLOADABLE || this == DOWNLOADING
    }

    private val model: GenerativeModel? by lazy { runCatching { Generation.getClient() }.getOrNull() }
    private val _status = MutableStateFlow(Status.CHECKING)
    val status: StateFlow<Status> = _status.asStateFlow()

    init { refresh() }

    fun refresh() {
        if (_status.value == Status.DOWNLOADING) return
        scope.launch {
            _status.value = try {
                when (model?.checkStatus()) {
                    FeatureStatus.AVAILABLE -> Status.AVAILABLE
                    FeatureStatus.DOWNLOADABLE -> Status.DOWNLOADABLE
                    FeatureStatus.DOWNLOADING -> Status.DOWNLOADING
                    else -> Status.UNAVAILABLE
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.i("Lynx", "Gemini Nano unavailable", e)
                Status.UNAVAILABLE
            }
        }
    }

    /** Asks AICore to download Gemini Nano (the system manages the download). */
    fun download() {
        val m = model ?: return
        _status.value = Status.DOWNLOADING
        scope.launch {
            try {
                m.download().collect { s ->
                    when (s) {
                        is DownloadStatus.DownloadCompleted -> _status.value = Status.AVAILABLE
                        is DownloadStatus.DownloadFailed -> { Log.w("Lynx", "Gemini Nano download failed", s.e); _status.value = Status.DOWNLOADABLE }
                        else -> Unit
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w("Lynx", "Gemini Nano download failed", e)
                _status.value = Status.DOWNLOADABLE
            }
        }
    }

    /** No structured outputs here: the prompt asks for JSON and [QuickAddAI.parseLenient] reads the reply. */
    suspend fun read(text: String, lists: List<ListRow>, now: Instant, zone: ZoneId): QuickAddResult {
        val m = model ?: throw IllegalStateException("$NAME isn't on this phone.")
        val system = QuickAddAI.SYSTEM_PROMPT + "\n\n" + QuickAddAI.JSON_FORMAT
        val user = QuickAddAI.userMessage(text, lists, now, zone)
        val request = if (runCatching { m.isSystemPromptAvailable() }.getOrDefault(false)) {
            generateContentRequest(SystemInstruction(system), TextPart(user)) { temperature = 0f; maxOutputTokens = 400 }
        } else {
            generateContentRequest(TextPart("$system\n\n$user")) { temperature = 0f; maxOutputTokens = 400 }
        }
        val reply = try {
            m.generateContent(request).candidates.firstOrNull()?.text.orEmpty()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w("Lynx", "Gemini Nano failed", e)
            throw IllegalStateException("$NAME couldn't read it.")
        }
        return try {
            QuickAddAI.parseLenient(reply, text, lists, now, zone)
        } catch (e: Exception) {
            throw IllegalStateException("$NAME's answer couldn't be read.")
        }
    }

    companion object { const val NAME = "Gemini Nano" }
}
