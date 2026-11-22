import LynxCore
import SwiftUI

/// Repeat rules (SPEC §5): presets plus custom periods in minutes/hours/days/weeks/months/years, weekdays,
/// a daily window for minute/hour rhythms, end, from completion, and auto-advance.
struct RepeatEditor: View {
    let reminderId: UUID
    @Binding var expanded: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    private var reminder: Reminder? { model.db.reminders[reminderId] }
    private var rule: RepeatRule? { reminder?.repeat }

    enum Preset: String, CaseIterable, Identifiable {
        case never, daily, weekdays, weekly, monthly, yearly, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: return "Never"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            case .custom: return "Custom…"
            }
        }
    }

    private func edit(_ body: @escaping (inout RepeatRule) -> Void) {
        model.updateReminder(reminderId) { r in
            guard var rule = r.repeat else { return }
            body(&rule)
            rule.interval = max(1, rule.interval)
            r.repeat = rule
        }
    }

    private func apply(_ p: Preset) {
        model.updateReminder(reminderId) { r in
            guard let due = r.dueAt else { return }
            let anchor = Recurrence.anchor(for: due, in: r.zone)
            switch p {
            case .never: r.repeat = nil
            case .daily: r.repeat = RepeatRule(unit: .day, anchor: anchor)
            case .weekdays: r.repeat = RepeatRule(unit: .week, anchor: anchor, weekdays: [1, 2, 3, 4, 5])
            case .weekly: r.repeat = RepeatRule(unit: .week, anchor: anchor)
            case .monthly: r.repeat = RepeatRule(unit: .month, anchor: anchor)
            case .yearly: r.repeat = RepeatRule(unit: .year, anchor: anchor)
            case .custom: if r.repeat == nil { r.repeat = RepeatRule(unit: .day, interval: 2, anchor: anchor) }
            }
        }
        expanded = p == .custom
    }

    var body: some View {
        VStack(spacing: 0) {
            FormRow("Repeat", symbol: "arrow.clockwise") {
                Menu {
                    ForEach(Preset.allCases) { p in Button(p.title) { apply(p) } }
                } label: {
                    Text(rule.map { Formats.repeatText($0, short: true) } ?? "Never").font(Brand.text(13))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                if rule != nil {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.muted)
                            .frame(width: 22, height: 22).background(pal.sunk, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide repeat options" : "Show repeat options")
                }
            }
            if let rule, expanded {
                Hairline()
                custom(rule).transition(.opacity)
            }
        }
        .animation(Motion.content, value: expanded)
    }

    @ViewBuilder
    private func custom(_ rule: RepeatRule) -> some View {
        VStack(alignment: .leading, spacing: Brand.Space.m) {
            HStack(spacing: Brand.Space.s) {
                Text("Every").font(Brand.text(13))
                TextField("", value: Binding(get: { rule.interval }, set: { v in edit { $0.interval = v } }), format: .number)
                    .textFieldStyle(.plain).font(Brand.mono(13)).multilineTextAlignment(.center)
                    .frame(width: 44).padding(.vertical, Brand.Space.xxs)
                    .background(pal.sunk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Stepper("", value: Binding(get: { rule.interval }, set: { v in edit { $0.interval = v } }), in: 1...999).labelsHidden()
                Picker("", selection: Binding(get: { rule.unit }, set: { u in edit { r in
                    r.unit = u
                    if u != .minute && u != .hour { r.window = nil }
                    if u != .week && u != .minute && u != .hour { r.weekdays = nil }
                } })) {
                    ForEach(RepeatUnit.allCases, id: \.self) { Text(Formats.unitName($0, rule.interval)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if [.week, .minute, .hour].contains(rule.unit) {
                VStack(alignment: .leading, spacing: Brand.Space.xs) {
                    Caption(rule.unit == .week ? "On" : "Only on")
                    WeekdayPicker(selection: Binding(get: { Set(rule.weekdays ?? []) }, set: { s in
                        edit { $0.weekdays = s.isEmpty ? nil : s.sorted() }
                    }))
                }
            }
            if rule.unit == .minute || rule.unit == .hour {
                windowRow(rule)
            }
            endRow(rule)
            HStack {
                Text("Next one counts from").font(Brand.text(13))
                Spacer()
                CapsuleTabs(items: [("due", "Due date"), ("completion", "Completion")],
                            selection: Binding(get: { rule.from ?? "due" }, set: { v in edit { $0.from = v == "due" ? nil : v } }))
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roll on without me").font(Brand.text(13))
                    Text("Moves to the next slot by itself; never overdue by more than one slot.")
                        .font(Brand.caption).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { rule.autoAdvance }, set: { v in edit { $0.advance = v ? "auto" : nil } }))
                    .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
            }
        }
        .padding(Brand.Space.l)
    }

    private func windowRow(_ rule: RepeatRule) -> some View {
        let on = rule.window != nil
        return VStack(alignment: .leading, spacing: Brand.Space.s) {
            HStack {
                Text("Only between").font(Brand.text(13))
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { v in edit { $0.window = v ? RepeatWindow(start: "09:00", end: "18:00") : nil } }))
                    .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
            }
            if let w = rule.window {
                HStack(spacing: Brand.Space.s) {
                    DatePicker("", selection: hmBinding(w.start) { s in edit { $0.window?.start = s } }, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize()
                    Text("–").foregroundStyle(pal.muted)
                    DatePicker("", selection: hmBinding(w.end) { s in edit { $0.window?.end = s } }, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize()
                }
            }
        }
    }

    private func hmBinding(_ hm: String, set: @escaping (String) -> Void) -> Binding<Date> {
        Binding(get: {
            let p = hm.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            set(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
        })
    }

    private func endRow(_ rule: RepeatRule) -> some View {
        let type = rule.end?.type ?? "never"
        return VStack(alignment: .leading, spacing: Brand.Space.s) {
            HStack {
                Text("Ends").font(Brand.text(13))
                Spacer()
                CapsuleTabs(items: [("never", "Never"), ("on", "On date"), ("after", "After")], selection: Binding(get: { type }, set: { t in
                    edit { r in
                        switch t {
                        case "on":
                            let d = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
                            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                            r.end = .on(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
                        case "after": r.end = .after(10)
                        default: r.end = nil
                        }
                    }
                }))
            }
            if type == "on", let ds = rule.end?.date {
                DatePicker("Last day", selection: Binding(get: {
                    LynxTime.parse(ds + "T12:00:00Z") ?? Date()
                }, set: { d in
                    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                    edit { $0.end = .on(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)) }
                }), displayedComponents: .date)
                .font(Brand.text(13))
            }
            if type == "after" {
                Stepper(value: Binding(get: { rule.end?.count ?? 10 }, set: { v in edit { $0.end = .after(max(1, v)) } }), in: 1...999) {
                    Text("\(rule.end?.count ?? 10) times · \(rule.completedCount ?? 0) done").font(Brand.mono(12))
                }
            }
        }
    }
}

/// ISO weekdays 1 = Mon … 7 = Sun as seven small capsules.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: Brand.Space.xxs) {
            ForEach(1...7, id: \.self) { d in
                let on = selection.contains(d)
                Button {
                    if on { selection.remove(d) } else { selection.insert(d) }
                } label: {
                    Text(String(Formats.weekdayShort[d - 1].prefix(2)))
                        .font(Brand.text(12, .medium))
                        .frame(width: 34, height: 28)
                        .background(on ? pal.fg : pal.sunk, in: Capsule())
                        .foregroundStyle(on ? pal.bg : pal.fg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Formats.weekdayShort[d - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// "Alert again every N minutes until done" (SPEC §5.4).
struct NagEditor: View {
    let reminderId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        let nag = model.db.reminders[reminderId]?.nag
        VStack(spacing: 0) {
            FormRow("Alert again until done", symbol: "bell.badge") {
                Toggle("", isOn: Binding(get: { nag != nil }, set: { on in
                    model.updateReminder(reminderId) { $0.nag = on ? Nag(everyMinutes: 10, max: 6) : nil }
                }))
                .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
            }
            if let nag {
                Hairline()
                HStack(spacing: Brand.Space.s) {
                    Text("Every").font(Brand.text(13))
                    Picker("", selection: Binding(get: { nag.everyMinutes }, set: { v in model.updateReminder(reminderId) { $0.nag?.everyMinutes = v } })) {
                        ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text(Formats.duration(minutes: $0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Picker("", selection: Binding(get: { nag.max ?? 0 }, set: { v in model.updateReminder(reminderId) { $0.nag?.max = v == 0 ? nil : v } })) {
                        ForEach([3, 6, 12], id: \.self) { Text("\($0) times").tag($0) }
                        Text("Until done (24 h)").tag(0)
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.s)
            }
        }
    }
}
