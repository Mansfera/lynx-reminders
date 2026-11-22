import LynxCore
import SwiftUI

/// Root: welcome until the person signs in or chooses to continue without an account, then the split view.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The palette environment is set below this view, so read the scheme directly here.
    private var pal: Palette { Palette(scheme: scheme) }

    var body: some View {
        let inside = model.settings.onboarded || model.signedIn
        ZStack {
            if inside {
                MainView().transition(Motion.settle(reduce: reduceMotion))
            } else {
                WelcomeFlow().transition(.opacity)
            }
        }
        .animation(Motion.enter(0.36), value: inside)
        .background(pal.bg)
        #if os(macOS)
        // The window chrome takes the page color: no gray toolbar band over the content.
        .modifier(HideWindowTitle())
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        .themed()
        .font(Brand.row)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $model.compactColumn) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 236, ideal: 260, max: 320)
        } content: {
            ReminderListView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 440)
        } detail: {
            DetailColumn()
                .navigationSplitViewColumnWidth(min: 340, ideal: 380)
        }
        .navigationSplitViewStyle(.balanced)
        .confirmationDialog(goalDialogTitle, isPresented: Binding(get: { model.pendingGoalCompletion != nil },
                                                                   set: { if !$0 { model.pendingGoalCompletion = nil } }),
                            titleVisibility: .visible) {
            Button("Complete all") { if let id = model.pendingGoalCompletion { model.completeGoal(id, includeSubtasks: true) } }
            Button("Only the goal") { if let id = model.pendingGoalCompletion { model.completeGoal(id, includeSubtasks: false) } }
            Button("Cancel", role: .cancel) { model.pendingGoalCompletion = nil }
        }
        .sheet(item: $model.listEditor) { state in
            ListEditorSheet(state: state).themed()
        }
        .sheet(item: Binding(get: { model.shareListTarget.map(IdBox.init) }, set: { model.shareListTarget = $0?.id })) { box in
            ShareListSheet(listId: box.id).themed()
        }
        .sheet(item: Binding(get: { model.shareReminderTarget.map(IdBox.init) }, set: { model.shareReminderTarget = $0?.id })) { box in
            ShareReminderSheet(reminderId: box.id).themed()
        }
        .sheet(isPresented: $model.showAccount) {
            AccountSheet().themed()
        }
        #if os(iOS)
        .sheet(isPresented: $model.showSettings) {
            NavigationStack { SettingsView().navigationTitle("Settings").toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showSettings = false } }
            } }.themed()
        }
        #endif
    }

    private var goalDialogTitle: String {
        guard let id = model.pendingGoalCompletion else { return "" }
        let n = model.db.subtasks(of: id).filter(\.isOpen).count
        return "Complete all \(n) open subtask\(n == 1 ? "" : "s") too?"
    }
}

struct IdBox: Identifiable {
    let id: UUID
}

/// The detail column: the selected reminder's editor, or a short hint.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    var body: some View {
        Group {
            if let id = model.selectedReminder, let r = model.db.reminders[id], !r.isDeleted {
                ReminderDetailView(reminderId: id).id(id)
                    .transition(.opacity)
            } else {
                VStack(spacing: Brand.Space.s) {
                    Text("Select a reminder to see its details.").font(Brand.text(13)).foregroundStyle(pal.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        // Switching reminders crossfades quickly, so arrow-key browsing stays snappy.
        .animation(Motion.tap, value: model.selectedReminder)
        .background(pal.bg)
    }
}

#if os(macOS)
/// The window title repeats the app name above the columns; drop it where macOS allows (15+).
struct HideWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
#endif
