import Foundation
import XCTest
import Supabase
@testable import LynxCore
@testable import LynxSync

/// Session storage in memory, so the live tests never touch the Keychain.
final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    func store(key: String, value: Data) throws { lock.lock(); items[key] = value; lock.unlock() }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func remove(key: String) throws { lock.lock(); items[key] = nil; lock.unlock() }
}

/// End-to-end against the local Supabase from backend/ (`npx supabase start`).
/// Run with `LYNX_LIVE=1 swift test --filter LiveBackendTests`. Creates throwaway users and deletes them.
final class LiveBackendTests: XCTestCase {
    static let config = BackendConfig(
        url: URL(string: ProcessInfo.processInfo.environment["LYNX_SUPABASE_URL"] ?? "http://127.0.0.1:54321")!,
        anonKey: ProcessInfo.processInfo.environment["LYNX_SUPABASE_ANON_KEY"]
            ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    )

    struct Device {
        let backend: LynxBackend
        let user: SignedInUser
        let store: LynxStore
        let engine: SyncEngine
        var email: String { user.email ?? "" }
    }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LYNX_LIVE"] == "1", "set LYNX_LIVE=1 to run against a local Supabase")
    }

    func newDevice(_ tag: String) async throws -> Device {
        let backend = LynxBackend(config: Self.config, sessionStorage: MemoryStorage())
        let email = "lynx-apple-\(tag)-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let outcome = try await backend.signUp(email: email, password: "correct-horse-\(UUID().uuidString.prefix(6))")
        guard case .signedIn(let user) = outcome else { throw XCTSkip("email confirmation is on") }
        let store = LynxStore()
        store.write { $0.claim(for: user.id, email: email) }
        return Device(backend: backend, user: user, store: store, engine: SyncEngine(store: store, remote: backend.remote, me: user.id))
    }

    func sync(_ d: Device, manifest: Bool = false) async throws -> SyncReport {
        let r = await d.engine.syncNow(manifest: manifest)
        if let e = r.error { XCTFail("sync failed: \(e)") }
        return r
    }

    func testSignUpSyncShareAndRevoke() async throws {
        let a = try await newDevice("a")
        let b = try await newDevice("b")
        let c = try await newDevice("c")
        defer {
            for d in [a, b, c] { Task { try? await d.backend.deleteAccount() } }
        }

        // A: a list, a repeating reminder and a goal with two subtasks, created offline-first.
        let list = LynxList(ownerId: a.user.id, name: "Groceries", color: .green, icon: .cart, sortOrder: 1)
        var water = Reminder(listId: list.id, createdBy: a.user.id, title: "Water plants", sortOrder: 1, timeZone: "Europe/Bratislava")
        water.dueAt = LynxTime.parse("2026-11-15T08:00:00Z")
        water.repeat = RepeatRule(unit: .day, interval: 3, anchor: "2026-11-15T09:00")
        water.nag = Nag(everyMinutes: 10, max: nil)
        let goal = Reminder(listId: list.id, createdBy: a.user.id, title: "Party", sortOrder: 2)
        let sub1 = Reminder(listId: list.id, parentId: goal.id, createdBy: a.user.id, title: "Cake", sortOrder: 1)
        let sub2 = Reminder(listId: list.id, parentId: goal.id, createdBy: a.user.id, title: "Balloons", sortOrder: 2)
        a.store.write { db in
            db.upsertList(list)
            for r in [water, goal, sub1, sub2] { db.upsertReminder(r) }
        }
        let pushed = try await sync(a)
        XCTAssertEqual(pushed.pushed, 5)
        XCTAssertFalse(a.store.snapshot.hasDirtyRows)
        XCTAssertNotNil(a.store.snapshot.reminders[water.id]?.version)
        XCTAssertEqual(a.store.snapshot.reminders[water.id]?.repeat?.interval, 3)
        _ = try await sync(a)
        XCTAssertEqual(a.store.snapshot.members(of: list.id).first?.role, "owner", "owner row from the server trigger")

        // Share the list with B; B sees it after a sync.
        let share = try await a.backend.shareList(list.id, email: b.email)
        XCTAssertEqual(share.status, "added")
        _ = try await sync(b)
        XCTAssertEqual(b.store.snapshot.lists[list.id]?.name, "Groceries")
        XCTAssertEqual(b.store.snapshot.subtasks(of: goal.id).count, 2)
        XCTAssertEqual(b.store.snapshot.members(of: list.id).count, 2)
        XCTAssertNotNil(b.store.snapshot.members(of: list.id).first { $0.userId == a.user.id }?.profile?.email)

        // B completes a subtask; A gets the change.
        b.store.write { $0.complete(sub1.id, by: b.user.id) }
        _ = try await sync(b)
        _ = try await sync(a)
        XCTAssertEqual(a.store.snapshot.progress(of: goal.id).done, 1)
        XCTAssertEqual(a.store.snapshot.reminders[sub1.id]?.completedBy, b.user.id)

        // Last writer wins: A's older edit loses to B's newer one.
        let older = LynxTime.now()
        try await Task.sleep(nanoseconds: 20_000_000)
        b.store.write { $0.editReminder(water.id) { $0.title = "Water plants (B)" } }
        _ = try await sync(b)
        a.store.write { $0.editReminder(water.id, now: older) { $0.title = "Water plants (A, older)" } }
        _ = try await sync(a)
        XCTAssertEqual(a.store.snapshot.reminders[water.id]?.title, "Water plants (B)")
        XCTAssertFalse(a.store.snapshot.hasDirtyRows)

        // Share one reminder with C: it shows in C's "Shared with me".
        let rshare = try await a.backend.shareReminder(water.id, email: c.email)
        XCTAssertEqual(rshare.status, "added")
        _ = try await sync(c)
        let q = SmartQueries(db: c.store.snapshot, me: c.user.id, now: Date())
        XCTAssertEqual(q.reminders(.sharedWithMe).map(\.id), [water.id])
        XCTAssertNil(c.store.snapshot.lists[list.id], "the list itself is not shared")

        // RLS: C cannot rename the list it can't see — the change is dropped.
        var hijack = list
        hijack.name = "Hijacked"
        c.store.write { $0.upsertList(hijack, now: LynxTime.now()) }
        let rep = try await sync(c)
        XCTAssertGreaterThanOrEqual(rep.rejected, 1)
        XCTAssertFalse(c.store.snapshot.hasDirtyRows)
        _ = try await sync(a)
        XCTAssertEqual(a.store.snapshot.lists[list.id]?.name, "Groceries")

        // Invite for an email without an account.
        let pending = try await a.backend.shareList(list.id, email: "nobody-\(UUID().uuidString.prefix(6))@example.com")
        XCTAssertEqual(pending.status, "invited")
        _ = try await sync(a)
        XCTAssertEqual(a.store.snapshot.invites.count, 1)
        try await a.backend.cancelInvite(a.store.snapshot.invites[0].id)
        _ = try await sync(a)
        XCTAssertTrue(a.store.snapshot.invites.isEmpty)

        // Revoke B: B's manifest removes the list and its reminders.
        try await a.backend.unshareList(list.id, user: b.user.id)
        _ = try await sync(b)
        XCTAssertNil(b.store.snapshot.lists[list.id])
        XCTAssertNil(b.store.snapshot.reminders[goal.id])
    }

    func testRealtimeEventArrives() async throws {
        let a = try await newDevice("rt")
        defer { Task { try? await a.backend.deleteAccount() } }
        let got = expectation(description: "realtime event")
        got.assertForOverFulfill = false
        let handle = a.backend.startRealtime(onChange: { got.fulfill() }, onReconnect: {})
        defer { handle.stop() }
        try await Task.sleep(nanoseconds: 2_000_000_000)  // let the channel join
        a.store.write { $0.upsertList(LynxList(ownerId: a.user.id, name: "RT", sortOrder: 1)) }
        _ = try await sync(a)
        await fulfillment(of: [got], timeout: 10)
    }

    func testEmailCodeSignIn() async throws {
        let backend = LynxBackend(config: Self.config, sessionStorage: MemoryStorage())
        let email = "lynx-apple-otp-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        try await backend.sendCode(email: email)
        // Mailpit (local Supabase inbucket) receives the code.
        var code: String?
        for _ in 0..<10 where code == nil {
            try await Task.sleep(nanoseconds: 700_000_000)
            code = try await Self.latestCode(for: email)
        }
        let c = try XCTUnwrap(code, "no OTP code in Mailpit (the email template must include {{ .Token }})")
        let user = try await backend.verifyCode(email: email, code: c)
        XCTAssertEqual(user.email, email)
        try await backend.deleteAccount()
    }

    static func latestCode(for email: String) async throws -> String? {
        let base = URL(string: "http://127.0.0.1:54324")!
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/v1/search").appending(queryItems: [URLQueryItem(name: "query", value: "to:\(email)")]))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgs = json["messages"] as? [[String: Any]], let id = msgs.first?["ID"] as? String else { return nil }
        let (body, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/v1/message/\(id)"))
        guard let msg = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let text = (msg["Text"] as? String ?? "") + " " + (msg["HTML"] as? String ?? "")
        let re = try NSRegularExpression(pattern: "(?<![\\w=/.-])(\\d{6,10})(?![\\w])")
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
