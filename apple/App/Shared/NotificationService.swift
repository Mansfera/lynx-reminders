import Foundation
import LynxCore
import UserNotifications

/// Local notifications (SPEC §5.5): the planner's list goes to UNUserNotificationCenter, with the
/// Done / Snooze 10 min / Snooze 1 h actions. Done works without opening the UI.
@MainActor
final class NotificationService: NSObject {
    static let category = "LYNX_REMINDER"
    static let done = "LYNX_DONE"
    static let snooze10 = "LYNX_SNOOZE_10"
    static let snooze60 = "LYNX_SNOOZE_60"

    private unowned let model: AppModel
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a real app bundle (not available to command-line test hosts).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    private var scheduled: [String: PlannedNotification] = [:]
    private var pending: [PlannedNotification]?
    private var applyTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.done, title: "Done", options: [])
        let s10 = UNNotificationAction(identifier: Self.snooze10, title: "Snooze 10 min", options: [])
        let s60 = UNNotificationAction(identifier: Self.snooze60, title: "Snooze 1 h", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [done, s10, s60], intentIdentifiers: [], options: [])
        ])
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Replaces the pending time-based notifications with the plan (debounced: many edits → one rebuild).
    func schedule(_ plan: [PlannedNotification]) {
        pending = plan
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    private func apply() {
        guard let plan = pending, let center else { return }
        pending = nil
        let wanted = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Remove what's no longer planned or changed; add what's new.
        let stale = scheduled.filter { wanted[$0.key] != $0.value }.map(\.key)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for (id, p) in wanted where scheduled[id] != p {
            center.add(request(for: p))
        }
        scheduled = wanted
    }

    /// On launch: forget requests a previous run left that the plan no longer wants.
    func purgeUnknown() {
        guard let center else { return }
        let env = ProcessInfo.processInfo.environment
        // Dev switch: LYNX_CLEAR_NOTIFICATIONS=1 also empties Notification Center (e.g. after demo runs).
        let clearDelivered = env["LYNX_CLEAR_NOTIFICATIONS"] == "1"
        scheduled = [:]
        // Dev switch: LYNX_NOTIFICATION_REPORT=<file> writes what macOS holds for the app before and after this purge.
        guard let path = env["LYNX_NOTIFICATION_REPORT"] else {
            center.removeAllPendingNotificationRequests()
            if clearDelivered { center.removeAllDeliveredNotifications() }
            return
        }
        Task {
            let before = await Self.snapshot(center, "before purge")
            center.removeAllPendingNotificationRequests()
            if clearDelivered { center.removeAllDeliveredNotifications() }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let after = await Self.snapshot(center, "3 s after purge")
            try? (before + "\n" + after + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func snapshot(_ center: UNUserNotificationCenter, _ label: String) async -> String {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let p = pending.map { "  pending   \($0.identifier)  \($0.content.title)  \(String(describing: $0.trigger))" }
        let d = delivered.map { "  delivered \($0.request.identifier)  \($0.request.content.title)  \($0.date)" }
        return (["\(label): \(pending.count) pending, \(delivered.count) delivered"] + p + d).joined(separator: "\n")
    }

    private func request(for p: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = p.title.isEmpty ? "Reminder" : p.title
        content.body = p.body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = p.reminderId.uuidString
        content.userInfo = ["reminder": p.reminderId.uuidString]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: p.id, content: content, trigger: trigger)
    }

    /// A context trigger fired: alert now (`<id>|ctx|0`).
    func postContext(_ r: Reminder, event: TriggerEvent, list: String?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = r.title.isEmpty ? "Reminder" : r.title
        content.body = Self.describe(event, r) + (list.map { " · \($0)" } ?? "")
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["reminder": r.id.uuidString]
        let id = PlannedNotification.makeId(r.id, .ctx, 0)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func describe(_ event: TriggerEvent, _ r: Reminder) -> String {
        switch event {
        case .location(_, let ev): return ev == .arrive ? "Arrived at \(r.location?.name ?? "the place")" : "Left \(r.location?.name ?? "the place")"
        case .bluetooth(let name, _, let ev): return ev == .connect ? "\(name) connected" : "\(name) disconnected"
        case .app(let name, _): return "\(name) opened"
        }
    }

    fileprivate func handle(action: String, reminder: UUID) {
        switch action {
        case Self.done:
            model.completeFromNotification(reminder)
        case Self.snooze10:
            model.snooze(reminder, minutes: 10)
        case Self.snooze60:
            model.snooze(reminder, minutes: 60)
        case UNNotificationDefaultActionIdentifier:
            model.selectedReminder = reminder
            if let r = model.db.reminders[reminder], model.db.list(r.listId) != nil { model.selection = .list(r.listId) }
            Platform.bringToFront()
        default:
            break
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo["reminder"] as? String).flatMap(UUID.init(uuidString:))
            ?? PlannedNotification.parse(response.notification.request.identifier)?.reminder
        let done = UncheckedSendable(completionHandler)
        Task { @MainActor in
            if let id { self.handle(action: action, reminder: id) }
            AppModel.shared.willTerminate()  // make sure the change reaches disk if the system suspends us
            done.value()
        }
    }
}

/// Carries a non-Sendable completion handler across to the main actor.
nonisolated struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
