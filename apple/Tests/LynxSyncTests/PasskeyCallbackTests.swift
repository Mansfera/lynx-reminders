import Foundation
@testable import LynxSync
import Testing

/// The passkey page's replies to `lynxreminders://auth-callback` (SPEC §9).
struct PasskeyCallbackTests {
    let state = "abc123DEF456ghi789"

    @Test func signInReplyCarriesTokensInTheFragment() throws {
        let url = URL(string: "lynxreminders://auth-callback?state=\(state)#access_token=a.b.c&refresh_token=r1&expires_in=3600&token_type=bearer")!
        let fragment = try LynxBackend.checkPasskeyCallback(url, state: state)
        #expect(fragment["access_token"] == "a.b.c")
        #expect(fragment["refresh_token"] == "r1")
    }

    @Test func replyForAnotherRequestIsRefused() {
        let url = URL(string: "lynxreminders://auth-callback?state=someoneelse#access_token=a&refresh_token=r")!
        #expect(throws: PasskeyError.self) { try LynxBackend.checkPasskeyCallback(url, state: state) }
    }

    @Test func wrongSchemeOrHostIsRefused() {
        for s in ["https://auth-callback?state=\(state)", "lynxreminders://reminder?state=\(state)"] {
            #expect(throws: PasskeyError.self) { try LynxBackend.checkPasskeyCallback(URL(string: s)!, state: state) }
        }
    }

    @Test func goingBackIsCancelledAndOtherErrorsCarryTheMessage() {
        let back = URL(string: "lynxreminders://auth-callback?state=\(state)&error=cancelled")!
        #expect(throws: PasskeyError.cancelled) { try LynxBackend.checkPasskeyCallback(back, state: state) }
        let failed = URL(string: "lynxreminders://auth-callback?state=\(state)&error=Passkey%20not%20found")!
        #expect(throws: PasskeyError.server("Passkey not found")) { try LynxBackend.checkPasskeyCallback(failed, state: state) }
    }

    @Test func signInPageURLCarriesModeAndState() throws {
        let backend = LynxBackend(
            config: BackendConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon",
                                  passkeyPage: URL(string: "https://reminders.etherlynx.xyz/passkey/")!),
            sessionStorage: FileSessionStorage(folder: FileManager.default.temporaryDirectory)
        )
        let url = try backend.passkeySignInURL(state: state)
        #expect(url.absoluteString == "https://reminders.etherlynx.xyz/passkey/?mode=signin&state=\(state)")
        #expect(LynxBackend.newPasskeyState().count == 48)
    }

    @Test func noPasskeyPageMeansNoPasskeys() {
        let backend = LynxBackend(
            config: BackendConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon"),
            sessionStorage: FileSessionStorage(folder: FileManager.default.temporaryDirectory)
        )
        #expect(!backend.supportsPasskeys)
        #expect(throws: PasskeyError.unavailable) { try backend.passkeySignInURL(state: state) }
    }
}
