import LynxCore
import SwiftUI

/// The Today hero (SPEC §8): sky stage, the open count big, "3 overdue · next at 14:30", and the day ruler.
struct TodayStage: View {
    let summary: SmartQueries.TodaySummary
    let now: Date
    @Environment(\.palette) private var pal

    var body: some View {
        Stage {
            VStack(alignment: .leading, spacing: Brand.Space.l) {
                HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s) {
                    Text("\(summary.open)")
                        .font(Brand.hero)
                        .tracking(-4)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(summary.open == 1 ? "open today" : "open today").font(Brand.display(17)).foregroundStyle(pal.fg.opacity(0.6))
                    Spacer()
                }
                .frame(height: 78)
                DayRuler(marks: summary.marks, now: now)
                captionText.font(Brand.text(13, .medium))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.open) open today. \(caption)")
    }

    /// Only the overdue part is red: color marks the problem, not the sentence.
    private var captionText: Text {
        let rest = summary.next.map { "next at \(Formats.time($0))" }
        if summary.overdue > 0 {
            let red = Text("\(summary.overdue) overdue").foregroundColor(pal.signal)
            guard let rest else { return red }
            return red + Text(" · \(rest)").foregroundColor(pal.fg.opacity(0.7))
        }
        return Text(caption).foregroundColor(pal.fg.opacity(0.7))
    }

    private var caption: String {
        var parts: [String] = []
        if summary.overdue > 0 { parts.append("\(summary.overdue) overdue") }
        if let n = summary.next { parts.append("next at \(Formats.time(n))") }
        if parts.isEmpty { return summary.open == 0 ? "Nothing left for today" : "Nothing else timed today" }
        return parts.joined(separator: " · ")
    }
}

/// The Lynx tick ruler as 24 h of today: a major tick every 6 h, labels 00 06 12 18 24 in Geist Mono,
/// a dot per reminder at its time, the past drawn as a line, overdue dots in signal red, a "now" marker.
struct DayRuler: View {
    let marks: [SmartQueries.TodaySummary.Mark]
    let now: Date
    @Environment(\.palette) private var pal

    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let day = (cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).timeIntervalSince(start)
        let frac = { (d: Date) -> CGFloat in CGFloat(min(max(d.timeIntervalSince(start) / day, 0), 1)) }
        Canvas { ctx, size in
            let n = 25  // one tick per hour
            let base = size.height
            for i in 0..<n {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let major = i % 6 == 0
                let h: CGFloat = major ? 8 : 4
                ctx.fill(Path(CGRect(x: x - 0.5, y: base - h, width: 1, height: h)), with: .color(pal.fg.opacity(major ? 0.45 : 0.2)))
            }
            let nx = size.width * frac(now)
            // The covered part of the day.
            ctx.fill(Path(CGRect(x: 0, y: base - 1.5, width: nx, height: 1.5)), with: .color(pal.fg.opacity(0.8)))
            // Now marker.
            ctx.fill(Path(CGRect(x: nx - 0.75, y: base - 14, width: 1.5, height: 14)), with: .color(pal.fg))
            for m in marks {
                let x = size.width * frac(m.date)
                let c: Color = m.overdue ? pal.signal : pal.fg
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 0, width: 8, height: 8)), with: .color(c))
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { t in
                    Text(t)
                    if t != "24" { Spacer() }
                }
            }
            .font(Brand.mono(10, .regular)).foregroundStyle(pal.fg.opacity(0.55))
            .offset(y: 15)
        }
        .padding(.bottom, Brand.Space.m)
        .accessibilityLabel("Day ruler: \(marks.count) reminders today")
    }
}
