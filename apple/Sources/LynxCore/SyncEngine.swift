import Foundation

public enum RemoteError: Error, Equatable, Sendable, LocalizedError {
    /// Rejected by row-level security (HTTP 403 / Postgres 42501).
    case forbidden(String)
    /// The session is missing or expired.
    case unauthorized
    case network(String)
    case server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .forbidden(let m): return "Not allowed: \(m)"
        case .unauthorized: return "Signed out. Sign in again to sync."
        case .network(let m): return "Offline: \(m)"
        case .server(let code, let m): return "Server error \(code): \(m)"
        }
    }
}

/// What the sync engine needs from the server (SPEC §4). Implemented over Supabase in LynxSync,
/// and by an in-memory fake in tests.
public protocol RemoteStore: Sendable {
    /// `GET /lists?version=gt.{cursor}&order=version.asc&limit={limit}`
    func pullLists(after version: Int64, limit: Int) async throws -> [LynxList]
    func pullReminders(after version: Int64, limit: Int) async throws -> [Reminder]
    /// `GET /list_members?select=*,profile:profiles(*)`
    func fetchMembers() async throws -> [ListMember]
    func fetchShares() async throws -> [ReminderShare]
    func fetchInvites() async throws -> [Invite]
    /// `rpc/sync_manifest`
    func manifest() async throws -> [ManifestEntry]
    /// `id=in.(…)`
    func fetchLists(ids: [UUID]) async throws -> [LynxList]
    func fetchReminders(ids: [UUID]) async throws -> [Reminder]
    /// Upsert (`on_conflict=id`, merge duplicates), returning the stored rows.
    func upsertLists(_ rows: [LynxList]) async throws -> [LynxList]
    func upsertReminders(_ rows: [Reminder]) async throws -> [Reminder]
}

public struct SyncReport: Sendable, Equatable {
    /// Local rows added, replaced or removed by this run.
    public var changed = 0
    public var pushed = 0
    public var rejected = 0
    public var ranManifest = false
    public var error: String?
    public init() {}
}

