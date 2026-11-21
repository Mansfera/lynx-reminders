import Foundation

/// A local wall time with no zone (`2026-11-14T09:00`), stored as seconds since 1970-01-01T00:00 wall time.
/// Arithmetic on it is plain integer arithmetic, like Python's naive `datetime` in the reference.
public struct WallTime: Hashable, Comparable, Sendable {
    public var seconds: Int64

    public init(seconds: Int64) { self.seconds = seconds }

    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        seconds = Civil.days(year, month, day) * 86_400 + Int64(hour * 3600 + minute * 60 + second)
    }

    /// `2026-11-14T09:00` (seconds optional).
    public init?(_ s: String) {
        let parts = s.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let d = parts[0].split(separator: "-").compactMap { Int($0) }
        let t = parts[1].split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        self.init(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1], second: t.count > 2 ? t[2] : 0)
    }

    public var days: Int64 { floorDiv(seconds, 86_400) }
    public var secondOfDay: Int64 { seconds - days * 86_400 }
    public var ymd: (Int, Int, Int) { Civil.date(fromDays: days) }
    public var hour: Int { Int(secondOfDay / 3600) }
    public var minute: Int { Int(secondOfDay % 3600 / 60) }
    public var isoWeekday: Int { Civil.isoWeekday(days: days) }

    /// `2026-11-14T09:00`
    public var string: String {
        let (y, m, d) = ymd
        return String(format: "%04d-%02d-%02dT%02d:%02d", y, m, d, hour, minute)
    }

    /// `2026-11-14`
    public var dateString: String {
        let (y, m, d) = ymd
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func + (a: WallTime, s: Int64) -> WallTime { WallTime(seconds: a.seconds + s) }
    public static func < (a: WallTime, b: WallTime) -> Bool { a.seconds < b.seconds }

    public static func atDay(_ days: Int64, secondOfDay: Int64) -> WallTime { WallTime(seconds: days * 86_400 + secondOfDay) }

    /// Months added with the day clamped to the target month's length; time of day kept.
    public func addingMonths(_ months: Int, day: Int) -> WallTime {
        let (y, m, _) = ymd
        let total = (m - 1) + months
        let y2 = y + Int(floorDiv(Int64(total), 12))
        let m2 = Int(Int64(total) - floorDiv(Int64(total), 12) * 12) + 1
        let d2 = min(day, Civil.daysInMonth(y2, m2))
        return WallTime.atDay(Civil.days(y2, m2, d2), secondOfDay: secondOfDay)
    }

    // MARK: zone conversion

    /// Wall time → instant. Gaps resolve forward, overlaps take the earlier offset
    /// (Python `fold=0`, java.time `ZonedDateTime.of`).
    public func instant(in tz: TimeZone) -> Date {
        let naive = Date(timeIntervalSince1970: TimeInterval(seconds))
        let before = Int64(tz.secondsFromGMT(for: naive.addingTimeInterval(-86_400)))
        let after = Int64(tz.secondsFromGMT(for: naive.addingTimeInterval(86_400)))
        func valid(_ off: Int64) -> Bool {
            Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds - off)))) == off
        }
        let vb = valid(before), va = valid(after)
        let off: Int64
        if vb && va {
            off = max(before, after)  // overlap: the earlier instant
        } else if vb {
            off = before
        } else if va {
            off = after
        } else {
            off = before  // gap: the pre-transition offset pushes the wall time forward
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds - off))
    }

    public init(_ instant: Date, in tz: TimeZone) {
        let secs = Int64(instant.timeIntervalSince1970.rounded(.down))
        seconds = secs + Int64(tz.secondsFromGMT(for: instant))
    }
}

/// `HH:MM` → seconds of the day.
func parseHM(_ s: String) -> Int64? {
    let p = s.split(separator: ":").compactMap { Int64($0) }
    guard p.count >= 2 else { return nil }
    return p[0] * 3600 + p[1] * 60
}

/// `YYYY-MM-DD` → day number.
func parseDay(_ s: String) -> Int64? {
    let p = s.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    return Civil.days(p[0], p[1], p[2])
}

