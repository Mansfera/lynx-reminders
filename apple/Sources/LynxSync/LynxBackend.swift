import Foundation
import LynxCore
@_spi(Experimental) import Supabase

/// `Supabase.json` bundled with the app: `{ "url": "...", "anon_key": "...", "passkey_page": "..." }`.
public struct BackendConfig: Codable, Sendable, Equatable {
    public var url: URL
    public var anonKey: String
    /// The hosted passkey page on the WebAuthn relying party's domain (SPEC §9). Nil hides passkeys,
    /// e.g. for the local stack, whose Auth server can't verify passkeys for that domain.
    public var passkeyPage: URL?

    enum CodingKeys: String, CodingKey {
        case url
        case anonKey = "anon_key"
        case passkeyPage = "passkey_page"
    }

    public init(url: URL, anonKey: String, passkeyPage: URL? = nil) {
        self.url = url
        self.anonKey = anonKey
        self.passkeyPage = passkeyPage
    }

    /// Reads `Supabase.json` from the bundle; nil when it is missing or malformed (the app then stays local-only).
    public static func load(bundle: Bundle = .main) -> BackendConfig? {
        guard let url = bundle.url(forResource: "Supabase", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(BackendConfig.self, from: data),
              !cfg.anonKey.isEmpty
        else { return nil }
        return cfg
    }
}

/// Session storage in a JSON file — only for scratch/demo data folders, so test runs never touch the
/// real Keychain session.
public final class FileSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(folder: URL) { url = folder.appendingPathComponent("session.json") }

    private func load() -> [String: Data] {
        (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))) ?? [:]
    }

    public func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[key] = value
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    public func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return load()[key]
    }

    public func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[key] = nil
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}

public struct SignedInUser: Sendable, Equatable {
    public var id: UUID
    public var email: String?
}

public struct PasskeyInfo: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
}

public enum PasskeyError: LocalizedError, Equatable {
    /// This build has no passkey page configured.
    case unavailable
    /// The user went back without using a passkey.
    case cancelled
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Passkeys aren't set up for this server."
        case .cancelled: return "No passkey was used."
        case .server(let m): return m
        }
    }
}

public enum AuthOutcome: Sendable, Equatable {
    case signedIn(SignedInUser)
    /// Sign-up succeeded but the server wants the email confirmed first.
    case confirmEmail
}

/// The Supabase connection: auth (session in the Keychain), the RemoteStore for sync, sharing RPCs, realtime.
public final class LynxBackend: Sendable {
    public let config: BackendConfig
    public let client: SupabaseClient

    /// `sessionStorage` defaults to the Keychain (service `com.mansfera.lynxreminders`, SPEC §9).
    public convenience init(config: BackendConfig, sessionFolder: URL) {
        self.init(config: config, sessionStorage: FileSessionStorage(folder: sessionFolder))
    }

