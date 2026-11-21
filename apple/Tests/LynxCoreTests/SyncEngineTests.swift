import Foundation
import XCTest
@testable import LynxCore

/// An in-memory server with the rules from SPEC §3/§4 that the client depends on:
/// versions from one sequence, LWW by updated_at, RLS rejects for forbidden lists.
actor FakeRemote: RemoteStore {
    var lists: [UUID: LynxList] = [:]
    var reminders: [UUID: Reminder] = [:]
    var members: [ListMember] = []
    var shares: [ReminderShare] = []
    var invites: [Invite] = []
    /// Ids visible to the caller (the manifest); nil = everything.
    var visibleLists: Set<UUID>?
    var visibleReminders: Set<UUID>?
    /// Lists the caller may not write to (and reminders inside them).
    var forbiddenLists: Set<UUID> = []
    var seq: Int64 = 0
    var log: [String] = []

    func nextVersion() -> Int64 { seq += 1; return seq }

    func seed(list: LynxList) -> LynxList {
        var l = list
        l.version = nextVersion()
        lists[l.id] = l
        return l
    }

    func seed(reminder: Reminder) -> Reminder {
        var r = reminder
        r.version = nextVersion()
        reminders[r.id] = r
        return r
    }

    func setMembers(_ m: [ListMember]) { members = m }
    func setForbidden(_ ids: Set<UUID>) { forbiddenLists = ids }
    func setVisible(lists l: Set<UUID>?, reminders r: Set<UUID>?) { visibleLists = l; visibleReminders = r }
    func clearLog() { log = [] }

    private func canSeeList(_ id: UUID) -> Bool { visibleLists?.contains(id) ?? true }
    private func canSeeReminder(_ id: UUID) -> Bool { visibleReminders?.contains(id) ?? true }

    func pullLists(after version: Int64, limit: Int) async throws -> [LynxList] {
        log.append("pull lists")
        return Array(lists.values.filter { ($0.version ?? 0) > version && canSeeList($0.id) }
            .sorted { $0.version! < $1.version! }.prefix(limit))
    }

    func pullReminders(after version: Int64, limit: Int) async throws -> [Reminder] {
        log.append("pull reminders")
        return Array(reminders.values.filter { ($0.version ?? 0) > version && canSeeReminder($0.id) }
            .sorted { $0.version! < $1.version! }.prefix(limit))
    }

    func fetchMembers() async throws -> [ListMember] { members }
    func fetchShares() async throws -> [ReminderShare] { shares }
    func fetchInvites() async throws -> [Invite] { invites }

    func manifest() async throws -> [ManifestEntry] {
        log.append("manifest")
        return lists.values.filter { canSeeList($0.id) }.map { ManifestEntry(t: "lists", id: $0.id, v: $0.version!) }
            + reminders.values.filter { canSeeReminder($0.id) }.map { ManifestEntry(t: "reminders", id: $0.id, v: $0.version!) }
    }

    func fetchLists(ids: [UUID]) async throws -> [LynxList] {
        log.append("fetch lists \(ids.count)")
        return ids.compactMap { lists[$0] }.filter { canSeeList($0.id) }
    }

    func fetchReminders(ids: [UUID]) async throws -> [Reminder] {
        log.append("fetch reminders \(ids.count)")
        return ids.compactMap { reminders[$0] }.filter { canSeeReminder($0.id) }
    }

    func upsertLists(_ rows: [LynxList]) async throws -> [LynxList] {
        log.append("upsert lists " + rows.map(\.name).joined(separator: ","))
        if rows.contains(where: { forbiddenLists.contains($0.id) }) { throw RemoteError.forbidden("42501") }
        // LWW: a write older than the stored row is skipped and left out of the response (like the server).
        return rows.compactMap { row in
            if let cur = lists[row.id], row.updatedAt < cur.updatedAt { return nil }
            var r = row
            r.version = nextVersion()
            lists[r.id] = r
            return r
        }
    }

    func upsertReminders(_ rows: [Reminder]) async throws -> [Reminder] {
        log.append("upsert reminders " + rows.map(\.title).joined(separator: ","))
        if rows.contains(where: { forbiddenLists.contains($0.listId) }) { throw RemoteError.forbidden("42501") }
        return rows.compactMap { row in
            if let cur = reminders[row.id], row.updatedAt < cur.updatedAt { return nil }
            var r = row
            r.version = nextVersion()
            reminders[r.id] = r
            return r
        }
    }
}

