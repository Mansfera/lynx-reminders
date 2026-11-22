package com.mansfera.lynxreminders.remote

import android.app.Activity
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.annotations.SupabaseExperimental
import io.github.jan.supabase.auth.auth
import com.mansfera.lynxreminders.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant

/** A passkey registered on the account (Account screen). */
data class PasskeyInfo(val id: String, val name: String?, val createdAt: Instant)

/** The user closed the passkey sheet: not an error worth showing. */
class PasskeyCancelled : Exception("No passkey was used.")

/**
 * Passkey sign-in (SPEC §9): Supabase Auth issues the WebAuthn options and verifies the result;
 * Credential Manager runs the passkey prompt. The relying party is `reminders.etherlynx.xyz`, which
 * serves `/.well-known/assetlinks.json` for this app, and the server accepts this app's
 * `android:apk-key-hash:` origin (backend/supabase/config.toml).
 * supabase-kt marks its passkey API experimental. Its 3.9.0 option models decode `expires_at` as an
 * ISO date while Supabase Auth sends Unix seconds, so the two `…/options` calls go through [options].
 */
@OptIn(SupabaseExperimental::class)
class Passkeys(private val client: SupabaseClient) {

    /** Signs in with a passkey; the session is stored and the session status turns Authenticated. */
    suspend fun signIn(activity: Activity) {
        val start = options("passkeys/authentication/options", accessToken = null)
        val request = GetCredentialRequest(listOf(GetPublicKeyCredentialOption(start.options.toString())))
        val credential = try {
            CredentialManager.create(activity).getCredential(activity, request).credential
        } catch (e: GetCredentialCancellationException) {
            throw PasskeyCancelled()
        } catch (e: NoCredentialException) {
            throw Exception("There's no Lynx passkey on this phone. Sign in with your email, then add one under Account.")
        } catch (e: GetCredentialException) {
            throw Exception(e.errorMessage?.toString() ?: "The passkey couldn't be used.")
        }
        val json = (credential as? PublicKeyCredential)?.authenticationResponseJson
            ?: throw Exception("That wasn't a passkey.")
        client.auth.passkeys.verifyAuthentication(start.challengeId, json)
    }

    /** Creates a passkey for the signed-in account. */
    suspend fun add(activity: Activity) {
        val token = client.auth.currentAccessTokenOrNull() ?: throw Exception("Sign in again to add a passkey.")
        val start = options("passkeys/registration/options", token)
        val response = try {
            CredentialManager.create(activity).createCredential(activity, CreatePublicKeyCredentialRequest(start.options.toString()))
        } catch (e: CreateCredentialCancellationException) {
            throw PasskeyCancelled()
        } catch (e: CreateCredentialException) {
            throw Exception(e.errorMessage?.toString() ?: "The passkey couldn't be created.")
        }
        val json = (response as? CreatePublicKeyCredentialResponse)?.registrationResponseJson
            ?: throw Exception("No passkey was created.")
        client.auth.passkeys.verifyRegistration(start.challengeId, json)
    }

    suspend fun list(): List<PasskeyInfo> = client.auth.passkeys.list()
        .map { PasskeyInfo(it.id, it.friendlyName, Instant.ofEpochMilli(it.createdAt.toEpochMilliseconds())) }
        .sortedBy { it.createdAt }

    suspend fun rename(id: String, name: String) {
        client.auth.passkeys.update(id, name.trim())
    }

    suspend fun remove(id: String) = client.auth.passkeys.delete(id)

    private class Challenge(val challengeId: String, val options: JsonObject)

    /** POSTs to an `auth/v1/…/options` endpoint and reads `challenge_id` and the W3C options. */
    private suspend fun options(path: String, accessToken: String?): Challenge = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(BuildConfig.SUPABASE_URL.trimEnd('/') + "/auth/v1/" + path)
            .header("apikey", BuildConfig.SUPABASE_ANON_KEY)
            .header("Authorization", "Bearer " + (accessToken ?: BuildConfig.SUPABASE_ANON_KEY))
            .post("{}".toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(request).execute().use { res ->
            val body = res.body.string()
            val json = runCatching { Json.parseToJsonElement(body).jsonObject }.getOrNull()
            if (!res.isSuccessful || json == null) {
                val msg = json?.let { j -> listOf("msg", "message", "error_description", "error").firstNotNullOfOrNull { (j[it] as? JsonPrimitive)?.content } }
                throw Exception(msg ?: "Passkeys aren't available right now (${res.code}).")
            }
            val id = (json["challenge_id"] as? JsonPrimitive)?.content ?: throw Exception("The server didn't send a passkey challenge.")
            val options = json["options"]?.jsonObject ?: throw Exception("The server didn't send passkey options.")
            // Credential Manager wants the bare W3C options JSON; unwrap `{ "publicKey": … }` if the server sends it.
            Challenge(id, options["publicKey"]?.jsonObject ?: options)
        }
    }

    private companion object {
        val http = OkHttpClient()
    }
}
