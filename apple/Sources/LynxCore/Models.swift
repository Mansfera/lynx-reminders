import Foundation

// Rows mirroring the server tables (SPEC §2). Keys are the server's snake_case column names.
// Lists and reminders encode every column, writing `null` for empty optionals: a bulk upsert
// through PostgREST takes its column set from the payload, so a missing key would not clear a value.

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var email: String?
    public var displayName: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: UUID, email: String?, displayName: String?) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }

    /// The name to show: display name, else the part of the email before `@`.
    public var name: String {
        if let n = displayName, !n.isEmpty { return n }
        if let e = email, let at = e.firstIndex(of: "@") { return String(e[..<at]) }
        return email ?? "Someone"
    }

    /// One or two letters for the avatar chip.
    public var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// List color tokens (SPEC §8).
public enum ListColor: String, Codable, CaseIterable, Sendable {
    case ink, slate, blue, green, yellow, orange, red, pink, brown
}

/// List icon keys (SPEC §8).
public enum ListIcon: String, Codable, CaseIterable, Sendable {
    case list, cart, house, briefcase, book, heart, star, flag, gift, plane, leaf, bolt
}

public struct LynxList: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ownerId: UUID?
    public var name: String
    public var color: String
    public var icon: String
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, color, icon, version
        case ownerId = "owner_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    /// The name of the list a device makes when it has none.
    public static let defaultName = "Reminders"

    /// Still looks exactly like the automatic default list (name, color and icon unchanged).
    public var isUntouchedDefault: Bool {
        name == Self.defaultName && color == ListColor.ink.rawValue && icon == ListIcon.list.rawValue && !isDeleted
    }

    public init(id: UUID = UUID(), ownerId: UUID?, name: String, color: ListColor = .ink, icon: ListIcon = .list,
                sortOrder: Double, now: Date = LynxTime.now()) {
        self.id = id
        self.ownerId = ownerId
        self.name = name
        self.color = color.rawValue
        self.icon = icon.rawValue
        self.sortOrder = sortOrder
        self.createdAt = now
        self.updatedAt = now
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ownerId, forKey: .ownerId)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(version, forKey: .version)
    }

    public var listColor: ListColor { ListColor(rawValue: color) ?? .ink }
    public var listIcon: ListIcon { ListIcon(rawValue: icon) ?? .list }
    public var isDeleted: Bool { deletedAt != nil }
}

public struct ListMember: Codable, Hashable, Sendable {
    public var listId: UUID
    public var userId: UUID
    public var role: String
    public var addedBy: UUID?
    public var createdAt: Date?
    public var version: Int64?
    public var profile: Profile?

    enum CodingKeys: String, CodingKey {
        case role, version, profile
        case listId = "list_id"
        case userId = "user_id"
        case addedBy = "added_by"
        case createdAt = "created_at"
    }

    public init(listId: UUID, userId: UUID, role: String, profile: Profile? = nil) {
        self.listId = listId
        self.userId = userId
        self.role = role
        self.profile = profile
    }

    public var isOwner: Bool { role == "owner" }
}

public struct ReminderShare: Codable, Hashable, Sendable {
    public var reminderId: UUID
    public var userId: UUID
    public var addedBy: UUID?
    public var createdAt: Date?
    public var version: Int64?
    public var profile: Profile?

    enum CodingKeys: String, CodingKey {
        case version, profile
        case reminderId = "reminder_id"
        case userId = "user_id"
        case addedBy = "added_by"
        case createdAt = "created_at"
    }

    public init(reminderId: UUID, userId: UUID, addedBy: UUID? = nil, profile: Profile? = nil) {
        self.reminderId = reminderId
        self.userId = userId
        self.addedBy = addedBy
        self.profile = profile
    }
}

public struct Invite: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var email: String
    public var listId: UUID?
    public var reminderId: UUID?
    public var invitedBy: UUID?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, email
        case listId = "list_id"
        case reminderId = "reminder_id"
        case invitedBy = "invited_by"
        case createdAt = "created_at"
    }

    public init(id: UUID, email: String, listId: UUID? = nil, reminderId: UUID? = nil, invitedBy: UUID? = nil) {
        self.id = id
        self.email = email
        self.listId = listId
        self.reminderId = reminderId
        self.invitedBy = invitedBy
    }
}

/// One entry of `rpc/sync_manifest`.
public struct ManifestEntry: Codable, Hashable, Sendable {
    public var t: String
    public var id: UUID
    public var v: Int64