final class SyncEngineTests: XCTestCase {
    let me = UUID()
    let t0 = LynxTime.parse("2026-11-14T08:00:00Z")!

    func list(_ name: String, at t: Date? = nil) -> LynxList {
        LynxList(ownerId: me, name: name, sortOrder: 1, now: t ?? t0)
    }

    func reminder(_ title: String, in l: LynxList, parent: UUID? = nil, at t: Date? = nil) -> Reminder {
        Reminder(listId: l.id, parentId: parent, createdBy: me, title: title, sortOrder: 1, timeZone: "Europe/Bratislava", now: t ?? t0)
    }

    // MARK: Pull merge rules

    func testPullReplacesCleanLocalRow() async throws {
        let remote = FakeRemote()
        var l = list("Home")
        l = await remote.seed(list: l)
        var db = LocalDatabase()
        var stale = l
        stale.name = "Old name"
        stale.version = 0
        db.lists[l.id] = stale  // clean
        let store = LynxStore(db)
        let engine = SyncEngine(store: store, remote: remote, me: me)
        let report = await engine.syncNow()
        XCTAssertNil(report.error)
        XCTAssertEqual(store.snapshot.lists[l.id]?.name, "Home")
        XCTAssertFalse(store.snapshot.dirtyLists.contains(l.id))
    }

    func testPullKeepsNewerDirtyLocalRowAndPushesIt() async throws {
        let remote = FakeRemote()
        let l = await remote.seed(list: list("Server name"))
        var db = LocalDatabase()
        var local = l
        local.name = "Local edit"
        local.updatedAt = t0.addingTimeInterval(60)  // newer than the server's
        db.lists[l.id] = local
        db.dirtyLists = [l.id]
        let store = LynxStore(db)
        _ = await SyncEngine(store: store, remote: remote, me: me).syncNow()
        XCTAssertEqual(store.snapshot.lists[l.id]?.name, "Local edit")
        let server = await remote.lists[l.id]
        XCTAssertEqual(server?.name, "Local edit", "the dirty row is pushed after the pull")
        XCTAssertTrue(store.snapshot.dirtyLists.isEmpty)
        XCTAssertEqual(store.snapshot.lists[l.id]?.version, server?.version)
    }

    func testPullReplacesOlderDirtyLocalRow() async throws {
        // server.updated_at >= local.updated_at → server wins even over a dirty row.
        let remote = FakeRemote()
        var serverRow = list("Server wins", at: t0.addingTimeInterval(120))
        serverRow = await remote.seed(list: serverRow)
        var db = LocalDatabase()
        var local = serverRow
        local.name = "Older local edit"
        local.updatedAt = t0.addingTimeInterval(60)
        db.lists[local.id] = local
        db.dirtyLists = [local.id]
        let store = LynxStore(db)
        _ = await SyncEngine(store: store, remote: remote, me: me).syncNow()
        XCTAssertEqual(store.snapshot.lists[local.id]?.name, "Server wins")
        XCTAssertTrue(store.snapshot.dirtyLists.isEmpty)
    }

    func testEqualTimestampsServerWins() {
        var db = LocalDatabase()
        var local = list("Local")
        local.version = 1
        db.lists[local.id] = local
        db.dirtyLists = [local.id]
        var server = local
        server.name = "Server"
        server.version = 2
        mergeLists([server], into: &db)
        XCTAssertEqual(db.lists[local.id]?.name, "Server")
        XCTAssertTrue(db.dirtyLists.isEmpty)
    }

    func testCursorAdvancesAndPagesUntilShortPage() async throws {
        let remote = FakeRemote()
        let l = await remote.seed(list: list("A"))
        for i in 0..<7 { _ = await remote.seed(reminder: reminder("r\(i)", in: l)) }
        let store = LynxStore()
        let engine = SyncEngine(store: store, remote: remote, me: me, pageSize: 3)
        _ = await engine.syncNow()
        XCTAssertEqual(store.snapshot.reminders.count, 7)
        XCTAssertEqual(store.snapshot.sync.cursorReminders, 8)
        XCTAssertEqual(store.snapshot.sync.cursorLists, 1)
        let pulls = await remote.log.filter { $0 == "pull reminders" }.count
        XCTAssertEqual(pulls, 3, "3 + 3 + 1 rows")
    }

    // MARK: Manifest