/// Repeat rules, a port of `shared/reference/recurrence.py` (SPEC §5).
public enum Recurrence {
    /// Occurrences strictly after `after`, ascending, as instants. Ignores `end` (callers apply it).
    /// Starts close to `after` instead of at the anchor, so old series stay cheap.
    public static func occurrences(_ rule: RepeatRule, in tz: TimeZone, after: Date) -> AnyIterator<Date> {
        guard let anchor = WallTime(rule.anchor) else { return AnyIterator { nil } }
        let n = Int64(max(1, rule.interval))
        let weekdays = Array(Set((rule.weekdays ?? []).filter { (1...7).contains($0) })).sorted()
        let afterLocalDays = WallTime(after, in: tz).days
        var guardCount = 0
        let guardLimit = 200_000

        switch rule.unit {
        case .minute, .hour:
            let step = n * (rule.unit == .minute ? 60 : 3600)
            if let window = rule.window, let ws = parseHM(window.start), let we = parseHM(window.end) {
                // Each local day (only listed weekdays): window.start + k·step while ≤ window.end on the same day.
                var day = max(anchor.days, afterLocalDays - 1)
                var t: WallTime? = nil
                var emptyDays = 0
                return AnyIterator {
                    while true {
                        if t == nil {
                            if emptyDays > 3700 { return nil }  // no slot for ~10 years: a malformed window
                            if weekdays.isEmpty || weekdays.contains(Civil.isoWeekday(days: day)) {
                                t = WallTime.atDay(day, secondOfDay: ws)
                            } else {
                                day += 1
                                emptyDays += 1
                                continue
                            }
                        }
                        let cur = t!
                        if cur.days != day || cur.secondOfDay > we {
                            t = nil
                            day += 1
                            emptyDays += 1
                            continue
                        }
                        t = cur + step
                        if cur >= anchor {
                            let inst = cur.instant(in: tz)
                            if inst > after {
                                emptyDays = 0
                                return inst
                            }
                        }
                    }
                }
            }
            // Absolute durations: the rhythm is real time; DST does not shift it.
            let start = anchor.instant(in: tz).timeIntervalSince1970
            var k: Int64 = 0
            let a = after.timeIntervalSince1970
            if a >= start { k = Int64(((a - start) / Double(step)).rounded(.down)) }
            return AnyIterator {
                while true {
                    let inst = Date(timeIntervalSince1970: start + Double(k * step))
                    k += 1
                    if inst > after { return inst }
                    guardCount += 1
                    if guardCount > guardLimit { return nil }
                }
            }

        case .day, .week:
            if rule.unit == .week && !weekdays.isEmpty { break }
            let stepDays = rule.unit == .day ? n : n * 7
            var k = max(0, floorDiv(afterLocalDays - anchor.days - 2, stepDays))
            return AnyIterator {
                while true {
                    let inst = (anchor + k * stepDays * 86_400).instant(in: tz)
                    k += 1
                    if inst > after { return inst }
                    guardCount += 1
                    if guardCount > guardLimit { return nil }
                }
            }

        case .month, .year:
            let stepMonths = rule.unit == .month ? n : n * 12
            let (ay, am, aday) = anchor.ymd
            let (by, bm, _) = Civil.date(fromDays: afterLocalDays)
            let monthsBetween = Int64((by - ay) * 12 + (bm - am))
            var k = max(0, floorDiv(monthsBetween - 2, stepMonths))
            return AnyIterator {
                while true {
                    let inst = anchor.addingMonths(Int(k * stepMonths), day: aday).instant(in: tz)
                    k += 1
                    if inst > after { return inst }
                    guardCount += 1
                    if guardCount > guardLimit { return nil }
                }
            }
        }

        // week with weekdays
        do {
            // Weeks start on Monday; week index w counts from the anchor's week; every n-th week.
            let week0 = anchor.days - Int64(anchor.isoWeekday - 1)
            var w = max(0, floorDiv(afterLocalDays - week0 - 14, 7 * n))
            var idx = 0
            return AnyIterator {
                while true {
                    if idx >= weekdays.count {
                        idx = 0
                        w += 1
                        guardCount += 1
                        if guardCount > guardLimit { return nil }
                    }
                    let wd = Int64(weekdays[idx])
                    idx += 1
                    let t = WallTime.atDay(week0 + w * n * 7 + wd - 1, secondOfDay: anchor.secondOfDay)
                    if t >= anchor {
                        let inst = t.instant(in: tz)
                        if inst > after { return inst }
                    }
                }
            }

        }
    }

    /// `end.on`: occurrences whose local date is after `end.date` don't exist. (`after` is counted in completions.)
    public static func withinEnd(_ rule: RepeatRule, _ instant: Date, in tz: TimeZone) -> Bool {
        guard let end = rule.end, end.type == "on", let date = end.date, let last = parseDay(date) else { return true }
        return WallTime(instant, in: tz).days <= last
    }

