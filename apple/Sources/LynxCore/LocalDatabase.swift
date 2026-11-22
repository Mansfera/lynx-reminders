import Foundation

/// Sync bookkeeping (SPEC §4).
public struct SyncState: Codable, Hashable, Sendable {
    public var cursorLists: Int64 = 0
    public var cursorReminders: Int64 = 0
    public var lastManifestAt: Date?
    public var lastSyncAt: Date?
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case cursorLists = "cursor_lists"
        case cursorReminders = "cursor_reminders"
        case lastManifestAt = "last_manifest_at"
        case lastSyncAt = "last_sync_at"
        case lastError = "last_error"
    }

    public init() {}
}

/// Everything this device can see: server rows + the local-only `dirty` marks (kept as id sets so the
/// row types stay identical to the server's).
public struct LocalDatabase: Codable, Sendable, Equatable {
    /// The account the rows belong to; nil = local-only data (no account).
    public var accountId: UUID?
    public var accountEmail: String?
    public var lists: [UUID: LynxList] = [:]
    public var reminders: [UUID: Reminder] = [:]
    public var members: [ListMember] = []
    public var shares: [ReminderShare] = []
    public var invites: [Invite] = []
    public var dirtyLists: Set<UUID> = []
    public var dirtyReminders: Set<UUID> = []
    public var sync = SyncState()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case accountEmail = "account_email"
        case lists, reminders, members, shares, invites, sync
        case dirtyLists = "dirty_lists"
        case dirtyReminders = "dirty_reminders"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decodeIfPresent(UUID.self, forKey: .accountId)
        accountEmail = try c.decodeIfPresent(String.self, forKey: .accountEmail)
        let ls = try c.decodeIfPresent([LynxList].self, forKey: .lists) ?? []
        lists = Dictionary(ls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rs = try c.decodeIfPresent([Reminder].self, forKey: .reminders) ?? []
        reminders = Dictionary(rs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        members = try c.decodeIfPresent([ListMember].self, forKey: .members) ?? []
        shares = try c.decodeIfPresent([ReminderShare].self, forKey: .shares) ?? []
        invites = try c.decodeIfPresent([Invite].self, forKey: .invites) ?? []
        dirtyLists = try c.decodeIfPresent(Set<UUID>.self, forKey: .dirtyLists) ?? []
        dirtyReminders = try c.decodeIfPresent(Set<UUID>.self, forKey: .dirtyReminders) ?? []
        sync = try c.decodeIfPresent(SyncState.self, forKey: .sync) ?? SyncState()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(accountEmail, forKey: .accountEmail)
        try c.encode(lists.values.sorted { $0.id.uuidString < $1.id.uuidString }, forKey: .lists)
        try c.encode(reminders.values.sorted { $0.id.uuidString < $1.id.uuidString }, forKey: .reminders)
        try c.encode(members, forKey: .members)
        try c.encode(shares, forKey: .shares)
        try c.encode(invites, forKey: .invites)
        try c.encode(dirtyLists.sorted { $0.uuidString < $1.uuidString }, forKey: .dirtyLists)
        try c.encode(dirtyReminders.sorted { $0.uuidString < $1.uuidString }, forKey: .dirtyReminders)
        try c.encode(sync, forKey: .sync)
    }

    // MARK: Queries

    public var visibleLists: [LynxList] {
        lists.values.filter { !$0.isDeleted }.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    public func list(_ id: UUID?) -> LynxList? {
        guard let id, let l = lists[id], !l.isDeleted else { return nil }
        return l
    }

    /// Non-deleted subtasks of a reminder, in order.
    public func subtasks(of id: UUID) -> [Reminder] {
        reminders.values.filter { $0.parentId == id && !$0.isDeleted }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    /// Goal = a reminder with at least one non-deleted subtask (SPEC §2).
    public func isGoal(_ id: UUID) -> Bool {
        reminders.values.contains { $0.parentId == id && !$0.isDeleted }
    }

    /// (completed, total) subtasks.
    public func progress(of id: UUID) -> (done: Int, total: Int) {
        let subs = subtasks(of: id)
        return (subs.filter(\.isCompleted).count, subs.count)
    }

    public func members(of listId: UUID) -> [ListMember] {
        members.filter { $0.listId == listId }.sorted { ($0.isOwner ? 0 : 1, $0.profile?.name ?? "") < ($1.isOwner ? 0 : 1, $1.profile?.name ?? "") }
    }

    public func shares(of reminderId: UUID) -> [ReminderShare] {
        shares.filter { $0.reminderId == reminderId }
    }

    /// A list counts as shared when it has another member or a pending invite.
    public func isShared(_ listId: UUID) -> Bool {
        members.filter { $0.listId == listId }.count > 1 || invites.contains { $0.listId == listId }
    }

    /// People who can see a reminder: list members plus direct shares (of it or its parent).
    public func participants(of reminder: Reminder) -> [Profile] {
        var seen = Set<UUID>()
        var out: [Profile] = []
        let shareIds = [reminder.id, reminder.parentId].compactMap { $0 }
        let rows = members.filter { $0.listId == reminder.listId }.map { ($0.userId, $0.profile) }
            + shares.filter { shareIds.contains($0.reminderId) }.map { ($0.userId, $0.profile) }
        for (uid, p) in rows where !seen.contains(uid) {
            seen.insert(uid)
            out.append(p ?? Profile(id: uid, email: nil, displayName: nil))
        }
        return out
    }

    public func profile(_ id: UUID?) -> Profile? {
        guard let id else { return nil }
        return members.first { $0.userId == id && $0.profile != nil }?.profile
            ?? shares.first { $0.userId == id && $0.profile != nil }?.profile
    }

    public var hasDirtyRows: Bool { !dirtyLists.isEmpty || !dirtyReminders.isEmpty }

    // MARK: Edits (each marks the row dirty with a fresh updated_at)

    public mutating func upsertList(_ list: LynxList, now: Date = LynxTime.now()) {
        var l = list
        l.updatedAt = now
        lists[l.id] = l
        dirtyLists.insert(l.id)
    }

    public mutating func editList(_ id: UUID, now: Date = LynxTime.now(), _ body: (inout LynxList) -> Void) {
        guard var l = lists[id] else { return }
        body(&l)
        l.updatedAt = now
        lists[id] = l
        dirtyLists.insert(id)
    }

    public mutating func upsertReminder(_ r: Reminder, now: Date = LynxTime.now()) {
        var r = r
        r.updatedAt = now
        reminders[r.id] = r
        dirtyReminders.insert(r.id)
    }

    public mutating func editReminder(_ id: UUID, now: Date = LynxTime.now(), _ body: (inout Reminder) -> Void) {
        guard var r = reminders[id] else { return }
        let before = r
        body(&r)
        guard r != before else { return }
        r.updatedAt = now
        reminders[id] = r
        dirtyReminders.insert(id)
    }

    /// Soft-deletes a reminder and its subtasks.
    public mutating func deleteReminder(_ id: UUID, now: Date = LynxTime.now()) {
        for sub in subtasks(of: id) { editReminder(sub.id, now: now) { $0.deletedAt = now } }
        editReminder(id, now: now) { $0.deletedAt = now }
    }

    /// Soft-deletes a list and everything in it.
    public mutating func deleteList(_ id: UUID, now: Date = LynxTime.now()) {
        for r in reminders.values where r.listId == id && !r.isDeleted {
            editReminder(r.id, now: now) { $0.deletedAt = now }
        }
        editList(id, now: now) { $0.deletedAt = now }
    }

    /// Moves a reminder (and its subtasks) to another list.
    public mutating func move(_ id: UUID, toList listId: UUID, now: Date = LynxTime.now()) {
        editReminder(id, now: now) { $0.listId = listId; $0.parentId = nil }
        for sub in subtasks(of: id) { editReminder(sub.id, now: now) { $0.listId = listId } }
    }

    public enum CompletionOutcome: Equatable, Sendable {
        /// The repeat advanced to a new due date; the reminder stays open.
        case advanced(Date)
        case completed
        case uncompleted
        case none
    }

    /// Toggles completion (SPEC §2 goals, §5.3 repeats). Completing a goal completes its open subtasks
    /// only when `includeSubtasks` is true.
    @discardableResult
    public mutating func toggleComplete(_ id: UUID, by user: UUID?, includeSubtasks: Bool = false,
                                        now: Date = LynxTime.now()) -> CompletionOutcome {
        guard let r = reminders[id], !r.isDeleted else { return .none }
        if r.isCompleted {
            editReminder(id, now: now) { $0.completedAt = nil; $0.completedBy = nil }
            return .uncompleted
        }
        return complete(id, by: user, includeSubtasks: includeSubtasks, now: now)
    }

    @discardableResult
    public mutating func complete(_ id: UUID, by user: UUID?, includeSubtasks: Bool = false,
                                  now: Date = LynxTime.now()) -> CompletionOutcome {
        guard let r = reminders[id], r.isOpen else { return .none }
        if includeSubtasks {
            for sub in subtasks(of: id) where sub.isOpen {
                editReminder(sub.id, now: now) { $0.completedAt = now; $0.completedBy = user }
            }
        }
        if let rule = r.repeat, let due = r.dueAt {
            let result = Recurrence.complete(rule, in: r.zone, dueAt: due, completedAt: now)
            if result.completed {
                editReminder(id, now: now) {
                    $0.repeat = result.rule
                    $0.dueAt = result.dueAt
                    $0.completedAt = now
                    $0.completedBy = user
                }
                return .completed
            }
            editReminder(id, now: now) {
                $0.repeat = result.rule
                $0.dueAt = result.dueAt
            }
            // A goal that repeats starts over: its subtasks reopen with the next occurrence.
            if includeSubtasks || !subtasks(of: id).isEmpty {
                for sub in subtasks(of: id) where sub.isCompleted {
                    editReminder(sub.id, now: now) { $0.completedAt = nil; $0.completedBy = nil }
                }
            }
            return .advanced(result.dueAt)
        }
        editReminder(id, now: now) { $0.completedAt = now; $0.completedBy = user }
        return .completed
    }

    /// Next sort order at the end of a list (or of a goal's subtasks).
    public func nextReminderSortOrder(list: UUID, parent: UUID? = nil) -> Double {
        let siblings = reminders.values.filter { $0.listId == list && $0.parentId == parent && !$0.isDeleted }
        return (siblings.map(\.sortOrder).max() ?? 0) + 1
    }

    public func nextListSortOrder() -> Double {
        (lists.values.filter { !$0.isDeleted }.map(\.sortOrder).max() ?? 0) + 1
    }

    // MARK: Accounts

    /// Signing in with local-only data: rows get the user's id and are queued for upload (SPEC §1).
    public mutating func claim(for user: UUID, email: String?, now: Date = LynxTime.now()) {
        accountId = user
        accountEmail = email
        // A fresh device's automatic "Reminders" list, still empty, stays behind: the account already
        // has its lists, and uploading it would add another "Reminders" per device (SPEC §1).
        let used = Set(reminders.values.map(\.listId))
        for (id, l) in lists where l.version == nil && l.ownerId == nil && !used.contains(id) && l.isUntouchedDefault {
            lists[id] = nil
            dirtyLists.remove(id)
        }
        for (id, var l) in lists where l.ownerId == nil || l.version == nil {
            if l.ownerId == nil { l.ownerId = user }
            lists[id] = l
            dirtyLists.insert(id)
        }
        for (id, var r) in reminders where r.createdBy == nil || r.version == nil {
            if r.createdBy == nil { r.createdBy = user }
            reminders[id] = r
            dirtyReminders.insert(id)
        }
        sync = SyncState()
    }

    /// Sign out with "Keep a local copy": the data becomes a local-only copy with fresh ids, so signing
    /// in to any account later uploads it as new rows instead of colliding with the server's.
    public mutating func detachAsLocalCopy() {
        var listIds: [UUID: UUID] = [:]
        var reminderIds: [UUID: UUID] = [:]
        for id in lists.keys { listIds[id] = UUID() }
        for id in reminders.keys { reminderIds[id] = UUID() }
        var newLists: [UUID: LynxList] = [:]
        for var l in lists.values where !l.isDeleted {
            l.id = listIds[l.id]!
            l.ownerId = nil
            l.version = nil
            newLists[l.id] = l
        }
        var newReminders: [UUID: Reminder] = [:]
        for var r in reminders.values where !r.isDeleted {
            guard let lid = listIds[r.listId], newLists[lid] != nil else { continue }
            r.id = reminderIds[r.id]!
            r.listId = lid
            r.parentId = r.parentId.flatMap { reminderIds[$0] }
            r.createdBy = nil
            r.assigneeId = nil
            r.completedBy = nil
            r.version = nil
            newReminders[r.id] = r
        }
        // Reminders shared with me (whose list I can't see) have no list to live in: drop them.
        lists = newLists
        reminders = newReminders
        members = []
        shares = []
        invites = []
        dirtyLists = []
        dirtyReminders = []
        accountId = nil
        accountEmail = nil
        sync = SyncState()
    }
}

/// Device-local state that is never synced (SPEC §4 last bullet): trigger cooldowns, snoozes,
/// when context triggers fired (for nags), last known region states.
public struct DeviceState: Codable, Sendable, Equatable {
    /// `<reminder_id>|<trigger kind>` → last fire time.
    public var cooldowns: [String: Date] = [:]
    /// reminder id → snoozed-until.
    public var snoozes: [UUID: Date] = [:]
    /// reminder id → when a context trigger last fired (the nag series starts there).
    public var contextFired: [UUID: Date] = [:]
    /// region identifier → "inside" / "outside".
    public var regionStates: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case cooldowns, snoozes
        case contextFired = "context_fired"
        case regionStates = "region_states"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cooldowns = try c.decodeIfPresent([String: Date].self, forKey: .cooldowns) ?? [:]
        let s = try c.decodeIfPresent([String: Date].self, forKey: .snoozes) ?? [:]
        snoozes = Dictionary(uniqueKeysWithValues: s.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        let f = try c.decodeIfPresent([String: Date].self, forKey: .contextFired) ?? [:]
        contextFired = Dictionary(uniqueKeysWithValues: f.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        regionStates = try c.decodeIfPresent([String: String].self, forKey: .regionStates) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cooldowns, forKey: .cooldowns)
        try c.encode(Dictionary(uniqueKeysWithValues: snoozes.map { ($0.key.uuidString, $0.value) }), forKey: .snoozes)
        try c.encode(Dictionary(uniqueKeysWithValues: contextFired.map { ($0.key.uuidString, $0.value) }), forKey: .contextFired)
        try c.encode(regionStates, forKey: .regionStates)
    }

    /// Drops state for reminders that are gone or done, and cooldowns older than a day.
    public mutating func prune(open: Set<UUID>, now: Date) {
        snoozes = snoozes.filter { open.contains($0.key) && $0.value > now.addingTimeInterval(-86_400) }
        contextFired = contextFired.filter { open.contains($0.key) && $0.value > now.addingTimeInterval(-86_400) }
        cooldowns = cooldowns.filter { $0.value > now.addingTimeInterval(-86_400) }
    }
}
