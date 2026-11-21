import AppKit
import LynxCore
import SwiftUI

/// Keeps the app running with no window so location, Bluetooth and app triggers keep working (SPEC §6.1).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Screenshots and checks can pin the appearance: LYNX_APPEARANCE=light|dark.
        if let a = ProcessInfo.processInfo.environment["LYNX_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.becameActive() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.willTerminate() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls { AppModel.shared.open(u) }
        }
    }
}

/// ⌘N new reminder, ⌘F search, ⌘⌫ delete, ⌘↩ complete (space completes in the list).
struct LynxCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Reminder") { newReminder() }.keyboardShortcut("n")
            Button("New List") { model.listEditor = ListEditorState(id: nil, name: "", color: .blue, icon: .list) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("Search") { openWindow(id: "main"); model.focusSearch += 1 }.keyboardShortcut("f")
            Divider()
            ForEach(Array(SmartList.grid.enumerated()), id: \.offset) { i, s in
                Button(s.title) { model.selection = .smart(s) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
        }
        CommandMenu("Reminder") {
            Button(completeTitle) { if let id = model.selectedReminder { model.toggle(id) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selectedReminder == nil)
            Button(model.selectedReminder.flatMap { model.db.reminders[$0] }?.flagged == true ? "Unflag" : "Flag") {
                if let id = model.selectedReminder { model.updateReminder(id) { $0.flagged.toggle() } }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model.selectedReminder == nil)
            Button("Snooze \(model.settings.defaultSnooze) min") {
                if let id = model.selectedReminder { model.snooze(id, minutes: model.settings.defaultSnooze) }
            }
            .disabled(model.selectedReminder == nil)
            Divider()
            Button("Delete") { deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedReminder == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Sync Now") { Task { await model.runSync(manifest: true) } }.disabled(!model.signedIn)
        }
    }

    private var completeTitle: String {
        model.selectedReminder.flatMap { model.db.reminders[$0] }?.isCompleted == true ? "Mark as Not Done" : "Mark as Done"
    }

    private func newReminder() {
        openWindow(id: "main")
        switch model.selection {
        case .smart(.today), .smart(.scheduled), .smart(.all), .smart(.flagged), .list: break
        default: if let l = model.currentListForNew { model.selection = .list(l) }
        }
        model.focusQuickAdd += 1
    }

    /// ⌘⌫ while typing deletes text, not the reminder.
    private func deleteSelected() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable {
            tv.deleteToBeginningOfLine(nil)
            return
        }
        if let id = model.selectedReminder { model.deleteReminder(id) }
    }
}

/// Menu bar icon: a checklist glyph plus today's count when there is something.
struct MenuBarLabel: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checklist")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
    }
}

/// The menu bar extra: Today and quick add (SPEC §10).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""

    var body: some View {
        let q = model.queries
        let rows = q.reminders(.today)
        let summary = q.todaySummary()
        VStack(alignment: .leading, spacing: Brand.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(summary.open)").font(Brand.stat).tracking(-0.8).monospacedDigit()
                Text("today").font(Brand.text(13, .medium)).foregroundStyle(pal.muted)
                Spacer()
                if summary.overdue > 0 {
                    Text("\(summary.overdue) overdue").font(Brand.text(11, .medium)).foregroundStyle(pal.signal)
                }
            }
            HStack(spacing: Brand.Space.s) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.muted)
                TextField("New reminder", text: $text).textFieldStyle(.plain).font(Brand.row)
                    .onSubmit {
                        var input = text
                        if QuickAddParser.parse(text, lists: model.db.visibleLists, now: Date()).dueAt == nil { input += " today" }
                        model.quickAdd(input, list: model.defaultList?.id)
                        text = ""
                    }
            }
            .padding(.horizontal, Brand.Space.m).padding(.vertical, Brand.Space.s)
            .background(pal.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if rows.isEmpty {
                Text("Nothing due today.").font(Brand.text(13)).foregroundStyle(pal.muted).padding(.vertical, Brand.Space.xs)
            } else {
                Panel(padding: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.prefix(30).enumerated()), id: \.element.id) { i, r in
                                if i > 0 { Hairline().padding(.leading, 46) }
                                ReminderRow(reminder: r, showList: true, compact: true)
                                    .onTapGesture(count: 2) { open(r.id) }
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                SoftButton(title: "Open Lynx Reminders") { open(nil) }
                Spacer()
                LinkButton(title: "Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(Brand.Space.l)
        .frame(width: 340)
        .background(pal.bg)
    }

    private func open(_ id: UUID?) {
        if let id { model.selectedReminder = id }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
