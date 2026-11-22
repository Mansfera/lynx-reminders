import LynxCore
import SwiftUI

/// The content column: a smart list, a list, or search results.
struct ReminderListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @FocusState private var listFocused: Bool

    var body: some View {
        let item = model.selection ?? .smart(.today)
        let q = model.queries
        let groups = groups(for: item, q: q)
        let flat = groups.flatMap(\.rows)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Space.l) {
                    ListHeader(item: item)
                    if item == .smart(.today) { TodayStage(summary: q.todaySummary(), now: model.now) }
                    if canAdd(item) { QuickAddField(item: item) }
                    if flat.isEmpty {
                        Text(emptyText(item)).font(Brand.text(13)).foregroundStyle(pal.muted)
                            .padding(.horizontal, Brand.Space.xxs).padding(.top, Brand.Space.xs)
                    }
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: Brand.Space.xs) {
                            if let title = g.title {
                                HStack(spacing: Brand.Space.xs) {
                                    if let l = g.list { ListBadge(list: l, size: 16) }
                                    Caption(title)
                                }
                                .padding(.horizontal, Brand.Space.xxs)
                            }
                            Panel(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, row in
                                        if i > 0 { Hairline().padding(.leading, row.indent ? 76 : 46) }
                                        ReminderRow(reminder: row.reminder, indent: row.indent, showList: g.showList)
                                            .id(row.reminder.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Brand.Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .background(pal.bg)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { moveSelection(-1, flat, proxy); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1, flat, proxy); return .handled }
            .onKeyPress(.space) {
                guard let id = model.selectedReminder else { return .ignored }
                model.toggle(id)
                return .handled
            }
            .onKeyPress(.delete) {
                guard let id = model.selectedReminder else { return .ignored }
                model.deleteReminder(id)
                return .handled
            }
        }
        #if os(iOS)
        .syncOnPull()
        .navigationTitle(model.title(for: item))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func moveSelection(_ delta: Int, _ rows: [RowItem], _ proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.reminder.id == model.selectedReminder }
        let next = i.map { min(max(0, $0 + delta), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        model.selectedReminder = rows[next].reminder.id
        proxy.scrollTo(rows[next].reminder.id)
    }

    private func canAdd(_ item: SidebarItem) -> Bool {
        switch item {
        case .smart(let s): return [.today, .scheduled, .all, .flagged].contains(s)
        case .list: return true
        case .search: return false
        }
    }

    private func emptyText(_ item: SidebarItem) -> String {
        switch item {
        case .smart(.today): return "Nothing due today."
        case .smart(.scheduled): return "Nothing scheduled. Add a date to a reminder and it shows up here."
        case .smart(.all): return "No open reminders."
        case .smart(.flagged): return "No flagged reminders."
        case .smart(.goals): return "No goals yet. Add subtasks to a reminder to turn it into a goal."
        case .smart(.sharedWithMe): return model.signedIn ? "Nothing has been shared with you." : "Sign in to share reminders with people."
        case .smart(.assignedToMe): return model.signedIn ? "Nothing is assigned to you." : "Sign in to assign reminders in shared lists."
        case .smart(.completed): return "Completed reminders show up here."
        case .list: return "No reminders in this list."
        case .search: return model.searchText.isEmpty ? "Type to search titles and notes." : "No matches."
        }
    }

    struct RowItem: Identifiable {
        var id: UUID { reminder.id }
        let reminder: Reminder
        let indent: Bool
    }

    struct RowGroup: Identifiable {
        let id: String
        var title: String?
        var list: LynxList?
        var showList: Bool
        var rows: [RowItem]
    }

    private func groups(for item: SidebarItem, q: SmartQueries) -> [RowGroup] {
        func flat(_ rs: [Reminder]) -> [RowItem] { rs.map { RowItem(reminder: $0, indent: false) } }
        switch item {
        case .smart(let s):
            switch s {
            case .scheduled, .completed:
                return q.groups(s).map { g in
                    RowGroup(id: g.id, title: g.day.map { Formats.dayName($0, now: model.now) } ?? "No date", showList: true, rows: flat(g.reminders))
                }
            case .all:
                return q.groups(.all).map { g in
                    let l = g.listId.flatMap { model.db.list($0) }
                    return RowGroup(id: g.id, title: l?.name ?? "Shared with me", list: l, showList: false, rows: withSubtasks(g.reminders))
                }
            default:
                let rows = q.reminders(s)
                return rows.isEmpty ? [] : [RowGroup(id: s.rawValue, title: nil, showList: true, rows: s == .goals ? withSubtasks(rows) : flat(rows))]
            }
        case .list(let id):
            let rows = q.reminders(inList: id, showCompleted: model.settings.showCompleted)
            return rows.isEmpty ? [] : [RowGroup(id: id.uuidString, title: nil, showList: false, rows: withSubtasks(rows))]
        case .search:
            let rows = q.search(model.searchText)
            return rows.isEmpty ? [] : [RowGroup(id: "search", title: "\(rows.count) result\(rows.count == 1 ? "" : "s")", showList: true, rows: flat(rows))]
        }
    }

    /// Goals show their subtasks indented underneath.
    private func withSubtasks(_ rs: [Reminder]) -> [RowItem] {
        var out: [RowItem] = []
        for r in rs {
            out.append(RowItem(reminder: r, indent: false))
            for s in model.db.subtasks(of: r.id) where s.isOpen || model.settings.showCompleted || r.isCompleted {
                out.append(RowItem(reminder: s, indent: true))
            }
        }
        return out
    }
}

/// Title, count and actions for the current selection.
struct ListHeader: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(alignment: .center, spacing: Brand.Space.m) {
            if case .list(let id) = item, let l = model.db.list(id) {
                ListBadge(list: l, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title(for: item)).font(Brand.display(24, .semibold)).tracking(-0.5).lineLimit(1)
                if let sub = subtitle { Text(sub).font(Brand.caption).foregroundStyle(pal.muted) }
            }
            Spacer(minLength: Brand.Space.s)
            SearchField()
            if case .list(let id) = item {
                listMenu(id)
            }
        }
    }

    private var subtitle: String? {
        switch item {
        case .smart(.today): return Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .list(let id):
            let members = model.db.members(of: id)
            return members.count > 1 ? members.compactMap { $0.profile?.name }.joined(separator: ", ") : nil
        default: return nil
        }
    }

    @ViewBuilder private func listMenu(_ id: UUID) -> some View {
        if model.signedIn {
            RoundIconButton(symbol: "person.2", label: "Share list", filled: false) { model.shareListTarget = id }
        }
        Menu {
            Button("Edit list…") {
                if let l = model.db.list(id) {
                    model.listEditor = ListEditorState(id: id, name: l.name, color: l.listColor, icon: l.listIcon)
                }
            }
            Toggle("Show completed", isOn: Binding(get: { model.settings.showCompleted }, set: { model.settings.showCompleted = $0 }))
            if model.isOwner(of: id) {
                Divider()
                Button("Delete list", role: .destructive) { model.deleteList(id) }
            } else if model.signedIn {
                Divider()
                Button("Leave list", role: .destructive) { Task { try? await model.leaveList(id) } }
            }
        } label: {
            ZStack {
                Circle().fill(pal.sunk)
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.fg)
            }
            .frame(width: 30, height: 30)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("List options")
    }
}

