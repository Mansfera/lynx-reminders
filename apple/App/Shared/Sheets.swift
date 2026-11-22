import LynxCore
import LynxSync
import SwiftUI

// MARK: - List editor

struct ListEditorSheet: View {
    @State var state: ListEditorState
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal

    var body: some View {
        SheetScaffold(title: state.id == nil ? "New list" : "Edit list", doneTitle: state.id == nil ? "Create" : "Save",
                      doneDisabled: state.name.trimmingCharacters(in: .whitespaces).isEmpty,
                      onCancel: { dismiss() }, onDone: save) {
            HStack(spacing: Brand.Space.m) {
                ListBadge(list: preview, size: 44)
                SunkField(placeholder: "List name", text: $state.name)
                    .onSubmit(save)
            }
            Caption("Color")
            HStack(spacing: Brand.Space.s) {
                ForEach(ListColor.allCases, id: \.self) { c in
                    Button { state.color = c } label: {
                        Circle().fill(pal.color(c)).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(pal.bg, lineWidth: state.color == c ? 3 : 0))
                            .overlay(Circle().strokeBorder(state.color == c ? pal.fg : pal.line, lineWidth: state.color == c ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.rawValue)
                }
            }
            Caption("Icon")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: Brand.Space.s), count: 6), alignment: .leading, spacing: Brand.Space.s) {
                ForEach(ListIcon.allCases, id: \.self) { i in
                    Button { state.icon = i } label: {
                        Image(systemName: i.symbol).font(.system(size: 15))
                            .frame(width: 40, height: 40)
                            .background(state.icon == i ? pal.fg : pal.sunk, in: Circle())
                            .foregroundStyle(state.icon == i ? pal.bg : pal.fg)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i.rawValue)
                }
            }
            Spacer(minLength: 0)
        }
        #if os(macOS)
        .frame(width: 440, height: 380)
        #endif
    }

    private var preview: LynxList {
        LynxList(ownerId: nil, name: state.name, color: state.color, icon: state.icon, sortOrder: 0)
    }

    private func save() {
        let name = state.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = state.id {
            let s = state
            model.updateList(id) { $0.name = name; $0.color = s.color.rawValue; $0.icon = s.icon.rawValue }
        } else {
            let l = model.createList(name: name, color: state.color, icon: state.icon)
            model.selection = .list(l.id)
        }
        dismiss()
    }
}

// MARK: - Sharing

/// Share a list by email, see members and pending invites, remove or leave (SPEC §3).
struct ShareListSheet: View {
    let listId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal
    @State private var email = ""
    @State private var busy = false
    @State private var message: String?
    @State private var error = false

