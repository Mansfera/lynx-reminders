import LynxCore
import SwiftUI

/// Sidebar (SPEC §7): the 2×2 stats grid, the other smart lists, My lists, Shared lists, account.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone: the account moves to the top bar and a new-reminder field takes the footer's place.
    private var phone: Bool { sizeClass == .compact }
    #else
    private let phone = false
    #endif

    var body: some View {
        let q = model.queries
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Space.l) {
                    StatsGrid(queries: q)
                    VStack(spacing: 2) {
                        ForEach(SmartList.rows, id: \.self) { s in
                            SidebarRow(item: .smart(s), symbol: symbol(s), title: s.title, count: s == .completed ? nil : q.count(s))
                        }
                    }
                    listSection("My lists", lists: q.myLists, q: q, shared: false)
                    if !q.sharedLists.isEmpty {
                        listSection("Shared lists", lists: q.sharedLists, q: q, shared: true)
                    }
                }
                .padding(.horizontal, Brand.Space.m)
                .padding(.top, Brand.Space.xs)
                .padding(.bottom, Brand.Space.xl)
            }
            .scrollIndicators(.never)
            if phone {
                QuickAddField(item: .smart(.all), intoDefaultList: true)
                    .padding(.horizontal, Brand.Space.m).padding(.vertical, Brand.Space.s)
            } else {
                Hairline()
                SidebarFooter()
            }
        }
        .background(pal.bg)
        #if os(iOS)
        .syncOnPull()
        .navigationTitle(phone ? "" : "Lynx")
        .navigationBarTitleDisplayMode(phone ? .inline : .automatic)
        .toolbar {
            if phone {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        #endif
    }

    private func symbol(_ s: SmartList) -> String {
        switch s {
        case .goals: return "circle.dashed"
        case .sharedWithMe: return "person.crop.circle.badge.checkmark"
        case .assignedToMe: return "person.crop.circle"
        case .completed: return "checkmark.circle"
        default: return "circle"
        }
    }

    @ViewBuilder
    private func listSection(_ title: String, lists: [LynxList], q: SmartQueries, shared: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Caption(title)
                Spacer()
                if !shared {
                    Button {
                        model.listEditor = ListEditorState(id: nil, name: "", color: .blue, icon: .list)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.muted)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New list")
                    .accessibilityLabel("New list")
                }
            }
            .padding(.horizontal, Brand.Space.s)
            .padding(.bottom, Brand.Space.xxs)
            if lists.isEmpty {
                Text(shared ? "Nothing shared yet." : "No lists yet.").font(Brand.caption).foregroundStyle(pal.muted)
                    .padding(.horizontal, Brand.Space.s)
            }
            ForEach(lists) { l in
                ListRow(list: l, count: q.openCount(inList: l.id), members: shared ? model.db.members(of: l.id).compactMap(\.profile) : [])
                    // Drag a list onto another to reorder.
                    .draggable(l.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let s = items.first, let id = UUID(uuidString: s), id != l.id,
                              let from = lists.firstIndex(where: { $0.id == id }),
                              let to = lists.firstIndex(where: { $0.id == l.id }) else { return false }
                        model.moveLists(lists.map(\.id), from: IndexSet(integer: from), to: to > from ? to + 1 : to)
                        return true
                    }
            }
        }
    }
}

