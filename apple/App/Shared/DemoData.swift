import Foundation
import LynxCore

/// `LYNX_DEMO=1` (with `LYNX_DATA_DIR` pointing at a scratch folder) fills an empty store through the same
/// calls the UI makes — lists, quick add, the editor's fields — so screenshots and manual checks start from
/// realistic data. `LYNX_SCREEN` picks the first screen: `today`, `list:<name>`, `reminder:<title>`, `signin`.
@MainActor
enum DemoData {
    static func seed(into model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if model.db.reminders.isEmpty {
            model.settings.onboarded = !["signin", "welcome"].contains(env["LYNX_SCREEN"] ?? "")
            let home = model.createList(name: "Home", color: .green, icon: .house)
            let work = model.createList(name: "Work", color: .blue, icon: .briefcase)
            let trip = model.createList(name: "Trip to Vienna", color: .orange, icon: .plane)
            model.settings.defaultListId = home.id

            // Quick add, exactly as typed into the field.
            let water = model.quickAdd("Drink water every 45 min #home")
            if let id = water?.id {
                model.updateReminder(id) { r in
                    r.repeat?.window = RepeatWindow(start: "09:00", end: "18:00")
                    r.repeat?.advance = "auto"
                    if let rule = r.repeat, let due = r.dueAt {
                        // Start the series at 09:00 today so it reads as a working-day rhythm.
                        let day = WallTime(due, in: r.zone).days
                        let start = WallTime.atDay(day, secondOfDay: 9 * 3600)
                        r.dueAt = start.instant(in: r.zone)
                        r.repeat = RepeatRule(unit: rule.unit, interval: rule.interval, anchor: start.string, window: rule.window,
                                              advance: "auto")
                    }
                }
            }
            model.quickAdd("Water the plants every 3 days at 8 #home")
            if let pay = model.quickAdd("Pay rent today at 10 !! #home") {
                model.updateReminder(pay.id) { r in
                    r.dueAt = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date().addingTimeInterval(-86_400))
                    if let d = r.dueAt { r.repeat = RepeatRule(unit: .month, anchor: Recurrence.anchor(for: d, in: r.zone)) }
                }
            }
            if let standup = model.quickAdd("Stand-up notes today at 16:30 #work") {
                model.updateReminder(standup.id) { r in
                    r.earlyAlertMinutes = 15
                    r.nag = Nag(everyMinutes: 10, max: 3)
                    r.notes = "Blockers, yesterday, today."
                }
            }
            if let charge = model.quickAdd("Charge the headphones #work") {
                model.updateReminder(charge.id) { r in
                    r.bluetooth = BluetoothTrigger(name: "AirPods Pro", on: .disconnect)
                    r.appTrigger = nil
                }
            }
            if let slack = model.quickAdd("Reply to Marta in Slack #work") {
                model.updateReminder(slack.id) { r in
                    r.appTrigger = AppTrigger(name: "Slack", apple: "com.tinyspeck.slackmacgap")
                    r.flagged = true
                }
            }
            // A goal with subtasks.
            if let pack = model.quickAdd("Pack for Vienna tomorrow at 18 #trip") {
                model.updateReminder(pack.id) { r in
                    r.location = LocationTrigger(name: "Home", address: "Obchodná 2, Bratislava", lat: 48.1486, lon: 17.1077,
                                                 radius: 150, on: .leave)
                    r.nag = Nag(everyMinutes: 10, max: 6)
                    r.notes = "Train at 19:12 from hlavná stanica."
                }
                for (i, t) in ["Passport", "Train tickets", "Charger", "Umbrella", "Gift for Anna"].enumerated() {
                    if let s = model.quickAdd(t, parent: pack.id), i < 2 { model.toggle(s.id) }
                }
            }
            model.quickAdd("Book a table at Figlmüller #trip")
            if let old = model.quickAdd("Return library books #home") { model.toggle(old.id) }
            _ = (home, work, trip)
        }
        // LYNX_DEMO_SIGNUP=1: create a throwaway account on the configured server and sync the demo data up.
        if env["LYNX_DEMO_SIGNUP"] == "1", !model.signedIn, let backend = model.backend {
            Task {
                let email = "lynx-demo-\(UUID().uuidString.prefix(8).lowercased())@example.com"
                do {
                    if case .signedIn(let u) = try await backend.signUp(email: email, password: "demo-\(UUID().uuidString)") {
                        model.signedIn(u)
                    }
                } catch {
                    NSLog("Lynx demo sign-up failed: \(error)")
                }
            }
        }
        let screen = env["LYNX_SCREEN"] ?? "today"
        if screen.hasPrefix("list:") {
            let name = String(screen.dropFirst(5))
            if let l = model.db.visibleLists.first(where: { $0.name == name }) { model.selection = .list(l.id) }
        } else if screen.hasPrefix("reminder:") {
            let title = String(screen.dropFirst(9))
            if let r = model.db.reminders.values.first(where: { $0.title == title && !$0.isDeleted }) {
                if model.db.list(r.listId) != nil { model.selection = .list(r.listId) }
                model.selectedReminder = r.id
            }
        } else if screen.hasPrefix("smart:"), let s = SmartList(rawValue: String(screen.dropFirst(6))) {
            model.selection = .smart(s)
        } else if screen == "today" {
            model.selection = .smart(.today)
            model.selectedReminder = model.queries.reminders(.today).first?.id
        }
    }
}