    var body: some View {
        let list = model.db.lists[listId]
        let owner = model.isOwner(of: listId)
        let members = model.db.members(of: listId)
        let invites = model.db.invites.filter { $0.listId == listId }
        SheetScaffold(title: "Share “\(list?.name ?? "List")”", subtitle: "Everyone in the list can see, edit and complete its reminders.",
                      doneTitle: "Close", onCancel: { dismiss() }, onDone: { dismiss() }) {
            if owner {
                ShareEmailRow(email: $email, buttonTitle: "Invite", busy: busy,
                              check: { try await model.sharePreview(email: $0, list: listId) }, share: share)
                if let message { Text(message).font(Brand.caption).foregroundStyle(error ? pal.signal : pal.muted) }
            } else {
                Text("Only the owner can invite people.").font(Brand.caption).foregroundStyle(pal.muted)
            }
            Caption("People")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.userId) { i, m in
                        if i > 0 { Hairline() }
                        PersonRow(profile: m.profile ?? Profile(id: m.userId, email: nil, displayName: nil),
                                  detail: m.isOwner ? "Owner" : "Member", isMe: m.userId == model.me) {
                            if owner && !m.isOwner {
                                SoftButton(title: "Remove", role: .destructive) { run { try await model.unshareList(listId, user: m.userId) } }
                            } else if !owner && m.userId == model.me {
                                SoftButton(title: "Leave", role: .destructive) {
                                    run { try await model.leaveList(listId); dismiss() }
                                }
                            }
                        }
                    }
                    if members.isEmpty {
                        Text("Sync to see who's in this list.").font(Brand.caption).foregroundStyle(pal.muted).padding(Brand.Space.l)
                    }
                    ForEach(invites) { inv in
                        Hairline()
                        PersonRow(profile: Profile(id: inv.id, email: inv.email, displayName: inv.email), detail: "Invited · pending", isMe: false) {
                            if owner || inv.invitedBy == model.me {
                                SoftButton(title: "Cancel") { run { try await model.cancelInvite(inv.id) } }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        #if os(macOS)
        .frame(width: 480, height: 440)
        #endif
    }

    private func share() {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@") else { return }
        run {
            let r = try await model.shareList(listId, email: e)
            message = ShareText.describe(r, email: e)
            email = ""
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        busy = true
        error = false
        Task {
            do { try await body() } catch {
                self.error = true
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Share a single reminder (and its subtasks) without sharing the list.
struct ShareReminderSheet: View {
    let reminderId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal
    @State private var email = ""
    @State private var busy = false
    @State private var message: String?
    @State private var error = false

    var body: some View {
        let r = model.db.reminders[reminderId]
        let shares = model.db.shares(of: reminderId)
        let invites = model.db.invites.filter { $0.reminderId == reminderId }
        SheetScaffold(title: "Share “\(r?.title ?? "Reminder")”", subtitle: "They see this reminder in Shared with me; the list stays yours.",
                      doneTitle: "Close", onCancel: { dismiss() }, onDone: { dismiss() }) {
            ShareEmailRow(email: $email, buttonTitle: "Share", busy: busy,
                          check: { try await model.sharePreview(email: $0, reminder: reminderId) }, share: share)
            if let message { Text(message).font(Brand.caption).foregroundStyle(error ? pal.signal : pal.muted) }
            Caption("Shared with")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    if shares.isEmpty && invites.isEmpty {
                        Text("Not shared with anyone yet.").font(Brand.caption).foregroundStyle(pal.muted).padding(Brand.Space.l)
                    }
                    ForEach(Array(shares.enumerated()), id: \.element.userId) { i, s in
                        if i > 0 { Hairline() }
                        PersonRow(profile: s.profile ?? Profile(id: s.userId, email: nil, displayName: nil), detail: "Can see and edit",
                                  isMe: s.userId == model.me) {
                            SoftButton(title: s.userId == model.me ? "Leave" : "Remove", role: .destructive) {
                                run { try await model.unshareReminder(reminderId, user: s.userId) }
                            }
                        }
                    }
                    ForEach(invites) { inv in
                        Hairline()
                        PersonRow(profile: Profile(id: inv.id, email: inv.email, displayName: inv.email), detail: "Invited · pending", isMe: false) {
                            SoftButton(title: "Cancel") { run { try await model.cancelInvite(inv.id) } }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        #if os(macOS)
        .frame(width: 480, height: 400)
        #endif
    }

    private func share() {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@") else { return }
        run {
            let r = try await model.shareReminder(reminderId, email: e)
            message = ShareText.describe(r, email: e)
            email = ""
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        busy = true
        error = false
        Task {
            do { try await body() } catch {
                self.error = true
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The share sheets' email field and Share button. Two seconds after typing stops it asks the server
/// what sharing would do (`share_preview`, SPEC §3) and says so under the field; Share turns on once
/// the answer is "added" or "invited" (or the check couldn't run, e.g. offline).
struct ShareEmailRow: View {
    @Binding var email: String
    let buttonTitle: String
    let busy: Bool
    let check: (String) async throws -> ShareResult
    let share: () -> Void
    @Environment(\.palette) private var pal
    @State private var result: (email: String, status: String)?
    @State private var checking = false

    private var address: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksLikeEmail: Bool { address.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil }
    /// The answer for what's in the field now (nil while typing or checking).
    private var status: String? { result?.email == address ? result?.status : nil }
    private var canShare: Bool {
        guard !busy, looksLikeEmail, let status else { return false }
        return status == "added" || status == "invited" || status == "unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.xs) {
            HStack(spacing: Brand.Space.s) {
                SunkField(placeholder: "name@example.com", text: $email, email: true).onSubmit { if canShare { share() } }
                InkPill(title: buttonTitle, symbol: "arrow.right", busy: busy, action: share).disabled(!canShare)
            }
            if let hint {
                Text(hint.text).font(Brand.caption).foregroundStyle(hint.warn ? pal.signal : pal.muted)
            }
        }
        .task(id: address) {
            checking = false
            guard !address.isEmpty else { return }
            // Debounce: a new keystroke cancels this task (and its sleep) and starts another.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard looksLikeEmail else { result = (address, "invalid"); return }
            checking = true
            let status = (try? await check(address))?.status ?? "unknown"
            guard !Task.isCancelled else { return }
            result = (address, status)
            checking = false
        }
    }

    private var hint: (text: String, warn: Bool)? {
        if checking { return ("Checking…", false) }
        switch status {
        case "added": return ("Has a Lynx account: they get access right away.", false)
        case "invited": return ("No Lynx account yet: they get access when they sign up with this email.", false)
        case "already": return ("Already has access.", true)
        case "invalid": return ("Not an email address.", true)
        default: return nil
        }
    }
}

enum ShareText {
    static func describe(_ r: ShareResult, email: String) -> String {
        switch r.status {
        case "added": return "Added \(email)."
        case "invited": return "\(email) has no account yet. They get access when they sign up with this email."
        case "already": return "\(email) already has access."
        default: return r.status
        }
    }
}

struct PersonRow<Trailing: View>: View {
    let profile: Profile
    let detail: String
    let isMe: Bool
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: Brand.Space.s) {
            Avatar(profile: profile, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(isMe ? "\(profile.name) (me)" : profile.name).font(Brand.text(13))
                Text([profile.email, detail].compactMap { $0 }.filter { $0 != profile.name }.joined(separator: " · "))
                    .font(Brand.caption).foregroundStyle(pal.muted).lineLimit(1)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.s)
    }
}
