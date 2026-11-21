import Foundation
import LynxCore

/// Human text for dates, repeats and alerts. Times follow the system's 12/24 h setting.
enum Formats {
    static var calendar: Calendar { .current }

    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute()) }

    static func dayName(_ day: Date, now: Date) -> String {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let diff = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: day)).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default:
            let sameYear = cal.component(.year, from: day) == cal.component(.year, from: now)
            return sameYear ? day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                : day.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    /// Due text for a row: `14:30`, `Tomorrow 09:00`, `Mon 17 Nov`.
    static func due(_ r: Reminder, effective: Date?, now: Date) -> String? {
        guard let due = effective else { return nil }
        if r.allDay {
            let (y, m, d) = WallTime(due, in: r.zone).ymd
            guard let day = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
            return dayName(day, now: now)
        }
        let name = dayName(due, now: now)
        return name == "Today" ? time(due) : "\(name) \(time(due))"
    }

    static func unitName(_ u: RepeatUnit, _ n: Int) -> String {
        let one: String, many: String
        switch u {
        case .minute: one = "minute"; many = "min"
        case .hour: one = "hour"; many = "hours"
        case .day: one = "day"; many = "days"
        case .week: one = "week"; many = "weeks"
        case .month: one = "month"; many = "months"
        case .year: one = "year"; many = "years"
        }
        return n == 1 ? one : many
    }

    static let weekdayShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// `Daily`, `Every 45 min · 09:00–18:00`, `Every 2 weeks · Mon, Thu`.
    static func repeatText(_ rule: RepeatRule, short: Bool = false) -> String {
        var s: String
        let n = rule.interval
        switch (rule.unit, n) {
        case (.day, 1): s = "Daily"
        case (.week, 1): s = "Weekly"
        case (.month, 1): s = "Monthly"
        case (.year, 1): s = "Yearly"
        case (.hour, 1): s = "Hourly"
        case (.minute, _): s = "Every \(n) min"
        default: s = "Every \(n) \(unitName(rule.unit, n))"
        }
        if let wd = rule.weekdays, !wd.isEmpty {
            let sorted = wd.sorted()
            if sorted == [1, 2, 3, 4, 5] { s += " · weekdays" }
            else if sorted == [6, 7] { s += " · weekends" }
            else if !short { s += " · " + sorted.compactMap { (1...7).contains($0) ? weekdayShort[$0 - 1] : nil }.joined(separator: ", ") }
        }
        if let w = rule.window, !short { s += " · \(w.start)–\(w.end)" }
        if !short {
            if rule.fromCompletion { s += " · after done" }
            if rule.autoAdvance { s += " · rolls on" }
            if let e = rule.end {
                if e.type == "on", let d = e.date { s += " · until \(d)" }
                if e.type == "after", let c = e.count { s += " · \(c) times" }
            }
        }
        return s
    }

    /// `15 min`, `1 hour`, `2 days` — used for early alerts and nags.
    static func duration(minutes m: Int) -> String {
        if m % 1440 == 0 { return m == 1440 ? "1 day" : "\(m / 1440) days" }
        if m % 60 == 0 { return m == 60 ? "1 hour" : "\(m / 60) hours" }
        return "\(m) min"
    }
}
