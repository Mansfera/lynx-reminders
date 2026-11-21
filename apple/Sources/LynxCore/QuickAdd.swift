import Foundation

/// Light natural-language parsing for quick add (SPEC §7). Optional sugar: the editor is the source of truth.
public struct QuickAddResult: Equatable, Sendable {
    public var title: String
    public var dueAt: Date?
    public var allDay: Bool = false
    public var `repeat`: RepeatRule?
    public var priority: Int = 0
    public var listId: UUID?
    /// The `#tag` as typed, when it matched no list.
    public var unknownListTag: String?
}

public enum QuickAddParser {
    static let weekdayNames: [String: Int] = [
        "mon": 1, "monday": 1, "tue": 2, "tues": 2, "tuesday": 2, "wed": 3, "wednesday": 3,
        "thu": 4, "thur": 4, "thurs": 4, "thursday": 4, "fri": 5, "friday": 5,
        "sat": 6, "saturday": 6, "sun": 7, "sunday": 7,
    ]

    static func unit(_ s: String) -> RepeatUnit? {
        switch s {
        case "min", "mins", "minute", "minutes", "m": return .minute
        case "h", "hr", "hrs", "hour", "hours": return .hour
        case "day", "days", "d": return .day
        case "week", "weeks", "w", "wk", "wks": return .week
        case "month", "months": return .month
        case "year", "years", "yr", "yrs": return .year
        default: return nil
        }
    }

    /// `9`, `9:30`, `21:00`, `9pm`, `9:30am`, `9.30` → minutes after midnight.
    static func time(_ s: String, requireMarker: Bool) -> Int? {
        var t = s
        var pm: Bool? = nil
        if t.hasSuffix("am") { pm = false; t.removeLast(2) } else if t.hasSuffix("pm") { pm = true; t.removeLast(2) }
        let parts = t.split(separator: t.contains(":") ? ":" : ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let h = Int(parts[0]), parts[0].count <= 2 else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let m = Int(parts[1]), (0..<60).contains(m) else { return nil }
            minute = m
        } else if requireMarker && pm == nil {
            return nil  // a bare number is not a time unless it follows "at"
        }
        var hour = h
        if let pm {
            guard (1...12).contains(h) else { return nil }
            hour = h % 12 + (pm ? 12 : 0)
        }
        guard (0..<24).contains(hour) else { return nil }
        return hour * 60 + minute
    }