/// Search (⌘F focuses it): titles and notes across everything.
struct SearchField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Brand.Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.muted)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(Brand.text(12.5))
                .focused($focused)
                .onExitCommandIfAvailable { model.searchText = ""; focused = false }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(pal.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Brand.Space.s).padding(.vertical, 7)
        .frame(width: focused || !model.searchText.isEmpty ? 200 : 130)
        .background(pal.sunk, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: focused)
        .onChange(of: model.focusSearch) { _, _ in focused = true }
    }
}

extension View {
    @ViewBuilder func onExitCommandIfAvailable(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

/// Quick add: one line with light natural-language parsing (SPEC §7).
struct QuickAddField: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let preview = text.isEmpty ? nil : QuickAddParser.parse(text, lists: model.db.visibleLists, now: Date())
        VStack(alignment: .leading, spacing: Brand.Space.xs) {
            HStack(spacing: Brand.Space.m) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(pal.muted).frame(width: 20)
                TextField("New reminder — try “tomorrow at 9 #home”", text: $text)
                    .textFieldStyle(.plain)
                    .font(Brand.row)
                    .focused($focused)
                    .onSubmit(add)
            }
            .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.m)
            .background(pal.sunk, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let p = preview, hint(p) != nil {
                Text(hint(p)!).font(Brand.mono(10.5)).foregroundStyle(pal.muted).padding(.leading, 46)
            }
        }
        .onChange(of: model.focusQuickAdd) { _, _ in focused = true }
    }

    private func hint(_ p: QuickAddResult) -> String? {
        var parts: [String] = []
        if let d = p.dueAt { parts.append(p.allDay ? Formats.dayName(d, now: Date()) : "\(Formats.dayName(d, now: Date())) \(Formats.time(d))") }
        if let r = p.repeat { parts.append(Formats.repeatText(r, short: true)) }
        if p.priority > 0 { parts.append(String(repeating: "!", count: p.priority)) }
        if let l = p.listId.flatMap({ model.db.list($0) }) { parts.append("in \(l.name)") }
        if let t = p.unknownListTag { parts.append("no list “\(t)”") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func add() {
        var list: UUID? = nil
        if case .list(let id) = item { list = id }
        var input = text
        // In Today, a reminder without a date is for today.
        if item == .smart(.today), QuickAddParser.parse(text, lists: model.db.visibleLists, now: Date()).dueAt == nil { input += " today" }
        if let r = model.quickAdd(input, list: list, flagged: item == .smart(.flagged)) {
            model.selectedReminder = r.id
        }
        text = ""
        focused = true
    }
}

// MARK: - Row

struct ReminderRow: View {
    let reminder: Reminder
    var indent = false
    var showList = true
    var compact = false
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        let r = reminder
        let db = model.db
        let color = model.color(for: r)
        let selected = model.selectedReminder == r.id
        let progress = db.progress(of: r.id)
        let isGoal = progress.total > 0
        HStack(alignment: .top, spacing: Brand.Space.m) {
            Checkbox(checked: r.isCompleted, color: color, pulse: isGoal && r.isOpen && progress.done == progress.total) {
                model.toggle(r.id)
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: Brand.Space.xxs) {
                HStack(spacing: Brand.Space.xs) {
                    if r.priority > 0 {
                        Text(String(repeating: "!", count: r.priority)).font(Brand.mono(12, .semibold)).foregroundStyle(pal.color(color == .ink ? .ink : color))
                    }
                    Text(r.title.isEmpty ? "New reminder" : r.title)
                        .font(Brand.row)
                        .foregroundStyle(r.isCompleted || r.title.isEmpty ? pal.muted : pal.fg)
                        .lineLimit(compact ? 1 : 3)
                }
                TriggerChips(reminder: r, showList: showList)
            }
            Spacer(minLength: Brand.Space.xs)
            if isGoal {
                HStack(spacing: Brand.Space.xs) {
                    Text("\(progress.done)/\(progress.total)").font(Brand.mono(11)).foregroundStyle(pal.muted).monospacedDigit()
                    GoalRing(done: progress.done, total: progress.total, color: color)
                }
            }
            if r.flagged {
                Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(pal.color(.orange)).padding(.top, 3)
                    .accessibilityLabel("Flagged")
            }
            if let a = db.profile(r.assigneeId) ?? r.assigneeId.map({ Profile(id: $0, email: nil, displayName: nil) }) {
                Avatar(profile: a, size: 20)
            }
        }
        .padding(.leading, indent ? 44 : Brand.Space.l)
        .padding(.trailing, Brand.Space.l)
        .padding(.vertical, compact ? Brand.Space.s : Brand.Space.m)
        .background(selected ? pal.sunk : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedReminder = r.id }
        .contextMenu { RowMenu(reminder: r) }
        .accessibilityElement(children: .combine)
    }
}