/// 2×2 grid with hairline dividers; each cell a 28 pt count + 10.5 pt caption. Selected cell = sunk.
struct StatsGrid: View {
    let queries: SmartQueries
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        let cells = SmartList.grid
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cell(cells[0]); VHairline(); cell(cells[1])
            }
            Hairline()
            HStack(spacing: 0) {
                cell(cells[2]); VHairline(); cell(cells[3])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(pal.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(pal.line))
    }

    private func cell(_ s: SmartList) -> some View {
        let selected = model.selection == .smart(s)
        let n = queries.count(s)
        let overdueCount = s == .today ? queries.todaySummary().overdue : 0
        let overdue = overdueCount > 0
        return Button { model.show(.smart(s)) } label: {
            VStack(alignment: .leading, spacing: Brand.Space.xxs) {
                // The count stays ink; red is only for the overdue items themselves (SPEC §8).
                HStack(alignment: .firstTextBaseline, spacing: Brand.Space.xs) {
                    Text("\(n)").font(Brand.stat).tracking(-0.8).monospacedDigit()
                        .contentTransition(.numericText())
                    if overdue {
                        Text("\(overdueCount) late").font(Brand.mono(10.5)).foregroundStyle(pal.signal).lineLimit(1)
                    }
                }
                Text(s.title).font(Brand.captionSmall).foregroundStyle(pal.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Brand.Space.l)
            .background(selected ? pal.sunk : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.title), \(n)")
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    let symbol: String
    let title: String
    let count: Int?
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        let selected = model.selection == item
        Button { model.show(item) } label: {
            HStack(spacing: Brand.Space.s) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(pal.ink2).frame(width: 22)
                Text(title).font(Brand.text(13.5, selected ? .medium : .regular))
                Spacer(minLength: Brand.Space.xs)
                if let count, count > 0 {
                    Text("\(count)").font(Brand.mono(11)).foregroundStyle(pal.muted).monospacedDigit()
                }
            }
            .padding(.horizontal, Brand.Space.s).padding(.vertical, 7)
            .background(selected ? pal.sunk : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ListRow: View {
    let list: LynxList
    let count: Int
    let members: [Profile]
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        let selected = model.selection == .list(list.id)
        Button { model.show(.list(list.id)) } label: {
            HStack(spacing: Brand.Space.s) {
                ListBadge(list: list, size: 22)
                Text(list.name).font(Brand.text(13.5, selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: Brand.Space.xs)
                if !members.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(members.prefix(3)) { Avatar(profile: $0, size: 18) }
                    }
                }
                if count > 0 {
                    Text("\(count)").font(Brand.mono(11)).foregroundStyle(pal.muted).monospacedDigit()
                }
            }
            .padding(.horizontal, Brand.Space.s).padding(.vertical, 5)
            .background(selected ? pal.sunk : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit list…") {
                model.listEditor = ListEditorState(id: list.id, name: list.name, color: list.listColor, icon: list.listIcon)
            }
            if model.backend != nil && model.signedIn {
                Button("Share…") { model.shareListTarget = list.id }
            }
            if model.isOwner(of: list.id) {
                Divider()
                Button("Delete list", role: .destructive) { model.deleteList(list.id) }
            }
        }
    }
}

/// Account entry at the bottom of the sidebar.
#if os(iOS)
/// iPhone top bar: the person's avatar (or a person icon when signed out) opens Account. A red dot
/// stands in for the footer's sync error line. The avatar is drawn into an image so the bar treats it
/// like the gear: the same round button, same inset.
struct AccountButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @Environment(\.displayScale) private var scale

    var body: some View {
        Button { model.showAccount = true } label: { icon }
            .accessibilityLabel(model.user == nil ? "Sign in to sync" : "Account")
    }

    private var icon: Image {
        guard let u = model.user else { return Image(systemName: "person.crop.circle") }
        let face = Avatar(profile: model.profile ?? Profile(id: u.id, email: u.email, displayName: nil), size: 28)
            .overlay(alignment: .topTrailing) {
                if model.syncError != nil { Circle().fill(pal.signal).frame(width: 8, height: 8) }
            }
            .environment(\.palette, pal)
        let renderer = ImageRenderer(content: face)
        renderer.scale = scale
        guard let image = renderer.uiImage else { return Image(systemName: "person.crop.circle") }
        return Image(uiImage: image).renderingMode(.original)
    }
}
#endif

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        Button { model.showAccount = true } label: {
            HStack(spacing: Brand.Space.s) {
                if let u = model.user {
                    Avatar(profile: model.profile ?? Profile(id: u.id, email: u.email, displayName: nil), size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.profile?.name ?? u.email ?? "Account").font(Brand.text(12.5, .medium)).lineLimit(1)
                        Text(syncLine).font(Brand.captionSmall).foregroundStyle(model.syncError == nil ? pal.muted : pal.signal).lineLimit(1)
                    }
                } else {
                    Image(systemName: "person.crop.circle").font(.system(size: 20)).foregroundStyle(pal.ink2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sign in to sync").font(Brand.text(12.5, .medium))
                        Text("Reminders stay on this device").font(Brand.captionSmall).foregroundStyle(pal.muted).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Brand.Space.xl).padding(.vertical, Brand.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var syncLine: String {
        if model.syncing { return "Syncing…" }
        if let e = model.syncError { return e }
        if let t = model.db.sync.lastSyncAt { return "Synced \(Formats.time(t))" }
        return "Not synced yet"
    }
}
