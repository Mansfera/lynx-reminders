import LynxCore
import SwiftUI

/// The editor: the source of truth for every field (quick add is only sugar).
struct ReminderDetailView: View {
    let reminderId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @State private var sheet: TriggerSheet?
    @State private var newSubtask = ""
    @FocusState private var subtaskFocused: Bool
    @State private var showRepeatDetails = false

    enum TriggerSheet: String, Identifiable {
        case location, bluetooth, app, guide
        var id: String { rawValue }
    }

    private var r: Reminder? { model.db.reminders[reminderId] }

    private func bind<T>(_ kp: WritableKeyPath<Reminder, T>) -> Binding<T> {
        Binding(get: { model.db.reminders[reminderId]![keyPath: kp] },
                set: { v in model.updateReminder(reminderId) { $0[keyPath: kp] = v } })
    }

    private func bindText(_ kp: WritableKeyPath<Reminder, String?>) -> Binding<String> {
        Binding(get: { model.db.reminders[reminderId]?[keyPath: kp] ?? "" },
                set: { v in model.updateReminder(reminderId) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }

    var body: some View {
        if let r {
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Space.l) {
                    // Order follows use: when → what else alerts → the parts of a goal → list/priority bookkeeping.
                    header(r)
                    datePanel(r)
                    triggersPanel(r)
                    if r.parentId == nil { subtasksPanel(r) }
                    detailsPanel(r)
                    if model.signedIn && r.parentId == nil { sharingPanel(r) }
                    footer(r)
                }
                .padding(Brand.Space.xl)
            }
            .background(pal.bg)
            .onAppear {
                // A custom rule opens with its options visible; a plain preset stays one line.
                if let rule = r.repeat {
                    showRepeatDetails = rule.interval > 1 || rule.window != nil || rule.end != nil || rule.fromCompletion
                        || rule.autoAdvance || [.minute, .hour].contains(rule.unit)
                }
            }
            .sheet(item: $sheet) { s in
                Group {
                    switch s {
                    case .location: LocationPickerSheet(reminderId: reminderId)
                    case .bluetooth: BluetoothPickerSheet(reminderId: reminderId)
                    case .app: AppPickerSheet(reminderId: reminderId)
                    case .guide: ShortcutsGuideSheet()
                    }
                }
                .themed()
            }
            #if os(iOS)
            .navigationTitle(r.title)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: Header

    private func header(_ r: Reminder) -> some View {
        let color = model.color(for: r)
        let p = model.db.progress(of: r.id)
        return Panel {
            HStack(alignment: .top, spacing: Brand.Space.m) {
                Checkbox(checked: r.isCompleted, color: color, pulse: p.total > 0 && r.isOpen && p.done == p.total) {
                    model.toggle(r.id)
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: Brand.Space.s) {
                TextField("Title", text: bind(\.title), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Brand.title)
                    .lineLimit(1...4)
                TextField("Notes", text: bindText(\.notes), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Brand.text(13))
                    .foregroundStyle(pal.ink2)
                    .lineLimit(1...10)
                HStack(spacing: Brand.Space.xs) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(pal.muted)
                    TextField("URL", text: bindText(\.url)).textFieldStyle(.plain).font(Brand.mono(11.5, .regular))
                    if let s = r.url, let u = URL(string: s), u.scheme != nil {
                        Button { Platform.open(u) } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain).accessibilityLabel("Open link")
                    }
                }
                if let parent = r.parentId.flatMap({ model.db.reminders[$0] }) {
                    Button { model.selectedReminder = parent.id } label: {
                        Text("Subtask of \(parent.title)").font(Brand.caption).foregroundStyle(pal.muted).underline(color: pal.line)
                    }
                    .buttonStyle(.plain)
                }
                }
                if p.total > 0 {
                    GoalRing(done: p.done, total: p.total, color: color, size: 64, showFraction: true)
                }
            }
        }
    }

    // MARK: Details

