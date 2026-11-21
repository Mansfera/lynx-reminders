import Foundation
import LynxCore
import Observation

/// Settings (SPEC §10), per device, in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    /// Demo runs (LYNX_DATA_DIR set, used for screenshots) keep their settings apart from the real ones.
    private let d: UserDefaults = ProcessInfo.processInfo.environment["LYNX_DATA_DIR"] != nil
        ? UserDefaults(suiteName: "com.mansfera.lynxreminders.demo") ?? .standard : .standard

    var defaultListId: UUID? {
        didSet { d.set(defaultListId?.uuidString, forKey: "defaultList") }
    }
    /// Minutes after midnight when all-day reminders alert (default 09:00).
    var allDayAlertMinutes: Int {
        didSet { d.set(allDayAlertMinutes, forKey: "allDayAlertMinutes") }
    }
    /// Default early alert for new reminders with a time; 0 = none.
    var defaultEarlyAlert: Int {
        didSet { d.set(defaultEarlyAlert, forKey: "defaultEarlyAlert") }
    }
    /// Snooze used by a plain tap on "Snooze" in the app (notifications offer 10 min and 1 h).
    var defaultSnooze: Int {
        didSet { d.set(defaultSnooze, forKey: "defaultSnooze") }
    }
    var showCompleted: Bool {
        didSet { d.set(showCompleted, forKey: "showCompleted") }
    }
    var showMenuBarExtra: Bool {
        didSet { d.set(showMenuBarExtra, forKey: "showMenuBarExtra") }
    }
    var onboarded: Bool {
        didSet { d.set(onboarded, forKey: "onboarded") }
    }

    init() {
        defaultListId = d.string(forKey: "defaultList").flatMap(UUID.init(uuidString:))
        allDayAlertMinutes = d.object(forKey: "allDayAlertMinutes") as? Int ?? 9 * 60
        defaultEarlyAlert = d.object(forKey: "defaultEarlyAlert") as? Int ?? 0
        defaultSnooze = d.object(forKey: "defaultSnooze") as? Int ?? 10
        showCompleted = d.object(forKey: "showCompleted") as? Bool ?? false
        showMenuBarExtra = d.object(forKey: "showMenuBarExtra") as? Bool ?? true
        onboarded = d.bool(forKey: "onboarded")
    }

    var plannerSettings: PlannerSettings { PlannerSettings(allDayAlertMinutes: allDayAlertMinutes) }
}