    public init(t: String, id: UUID, v: Int64) {
        self.t = t
        self.id = id
        self.v = v
    }
}

/// Result of `rpc/share_list` and `rpc/share_reminder`.
public struct ShareResult: Codable, Hashable, Sendable {
    public var status: String
    public var userId: UUID?
    enum CodingKeys: String, CodingKey {
        case status
        case userId = "user_id"
    }
    public init(status: String, userId: UUID?) {
        self.status = status
        self.userId = userId
    }
}

// MARK: - Reminder

public struct Reminder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var listId: UUID
    public var parentId: UUID?
    public var createdBy: UUID?
    public var assigneeId: UUID?
    public var title: String
    public var notes: String?
    public var url: String?
    public var priority: Int
    public var flagged: Bool
    public var completedAt: Date?
    public var completedBy: UUID?
    public var dueAt: Date?
    public var allDay: Bool
    public var timeZone: String
    public var earlyAlertMinutes: Int?
    public var `repeat`: RepeatRule?
    public var nag: Nag?
    public var location: LocationTrigger?
    public var bluetooth: BluetoothTrigger?
    public var appTrigger: AppTrigger?
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, url, priority, flagged, nag, location, bluetooth, version
        case `repeat` = "repeat"
        case listId = "list_id"
        case parentId = "parent_id"
        case createdBy = "created_by"
        case assigneeId = "assignee_id"
        case completedAt = "completed_at"
        case completedBy = "completed_by"
        case dueAt = "due_at"
        case allDay = "all_day"
        case timeZone = "time_zone"
        case earlyAlertMinutes = "early_alert_minutes"
        case appTrigger = "app_trigger"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public init(id: UUID = UUID(), listId: UUID, parentId: UUID? = nil, createdBy: UUID?, title: String,
                sortOrder: Double, timeZone: String = TimeZone.current.identifier, now: Date = LynxTime.now()) {
        self.id = id
        self.listId = listId
        self.parentId = parentId
        self.createdBy = createdBy
        self.title = title
        self.priority = 0
        self.flagged = false
        self.allDay = false
        self.timeZone = timeZone
        self.sortOrder = sortOrder
        self.createdAt = now
        self.updatedAt = now
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        listId = try c.decode(UUID.self, forKey: .listId)
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        assigneeId = try c.decodeIfPresent(UUID.self, forKey: .assigneeId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        flagged = try c.decodeIfPresent(Bool.self, forKey: .flagged) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        completedBy = try c.decodeIfPresent(UUID.self, forKey: .completedBy)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
        earlyAlertMinutes = try c.decodeIfPresent(Int.self, forKey: .earlyAlertMinutes)
        // A malformed JSON column from another client must not make the whole row unreadable.
        `repeat` = try? c.decodeIfPresent(RepeatRule.self, forKey: .repeat)
        nag = try? c.decodeIfPresent(Nag.self, forKey: .nag)
        location = try? c.decodeIfPresent(LocationTrigger.self, forKey: .location)
        bluetooth = try? c.decodeIfPresent(BluetoothTrigger.self, forKey: .bluetooth)
        appTrigger = try? c.decodeIfPresent(AppTrigger.self, forKey: .appTrigger)
        sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        version = try c.decodeIfPresent(Int64.self, forKey: .version)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(listId, forKey: .listId)
        try c.encode(parentId, forKey: .parentId)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encode(assigneeId, forKey: .assigneeId)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(url, forKey: .url)
        try c.encode(priority, forKey: .priority)
        try c.encode(flagged, forKey: .flagged)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(completedBy, forKey: .completedBy)
        try c.encode(dueAt, forKey: .dueAt)
        try c.encode(allDay, forKey: .allDay)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(earlyAlertMinutes, forKey: .earlyAlertMinutes)
        try c.encode(`repeat`, forKey: .repeat)
        try c.encode(nag, forKey: .nag)
        try c.encode(location, forKey: .location)
        try c.encode(bluetooth, forKey: .bluetooth)
        try c.encode(appTrigger, forKey: .appTrigger)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(version, forKey: .version)
    }

    public var isCompleted: Bool { completedAt != nil }
    public var isDeleted: Bool { deletedAt != nil }
    public var isOpen: Bool { completedAt == nil && deletedAt == nil }
    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    public var hasContextTrigger: Bool { location != nil || bluetooth != nil || appTrigger != nil }
}

// MARK: - JSON columns

public enum RepeatUnit: String, Codable, CaseIterable, Sendable {
    case minute, hour, day, week, month, year
}

