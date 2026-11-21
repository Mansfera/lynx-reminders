import Foundation

/// JSON in the server's shape (SPEC §2): snake_case keys, ISO-8601 UTC instants.
/// Instants are written with millisecond precision (`2026-11-14T08:00:00.123Z`) and read in any of the forms
/// Postgres/PostgREST produce (`Z` or `+00:00`, 0–9 fractional digits).
public enum LynxJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(LynxTime.format(date))
        }
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = LynxTime.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO-8601 instant: \(s)")
            }
            return date
        }
        return d
    }
}

/// Instants: formatting, parsing and the millisecond clock used for `updated_at`.
public enum LynxTime {
    /// `now`, truncated to whole milliseconds so it survives a round trip through JSON unchanged
    /// (last-writer-wins compares these values exactly).
    public static func now() -> Date { truncate(Date()) }

    public static func truncate(_ d: Date) -> Date {
        let ms = (d.timeIntervalSince1970 * 1000).rounded(.down)
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// `2026-11-14T08:00:00.123Z`; whole seconds are written without a fraction (`2026-11-14T08:00:00Z`).
    public static func format(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let secs = Int64(floorDiv(totalMs, 1000))
        let ms = Int(totalMs - secs * 1000)
        let days = floorDiv(secs, 86_400)
        let rem = secs - days * 86_400
        let (y, m, d) = Civil.date(fromDays: days)
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, m, d, Int(rem / 3600), Int(rem % 3600 / 60), Int(rem % 60))
        return ms == 0 ? base + "Z" : base + String(format: ".%03dZ", ms)
    }

    /// Parses `YYYY-MM-DDTHH:MM[:SS[.fff…]](Z|±HH[:MM]|±HHMM)`; a space instead of `T` is accepted.
    public static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        var i = 0
        func num(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = b[i + k]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += n
            return v
        }
        func expect(_ c: UInt8) -> Bool {
            guard i < b.count, b[i] == c else { return false }
            i += 1
            return true
        }
        guard let y = num(4), expect(45), let mo = num(2), expect(45), let d = num(2) else { return nil }
        guard i < b.count, b[i] == 84 || b[i] == 116 || b[i] == 32 else { return nil }
        i += 1
        guard let h = num(2), expect(58), let mi = num(2) else { return nil }
        var sec = 0
        var frac = 0.0
        if i < b.count, b[i] == 58 {
            i += 1
            guard let s2 = num(2) else { return nil }
            sec = s2
            if i < b.count, b[i] == 46 || b[i] == 44 {
                i += 1
                var digits = 0
                var v: Int64 = 0
                while i < b.count, b[i] >= 48, b[i] <= 57 {
                    if digits < 9 { v = v * 10 + Int64(b[i] - 48); digits += 1 }
                    i += 1
                }
                guard digits > 0 else { return nil }
                // Keep milliseconds exact (the common case) so values compare equal after a round trip.
                if digits <= 3 {
                    var ms = v
                    for _ in digits..<3 { ms *= 10 }
                    frac = Double(ms) / 1000
                } else {
                    var ns = v
                    for _ in digits..<9 { ns *= 10 }
                    frac = Double(ns) / 1_000_000_000
                }
            }
        }
        var offset = 0
        if i < b.count {
            let c = b[i]
            if c == 90 || c == 122 { i += 1 } else if c == 43 || c == 45 {
                i += 1
                guard let oh = num(2) else { return nil }
                var om = 0
                if i < b.count, b[i] == 58 { i += 1 }
                if i < b.count, let m2 = num(2) { om = m2 }
                offset = (oh * 3600 + om * 60) * (c == 45 ? -1 : 1)
            } else { return nil }
        }
        guard i == b.count else { return nil }
        let days = Civil.days(y, mo, d)
        let secs = days * 86_400 + Int64(h * 3600 + mi * 60 + sec) - Int64(offset)
        if frac == 0 { return Date(timeIntervalSince1970: Double(secs)) }
        // Same formula as truncate(): an integral number of milliseconds divided by 1000.
        let ms = (frac * 1000).rounded()
        if abs(frac * 1000 - ms) < 1e-6 {
            return Date(timeIntervalSince1970: (Double(secs) * 1000 + ms) / 1000)
        }
        return Date(timeIntervalSince1970: Double(secs) + frac)
    }
}

/// Proleptic Gregorian calendar arithmetic on day numbers (days since 1970-01-01). Exact and zone-free.
public enum Civil {
    public static func days(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
        let y2 = Int64(m <= 2 ? y - 1 : y)
        let era = floorDiv(y2, 400)
        let yoe = y2 - era * 400
        let mp = Int64((m + 9) % 12)
        let doy = (153 * mp + 2) / 5 + Int64(d) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func date(fromDays z0: Int64) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(m <= 2 ? y + 1 : y), Int(m), Int(d))
    }

    /// ISO weekday, 1 = Monday … 7 = Sunday. 1970-01-01 was a Thursday.
    public static func isoWeekday(days: Int64) -> Int {
        Int(((days % 7) + 7 + 3) % 7) + 1
    }

    public static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        }
    }
}

@inline(__always) func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
}