/// Serialized sync runs: pull → memberships → manifest → push (SPEC §4).
public actor SyncEngine {
    public let store: LynxStore
    public let remote: any RemoteStore
    public let me: UUID
    public let pageSize: Int
    public let batchSize: Int
    public static let manifestInterval: TimeInterval = 6 * 3600

    private var running = false
    private var rerun = false
    private var wantManifest = false
    private var debounce: Task<Void, Never>?
    private var onReport: (@Sendable (SyncReport) -> Void)?

    public init(store: LynxStore, remote: any RemoteStore, me: UUID, pageSize: Int = 500, batchSize: Int = 100) {
        self.store = store
        self.remote = remote
        self.me = me
        self.pageSize = pageSize
        self.batchSize = batchSize
    }

    public func setReportHandler(_ h: (@Sendable (SyncReport) -> Void)?) { onReport = h }

    /// Debounced sync: edits use 1 s, realtime events 500 ms.
    public func schedule(after delay: TimeInterval, manifest: Bool = false) {
        if manifest { wantManifest = true }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    public func cancel() {
        debounce?.cancel()
        debounce = nil
    }

    /// Runs a sync now, or queues one more run if a sync is in flight. Returns the last run's report.
    @discardableResult
    public func syncNow(manifest: Bool = false) async -> SyncReport {
        if manifest { wantManifest = true }
        if running {
            rerun = true
            return SyncReport()
        }
        running = true
        var report = SyncReport()
        repeat {
            rerun = false
            let m = wantManifest
            wantManifest = false
            do {
                report = try await runOnce(forceManifest: m)
                store.write { $0.sync.lastSyncAt = LynxTime.now(); $0.sync.lastError = nil }
            } catch {
                report = SyncReport()
                report.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let msg = report.error
                store.write { $0.sync.lastError = msg }
                if m { wantManifest = true }  // try the manifest again next time
            }
            onReport?(report)
        } while rerun
        running = false
        return report
    }

    // MARK: - One run

    func runOnce(forceManifest: Bool) async throws -> SyncReport {
        var report = SyncReport()

        // 1. Pull changes after the cursors.
        var cursor = store.read { $0.sync.cursorLists }
        while true {
            let rows = try await remote.pullLists(after: cursor, limit: pageSize)
            report.changed += store.write { db in mergeLists(rows, into: &db) }
            if let maxV = rows.compactMap(\.version).max() { cursor = max(cursor, maxV) }
            let c = cursor
            store.write { $0.sync.cursorLists = c }
            if rows.count < pageSize { break }
        }
        cursor = store.read { $0.sync.cursorReminders }
        while true {
            let rows = try await remote.pullReminders(after: cursor, limit: pageSize)
            report.changed += store.write { db in mergeReminders(rows, into: &db) }
            if let maxV = rows.compactMap(\.version).max() { cursor = max(cursor, maxV) }
            let c = cursor
            store.write { $0.sync.cursorReminders = c }
            if rows.count < pageSize { break }
        }

        // 2. Memberships, shares, invites: small tables, replaced in full.
        let members = try await remote.fetchMembers()
        let shares = try await remote.fetchShares()
        let invites = try await remote.fetchInvites()
        let me = self.me
        let accessChanged: Bool = store.write { db in
            let beforeLists = Set(db.members.filter { $0.userId == me }.map(\.listId))
            let beforeShares = Set(db.shares.filter { $0.userId == me }.map(\.reminderId))
            let afterLists = Set(members.filter { $0.userId == me }.map(\.listId))
            let afterShares = Set(shares.filter { $0.userId == me }.map(\.reminderId))
            if db.members != members || db.shares != shares || db.invites != invites { report.changed += 1 }
            db.members = members
            db.shares = shares
            db.invites = invites
            return beforeLists != afterLists || beforeShares != afterShares
        }

        // 3. Manifest: on demand, when access changed, and at least every 6 h.
        let last = store.read { $0.sync.lastManifestAt }
        if forceManifest || accessChanged || last == nil || Date().timeIntervalSince(last!) > Self.manifestInterval {
            report.changed += try await runManifest()
            report.ranManifest = true
        }

        // 4. Push dirty rows: lists, then parent reminders, then subtasks.
        let (dirtyLists, dirtyReminders): ([LynxList], [Reminder]) = store.read { db in
            (db.dirtyLists.compactMap { db.lists[$0] }.sorted { $0.createdAt < $1.createdAt },
             db.dirtyReminders.compactMap { db.reminders[$0] })
        }
        for batch in dirtyLists.chunked(batchSize) {
            let (pushed, rejected, changed) = try await pushLists(batch)
            report.pushed += pushed
            report.rejected += rejected
            report.changed += changed
        }
        let parents = dirtyReminders.filter { $0.parentId == nil }.sorted { $0.createdAt < $1.createdAt }
        let subtasks = dirtyReminders.filter { $0.parentId != nil }.sorted { $0.createdAt < $1.createdAt }
        for batch in parents.chunked(batchSize) + subtasks.chunked(batchSize) {
            let (pushed, rejected, changed) = try await pushReminders(batch)
            report.pushed += pushed
            report.rejected += rejected
            report.changed += changed
        }
        return report
    }

    /// Step 3. Returns the number of local rows changed.
    func runManifest() async throws -> Int {
        let manifest = try await remote.manifest()
        var serverLists: [UUID: Int64] = [:]
        var serverReminders: [UUID: Int64] = [:]
        for e in manifest {
            if e.t == "lists" { serverLists[e.id] = e.v } else if e.t == "reminders" { serverReminders[e.id] = e.v }
        }
        let (staleLists, staleReminders): ([UUID], [UUID]) = store.read { db in
            (serverLists.filter { db.lists[$0.key]?.version != $0.value }.map(\.key),
             serverReminders.filter { db.reminders[$0.key]?.version != $0.value }.map(\.key))
        }
        var changed = 0
        for ids in staleLists.chunked(batchSize) {
            let rows = try await remote.fetchLists(ids: ids)
            changed += store.write { db in mergeLists(rows, into: &db) }
        }
        for ids in staleReminders.chunked(batchSize) {
            let rows = try await remote.fetchReminders(ids: ids)
            changed += store.write { db in mergeReminders(rows, into: &db) }
        }
        // Clean rows the server no longer lists for me: access lost.
        changed += store.write { db in
            var n = 0
            for id in Array(db.lists.keys) where serverLists[id] == nil && !db.dirtyLists.contains(id) {
                db.lists[id] = nil
                n += 1
            }
            for id in Array(db.reminders.keys) where serverReminders[id] == nil && !db.dirtyReminders.contains(id) {
                db.reminders[id] = nil
                n += 1
            }
            db.sync.lastManifestAt = LynxTime.now()
            return n
        }
        return changed
    }

    // MARK: Push

    private func pushLists(_ batch: [LynxList]) async throws -> (Int, Int, Int) {
        do {
            let saved = try await remote.upsertLists(batch)
            var changed = store.write { db in markPushed(lists: batch, saved: saved, in: &db) }
            // Missing from the response = skipped by last-writer-wins (the server's copy is newer).
            let skipped = skippedIds(sent: batch.map { ($0.id, $0.updatedAt) }, saved: Set(saved.map(\.id)),
                                     current: { db, id in db.lists[id]?.updatedAt }, dirty: \.dirtyLists)
            if !skipped.isEmpty {
                let rows = try await remote.fetchLists(ids: skipped)
                changed += store.write { db in mergeLists(rows, into: &db) }
            }
            return (saved.count, 0, changed)
        } catch RemoteError.forbidden {
            guard batch.count > 1 else { return (0, 1, try await rejectLists(batch)) }
            // Find the offending rows one by one.
            var pushed = 0, rejected = 0, changed = 0
            for row in batch {
                let (p, r, c) = try await pushLists([row])
                pushed += p; rejected += r; changed += c
            }
            return (pushed, rejected, changed)
        }
    }

    private func pushReminders(_ batch: [Reminder]) async throws -> (Int, Int, Int) {
        do {
            let saved = try await remote.upsertReminders(batch)
            var changed = store.write { db in markPushed(reminders: batch, saved: saved, in: &db) }
            let skipped = skippedIds(sent: batch.map { ($0.id, $0.updatedAt) }, saved: Set(saved.map(\.id)),
                                     current: { db, id in db.reminders[id]?.updatedAt }, dirty: \.dirtyReminders)
            if !skipped.isEmpty {
                let rows = try await remote.fetchReminders(ids: skipped)
                changed += store.write { db in mergeReminders(rows, into: &db) }
            }
            return (saved.count, 0, changed)
        } catch RemoteError.forbidden {
            guard batch.count > 1 else { return (0, 1, try await rejectReminders(batch)) }
            var pushed = 0, rejected = 0, changed = 0
            for row in batch {
                let (p, r, c) = try await pushReminders([row])
                pushed += p; rejected += r; changed += c
            }
            return (pushed, rejected, changed)
        }
    }

    /// Rows sent but absent from the upsert response: mark them clean (unless edited again meanwhile)
    /// so the re-fetched server copy replaces them.
    private func skippedIds(sent: [(UUID, Date)], saved: Set<UUID>,
                            current: @escaping (LocalDatabase, UUID) -> Date?,
                            dirty: WritableKeyPath<LocalDatabase, Set<UUID>>) -> [UUID] {
        let missing = sent.filter { !saved.contains($0.0) }
        guard !missing.isEmpty else { return [] }
        return store.write { db in
            var out: [UUID] = []
            for (id, sentAt) in missing where current(db, id) == sentAt {
                db[keyPath: dirty].remove(id)
                out.append(id)
            }
            return out
        }
    }

    /// A row rejected by RLS: drop the local change and re-fetch the server's copy (or remove it if there is none).
    private func rejectLists(_ rows: [LynxList]) async throws -> Int {
        let ids = rows.map(\.id)
        let server = try await remote.fetchLists(ids: ids)
        return store.write { db in
            for id in ids {
                db.dirtyLists.remove(id)
                db.lists[id] = server.first { $0.id == id }
            }
            return ids.count
        }
    }

    private func rejectReminders(_ rows: [Reminder]) async throws -> Int {
        let ids = rows.map(\.id)
        let server = try await remote.fetchReminders(ids: ids)
        return store.write { db in
            for id in ids {
                db.dirtyReminders.remove(id)
                db.reminders[id] = server.first { $0.id == id }
            }
            return ids.count
        }
    }
}

// MARK: - Merge rules (pure, tested directly)

/// Step 1 merge: take the server row if there is no local row, the local row is clean,
/// or `server.updated_at >= local.updated_at`; otherwise keep the local dirty row. Returns rows changed.
@discardableResult
public func mergeLists(_ rows: [LynxList], into db: inout LocalDatabase) -> Int {
    var n = 0
    for s in rows {
        if let local = db.lists[s.id], db.dirtyLists.contains(s.id), s.updatedAt < local.updatedAt { continue }
        if db.lists[s.id] != s { n += 1 }
        db.lists[s.id] = s
        db.dirtyLists.remove(s.id)
    }
    return n
}

@discardableResult
public func mergeReminders(_ rows: [Reminder], into db: inout LocalDatabase) -> Int {
    var n = 0
    for s in rows {
        if let local = db.reminders[s.id], db.dirtyReminders.contains(s.id), s.updatedAt < local.updatedAt { continue }
        if db.reminders[s.id] != s { n += 1 }
        db.reminders[s.id] = s
        db.dirtyReminders.remove(s.id)
    }
    return n
}

/// After a push: rows unchanged since they were sent become clean server copies; rows edited meanwhile
/// stay dirty but learn their new version.
func markPushed(lists sent: [LynxList], saved: [LynxList], in db: inout LocalDatabase) -> Int {
    var n = 0
    for s in saved {
        guard let local = db.lists[s.id] else { continue }
        let sentRow = sent.first { $0.id == s.id }
        if local.updatedAt == sentRow?.updatedAt {
            if local != s { n += 1 }
            db.lists[s.id] = s
            db.dirtyLists.remove(s.id)
        } else {
            db.lists[s.id]?.version = s.version
        }
    }
    return n
}

func markPushed(reminders sent: [Reminder], saved: [Reminder], in db: inout LocalDatabase) -> Int {
    var n = 0
    for s in saved {
        guard let local = db.reminders[s.id] else { continue }
        let sentRow = sent.first { $0.id == s.id }
        if local.updatedAt == sentRow?.updatedAt {
            if local != s { n += 1 }
            db.reminders[s.id] = s
            db.dirtyReminders.remove(s.id)
        } else {
            db.reminders[s.id]?.version = s.version
        }
    }
    return n
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
