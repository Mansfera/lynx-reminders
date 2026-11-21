import Foundation

/// A local notification to schedule. `id` is `<reminder_id>|<kind>|<n>` (SPEC §5.5).
public struct PlannedNotification: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case due, early, nag, auto, snooze, ctx }

    public var reminderId: UUID
    public var kind: Kind
    public var n: Int
    public var date: Date
    public var title: String
    public var body: String

    public var id: String { Self.makeId(reminderId, kind, n) }

    public static func makeId(_ reminder: UUID, _ kind: Kind, _ n: Int) -> String {
        "\(reminder.uuidString.lowercased())|\(kind.rawValue)|\(n)"
    }

    /// Splits a notification id back into its reminder and kind.
    public static func parse(_ id: String) -> (reminder: UUID, kind: Kind, n: Int)? {
        let p = id.split(separator: "|")
        guard p.count == 3, let r = UUID(uuidString: String(p[0])), let k = Kind(rawValue: String(p[1])), let n = Int(p[2])
        else { return nil }
        return (r, k, n)
    }
}

public struct PlannerSettings: Sendable {
    /// When all-day reminders alert, as minutes after local midnight (default 09:00).
    public var allDayAlertMinutes: Int
    /// Pending notifications per app: iOS allows 64, keep 4 for snoozes (SPEC §5.5).
    public var cap: Int
    /// How many future slots of an `advance: auto` series to schedule.
    public var autoLookahead: Int

    public init(allDayAlertMinutes: Int = 9 * 60, cap: Int = 60, autoLookahead: Int = 24) {
        self.allDayAlertMinutes = allDayAlertMinutes
        self.cap = cap
        self.autoLookahead = autoLookahead
    }
}

/// Turns the local store into the set of time-based notifications to schedule (SPEC §5.5).
/// Pure: the app hands the result to UNUserNotificationCenter.
public enum NotificationPlanner {
    /// The instant an occurrence alerts: the due instant, or for all-day reminders the alert time on that date.
    public static func alertTime(for r: Reminder, occurrence: Date, settings: PlannerSettings) -> Date {
        guard r.allDay else { return occurrence }
        let tz = r.zone
        let day = WallTime(occurrence, in: tz).days
        return WallTime.atDay(day, secondOfDay: Int64(settings.allDayAlertMinutes * 60)).instant(in: tz)
    }

    /// The effective due (SPEC §5.2) of an open reminder, or nil without a due date.
    public static func effectiveDue(_ r: Reminder, now: Date) -> Date? {
        guard let due = r.dueAt else { return nil }
        return Recurrence.effectiveDue(r.repeat, in: r.zone, dueAt: due, now: now)
    }

    public static func plan(db: LocalDatabase, device: DeviceState, now: Date,
                            settings: PlannerSettings = PlannerSettings()) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
        for r in db.reminders.values where r.isOpen {
            if let list = db.lists[r.listId], list.isDeleted { continue }
            out.append(contentsOf: plan(reminder: r, db: db, device: device, now: now, settings: settings))
        }
        out.sort { ($0.date, $0.id) < ($1.date, $1.id) }
        return Array(out.prefix(settings.cap))
    }

    public static func plan(reminder r: Reminder, db: LocalDatabase, device: DeviceState, now: Date,
                            settings: PlannerSettings) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
        let listName = db.lists[r.listId]?.name ?? ""
        func add(_ kind: PlannedNotification.Kind, _ n: Int, _ date: Date, body: String) {
            guard date > now else { return }
            out.append(PlannedNotification(reminderId: r.id, kind: kind, n: n, date: date, title: r.title, body: body))
        }
        let snoozedUntil = device.snoozes[r.id].flatMap { $0 > now ? $0 : nil }

        if let eff = effectiveDue(r, now: now) {
            let fire = alertTime(for: r, occurrence: eff, settings: settings)
            let dueBody = listName
            // A snooze replaces the pending due alert and restarts the nag from the snooze time.
            if snoozedUntil == nil {
                add(.due, 0, fire, body: dueBody)
                if let early = r.earlyAlertMinutes, early > 0 {
                    add(.early, 0, fire.addingTimeInterval(TimeInterval(-early * 60)), body: earlyBody(early, listName))
                }
                if let nag = r.nag, device.contextFired[r.id] == nil {
                    for (k, t) in Recurrence.nagTimes(nag, firedAt: fire).enumerated() { add(.nag, k + 1, t, body: dueBody) }
                }
            }
            if let rule = r.repeat, rule.autoAdvance {
                let next = Recurrence.upcoming(rule, in: r.zone, after: eff, limit: settings.autoLookahead)
                for (k, t) in next.enumerated() {
                    add(.auto, k + 1, alertTime(for: r, occurrence: t, settings: settings), body: dueBody)
                }
            }
        }
        if let until = snoozedUntil {
            add(.snooze, 0, until, body: listName)
            if let nag = r.nag {
                for (k, t) in Recurrence.nagTimes(nag, firedAt: until).enumerated() { add(.nag, k + 1, t, body: listName) }
            }
        } else if let fired = device.contextFired[r.id], let nag = r.nag {
            // A context trigger fired: the nag series runs from that moment (SPEC §6).
            for (k, t) in Recurrence.nagTimes(nag, firedAt: fired).enumerated() { add(.nag, k + 1, t, body: listName) }
        }
        return out
    }

    private static func earlyBody(_ minutes: Int, _ list: String) -> String {
        let s: String
        if minutes % 1440 == 0 { s = minutes == 1440 ? "In 1 day" : "In \(minutes / 1440) days" }
        else if minutes % 60 == 0 { s = minutes == 60 ? "In 1 hour" : "In \(minutes / 60) hours" }
        else { s = "In \(minutes) min" }
        return list.isEmpty ? s : "\(s) · \(list)"
    }
}