    public static func parse(_ text: String, lists: [LynxList], now: Date, timeZone: TimeZone = .current) -> QuickAddResult {
        let raw = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let low = raw.map { $0.lowercased() }
        var used = Set<Int>()
        var result = QuickAddResult(title: "")
        let nowLocal = WallTime(now, in: timeZone)
        var day: Int64? = nil
        var minutes: Int? = nil
        var absolute: Date? = nil

        var i = 0
        while i < low.count {
            let w = low[i]
            func consume(_ n: Int) {
                for k in i..<min(low.count, i + n) { used.insert(k) }
                i += n
            }
            // priority
            if w == "!" || w == "!!" || w == "!!!" {
                result.priority = w.count
                consume(1); continue
            }
            // #list
            if w.hasPrefix("#"), w.count > 1 {
                let tag = String(raw[i].dropFirst())
                let norm = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
                if let l = lists.first(where: { norm($0.name) == norm(tag) })
                    ?? lists.first(where: { norm($0.name).hasPrefix(norm(tag)) }) {
                    result.listId = l.id
                } else {
                    result.unknownListTag = tag
                }
                consume(1); continue
            }
            if w == "today" { day = nowLocal.days; consume(1); continue }
            if w == "tomorrow" || w == "tmr" || w == "tmrw" { day = nowLocal.days + 1; consume(1); continue }
            if w == "tonight" { day = nowLocal.days; minutes = minutes ?? 20 * 60; consume(1); continue }
            // weekday, optionally "on mon" / "next mon"
            if (w == "on" || w == "next"), i + 1 < low.count, let wd = weekdayNames[low[i + 1]] {
                day = nextWeekday(wd, from: nowLocal.days, skipWeek: w == "next")
                consume(2); continue
            }
            if let wd = weekdayNames[w] {
                day = nextWeekday(wd, from: nowLocal.days, skipWeek: false)
                consume(1); continue
            }
            // at 9 / at 9:30 / at 9pm (also "at 9 pm")
            if w == "at", i + 1 < low.count {
                var token = low[i + 1]
                var n = 2
                if i + 2 < low.count, low[i + 2] == "am" || low[i + 2] == "pm" { token += low[i + 2]; n = 3 }
                if let m = time(token, requireMarker: false) { minutes = m; consume(n); continue }
            }
            if let m = time(w, requireMarker: true) { minutes = m; consume(1); continue }
            // in 2 hours / in 30 min
            if w == "in", i + 2 < low.count, let n = Int(low[i + 1]), n > 0, let u = unit(low[i + 2]) {
                let secs: Int
                switch u {
                case .minute: secs = n * 60
                case .hour: secs = n * 3600
                case .day: secs = n * 86_400
                case .week: secs = n * 7 * 86_400
                case .month: secs = n * 30 * 86_400
                case .year: secs = n * 365 * 86_400
                }
                absolute = now.addingTimeInterval(TimeInterval(secs))
                consume(3); continue
            }
            // every day / every 45 min / every 2 weeks / daily
            if w == "every", i + 1 < low.count {
                if let u = unit(low[i + 1]) {
                    result.repeat = RepeatRule(unit: u, interval: 1, anchor: "")
                    consume(2); continue
                }
                if i + 2 < low.count, let n = Int(low[i + 1]), n > 0, let u = unit(low[i + 2]) {
                    result.repeat = RepeatRule(unit: u, interval: n, anchor: "")
                    consume(3); continue
                }
                if let wd = weekdayNames[low[i + 1]] {
                    result.repeat = RepeatRule(unit: .week, interval: 1, anchor: "", weekdays: [wd])
                    day = day ?? nextWeekday(wd, from: nowLocal.days, skipWeek: false)
                    consume(2); continue
                }
            }
            let shorthand: [String: RepeatUnit] = ["daily": .day, "weekly": .week, "monthly": .month, "yearly": .year, "hourly": .hour]
            if let u = shorthand[w] {
                result.repeat = RepeatRule(unit: u, interval: 1, anchor: "")
                consume(1); continue
            }
            i += 1
        }

        result.title = raw.enumerated().filter { !used.contains($0.offset) }.map(\.element).joined(separator: " ")

        // Resolve the due date.
        if let absolute {
            result.dueAt = Date(timeIntervalSince1970: (absolute.timeIntervalSince1970 / 60).rounded() * 60)
        } else if let minutes {
            var d = day ?? nowLocal.days
            let candidate = WallTime.atDay(d, secondOfDay: Int64(minutes * 60))
            if day == nil, candidate.instant(in: timeZone) <= now { d += 1 }  // "at 9" after 9 means tomorrow
            result.dueAt = WallTime.atDay(d, secondOfDay: Int64(minutes * 60)).instant(in: timeZone)
        } else if let day {
            result.dueAt = WallTime.atDay(day, secondOfDay: 0).instant(in: timeZone)
            result.allDay = true
        } else if let rule = result.repeat {
            switch rule.unit {
            case .minute, .hour:
                let step = TimeInterval(rule.interval * (rule.unit == .minute ? 60 : 3600))
                result.dueAt = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.up) * 60 + step)
            default:
                result.dueAt = WallTime.atDay(nowLocal.days, secondOfDay: 0).instant(in: timeZone)
                result.allDay = true
            }
        }
        if var rule = result.repeat, let due = result.dueAt {
            rule.anchor = Recurrence.anchor(for: due, in: timeZone)
            result.repeat = rule
        }
        return result
    }

    static func nextWeekday(_ wd: Int, from today: Int64, skipWeek: Bool) -> Int64 {
        let cur = Civil.isoWeekday(days: today)
        var delta = Int64((wd - cur + 7) % 7)
        if delta == 0 { delta = 7 }  // "mon" on a Monday means next Monday
        _ = skipWeek  // "next mon" reads the same as "mon": the coming one
        return today + delta
    }
}
