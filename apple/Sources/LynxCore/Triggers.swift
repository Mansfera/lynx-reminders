import Foundation

/// Context trigger matching (SPEC §6). Platform code observes the system and feeds events in here.
public enum TriggerPlatform: String, Sendable {
    case mac, ios, android

    /// Key in `bluetooth.ids` for this platform. iOS records no id (it cannot list devices).
    var bluetoothKey: String? {
        switch self {
        case .mac: return "mac"
        case .android: return "android"
        case .ios: return nil
        }
    }
}

public enum TriggerEvent: Sendable, Equatable {
    case bluetooth(name: String, id: String?, event: BluetoothEvent)
    case app(name: String, bundleId: String?)
    case location(regionId: UUID, event: LocationEvent)

    /// Kind used in the cooldown key.
    public var kind: String {
        switch self {
        case .bluetooth: return "bluetooth"
        case .app: return "app"
        case .location: return "location"
        }
    }
}

public enum TriggerMatcher {
    public static let cooldown: TimeInterval = 15 * 60

    /// §6.3: by this platform's id when the trigger has one, otherwise by name (case-insensitive, exact).
    /// When the event carries no id (e.g. a Shortcuts automation passes only a name) the name decides.
    public static func matches(_ t: BluetoothTrigger, name: String, id: String?, event: BluetoothEvent,
                               platform: TriggerPlatform) -> Bool {
        guard t.on == event else { return false }
        if let key = platform.bluetoothKey, let tid = t.ids?[key], !tid.isEmpty, let id, !id.isEmpty {
            return normalizeAddress(tid) == normalizeAddress(id)
        }
        return sameName(t.name, name)
    }

    /// §6.4: by this platform's identifier when both sides have it, otherwise by display name (case-insensitive).
    public static func matches(_ t: AppTrigger, name: String, bundleId: String?, platform: TriggerPlatform) -> Bool {
        let tid = platform == .android ? t.android : t.apple
        if let tid, !tid.isEmpty, let bundleId, !bundleId.isEmpty {
            return tid.caseInsensitiveCompare(bundleId) == .orderedSame
        }
        return sameName(t.name, name)
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        return !x.isEmpty && x.compare(y, options: [.caseInsensitive]) == .orderedSame
    }

    /// `A4:C3:61:…`, `a4-c3-61-…` and `a4c361…` are the same address.
    static func normalizeAddress(_ s: String) -> String {
        s.lowercased().filter { $0.isHexDigit }
    }

    public static func cooldownKey(_ reminder: UUID, _ kind: String) -> String {
        "\(reminder.uuidString.lowercased())|\(kind)"
    }

    /// Open reminders whose trigger matches the event and that are out of cooldown.
    public static func reminders(for event: TriggerEvent, in db: LocalDatabase, device: DeviceState, now: Date,
                                 platform: TriggerPlatform) -> [Reminder] {
        db.reminders.values.filter { r in
            guard r.isOpen, db.list(r.listId) != nil || db.shares.contains(where: { $0.reminderId == r.id || $0.reminderId == r.parentId }) else {
                return false
            }
            let matched: Bool
            switch event {
            case let .bluetooth(name, id, ev):
                matched = r.bluetooth.map { matches($0, name: name, id: id, event: ev, platform: platform) } ?? false
            case let .app(name, bundleId):
                matched = r.appTrigger.map { matches($0, name: name, bundleId: bundleId, platform: platform) } ?? false
            case let .location(regionId, ev):
                matched = r.id == regionId && r.location?.on == ev
            }
            guard matched else { return false }
            if let last = device.cooldowns[cooldownKey(r.id, event.kind)], now.timeIntervalSince(last) < cooldown {
                return false
            }
            return true
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Records that reminders fired: starts the cooldown and the nag series.
    public static func recordFired(_ reminders: [Reminder], event: TriggerEvent, device: inout DeviceState, now: Date) {
        for r in reminders {
            device.cooldowns[cooldownKey(r.id, event.kind)] = now
            device.contextFired[r.id] = now
        }
    }
}

/// Region selection for platforms with a monitoring limit (iOS: 20 regions → the nearest 20).
public enum RegionPlanner {
    public struct Region: Hashable, Sendable {
        public var reminderId: UUID
        public var lat: Double
        public var lon: Double
        public var radius: Double
        public var on: LocationEvent
    }

    public static func regions(in db: LocalDatabase, near origin: (lat: Double, lon: Double)?, limit: Int) -> [Region] {
        var all: [Region] = db.reminders.values.compactMap { r in
            guard r.isOpen, let l = r.location else { return nil }
            return Region(reminderId: r.id, lat: l.lat, lon: l.lon, radius: LocationTrigger.clampRadius(l.radius), on: l.on)
        }
        if let origin {
            all.sort { distance(origin, ($0.lat, $0.lon)) < distance(origin, ($1.lat, $1.lon)) }
        } else {
            all.sort { $0.reminderId.uuidString < $1.reminderId.uuidString }
        }
        return Array(all.prefix(limit))
    }

    /// Great-circle distance in meters.
    public static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(h), sqrt(1 - h))
    }
}
