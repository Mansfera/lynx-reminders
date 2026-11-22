import LynxCore
import SwiftUI

@main
struct LynxRemindersApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    init() {
        Brand.registerFonts()
        AppModel.shared.start()
    }

    var body: some Scene {
        #if os(macOS)
        Window("Lynx Reminders", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onChange(of: phase) { _, p in if p == .active { model.becameActive() } }
        }
        .defaultSize(width: 1220, height: 780)
        .commands { LynxCommands(model: model) }

        Settings {
            SettingsView().environment(model).themed()
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarExtra }, set: { model.settings.showMenuBarExtra = $0 })) {
            MenuBarView().environment(model).themed()
        } label: {
            MenuBarLabel(count: model.queries.count(.today))
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: phase) { _, p in if p == .active { model.becameActive() } }
                .onOpenURL { url in model.open(url) }
        }
        #endif
    }
}

extension AppModel {
    /// `lynxreminders://reminder/<id>` opens a reminder.
    func open(_ url: URL) {
        guard url.scheme == "lynxreminders", url.host == "reminder", let id = UUID(uuidString: url.lastPathComponent),
              let r = db.reminders[id] else { return }
        if db.list(r.listId) != nil { selection = .list(r.listId) }
        showReminder(id)
    }
}