    public init(config: BackendConfig, sessionStorage: (any AuthLocalStorage)? = nil) {
        self.config = config
        let storage = sessionStorage ?? KeychainLocalStorage(service: LynxPaths.appId)
        client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            options: SupabaseClientOptions(
                db: .init(encoder: LynxJSON.encoder(), decoder: LynxJSON.decoder()),
                auth: .init(storage: storage, flowType: .implicit, emitLocalSessionAsInitialSession: true),
                global: .init(logger: nil)
            )
        )
    }

    // MARK: Auth

    public var currentUser: SignedInUser? {
        guard let u = client.auth.currentUser else { return nil }
        return SignedInUser(id: u.id, email: u.email)
    }

    /// Restores the stored session (refreshing it if needed). Nil when there is none or it is unusable.
    public func restoreSession() async -> SignedInUser? {
        do {
            let s = try await client.auth.session
            return SignedInUser(id: s.user.id, email: s.user.email)
        } catch {
            // Offline with a stored session: keep the user signed in locally; sync retries later.
            return currentUser
        }
    }

    public func signUp(email: String, password: String) async throws -> AuthOutcome {
        let r = try await client.auth.signUp(email: email, password: password)
        switch r {
        case .session(let s): return .signedIn(SignedInUser(id: s.user.id, email: s.user.email))
        case .user: return .confirmEmail
        }
    }

    public func signIn(email: String, password: String) async throws -> SignedInUser {
        let s = try await client.auth.signIn(email: email, password: password)
        return SignedInUser(id: s.user.id, email: s.user.email)
    }

    /// "Email me a code": sends a one-time code (creates the account if the email is new).
    public func sendCode(email: String) async throws {
        try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    public func verifyCode(email: String, code: String) async throws -> SignedInUser {
        let r = try await client.auth.verifyOTP(email: email, token: code, type: .email)
        switch r {
        case .session(let s): return SignedInUser(id: s.user.id, email: s.user.email)
        case .user(let u): return SignedInUser(id: u.id, email: u.email)
        }
    }

    public func signOut() async {
        try? await client.auth.signOut(scope: .local)
    }

    // MARK: Passkeys (SPEC §9)
    //
    // Native passkeys on Apple platforms need the Associated Domains entitlement, i.e. a paid Apple
    // developer team. Without one the app opens the passkey page on the relying party's domain in a
    // browser sheet (ASWebAuthenticationSession); the page runs WebAuthn against Supabase Auth and
    // hands the result back to `lynxreminders://auth-callback`. These helpers build that URL and read
    // the callback; the UI drives the sheet.

    public static let passkeyCallbackScheme = "lynxreminders"

    public var supportsPasskeys: Bool { config.passkeyPage != nil }

    /// URL for the passkey sign-in sheet. `state` must come back unchanged in the callback.
    public func passkeySignInURL(state: String) throws -> URL {
        try passkeyURL(mode: "signin", state: state, accessToken: nil)
    }

    /// URL for the "add a passkey" sheet. Carries a fresh access token in the fragment (never sent to
    /// the web server) so the page can register the passkey for this account.
    public func passkeyAddURL(state: String) async throws -> URL {
        let session = try await client.auth.session
        return try passkeyURL(mode: "add", state: state, accessToken: session.accessToken)
    }

    private func passkeyURL(mode: String, state: String, accessToken: String?) throws -> URL {
        guard let page = config.passkeyPage,
              var c = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { throw PasskeyError.unavailable }
        c.queryItems = [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "state", value: state)]
        if let accessToken { c.fragment = "access_token=\(accessToken)" }
        guard let url = c.url else { throw PasskeyError.unavailable }
        return url
    }

    /// A random value tying a callback to the sheet this app opened.
    public static func newPasskeyState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
    }

    /// Reads the sign-in callback and stores the session it carries.
    public func completePasskeySignIn(callback: URL, state: String) async throws -> SignedInUser {
        let fragment = try Self.checkPasskeyCallback(callback, state: state)
        guard let access = fragment["access_token"], let refresh = fragment["refresh_token"] else {
            throw PasskeyError.server("The passkey page didn't return a session.")
        }
        let s = try await client.auth.setSession(accessToken: access, refreshToken: refresh)
        return SignedInUser(id: s.user.id, email: s.user.email)
    }

    /// Reads the "add a passkey" callback; throws when nothing was added.
    public func completePasskeyAdd(callback: URL, state: String) throws {
        _ = try Self.checkPasskeyCallback(callback, state: state)
        let query = Self.items(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        guard query["added"] == "1" else { throw PasskeyError.server("No passkey was added.") }
    }

    /// Checks scheme, path and `state`; maps `error=` to an error. Returns the fragment's items.
    static func checkPasskeyCallback(_ url: URL, state: String) throws -> [String: String] {
        guard url.scheme == passkeyCallbackScheme, url.host == "auth-callback",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw PasskeyError.server("Unexpected reply from the passkey page.") }
        let query = items(c.percentEncodedQuery)
        guard query["state"] == state else { throw PasskeyError.server("The passkey reply doesn't match this request.") }
        if let error = query["error"] { throw error == "cancelled" ? PasskeyError.cancelled : PasskeyError.server(error) }
        return items(c.percentEncodedFragment)
    }

    private static func items(_ s: String?) -> [String: String] {
        var c = URLComponents()
        c.percentEncodedQuery = s
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    public func passkeys() async throws -> [PasskeyInfo] {
        try await client.auth.listPasskeys()
            .map { PasskeyInfo(id: $0.id, name: $0.friendlyName, createdAt: $0.createdAt, lastUsedAt: $0.lastUsedAt) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func removePasskey(_ id: UUID) async throws {
        try await client.auth.deletePasskey(id: id)
    }

    /// `rpc/delete_account`, then the local session goes too.
    public func deleteAccount() async throws {
        try await mapErrors { try await client.rpc("delete_account").execute() }
        await signOut()
    }

    // MARK: Sharing (SPEC §3 RPCs)

    public func shareList(_ list: UUID, email: String) async throws -> ShareResult {
        try await mapErrors {
            try await client.rpc("share_list", params: ["p_list": list.uuidString, "p_email": email.lowercased()])
                .execute().value
        }
    }

    public func unshareList(_ list: UUID, user: UUID) async throws {
        try await mapErrors {
            try await client.rpc("unshare_list", params: ["p_list": list.uuidString, "p_user": user.uuidString]).execute()
        }
    }

    public func leaveList(_ list: UUID) async throws {
        try await mapErrors { try await client.rpc("leave_list", params: ["p_list": list.uuidString]).execute() }
    }

    public func shareReminder(_ reminder: UUID, email: String) async throws -> ShareResult {
        try await mapErrors {
            try await client.rpc("share_reminder", params: ["p_reminder": reminder.uuidString, "p_email": email.lowercased()])
                .execute().value
        }
    }

    public func unshareReminder(_ reminder: UUID, user: UUID) async throws {
        try await mapErrors {
            try await client.rpc("unshare_reminder", params: ["p_reminder": reminder.uuidString, "p_user": user.uuidString]).execute()
        }
    }

    public func cancelInvite(_ invite: UUID) async throws {
        try await mapErrors { try await client.rpc("cancel_invite", params: ["p_invite": invite.uuidString]).execute() }
    }

    public func updateDisplayName(_ name: String, user: UUID) async throws {
        struct Patch: Encodable { let display_name: String }
        try await mapErrors {
            try await client.from("profiles").update(Patch(display_name: name)).eq("id", value: user.uuidString).execute()
        }
    }

    public func fetchProfile(_ user: UUID) async throws -> Profile? {
        try await mapErrors {
            let rows: [Profile] = try await client.from("profiles").select().eq("id", value: user.uuidString).execute().value
            return rows.first
        }
    }

    public var remote: SupabaseRemote { SupabaseRemote(client: client) }

    // MARK: Realtime

    /// Subscribes to `postgres_changes` on the four synced tables. Any event calls `onChange`
    /// (the caller debounces a sync); a reconnect calls `onReconnect` (the caller runs the manifest).
    /// Returns a handle; cancel it to unsubscribe.
    public func startRealtime(onChange: @escaping @Sendable () -> Void,
                              onReconnect: @escaping @Sendable () -> Void) -> RealtimeHandle {
        let client = self.client
        let task = Task {
            if let token = try? await client.auth.session.accessToken {
                await client.realtimeV2.setAuth(token)
            }
            let channel = client.channel("lynx-sync")
            let streams = ["lists", "reminders", "list_members", "reminder_shares"].map {
                channel.postgresChange(AnyAction.self, schema: "public", table: $0)
            }
            await withTaskGroup(of: Void.self) { group in
                for s in streams {
                    group.addTask {
                        for await _ in s { onChange() }
                    }
                }
                group.addTask {
                    var wasConnected = false
                    for await status in client.realtimeV2.statusChange {
                        if status == .connected {
                            if wasConnected { onReconnect() }
                            wasConnected = true
                        }
                    }
                }
                group.addTask {
                    try? await channel.subscribeWithError()
                }
                await group.waitForAll()
            }
        }
        return RealtimeHandle(task: task, client: client)
    }
}

public final class RealtimeHandle: Sendable {
    let task: Task<Void, Never>
    let client: SupabaseClient

    init(task: Task<Void, Never>, client: SupabaseClient) {
        self.task = task
        self.client = client
    }

    public func stop() {
        task.cancel()
        let c = client
        Task { await c.removeAllChannels() }
    }
}

/// Maps SDK errors to `RemoteError` so the sync engine can tell RLS rejects, auth and network apart.
@discardableResult
func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let e as PostgrestError {
        if e.code == "42501" { throw RemoteError.forbidden(e.message) }
        if e.code == "PGRST301" || e.code == "PGRST302" { throw RemoteError.unauthorized }
        throw RemoteError.server(0, e.message)
    } catch let e as HTTPError {
        let msg = String(data: e.data, encoding: .utf8) ?? ""
        switch e.response.statusCode {
        case 401: throw RemoteError.unauthorized
        case 403: throw RemoteError.forbidden(msg)
        default: throw RemoteError.server(e.response.statusCode, msg)
        }
    } catch let e as URLError {
        throw RemoteError.network(e.localizedDescription)
    } catch let e as AuthError {
        if case .sessionMissing = e { throw RemoteError.unauthorized }
        throw RemoteError.server(0, e.localizedDescription)
    }
}

/// `RemoteStore` over PostgREST (SPEC §4 requests).
public struct SupabaseRemote: RemoteStore {
    let client: SupabaseClient

    public func pullLists(after version: Int64, limit: Int) async throws -> [LynxList] {
        try await mapErrors {
            try await client.from("lists").select().gt("version", value: Int(version))
                .order("version", ascending: true).limit(limit).execute().value
        }
    }

    public func pullReminders(after version: Int64, limit: Int) async throws -> [Reminder] {
        try await mapErrors {
            try await client.from("reminders").select().gt("version", value: Int(version))
                .order("version", ascending: true).limit(limit).execute().value
        }
    }

    public func fetchMembers() async throws -> [ListMember] {
        try await mapErrors { try await client.from("list_members").select("*,profile:profiles(*)").execute().value }
    }

    public func fetchShares() async throws -> [ReminderShare] {
        try await mapErrors { try await client.from("reminder_shares").select("*,profile:profiles(*)").execute().value }
    }

    public func fetchInvites() async throws -> [Invite] {
        try await mapErrors { try await client.from("invites").select().execute().value }
    }

    public func manifest() async throws -> [ManifestEntry] {
        try await mapErrors { try await client.rpc("sync_manifest").execute().value }
    }

    public func fetchLists(ids: [UUID]) async throws -> [LynxList] {
        guard !ids.isEmpty else { return [] }
        return try await mapErrors {
            try await client.from("lists").select().in("id", values: ids.map { $0.uuidString.lowercased() }).execute().value
        }
    }

    public func fetchReminders(ids: [UUID]) async throws -> [Reminder] {
        guard !ids.isEmpty else { return [] }
        return try await mapErrors {
            try await client.from("reminders").select().in("id", values: ids.map { $0.uuidString.lowercased() }).execute().value
        }
    }

    public func upsertLists(_ rows: [LynxList]) async throws -> [LynxList] {
        try await mapErrors {
            try await client.from("lists").upsert(rows, onConflict: "id", returning: .representation).execute().value
        }
    }

    public func upsertReminders(_ rows: [Reminder]) async throws -> [Reminder] {
        try await mapErrors {
            try await client.from("reminders").upsert(rows, onConflict: "id", returning: .representation).execute().value
        }
    }
}
