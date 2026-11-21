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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
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
 * supabase-kt marks its passkey API experimental.
 */
@OptIn(SupabaseExperimental::class)
class Passkeys(private val client: SupabaseClient) {

    /** Signs in with a passkey; the session is stored and the session status turns Authenticated. */
    suspend fun signIn(activity: Activity) {
        val start = client.auth.passkeys.startAuthentication()
        val request = GetCredentialRequest(listOf(GetPublicKeyCredentialOption(w3c(start.options).toString())))
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
        val start = client.auth.passkeys.startRegistration()
        val response = try {
            CredentialManager.create(activity).createCredential(activity, CreatePublicKeyCredentialRequest(w3c(start.options).toString()))
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

    suspend fun remove(id: String) = client.auth.passkeys.delete(id)

    // Credential Manager wants the bare W3C options JSON; unwrap `{ "publicKey": … }` if the server sends it.
    private fun w3c(options: JsonObject): JsonObject = options["publicKey"]?.jsonObject ?: options
}