    private func detailsPanel(_ r: Reminder) -> some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                FormRow("List") {
                    Menu {
                        ForEach(model.db.visibleLists) { l in
                            Button(l.name) { model.moveReminder(r.id, toList: l.id) }
                        }
                    } label: {
                        if let l = model.db.list(r.listId) {
                            HStack(spacing: Brand.Space.xs) { ListBadge(list: l, size: 16); Text(l.name).font(Brand.text(13)) }
                        } else {
                            Text("Shared with me").font(Brand.text(13))
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .disabled(r.parentId != nil || model.db.list(r.listId) == nil)
                }
                Hairline()
                FormRow("Priority") {
                    CapsuleTabs(items: [(0, "None"), (1, "Low"), (2, "Medium"), (3, "High")], selection: bind(\.priority))
                }
                Hairline()
                FormRow("Flag") {
                    Toggle("", isOn: bind(\.flagged)).labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                }
                let people = model.db.participants(of: r)
                if people.count > 1 {
                    Hairline()
                    FormRow("Assignee") {
                        Menu {
                            Button("Nobody") { model.updateReminder(r.id) { $0.assigneeId = nil } }
                            ForEach(people) { p in
                                Button(p.id == model.me ? "\(p.name) (me)" : p.name) { model.updateReminder(r.id) { $0.assigneeId = p.id } }
                            }
                        } label: {
                            if let a = model.db.profile(r.assigneeId) {
                                HStack(spacing: Brand.Space.xs) { Avatar(profile: a, size: 18); Text(a.name).font(Brand.text(13)) }
                            } else {
                                Text("Nobody").font(Brand.text(13)).foregroundStyle(pal.muted)
                            }
                        }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    }
                }
            }
        }
    }

    // MARK: Date, repeat, nag

    private func datePanel(_ r: Reminder) -> some View {
        let hasDate = r.dueAt != nil
        return Panel(padding: 0) {
            VStack(spacing: 0) {
                FormRow("Date", symbol: "calendar") {
                    Toggle("", isOn: Binding(get: { hasDate }, set: { setHasDate($0) })).labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                }
                if hasDate {
                    Hairline()
                    FormRow("Day") {
                        DatePicker("", selection: dueBinding(r), displayedComponents: .date).labelsHidden().fixedSize()
                    }
                    Hairline()
                    FormRow("Time", symbol: "clock") {
                        Toggle("", isOn: Binding(get: { !(model.db.reminders[reminderId]?.allDay ?? true) }, set: { setHasTime($0) }))
                            .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                    }
                    if !r.allDay {
                        Hairline()
                        FormRow("At") {
                            DatePicker("", selection: dueBinding(r), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                        }
                        Hairline()
                        FormRow("Early alert", symbol: "bell") {
                            Picker("", selection: Binding(get: { r.earlyAlertMinutes ?? 0 },
                                                          set: { v in model.updateReminder(reminderId) { $0.earlyAlertMinutes = v == 0 ? nil : v } })) {
                                Text("None").tag(0)
                                ForEach([5, 15, 30, 60, 120, 1440], id: \.self) { Text("\(Formats.duration(minutes: $0)) before").tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    Hairline()
                    RepeatEditor(reminderId: reminderId, expanded: $showRepeatDetails)
                }
                Hairline()
                NagEditor(reminderId: reminderId)
            }
        }
    }

    private func dueBinding(_ r: Reminder) -> Binding<Date> {
        Binding(get: { model.db.reminders[reminderId]?.dueAt ?? Date() }, set: { new in
            model.updateReminder(reminderId) { rem in
                var d = new
                if rem.allDay {
                    // All-day: local midnight of the chosen date in the reminder's zone.
                    let comps = Calendar.current.dateComponents([.year, .month, .day], from: new)
                    d = WallTime(year: comps.year!, month: comps.month!, day: comps.day!).instant(in: rem.zone)
                }
                rem.dueAt = d
                if var rule = rem.repeat {
                    rule.anchor = Recurrence.anchor(for: d, in: rem.zone)
                    rem.repeat = rule
                }
            }
        })
    }

    private func setHasDate(_ on: Bool) {
        model.updateReminder(reminderId) { r in
            if on {
                r.timeZone = TimeZone.current.identifier
                let (y, m, d) = WallTime(Date(), in: r.zone).ymd
                r.dueAt = WallTime(year: y, month: m, day: d).instant(in: r.zone)
                r.allDay = true
            } else {
                r.dueAt = nil
                r.allDay = false
                r.repeat = nil
                r.earlyAlertMinutes = nil
            }
        }
    }

    private func setHasTime(_ on: Bool) {
        let early = model.settings.defaultEarlyAlert
        model.updateReminder(reminderId) { r in
            guard let due = r.dueAt else { return }
            let day = WallTime(due, in: r.zone).days
            if on {
                // The next whole hour if the day is today, else 09:00.
                let nowLocal = WallTime(Date(), in: r.zone)
                let secs: Int64 = day == nowLocal.days ? min(23, Int64(nowLocal.hour + 1)) * 3600 : 9 * 3600
                r.dueAt = WallTime.atDay(day, secondOfDay: secs).instant(in: r.zone)
                r.allDay = false
                if early > 0, r.earlyAlertMinutes == nil { r.earlyAlertMinutes = early }
            } else {
                r.dueAt = WallTime.atDay(day, secondOfDay: 0).instant(in: r.zone)
                r.allDay = true
                r.earlyAlertMinutes = nil
            }
            if var rule = r.repeat, let d = r.dueAt {
                rule.anchor = Recurrence.anchor(for: d, in: r.zone)
                r.repeat = rule
            }
        }
    }

    // MARK: Triggers

    private func triggersPanel(_ r: Reminder) -> some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                TriggerRow(symbol: "location", title: "Location",
                           value: r.location.map { "\($0.on == .arrive ? "Arriving at" : "Leaving") \($0.name) · \(Int($0.radius)) m" },
                           open: { sheet = .location }, clear: { model.updateReminder(reminderId) { $0.location = nil } })
                Hairline()
                TriggerRow(symbol: "headphones", title: "Bluetooth",
                           value: r.bluetooth.map { "\($0.name) \($0.on == .connect ? "connects" : "disconnects")" },
                           open: { sheet = .bluetooth }, clear: { model.updateReminder(reminderId) { $0.bluetooth = nil } })
                Hairline()
                TriggerRow(symbol: "app.badge", title: "App opened",
                           value: r.appTrigger.map { "\($0.name) opens" },
                           open: { sheet = .app }, clear: { model.updateReminder(reminderId) { $0.appTrigger = nil } })
                #if os(iOS)
                if r.bluetooth != nil || r.appTrigger != nil {
                    Hairline()
                    Button { sheet = .guide } label: {
                        HStack {
                            Image(systemName: "questionmark.circle").foregroundStyle(pal.muted)
                            Text("Set up the Shortcuts automation").font(Brand.text(13))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.muted)
                        }
                        .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.m)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                #endif
            }
        }
    }

    // MARK: Subtasks

    private func subtasksPanel(_ r: Reminder) -> some View {
        let subs = model.db.subtasks(of: r.id)
        return VStack(alignment: .leading, spacing: Brand.Space.xs) {
            Caption(subs.isEmpty ? "Subtasks" : "Subtasks · \(subs.filter(\.isCompleted).count) of \(subs.count) done")
                .padding(.horizontal, Brand.Space.xxs)
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(subs) { s in
                        ReminderRow(reminder: s, showList: false, compact: true)
                        Hairline().padding(.leading, 46)
                    }
                    HStack(spacing: Brand.Space.m) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.muted).frame(width: 20)
                        TextField(subs.isEmpty ? "Add a subtask to make this a goal" : "Add a subtask", text: $newSubtask)
                            .textFieldStyle(.plain).font(Brand.row)
                            .focused($subtaskFocused)
                            .onSubmit {
                                model.quickAdd(newSubtask, parent: r.id)
                                newSubtask = ""
                            }
                    }
                    .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.m)
                    .focusOnTap($subtaskFocused)
                }
            }
        }
    }

    // MARK: Sharing

    private func sharingPanel(_ r: Reminder) -> some View {
        let shares = model.db.shares(of: r.id)
        return Panel(padding: 0) {
            VStack(spacing: 0) {
                FormRow("Shared with", symbol: "person.2") {
                    if shares.isEmpty {
                        SoftButton(title: "Share…") { model.shareReminderTarget = r.id }
                    } else {
                        HStack(spacing: -6) { ForEach(shares, id: \.userId) { s in Avatar(profile: s.profile ?? Profile(id: s.userId, email: nil, displayName: nil)) } }
                        SoftButton(title: "Manage") { model.shareReminderTarget = r.id }
                    }
                }
            }
        }
    }

    private func footer(_ r: Reminder) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Created \(r.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                if let c = r.completedAt {
                    let by = model.db.profile(r.completedBy).map { " by \($0.name)" } ?? ""
                    Text("Completed \(c.formatted(.dateTime.day().month(.abbreviated).hour().minute()))\(by)")
                }
                if model.db.dirtyReminders.contains(r.id) && model.signedIn { Text("Waiting to sync") }
            }
            .font(Brand.mono(10, .regular)).foregroundStyle(pal.muted)
            Spacer()
            SoftButton(title: "Delete", symbol: "trash", role: .destructive) { model.deleteReminder(r.id) }
        }
        .padding(.horizontal, Brand.Space.xxs)
    }
}