    func testManifestRemovesCleanRowsOnlyAndFetchesStaleOnes() async throws {
        let remote = FakeRemote()
        let kept = await remote.seed(list: list("Kept"))
        let lost = await remote.seed(list: list("Lost access"))
        let store = LynxStore()
        let engine = SyncEngine(store: store, remote: remote, me: me)
        _ = await engine.syncNow()
        XCTAssertEqual(store.snapshot.lists.count, 2)

        // A local, not yet pushed list (dirty) and a lost list (clean).
        let draft = list("Draft")
        store.write { $0.upsertList(draft) }
        await remote.setVisible(lists: [kept.id, draft.id], reminders: nil)
        await remote.setForbidden([])
        _ = await engine.syncNow(manifest: true)
        let snap = store.snapshot
        XCTAssertNil(snap.lists[lost.id], "clean row missing from the manifest is removed")
        XCTAssertNotNil(snap.lists[kept.id])
        XCTAssertNotNil(snap.lists[draft.id], "dirty row is kept (and pushed)")
    }

    func testManifestRefetchesRowsWithDifferentVersion() async throws {
        let remote = FakeRemote()
        let l = await remote.seed(list: list("Home"))
        var db = LocalDatabase()
        var old = l
        old.name = "Outdated"
        old.version = 0
        db.lists[l.id] = old
        // Cursor already past the row, so only the manifest can find it.
        db.sync.cursorLists = 100
        db.sync.cursorReminders = 100
        let store = LynxStore(db)
        _ = await SyncEngine(store: store, remote: remote, me: me).syncNow(manifest: true)
        XCTAssertEqual(store.snapshot.lists[l.id]?.name, "Home")
        let v1 = await remote.log.contains("fetch lists 1")
        XCTAssertTrue(v1)
    }

    func testMembershipChangeRunsManifest() async throws {
        let remote = FakeRemote()
        let l = await remote.seed(list: list("Shared"))
        let store = LynxStore()
        let engine = SyncEngine(store: store, remote: remote, me: me)
        _ = await engine.syncNow()  // first run: manifest because never ran
        await remote.clearLog()
        _ = await engine.syncNow()
        let v2 = await remote.log.contains("manifest")
        XCTAssertFalse(v2, "no manifest without a reason")
        await remote.setMembers([ListMember(listId: l.id, userId: me, role: "owner")])
        let report = await engine.syncNow()
        XCTAssertTrue(report.ranManifest)
        XCTAssertEqual(store.snapshot.members.count, 1)
    }

    // MARK: Push

    func testPushOrderListsThenParentsThenSubtasks() async throws {
        let remote = FakeRemote()
        let store = LynxStore()
        let l = list("Trip")
        let goal = reminder("Pack", in: l)
        let sub = reminder("Passport", in: l, parent: goal.id, at: t0.addingTimeInterval(-10))  // older than its parent
        store.write { db in
            db.upsertReminder(sub, now: self.t0)
            db.upsertReminder(goal, now: self.t0)
            db.upsertList(l, now: self.t0)
        }
        _ = await SyncEngine(store: store, remote: remote, me: me).syncNow()
        let upserts = await remote.log.filter { $0.hasPrefix("upsert") }
        XCTAssertEqual(upserts, ["upsert lists Trip", "upsert reminders Pack", "upsert reminders Passport"])
        XCTAssertFalse(store.snapshot.hasDirtyRows)
        XCTAssertNotNil(store.snapshot.reminders[sub.id]?.version)
    }

    func testPushSkippedByLWWIsMarkedCleanAndRefetched() async throws {
        let remote = FakeRemote()
        let l = await remote.seed(list: list("A"))
        let serverRow = await remote.seed(reminder: reminder("Newer on server", in: l, at: t0.addingTimeInterval(100)))
        var db = LocalDatabase()
        db.lists[l.id] = l
        var local = serverRow
        local.title = "Older local edit"
        local.updatedAt = t0.addingTimeInterval(50)
        local.version = serverRow.version
        db.reminders[local.id] = local
        db.dirtyReminders = [local.id]
        // The cursor is already past the row, so the pull does not see it; only the push meets the conflict.
        db.sync.cursorLists = 100
        db.sync.cursorReminders = 100
        db.sync.lastManifestAt = Date()
        let store = LynxStore(db)
        let report = await SyncEngine(store: store, remote: remote, me: me).syncNow()
        XCTAssertNil(report.error)
        XCTAssertEqual(store.snapshot.reminders[local.id]?.title, "Newer on server")
        XCTAssertFalse(store.snapshot.hasDirtyRows)
        let v3 = await remote.log.contains("fetch reminders 1")
        XCTAssertTrue(v3)
    }