    /// First occurrence strictly after `after`, or nil when the series has ended.
    public static func next(_ rule: RepeatRule, in tz: TimeZone, after: Date) -> Date? {
        guard let occ = occurrences(rule, in: tz, after: after).next() else { return nil }
        return withinEnd(rule, occ, in: tz) ? occ : nil
    }

    /// Up to `limit` occurrences after `after`, stopping at the end of the series.
    public static func upcoming(_ rule: RepeatRule, in tz: TimeZone, after: Date, limit: Int) -> [Date] {
        var out: [Date] = []
        let it = occurrences(rule, in: tz, after: after)
        while out.count < limit, let occ = it.next() {
            guard withinEnd(rule, occ, in: tz) else { break }
            out.append(occ)
        }
        return out
    }

    /// SPEC §5.2. `advance: auto`: the latest occurrence ≤ now that is ≥ due_at; before due_at it is due_at.
    public static func effectiveDue(_ rule: RepeatRule?, in tz: TimeZone, dueAt: Date, now: Date) -> Date {
        guard let rule, rule.autoAdvance, now >= dueAt else { return dueAt }
        var cur = dueAt
        let it = occurrences(rule, in: tz, after: dueAt)
        while let occ = it.next() {
            if !withinEnd(rule, occ, in: tz) || occ > now { return cur }
            cur = occ
        }
        return cur
    }

    public struct Completion: Equatable, Sendable {
        /// Completed for good (the series ended).
        public var completed: Bool
        public var dueAt: Date
        public var rule: RepeatRule
    }

    /// SPEC §5.3: what completing a repeating reminder does.
    public static func complete(_ input: RepeatRule, in tz: TimeZone, dueAt: Date, completedAt: Date) -> Completion {
        var rule = input
        let count = (rule.completedCount ?? 0) + 1
        rule.completedCount = count
        let current = effectiveDue(rule, in: tz, dueAt: dueAt, now: completedAt)

        if let end = rule.end, end.type == "after", count >= (end.count ?? Int.max) {
            return Completion(completed: true, dueAt: current, rule: rule)
        }

        if rule.fromCompletion {
            let n = max(1, rule.interval)
            let anchorTime = WallTime(rule.anchor)?.secondOfDay ?? 0
            let doneLocal = WallTime(completedAt, in: tz)
            let next: Date
            let newAnchor: WallTime
            switch rule.unit {
            case .minute, .hour:
                next = completedAt.addingTimeInterval(TimeInterval(n * (rule.unit == .minute ? 60 : 3600)))
                newAnchor = WallTime(next, in: tz)
            case .day, .week, .month, .year:
                let base = WallTime.atDay(doneLocal.days, secondOfDay: anchorTime)
                switch rule.unit {
                case .day: newAnchor = base + Int64(n) * 86_400
                case .week: newAnchor = base + Int64(n) * 7 * 86_400
                case .month: newAnchor = base.addingMonths(n, day: base.ymd.2)
                default: newAnchor = base.addingMonths(n * 12, day: base.ymd.2)
                }
                next = newAnchor.instant(in: tz)
            }
            // Seconds are dropped like the reference's replace(second=0).
            rule.anchor = WallTime(seconds: newAnchor.seconds - newAnchor.seconds % 60).string
            if !withinEnd(rule, next, in: tz) {
                return Completion(completed: true, dueAt: current, rule: rule)
            }
            return Completion(completed: false, dueAt: next, rule: rule)
        }

        guard let next = next(rule, in: tz, after: current) else {
            return Completion(completed: true, dueAt: current, rule: rule)
        }
        return Completion(completed: false, dueAt: next, rule: rule)
    }

    /// SPEC §5.4: alert again every N minutes after `firedAt`, up to `max` (null = 24 h worth, capped at 48).
    public static func nagTimes(_ nag: Nag, firedAt: Date) -> [Date] {
        let every = max(1, nag.everyMinutes)
        let mx = nag.max ?? min(48, (24 * 60) / every)
        guard mx > 0 else { return [] }
        return (1...mx).map { firedAt.addingTimeInterval(TimeInterval(every * $0 * 60)) }
    }

    /// The anchor string for a wall time: `2026-11-14T09:00`.
    public static func anchor(for instant: Date, in tz: TimeZone) -> String { WallTime(instant, in: tz).string }
}