/// A label on the left, a control on the right, inside a panel.
struct FormRow<Content: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var content: Content
    @Environment(\.palette) private var pal

    init(_ title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Brand.Space.s) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(pal.muted).frame(width: 18)
            }
            Text(title).font(Brand.text(13))
            Spacer(minLength: Brand.Space.s)
            content
        }
        .padding(.horizontal, Brand.Space.l)
        .padding(.vertical, Brand.Space.xs)
        .frame(minHeight: Platform.isMac ? 40 : 44)
    }
}

struct TriggerRow: View {
    let symbol: String
    let title: String
    let value: String?
    let open: () -> Void
    let clear: () -> Void
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: Brand.Space.s) {
            Button(action: open) {
                HStack(spacing: Brand.Space.s) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(pal.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Brand.text(13))
                        if let value { Text(value).font(Brand.mono(10.5, .regular)).foregroundStyle(pal.muted).lineLimit(1) }
                    }
                    Spacer()
                    if value == nil {
                        Text("Add").font(Brand.text(12.5, .medium)).foregroundStyle(pal.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if value != nil {
                Button(action: clear) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(pal.muted)
                        .frame(width: 22, height: 22).background(pal.sunk, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title.lowercased()) trigger")
            }
        }
        .padding(.horizontal, Brand.Space.l)
        .padding(.vertical, Brand.Space.xs)
        .frame(minHeight: Platform.isMac ? 40 : 44)
    }
}
