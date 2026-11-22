package com.mansfera.lynxreminders.core

import kotlinx.serialization.Serializable
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A secret sealed with a PIN on the device, as the server stores it (SPEC §7b). The server never sees the PIN or
 * the secret. Same format on Apple (`SecretSeal.swift`); `shared/vectors/secret-seal.json` checks both.
 */
@Serializable
data class SealedSecret(
    val v: Int = 1,
    val kdf: String = "pbkdf2-sha256",
    val iter: Int,
    val salt: String,
    val nonce: String,
    /** AES-GCM ciphertext followed by the 16-byte tag, base64. */
    val box: String,
)

/**
 * PBKDF2-HMAC-SHA256(NFC(PIN), 16-byte salt, 600 000 rounds) → AES-256-GCM over the secret, with `context`
 * (`lynx/claude-key/v1/<user id>`) as associated data so a blob can't be moved to another account.
 */
object SecretSeal {
    const val ITERATIONS = 600_000
    /** PINs and passphrases shorter than this are refused. */
    const val MINIMUM_PIN_LENGTH = 6

    class WrongPin : Exception("That PIN doesn't unlock the key.")
    class Unsupported : Exception("This key was synced by a newer version of Lynx.")
    class ShortPin : Exception("Use at least $MINIMUM_PIN_LENGTH characters.")

    fun contextForClaudeKey(userId: String) = "lynx/claude-key/v1/${userId.lowercase()}"

    private val b64 = Base64.getEncoder()
    private val unb64 = Base64.getDecoder()

    fun seal(secret: String, pin: String, context: String, iterations: Int = ITERATIONS, salt: ByteArray? = null, nonce: ByteArray? = null): SealedSecret {
        val nfc = Normalizer.normalize(pin, Normalizer.Form.NFC)
        if (nfc.codePointCount(0, nfc.length) < MINIMUM_PIN_LENGTH) throw ShortPin()
        val s = salt ?: random(16)
        val n = nonce ?: random(12)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(derive(pin, s, iterations), "AES"), GCMParameterSpec(128, n))
        c.updateAAD(context.toByteArray())
        return SealedSecret(iter = iterations, salt = b64.encodeToString(s), nonce = b64.encodeToString(n), box = b64.encodeToString(c.doFinal(secret.toByteArray())))
    }

    fun open(sealed: SealedSecret, pin: String, context: String): String {
        if (sealed.v != 1 || sealed.kdf != "pbkdf2-sha256" || sealed.iter !in 1..10_000_000) throw Unsupported()
        val (salt, nonce, box) = try {
            Triple(unb64.decode(sealed.salt), unb64.decode(sealed.nonce), unb64.decode(sealed.box))
        } catch (e: IllegalArgumentException) {
            throw Unsupported()
        }
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(derive(pin, salt, sealed.iter), "AES"), GCMParameterSpec(128, nonce))
            c.updateAAD(context.toByteArray())
            String(c.doFinal(box))
        } catch (e: AEADBadTagException) {
            throw WrongPin()
        }
    }

    internal fun derive(pin: String, salt: ByteArray, iterations: Int) =
        pbkdf2(Normalizer.normalize(pin, Normalizer.Form.NFC).toByteArray(), salt, iterations)

    /** PBKDF2-HMAC-SHA256, one 32-byte block. Written out so the password bytes are exactly UTF-8 on every JVM. */
    internal fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(password, "HmacSHA256")) }
        var u = mac.doFinal(salt + byteArrayOf(0, 0, 0, 1))
        val t = u.copyOf()
        repeat(iterations - 1) {
            u = mac.doFinal(u)
            for (i in t.indices) t[i] = (t[i].toInt() xor u[i].toInt()).toByte()
        }
        return t
    }

    private fun random(n: Int) = ByteArray(n).also { SecureRandom().nextBytes(it) }
}
