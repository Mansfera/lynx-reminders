import Foundation

/// Sidebar smart lists in SPEC §7 order.
public enum SmartList: String, CaseIterable, Sendable, Hashable, Codable {
    case today, scheduled, all, flagged, goals, sharedWithMe, assignedToMe, completed

    public var title: String {
        switch self {
        case .today: return "Today"
        case .scheduled: return "Scheduled"
        case .all: return "All"
        case .flagged: return "Flagged"
        case .goals: return "Goals"
        case .sharedWithMe: return "Shared with me"
        case .assignedToMe: return "Assigned to me"
        case .completed: return "Completed"
        }
    }

    /// The 2×2 stats grid at the top of the sidebar.
    public static let grid: [SmartList] = [.today, .scheduled, .all, .flagged]
    public static let rows: [SmartList] = [.goals, .sharedWithMe, .assignedToMe, .completed]
}

public struct ReminderGroup: Identifiable, Sendable, Equatable {
    public var id: String
    /// Start of the local day for day groups.
    public var day: Date?
    /// The list for list groups.
    public var listId: UUID?
    public var reminders: [Reminder]
}

/// Smart list and search queries over a local database snapshot (SPEC §7).
public struct SmartQueries: Sendable {
    public let db: LocalDatabase
    public let me: UUID?
    public let now: Date
    public let calendar: Calendar

    public init(db: LocalDatabase, me: UUID?, now: Date, calendar: Calendar = .current) {
        self.db = db
        self.me = me
        self.now = now
        self.calendar = calendar
    }

    // MARK: Basics

    /// Not deleted and reachable: its list is visible, or it (or its parent) is shared with me directly.
    public func isVisible(_ r: Reminder) -> Bool {
        guard !r.isDeleted else { return false }
        if db.list(r.listId) != nil { return true }
        return isDirectShare(r)
    }

    func isDirectShare(_ r: Reminder) -> Bool {
        db.shares.contains { $0.reminderId == r.id || (r.parentId != nil && $0.reminderId == r.parentId) }
    }

    public func effectiveDue(_ r: Reminder) -> Date? { NotificationPlanner.effectiveDue(r, now: now) }

    /// The local calendar day of the effective due: all-day dates are read in the reminder's zone,
    /// timed ones in the device's zone.
    public func dueDay(_ r: Reminder) -> Date? {
        guard let due = effectiveDue(r) else { return nil }
        if r.allDay {
            let (y, m, d) = WallTime(due, in: r.zone).ymd
            return calendar.date(from: DateComponents(year: y, month: m, day: d))
        }
        return calendar.startOfDay(for: due)
    }

    public func isOverdue(_ r: Reminder) -> Bool {
        guard r.isOpen, let due = effectiveDue(r) else { return false }
        // An auto-advancing series is never behind: its effective due is the current slot (SPEC §5.2).
        if r.repeat?.autoAdvance == true, due >= r.dueAt ?? due, due <= now { return false }
        if r.allDay, let day = dueDay(r) { return day < calendar.startOfDay(for: now) }
        return due < now
    }

    public func isDueTodayOrOverdue(_ r: Reminder) -> Bool {
        guard r.isOpen, let day = dueDay(r) else { return false }
        return day <= calendar.startOfDay(for: now)
    }

    private var open: [Reminder] { db.reminders.values.filter { $0.isOpen && isVisible($0) } }

    private func byDue(_ a: Reminder, _ b: Reminder) -> Bool {
        let da = effectiveDue(a) ?? .distantFuture, dbb = effectiveDue(b) ?? .distantFuture
        if a.allDay != b.allDay, dueDay(a) == dueDay(b) { return a.allDay }  // all-day first within a day
        return (da, a.sortOrder, a.createdAt) < (dbb, b.sortOrder, b.createdAt)
    }

    private func byOrder(_ a: Reminder, _ b: Reminder) -> Bool {
        (a.sortOrder, a.createdAt) < (b.sortOrder, b.createdAt)
    }

    // MARK: Smart lists

