import AppIntents
import LynxCore

/// iOS can't observe Bluetooth connections or other apps (SPEC §6.1). A Shortcuts personal automation
/// ("Bluetooth → Run Fire Lynx trigger", "App is opened → Run Fire Lynx trigger") calls this intent instead.
enum LynxTriggerKind: String, AppEnum {
    case bluetooth, app
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Trigger kind"
    static let caseDisplayRepresentations: [LynxTriggerKind: DisplayRepresentation] = [
        .bluetooth: "Bluetooth",
        .app: "App",
    ]
}

enum LynxTriggerEvent: String, AppEnum {
    case connect, disconnect, open
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Event"
    static let caseDisplayRepresentations: [LynxTriggerEvent: DisplayRepresentation] = [
        .connect: "Connect",
        .disconnect: "Disconnect",
        .open: "Open",
    ]
}

struct FireTriggerIntent: AppIntent {
    static let title: LocalizedStringResource = "Fire Lynx trigger"
    static let description = IntentDescription("Tells Lynx Reminders that a Bluetooth device connected or disconnected, or an app opened, so matching reminders alert.")
    static let openAppWhenRun = false

    @Parameter(title: "Kind", default: .bluetooth) var kind: LynxTriggerKind
    @Parameter(title: "Name") var name: String
    @Parameter(title: "Event", default: .connect) var event: LynxTriggerEvent

    static var parameterSummary: some ParameterSummary {
        Summary("Fire Lynx \(\.$kind) trigger for \(\.$name) on \(\.$event)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let model = AppModel.shared
        model.start()
        let before = model.device.cooldowns
        switch kind {
        case .bluetooth:
            model.handleTrigger(.bluetooth(name: name, id: nil, event: event == .disconnect ? .disconnect : .connect), platform: .ios)
        case .app:
            model.handleTrigger(.app(name: name, bundleId: nil), platform: .ios)
        }
        let fired = model.device.cooldowns.filter { before[$0.key] != $0.value }.count
        model.willTerminate()
        return .result(value: fired)
    }
}

struct LynxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FireTriggerIntent(), phrases: ["Fire \(.applicationName) trigger"],
                    shortTitle: "Fire Lynx trigger", systemImageName: "bell.badge")
    }
}