    func testPushBatchesOf100() async throws {
        let remote = FakeRemote()
        let store = LynxStore()
        let l = list("Big")
        store.write { db in
            db.upsertList(l)
            for i in 0..<250 { db.upsertReminder(self.reminder("r\(i)", in: l)) }
        }
        _ = await SyncEngine(store: store, remote: remote, me: me).syncNow()
        let batches = await remote.log.filter { $0.hasPrefix("upsert reminders") }.count
        XCTAssertEqual(batches, 3)
        let v4 = await remote.reminders.count
        XCTAssertEqual(v4, 250)
    }

    func testRowEditedDuringPushStaysDirty() {
        var db = LocalDatabase()
        let l = list("A")
        db.upsertList(l, now: t0)
        let sent = db.lists[l.id]!
        db.editList(l.id, now: t0.addingTimeInterval(5)) { $0.name = "B" }  // edited while the push was in flight
        var saved = sent
        saved.version = 42
        _ = markPushed(lists: [sent], saved: [saved], in: &db)
        XCTAssertTrue(db.dirtyLists.contains(l.id))
        XCTAssertEqual(db.lists[l.id]?.name, "B")
        XCTAssertEqual(db.lists[l.id]?.version, 42)
    }

    func testRLSRejectDropsLocalChangeAndRefetches() async throws {
        let remote = FakeRemote()
        let theirs = await remote.seed(list: LynxList(ownerId: UUID(), name: "Not mine", sortOrder: 1, now: t0))
        let existing = await remote.seed(reminder: reminder("Server title", in: theirs))
        let store = LynxStore()
        let engine = SyncEngine(store: store, remote: remote, me: me)
        _ = await engine.syncNow()
        await remote.setForbidden([theirs.id])

        let mine = list("Mine")
        let ok = reminder("Allowed", in: mine)
        let newInForbidden = reminder("Sneaky new row", in: theirs)
        store.write { db in
            db.upsertList(mine)
            db.upsertReminder(ok)
            db.upsertReminder(newInForbidden)
            db.editReminder(existing.id, now: self.t0.addingTimeInterval(30)) { $0.title = "Local edit" }
        }
        let report = await engine.syncNow()
        XCTAssertNil(report.error)
        XCTAssertEqual(report.rejected, 2)
        let snap = store.snapshot
        XCTAssertEqual(snap.reminders[existing.id]?.title, "Server title", "rejected edit replaced by the server copy")
        XCTAssertNil(snap.reminders[newInForbidden.id], "rejected new row has no server copy: removed")
        XCTAssertNotNil(snap.reminders[ok.id]?.version, "the allowed row in the same batch still goes through")
        XCTAssertFalse(snap.hasDirtyRows)
    }

    func testOfflineKeepsDirtyRowsQueued() async throws {
        struct Offline: RemoteStore {
            func pullLists(after version: Int64, limit: Int) async throws -> [LynxList] { throw RemoteError.network("offline") }
            func pullReminders(after version: Int64, limit: Int) async throws -> [Reminder] { [] }
            func fetchMembers() async throws -> [ListMember] { [] }
            func fetchShares() async throws -> [ReminderShare] { [] }
            func fetchInvites() async throws -> [Invite] { [] }
            func manifest() async throws -> [ManifestEntry] { [] }
            func fetchLists(ids: [UUID]) async throws -> [LynxList] { [] }
            func fetchReminders(ids: [UUID]) async throws -> [Reminder] { [] }
            func upsertLists(_ rows: [LynxList]) async throws -> [LynxList] { rows }
            func upsertReminders(_ rows: [Reminder]) async throws -> [Reminder] { rows }
        }
        let store = LynxStore()
        let l = list("Queued")
        store.write { $0.upsertList(l) }
        let report = await SyncEngine(store: store, remote: Offline(), me: me).syncNow()
        XCTAssertNotNil(report.error)
        XCTAssertTrue(store.snapshot.dirtyLists.contains(l.id))
        XCTAssertNotNil(store.snapshot.sync.lastError)
    }

    // MARK: Accounts

    func testClaimAssignsOwnerAndQueuesEverything() {
        var db = LocalDatabase()
        let l = LynxList(ownerId: nil, name: "Local", sortOrder: 1)
        db.lists[l.id] = l
        let r = Reminder(listId: l.id, createdBy: nil, title: "x", sortOrder: 1)
        db.reminders[r.id] = r
        db.claim(for: me, email: "a@b.c")
        XCTAssertEqual(db.lists[l.id]?.ownerId, me)
        XCTAssertEqual(db.reminders[r.id]?.createdBy, me)
        XCTAssertEqual(db.dirtyLists, [l.id])
        XCTAssertEqual(db.dirtyReminders, [r.id])
    }