public struct RepeatWindow: Codable, Hashable, Sendable {
    public var start: String
    public var end: String
    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public struct RepeatEnd: Codable, Hashable, Sendable {
    public var type: String  // never | on | after
    public var date: String?
    public var count: Int?

    public init(type: String, date: String? = nil, count: Int? = nil) {
        self.type = type
        self.date = date
        self.count = count
    }

    public static let never = RepeatEnd(type: "never")
    public static func on(_ date: String) -> RepeatEnd { RepeatEnd(type: "on", date: date) }
    public static func after(_ count: Int) -> RepeatEnd { RepeatEnd(type: "after", count: count) }
}

/// SPEC §5. Optional fields stay optional so a rule round-trips exactly as another client wrote it.
public struct RepeatRule: Codable, Hashable, Sendable {
    public var unit: RepeatUnit
    public var interval: Int
    /// Local wall time `2026-11-14T09:00` in the reminder's time zone.
    public var anchor: String
    public var weekdays: [Int]?
    public var window: RepeatWindow?
    public var end: RepeatEnd?
    public var from: String?
    public var advance: String?
    public var completedCount: Int?

    enum CodingKeys: String, CodingKey {
        case unit, interval, anchor, weekdays, window, end, from, advance
        case completedCount = "completed_count"
    }

    public init(unit: RepeatUnit, interval: Int = 1, anchor: String, weekdays: [Int]? = nil, window: RepeatWindow? = nil,
                end: RepeatEnd? = nil, from: String? = nil, advance: String? = nil, completedCount: Int? = nil) {
        self.unit = unit
        self.interval = interval
        self.anchor = anchor
        self.weekdays = weekdays
        self.window = window
        self.end = end
        self.from = from
        self.advance = advance
        self.completedCount = completedCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(RepeatUnit.self, forKey: .unit)
        interval = max(1, try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1)
        anchor = try c.decode(String.self, forKey: .anchor)
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays)
        window = try c.decodeIfPresent(RepeatWindow.self, forKey: .window)
        end = try c.decodeIfPresent(RepeatEnd.self, forKey: .end)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        advance = try c.decodeIfPresent(String.self, forKey: .advance)
        completedCount = try c.decodeIfPresent(Int.self, forKey: .completedCount)
    }

    public var fromCompletion: Bool { from == "completion" }
    public var autoAdvance: Bool { advance == "auto" }
}

public struct Nag: Codable, Hashable, Sendable {
    public var everyMinutes: Int
    public var max: Int?

    enum CodingKeys: String, CodingKey {
        case everyMinutes = "every_minutes"
        case max
    }

    public init(everyMinutes: Int, max: Int?) {
        self.everyMinutes = everyMinutes
        self.max = max
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(everyMinutes, forKey: .everyMinutes)
        try c.encode(max, forKey: .max)  // null = "as many as fit in 24 h"
    }
}

public enum LocationEvent: String, Codable, Sendable, CaseIterable { case arrive, leave }

public struct LocationTrigger: Codable, Hashable, Sendable {
    public var name: String
    public var address: String?
    public var lat: Double
    public var lon: Double
    public var radius: Double
    public var on: LocationEvent

    public init(name: String, address: String?, lat: Double, lon: Double, radius: Double = 150, on: LocationEvent = .arrive) {
        self.name = name
        self.address = address
        self.lat = lat
        self.lon = lon
        self.radius = LocationTrigger.clampRadius(radius)
        self.on = on
    }

    public static func clampRadius(_ r: Double) -> Double { min(2000, max(100, r)) }
}

public enum BluetoothEvent: String, Codable, Sendable, CaseIterable { case connect, disconnect }

public struct BluetoothTrigger: Codable, Hashable, Sendable {
    public var name: String
    public var on: BluetoothEvent
    /// Platform ids: `mac` (IOBluetooth address, `a4-c3-61-…`), `android` (`A4:C3:61:…`).
    public var ids: [String: String]?

    public init(name: String, on: BluetoothEvent = .connect, ids: [String: String]? = nil) {
        self.name = name
        self.on = on
        self.ids = ids
    }
}

public enum AppEvent: String, Codable, Sendable { case open }

public struct AppTrigger: Codable, Hashable, Sendable {
    public var name: String
    public var on: AppEvent
    /// Bundle id on Apple platforms.
    public var apple: String?
    /// Package name on Android.
    public var android: String?

    public init(name: String, on: AppEvent = .open, apple: String? = nil, android: String? = nil) {
        self.name = name
        self.on = on
        self.apple = apple
        self.android = android
    }
}
