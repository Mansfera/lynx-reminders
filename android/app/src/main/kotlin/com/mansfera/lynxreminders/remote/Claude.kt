package com.mansfera.lynxreminders.remote

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import com.anthropic.client.AnthropicClient
import com.anthropic.client.okhttp.AnthropicOkHttpClient
import com.anthropic.core.JsonValue
import com.anthropic.errors.AnthropicServiceException
import com.anthropic.models.beta.messages.BetaJsonOutputFormat
import com.anthropic.models.beta.messages.BetaOutputConfig
import com.anthropic.models.beta.messages.BetaStopReason
import com.anthropic.models.beta.messages.MessageCreateParams
import com.anthropic.models.models.ModelListParams
import com.mansfera.lynxreminders.core.ListRow
import com.mansfera.lynxreminders.core.QuickAddAI
import com.mansfera.lynxreminders.core.QuickAddResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.security.KeyStore
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The user's own Anthropic API key, encrypted with a device-bound Keystore key in `claude-key.bin` (excluded from
 * backups, like the session). It is only ever sent to api.anthropic.com.
 */
class ClaudeKeyVault(context: Context) {
    private val file = File(context.filesDir, "claude-key.bin")
    private val alias = "xyz.etherlynx.reminders.claude"

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

    fun save(apiKey: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val out = byteArrayOf(c.iv.size.toByte()) + c.iv + c.doFinal(apiKey.toByteArray())
        val tmp = File(file.parentFile, "claude-key.bin.tmp")
        tmp.writeBytes(out)
        tmp.renameTo(file)
    }

    fun load(): String? = try {
        if (!file.exists()) null else {
            val bytes = file.readBytes()
            val ivLen = bytes[0].toInt()
            val iv = bytes.copyOfRange(1, 1 + ivLen)
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv)) }
            String(c.doFinal(bytes.copyOfRange(1 + ivLen, bytes.size)))
        }
    } catch (e: Exception) {
        Log.w("Lynx", "Claude key unreadable; treating as not connected", e)
        null
    }

    fun clear() { file.delete() }
}

class ClaudeException(message: String) : Exception(message)

/** Quick add read by Claude (SPEC §7a) with the official Anthropic SDK and the user's own key. */
class ClaudeService(context: Context) {
    private val vault = ClaudeKeyVault(context)
    private val _connected = MutableStateFlow(vault.load() != null)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()

    private var client: Pair<String, AnthropicClient>? = null

    private val _models = MutableStateFlow<List<QuickAddAI.ModelOption>>(emptyList())
    /** Models the key can use that can read quick add, newest first (empty until loaded). */
    val models: StateFlow<List<QuickAddAI.ModelOption>> = _models.asStateFlow()

    @Synchronized
    private fun client(apiKey: String): AnthropicClient {
        client?.let { (k, c) -> if (k == apiKey) return c else c.close() }
        return AnthropicOkHttpClient.builder().apiKey(apiKey).timeout(Duration.ofSeconds(45)).maxRetries(1).build()
            .also { client = apiKey to it }
    }

    /** Checks the key with a free call (listing models), then keeps it. Returns the usable models. */
    suspend fun connect(apiKey: String): List<QuickAddAI.ModelOption> = withContext(Dispatchers.IO) {
        val key = apiKey.trim()
        val list = friendly { listModels(key) }
        vault.save(key)
        _connected.value = true
        _models.value = list
        list
    }

    /** Refreshes the model list; quietly keeps the old one when offline. */
    suspend fun loadModels(): List<QuickAddAI.ModelOption> = withContext(Dispatchers.IO) {
        val key = vault.load() ?: return@withContext emptyList()
        runCatching { listModels(key) }.onSuccess { _models.value = it }.getOrDefault(_models.value)
    }

    /** Models with structured outputs, effort `low` and adaptive thinking, in the API's order (newest first). */
    private fun listModels(key: String): List<QuickAddAI.ModelOption> =
        client(key).models().list(ModelListParams.builder().limit(1000L).build()).autoPager().mapNotNull { m ->
            val ok = runCatching {
                val caps = m.capabilities().orElse(null) ?: return@runCatching false
                caps.structuredOutputs().supported() && caps.effort().low().supported() && caps.thinking().types().adaptive().supported()
            }.getOrDefault(false)
            if (ok) QuickAddAI.ModelOption(m.id(), m.displayName()) else null
        }

    fun disconnect() {
        vault.clear()
        synchronized(this) { client?.second?.close(); client = null }
        _connected.value = false
        _models.value = emptyList()
    }

    /**
     * Reads one quick-add line. Structured outputs keep the answer to [QuickAddAI.schema]; low effort keeps it quick.
     * On models that take them, server-side fallbacks let another model answer if a safety classifier declines.
     */
    suspend fun read(text: String, model: String, lists: List<ListRow>, now: Instant, zone: ZoneId): QuickAddResult = withContext(Dispatchers.IO) {
        val key = vault.load() ?: throw ClaudeException("Claude isn't connected.")
        val schema = BetaJsonOutputFormat.Schema.builder().apply {
            QuickAddAI.schema.forEach { (k, v) -> putAdditionalProperty(k, JsonValue.from(v)) }
        }.build()
        val params = MessageCreateParams.builder()
            .model(model)
            .maxTokens(16000L)
            .system(QuickAddAI.SYSTEM_PROMPT)
            .addUserMessage(QuickAddAI.userMessage(text, lists, now, zone))
            .outputConfig(
                BetaOutputConfig.builder()
                    .effort(BetaOutputConfig.Effort.LOW)
                    .format(BetaJsonOutputFormat.builder().schema(schema).build())
                    .build(),
            )
            .apply { if (QuickAddAI.usesServerFallbacks(model)) addBeta("server-side-fallback-2026-07-01").fallbacksDefault() }
            .build()
        val message = friendly { client(key).beta().messages().create(params) }
        if (message.stopReason().orElse(null) == BetaStopReason.REFUSAL) throw ClaudeException("Claude declined to read this.")
        val answer = message.content().mapNotNull { it.text().orElse(null)?.text() }.joinToString("")
        try {
            QuickAddAI.parse(answer, text, lists, now, zone)
        } catch (e: Exception) {
            throw ClaudeException("Claude's answer couldn't be read.")
        }
    }

    private inline fun <T> friendly(block: () -> T): T = try {
        block()
    } catch (e: AnthropicServiceException) {
        throw ClaudeException(
            when (e.statusCode()) {
                401, 403 -> "Anthropic didn't accept this key."
                429, 529 -> "Claude is busy right now."
                400 if e.message.orEmpty().contains("credit balance", true) -> "Your Anthropic account is out of credit."
                else -> e.message?.lineSequence()?.first()?.take(140) ?: "Anthropic answered ${e.statusCode()}."
            },
        )
    }
}