    func testDetachAsLocalCopyGivesFreshIds() {
        var db = LocalDatabase()
        db.accountId = me
        var l = list("Home")
        l.version = 3
        db.lists[l.id] = l
        var r = reminder("Goal", in: l)
        r.version = 4
        db.reminders[r.id] = r
        var s = reminder("Sub", in: l, parent: r.id)
        s.version = 5
        db.reminders[s.id] = s
        db.detachAsLocalCopy()
        XCTAssertNil(db.accountId)
        XCTAssertEqual(db.lists.count, 1)
        XCTAssertNil(db.lists[l.id])
        let newList = db.lists.values.first!
        XCTAssertNil(newList.ownerId)
        let newGoal = db.reminders.values.first { $0.title == "Goal" }!
        let newSub = db.reminders.values.first { $0.title == "Sub" }!
        XCTAssertEqual(newSub.parentId, newGoal.id)
        XCTAssertEqual(newGoal.listId, newList.id)
        XCTAssertNil(newGoal.version)
    }

    // MARK: Wire format

    func testReminderEncodesNullsForEmptyColumns() throws {
        let l = list("A")
        let r = reminder("x", in: l)
        let json = try JSONSerialization.jsonObject(with: LynxJSON.encoder().encode(r)) as! [String: Any]
        for key in ["due_at", "repeat", "nag", "location", "bluetooth", "app_trigger", "parent_id", "deleted_at", "completed_at"] {
            XCTAssertTrue(json.keys.contains(key), key)
            XCTAssertTrue(json[key] is NSNull, key)
        }
        XCTAssertEqual(json["created_at"] as? String, "2026-11-14T08:00:00Z")
    }

    func testParsesServerTimestampForms() {
        let a = LynxTime.parse("2026-11-14T08:00:00Z")!
        XCTAssertEqual(LynxTime.parse("2026-11-14T08:00:00+00:00"), a)
        XCTAssertEqual(LynxTime.parse("2026-11-14 09:00:00+01"), a)
        XCTAssertEqual(LynxTime.parse("2026-11-14T08:00:00.123456+00:00")!.timeIntervalSince1970, a.timeIntervalSince1970 + 0.123456, accuracy: 1e-6)
        let ms = LynxTime.parse("2026-11-14T08:00:00.120Z")!
        XCTAssertEqual(LynxTime.format(ms), "2026-11-14T08:00:00.120Z")
        let now = LynxTime.now()
        XCTAssertEqual(LynxTime.parse(LynxTime.format(now)), now, "millisecond instants round-trip exactly")
    }

    func testServerRowDecodes() throws {
        let json = """
        {"id":"0b7c3a52-1f7b-4f0e-9d4a-3e8f1b2c9a10","list_id":"5d0d3a52-1f7b-4f0e-9d4a-3e8f1b2c9a10","parent_id":null,
         "created_by":"6e0d3a52-1f7b-4f0e-9d4a-3e8f1b2c9a10","assignee_id":null,"title":"Drink water","notes":null,"url":null,
         "priority":0,"flagged":false,"completed_at":null,"completed_by":null,"due_at":"2026-11-14T08:00:00+00:00",
         "all_day":false,"time_zone":"Europe/Bratislava","early_alert_minutes":null,
         "repeat":{"unit":"minute","interval":45,"anchor":"2026-11-14T09:00","window":{"start":"09:00","end":"18:00"},"advance":"auto"},
         "nag":{"every_minutes":10,"max":null},"location":null,"bluetooth":{"name":"AirPods","on":"connect","ids":{"android":"A4:C3"}},
         "app_trigger":null,"sort_order":1.5,"created_at":"2026-11-14T07:59:59.5+00:00","updated_at":"2026-11-14T07:59:59.5+00:00",
         "deleted_at":null,"version":17}
        """
        let r = try LynxJSON.decoder().decode(Reminder.self, from: Data(json.utf8))
        XCTAssertEqual(r.repeat?.interval, 45)
        XCTAssertEqual(r.nag, Nag(everyMinutes: 10, max: nil))
        XCTAssertEqual(r.bluetooth?.ids?["android"], "A4:C3")
        XCTAssertEqual(r.version, 17)
    }
}