    public func reminders(_ list: SmartList) -> [Reminder] {
        switch list {
        case .today:
            return open.filter(isDueTodayOrOverdue).sorted(by: byDue)
        case .scheduled:
            return open.filter { $0.dueAt != nil }.sorted(by: byDue)
        case .all:
            return open.filter { $0.parentId == nil }.sorted(by: byOrder)
        case .flagged:
            return open.filter(\.flagged).sorted(by: byOrder)
        case .goals:
            return open.filter { $0.parentId == nil && db.isGoal($0.id) }.sorted(by: byOrder)
        case .sharedWithMe:
            guard let me else { return [] }
            let sharedIds = Set(db.shares.filter { $0.userId == me }.map(\.reminderId))
            return db.reminders.values.filter { r in
                !r.isDeleted && r.parentId == nil && sharedIds.contains(r.id) && r.createdBy != me
                    && !db.members.contains { $0.listId == r.listId && $0.userId == me }
            }
            .sorted { ($0.isCompleted ? 1 : 0, $0.sortOrder) < ($1.isCompleted ? 1 : 0, $1.sortOrder) }
        case .assignedToMe:
            guard let me else { return [] }
            return open.filter { $0.assigneeId == me }.sorted(by: byDue)
        case .completed:
            return db.reminders.values.filter { $0.isCompleted && isVisible($0) }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
    }

    public func count(_ list: SmartList) -> Int { reminders(list).count }

    /// Grouped for display: Scheduled by day, All by list, Completed by completion day (newest first).
    public func groups(_ list: SmartList) -> [ReminderGroup] {
        let rows = reminders(list)
        switch list {
        case .scheduled:
            return groupByDay(rows) { dueDay($0) }
        case .completed:
            return groupByDay(rows) { $0.completedAt.map { calendar.startOfDay(for: $0) } }
        case .all:
            var out: [ReminderGroup] = []
            for l in db.visibleLists {
                let rs = rows.filter { $0.listId == l.id }
                if !rs.isEmpty { out.append(ReminderGroup(id: l.id.uuidString, listId: l.id, reminders: rs)) }
            }
            let orphans = rows.filter { db.list($0.listId) == nil }
            if !orphans.isEmpty { out.append(ReminderGroup(id: "shared", reminders: orphans)) }
            return out
        default:
            return [ReminderGroup(id: list.rawValue, reminders: rows)]
        }
    }

    private func groupByDay(_ rows: [Reminder], key: (Reminder) -> Date?) -> [ReminderGroup] {
        var out: [ReminderGroup] = []
        for r in rows {
            let day = key(r)
            let id = day.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            if let i = out.lastIndex(where: { $0.id == id }) {
                out[i].reminders.append(r)
            } else {
                out.append(ReminderGroup(id: id, day: day, reminders: [r]))
            }
        }
        return out
    }

    // MARK: Lists

    /// Top-level reminders of a list: open first (in order), then completed if asked (newest first).
    public func reminders(inList id: UUID, showCompleted: Bool) -> [Reminder] {
        let rows = db.reminders.values.filter { $0.listId == id && $0.parentId == nil && !$0.isDeleted }
        let openRows = rows.filter(\.isOpen).sorted(by: byOrder)
        guard showCompleted else { return openRows }
        let done = rows.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return openRows + done
    }

    public func openCount(inList id: UUID) -> Int {
        db.reminders.values.filter { $0.listId == id && $0.parentId == nil && $0.isOpen }.count
    }

    /// Lists I own that nobody else is in (or all lists without an account).
    public var myLists: [LynxList] {
        db.visibleLists.filter { l in (me == nil || l.ownerId == nil || l.ownerId == me) && !db.isShared(l.id) }
    }

    /// Lists shared with me or by me.
    public var sharedLists: [LynxList] {
        db.visibleLists.filter { l in !(me == nil || l.ownerId == nil || l.ownerId == me) || db.isShared(l.id) }
    }

    // MARK: Search

    /// Titles and notes across everything (SPEC §7): open first by due, then completed.
    public func search(_ text: String) -> [Reminder] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = db.reminders.values.filter { r in
            isVisible(r) && (r.title.range(of: q, options: opts) != nil || (r.notes?.range(of: q, options: opts) != nil))
        }
        return hits.filter(\.isOpen).sorted(by: byDue) + hits.filter(\.isCompleted).sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
    }

    // MARK: Today stage

    public struct TodaySummary: Sendable, Equatable {
        public var open: Int
        public var overdue: Int
        /// The next due instant later today.
        public var next: Date?
        /// Timed reminders due today (for the day ruler): instant + overdue flag.
        public var marks: [Mark]

        public struct Mark: Sendable, Equatable, Hashable {
            public var reminderId: UUID
            public var date: Date
            public var overdue: Bool
        }
    }

    public func todaySummary() -> TodaySummary {
        let rows = reminders(.today)
        let startToday = calendar.startOfDay(for: now)
        let endToday = calendar.date(byAdding: .day, value: 1, to: startToday) ?? now
        let overdue = rows.filter(isOverdue)
        let next = rows.compactMap { r -> Date? in
            guard !r.allDay, let d = effectiveDue(r), d >= now, d < endToday else { return nil }
            return d
        }.min()
        let marks = rows.compactMap { r -> TodaySummary.Mark? in
            guard !r.allDay, let d = effectiveDue(r), d >= startToday, d < endToday else { return nil }
            return TodaySummary.Mark(reminderId: r.id, date: d, overdue: isOverdue(r))
        }
        return TodaySummary(open: rows.count, overdue: overdue.count, next: next, marks: marks)
    }
}