struct RowMenu: View {
    let reminder: Reminder
    @Environment(AppModel.self) private var model
    var body: some View {
        Button(reminder.isCompleted ? "Mark as not done" : "Mark as done") { model.toggle(reminder.id) }
        Button(reminder.flagged ? "Unflag" : "Flag") { model.updateReminder(reminder.id) { $0.flagged.toggle() } }
        if reminder.isOpen && reminder.dueAt != nil {
            Button("Snooze \(model.settings.defaultSnooze) min") { model.snooze(reminder.id, minutes: model.settings.defaultSnooze) }
        }
        Menu("Move to") {
            ForEach(model.db.visibleLists) { l in
                Button(l.name) { model.moveReminder(reminder.id, toList: l.id) }.disabled(l.id == reminder.listId)
            }
        }
        if model.signedIn && reminder.parentId == nil {
            Button("Share…") { model.shareReminderTarget = reminder.id }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteReminder(reminder.id) }
    }
}

/// Trigger chips under the title (SPEC §8): Geist Mono 10.5 muted, SF Symbols.
struct TriggerChips: View {
    let reminder: Reminder
    var showList = true
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        let r = reminder
        let q = model.queries
        let eff = q.effectiveDue(r)
        let overdue = q.isOverdue(r)
        let chips = items(r, eff: eff)
        if !chips.isEmpty || (showList && model.db.list(r.listId) != nil) {
            FlowLayout(spacing: Brand.Space.s, lineSpacing: 2) {
                if showList, let l = model.db.list(r.listId), r.parentId == nil {
                    HStack(spacing: 4) {
                        Circle().fill(pal.color(l.listColor)).frame(width: 6, height: 6)
                        Text(l.name)
                    }
                }
                ForEach(Array(chips.enumerated()), id: \.offset) { i, c in
                    HStack(spacing: 3) {
                        Image(systemName: c.symbol).font(.system(size: 9, weight: .semibold))
                        Text(c.text)
                    }
                    .foregroundStyle(i == 0 && c.symbol == "clock" && overdue ? pal.signal : pal.muted)
                }
            }
            .font(Brand.mono(10.5, .regular))
            .foregroundStyle(pal.muted)
        }
    }

    struct Chip { let symbol: String; let text: String }

    private func items(_ r: Reminder, eff: Date?) -> [Chip] {
        var out: [Chip] = []
        if let t = Formats.due(r, effective: eff, now: model.now) { out.append(Chip(symbol: "clock", text: t)) }
        if let rule = r.repeat { out.append(Chip(symbol: "arrow.clockwise", text: Formats.repeatText(rule, short: true))) }
        if let l = r.location { out.append(Chip(symbol: "location", text: (l.on == .arrive ? "" : "leave ") + l.name)) }
        if let b = r.bluetooth { out.append(Chip(symbol: "headphones", text: (b.on == .connect ? "" : "off ") + b.name)) }
        if let a = r.appTrigger { out.append(Chip(symbol: "app.badge", text: a.name)) }
        if let n = r.nag { out.append(Chip(symbol: "bell.badge", text: "nag \(Formats.duration(minutes: n.everyMinutes))")) }
        if r.notes?.isEmpty == false { out.append(Chip(symbol: "text.alignleft", text: "note")) }
        if model.db.shares(of: r.id).count > 0 { out.append(Chip(symbol: "person.2", text: "shared")) }
        return out
    }
}

/// Wraps chips onto the next line when the row is narrow.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += sz.width + spacing
            maxW = max(maxW, x - spacing)
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: min(maxW, width), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
