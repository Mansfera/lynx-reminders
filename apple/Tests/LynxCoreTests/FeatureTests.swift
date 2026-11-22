import Foundation
import XCTest
@testable import LynxCore

final class TriggerTests: XCTestCase {
    func testBluetoothMatchesByPlatformIdWhenPresent() {
        let t = BluetoothTrigger(name: "AirPods Pro", on: .connect, ids: ["mac": "a4-c3-61-01-02-03", "android": "A4:C3:61:01:02:03"])
        XCTAssertTrue(TriggerMatcher.matches(t, name: "Renamed", id: "A4-C3-61-01-02-03", event: .connect, platform: .mac))
        XCTAssertFalse(TriggerMatcher.matches(t, name: "AirPods Pro", id: "ff-ff-ff-ff-ff-ff", event: .connect, platform: .mac),
                       "id present on both sides: a same-named other device does not match")
        XCTAssertTrue(TriggerMatcher.matches(t, name: "AirPods Pro", id: "A4:C3:61:01:02:03", event: .connect, platform: .android))
        XCTAssertFalse(TriggerMatcher.matches(t, name: "AirPods Pro", id: "a4-c3-61-01-02-03", event: .disconnect, platform: .mac))
    }

    func testBluetoothFallsBackToNameCaseInsensitiveExact() {
        let t = BluetoothTrigger(name: "AirPods Pro", on: .disconnect, ids: ["android": "A4:C3:61:01:02:03"])
        XCTAssertTrue(TriggerMatcher.matches(t, name: "airpods pro", id: "a4-c3-61-01-02-03", event: .disconnect, platform: .mac),
                      "no mac id recorded: match by name")
        XCTAssertFalse(TriggerMatcher.matches(t, name: "AirPods Pro 2", id: nil, event: .disconnect, platform: .mac), "exact, not prefix")
        XCTAssertTrue(TriggerMatcher.matches(t, name: "AIRPODS PRO", id: nil, event: .disconnect, platform: .ios))
    }

    func testAppMatchesByBundleIdThenName() {
        let t = AppTrigger(name: "Slack", apple: "com.tinyspeck.slackmacgap", android: "com.Slack")
        XCTAssertTrue(TriggerMatcher.matches(t, name: "Something", bundleId: "com.tinyspeck.slackmacgap", platform: .mac))
        XCTAssertFalse(TriggerMatcher.matches(t, name: "Slack", bundleId: "com.other.slack", platform: .mac))
        XCTAssertTrue(TriggerMatcher.matches(t, name: "slack", bundleId: nil, platform: .ios), "Shortcuts passes only the name")
        let noId = AppTrigger(name: "Slack", android: "com.Slack")
        XCTAssertTrue(TriggerMatcher.matches(noId, name: "SLACK", bundleId: "com.tinyspeck.slackmacgap", platform: .mac))
        XCTAssertTrue(TriggerMatcher.matches(t, name: "x", bundleId: "com.slack", platform: .android))
    }

    func testCooldownAndOpenOnly() {
        var db = LocalDatabase()
        let l = LynxList(ownerId: nil, name: "L", sortOrder: 1)
        db.upsertList(l)
        var r = Reminder(listId: l.id, createdBy: nil, title: "Charge", sortOrder: 1)
        r.bluetooth = BluetoothTrigger(name: "Car", on: .connect)
        db.upsertReminder(r)
        var done = Reminder(listId: l.id, createdBy: nil, title: "Done one", sortOrder: 2)
        done.bluetooth = BluetoothTrigger(name: "Car", on: .connect)
        done.completedAt = Date()
        db.upsertReminder(done)

        var device = DeviceState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ev = TriggerEvent.bluetooth(name: "car", id: nil, event: .connect)
        let first = TriggerMatcher.reminders(for: ev, in: db, device: device, now: now, platform: .mac)
        XCTAssertEqual(first.map(\.id), [r.id])
        TriggerMatcher.recordFired(first, event: ev, device: &device, now: now)
        XCTAssertTrue(TriggerMatcher.reminders(for: ev, in: db, device: device, now: now.addingTimeInterval(14 * 60), platform: .mac).isEmpty)
        XCTAssertEqual(TriggerMatcher.reminders(for: ev, in: db, device: device, now: now.addingTimeInterval(15 * 60), platform: .mac).count, 1)
        XCTAssertEqual(device.contextFired[r.id], now)
    }

    func testContextFireStartsNagInPlanner() {
        var db = LocalDatabase()
        let l = LynxList(ownerId: nil, name: "L", sortOrder: 1)
        db.upsertList(l)
        var r = Reminder(listId: l.id, createdBy: nil, title: "Take keys", sortOrder: 1)
        r.location = LocationTrigger(name: "Home", address: nil, lat: 48.1, lon: 17.1, on: .leave)
        r.nag = Nag(everyMinutes: 5, max: 2)
        db.upsertReminder(r)
        var device = DeviceState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        device.contextFired[r.id] = now
        let plan = NotificationPlanner.plan(db: db, device: device, now: now)
        XCTAssertEqual(plan.map(\.id), [PlannedNotification.makeId(r.id, .nag, 1), PlannedNotification.makeId(r.id, .nag, 2)])
    }

    func testNearestRegions() {
        var db = LocalDatabase()
        let l = LynxList(ownerId: nil, name: "L", sortOrder: 1)
        db.upsertList(l)
        for i in 0..<30 {
            var r = Reminder(listId: l.id, createdBy: nil, title: "r\(i)", sortOrder: Double(i))
            r.location = LocationTrigger(name: "p\(i)", address: nil, lat: 48 + Double(i) * 0.1, lon: 17, radius: 50)
            db.upsertReminder(r)
        }
        let regions = RegionPlanner.regions(in: db, near: (48, 17), limit: 20)
        XCTAssertEqual(regions.count, 20)
        XCTAssertEqual(regions.first?.lat, 48)
        XCTAssertEqual(regions.first?.radius, 100, "radius clamped to 100…2000")
        XCTAssertTrue(regions.allSatisfy { $0.lat < 50 })
    }
}

final class SmartListTests: XCTestCase {
    let me = UUID()
    let other = UUID()
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        return c
    }
    let now = LynxTime.parse("2026-11-14T12:00:00Z")!  // 13:00 in Bratislava

    func make() -> (LocalDatabase, [String: UUID]) {
        var db = LocalDatabase()
        var ids: [String: UUID] = [:]
        let home = LynxList(ownerId: me, name: "Home", sortOrder: 1)
        let work = LynxList(ownerId: other, name: "Work", sortOrder: 2)
        db.upsertList(home)
        db.upsertList(work)
        db.members = [ListMember(listId: home.id, userId: me, role: "owner"),
                      ListMember(listId: work.id, userId: other, role: "owner"),
                      ListMember(listId: work.id, userId: me, role: "editor")]
        func add(_ title: String, list: LynxList, due: String? = nil, allDay: Bool = false, _ body: (inout Reminder) -> Void = { _ in }) {
            var r = Reminder(listId: list.id, createdBy: me, title: title, sortOrder: Double(ids.count), timeZone: "Europe/Bratislava")
            r.dueAt = due.flatMap(LynxTime.parse)
            r.allDay = allDay
            body(&r)
            db.upsertReminder(r)
            ids[title] = r.id
        }
        add("overdue", list: home, due: "2026-11-13T08:00:00Z")
        add("later today", list: home, due: "2026-11-14T16:00:00Z")
        add("all day today", list: home, due: "2026-11-13T23:00:00Z", allDay: true)
        add("tomorrow", list: work, due: "2026-11-15T08:00:00Z") { $0.flagged = true; $0.assigneeId = self.me }
        add("no date", list: work) { $0.notes = "Buy café beans" }
        add("done", list: home) { $0.completedAt = LynxTime.parse("2026-11-14T10:00:00Z") }
        add("goal", list: home)
        add("sub1", list: home) { $0.parentId = ids["goal"] }
        add("sub2", list: home) { $0.parentId = ids["goal"]; $0.completedAt = Date() }
        add("deleted", list: home, due: "2026-11-14T09:00:00Z") { $0.deletedAt = Date() }
        // Shared with me directly: its list is not visible to me.
        let hidden = LynxList(ownerId: other, name: "Theirs", sortOrder: 3)
        var direct = Reminder(listId: hidden.id, createdBy: other, title: "direct share", sortOrder: 1)
        direct.updatedAt = Date()
        db.reminders[direct.id] = direct
        db.shares = [ReminderShare(reminderId: direct.id, userId: me)]
        ids["direct share"] = direct.id
        return (db, ids)
    }

    func titles(_ rs: [Reminder]) -> [String] { rs.map(\.title) }

    func testToday() {
        let (db, _) = make()
        let q = SmartQueries(db: db, me: me, now: now, calendar: cal)
        XCTAssertEqual(Set(titles(q.reminders(.today))), ["overdue", "later today", "all day today"])
        XCTAssertEqual(q.count(.today), 3)
        let s = q.todaySummary()
        XCTAssertEqual(s.overdue, 1)
        XCTAssertEqual(s.next, LynxTime.parse("2026-11-14T16:00:00Z"))
        XCTAssertEqual(s.marks.count, 1, "only timed reminders due today get a dot; the overdue one is from yesterday")
    }

    func testScheduledGroupsByDay() {
        let (db, _) = make()
        let q = SmartQueries(db: db, me: me, now: now, calendar: cal)
        let groups = q.groups(.scheduled)
        XCTAssertEqual(groups.map { titles($0.reminders) }, [["overdue"], ["all day today", "later today"], ["tomorrow"]])
    }

    func testAllFlaggedGoalsAssignedCompleted() {
        let (db, _) = make()
        let q = SmartQueries(db: db, me: me, now: now, calendar: cal)
        XCTAssertEqual(Set(titles(q.reminders(.all))), ["overdue", "later today", "all day today", "tomorrow", "no date", "goal", "direct share"])
        XCTAssertEqual(q.groups(.all).count, 3, "Home, Work, and the directly shared one")
        XCTAssertEqual(titles(q.reminders(.flagged)), ["tomorrow"])
        XCTAssertEqual(titles(q.reminders(.goals)), ["goal"])
        XCTAssertEqual(titles(q.reminders(.assignedToMe)), ["tomorrow"])
        XCTAssertEqual(titles(q.reminders(.sharedWithMe)), ["direct share"])
        XCTAssertEqual(Set(titles(q.reminders(.completed))), ["done", "sub2"])
        XCTAssertEqual(titles(q.reminders(.completed)).first, "sub2", "newest first")
    }

    func testGoalProgress() {
        let (db, ids) = make()
        XCTAssertTrue(db.isGoal(ids["goal"]!))
        XCTAssertEqual(db.progress(of: ids["goal"]!).done, 1)
        XCTAssertEqual(db.progress(of: ids["goal"]!).total, 2)
    }

    func testCompletingGoalWithSubtasks() {
        var (db, ids) = make()
        db.complete(ids["goal"]!, by: me, includeSubtasks: true)
        XCTAssertTrue(db.subtasks(of: ids["goal"]!).allSatisfy(\.isCompleted))
        var (db2, ids2) = make()
        db2.complete(ids2["goal"]!, by: me, includeSubtasks: false)
        XCTAssertFalse(db2.subtasks(of: ids2["goal"]!).allSatisfy(\.isCompleted), "Only the goal")
    }

    func testSearchTitlesAndNotesDiacriticInsensitive() {
        let (db, _) = make()
        let q = SmartQueries(db: db, me: me, now: now, calendar: cal)
        XCTAssertEqual(titles(q.search("cafe")), ["no date"])
        XCTAssertEqual(titles(q.search("TODAY")), ["later today", "all day today"].sorted { a, _ in a == "all day today" })
        XCTAssertTrue(q.search("deleted").isEmpty)
    }

    func testMyListsVsSharedLists() {
        let (db, _) = make()
        let q = SmartQueries(db: db, me: me, now: now, calendar: cal)
        XCTAssertEqual(q.myLists.map(\.name), ["Home"])
        XCTAssertEqual(q.sharedLists.map(\.name), ["Work"])
        let local = SmartQueries(db: db, me: nil, now: now, calendar: cal)
        XCTAssertTrue(local.reminders(.sharedWithMe).isEmpty)
    }
}

final class QuickAddTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/Bratislava")!
    let now = LynxTime.parse("2026-11-14T12:00:00Z")!  // Saturday 13:00 local
    let lists = [LynxList(ownerId: nil, name: "Groceries", sortOrder: 1), LynxList(ownerId: nil, name: "Work Stuff", sortOrder: 2)]

    func p(_ s: String) -> QuickAddResult { QuickAddParser.parse(s, lists: lists, now: now, timeZone: tz) }
    func local(_ d: Date?) -> String? { d.map { WallTime($0, in: tz).string } }

    func testTomorrowAt9() {
        let r = p("Call mom tomorrow at 9")
        XCTAssertEqual(r.title, "Call mom")
        XCTAssertEqual(local(r.dueAt), "2026-11-15T09:00")
        XCTAssertFalse(r.allDay)
    }

    func testDateOnlyIsAllDay() {
        let r = p("Pay rent mon")
        XCTAssertEqual(r.title, "Pay rent")
        XCTAssertEqual(local(r.dueAt), "2026-11-16T00:00")
        XCTAssertTrue(r.allDay)
    }

    func testTimeOnlyRollsToTomorrowWhenPast() {
        XCTAssertEqual(local(p("Stretch at 9:30").dueAt), "2026-11-15T09:30")
        XCTAssertEqual(local(p("Stretch 18:15").dueAt), "2026-11-14T18:15")
        XCTAssertEqual(local(p("Movie at 8pm").dueAt), "2026-11-14T20:00")
        XCTAssertEqual(local(p("Read tonight").dueAt), "2026-11-14T20:00")
    }

    func testInDuration() {
        let r = p("Check oven in 2 hours")
        XCTAssertEqual(r.title, "Check oven")
        XCTAssertEqual(r.dueAt, now.addingTimeInterval(7200))
        XCTAssertEqual(p("tea in 30 min").dueAt, now.addingTimeInterval(1800))
    }

    func testRepeats() {
        let water = p("Drink water every 45 min")
        XCTAssertEqual(water.title, "Drink water")
        XCTAssertEqual(water.repeat?.unit, .minute)
        XCTAssertEqual(water.repeat?.interval, 45)
        XCTAssertEqual(water.repeat?.anchor, local(water.dueAt))
        let daily = p("Vitamins every day at 8")
        XCTAssertEqual(daily.repeat?.unit, .day)
        XCTAssertEqual(local(daily.dueAt), "2026-11-15T08:00")
        XCTAssertEqual(daily.repeat?.anchor, "2026-11-15T08:00")
        XCTAssertEqual(p("Report every week").repeat?.unit, .week)
        XCTAssertEqual(p("Rent every month").repeat?.unit, .month)
    }

    func testPriorityAndList() {
        let r = p("Milk !! #groceries")
        XCTAssertEqual(r.title, "Milk")
        XCTAssertEqual(r.priority, 2)
        XCTAssertEqual(r.listId, lists[0].id)
        XCTAssertEqual(p("Deploy !!! #workstuff").listId, lists[1].id)
        XCTAssertEqual(p("x #nope").unknownListTag, "nope")
        XCTAssertEqual(p("Ship it!").title, "Ship it!", "a ! inside a word is not priority")
    }

    func testPlainTitleUntouched() {
        let r = p("Fix the 2 lamps")
        XCTAssertEqual(r.title, "Fix the 2 lamps")
        XCTAssertNil(r.dueAt)
    }
}

final class PlannerTests: XCTestCase {
    let now = LynxTime.parse("2026-11-14T08:00:00Z")!

    func base() -> (LocalDatabase, LynxList) {
        var db = LocalDatabase()
        let l = LynxList(ownerId: nil, name: "Home", sortOrder: 1)
        db.upsertList(l)
        return (db, l)
    }

    func testDueEarlyAndNag() {
        var (db, l) = base()
        var r = Reminder(listId: l.id, createdBy: nil, title: "Meds", sortOrder: 1, timeZone: "Europe/Bratislava")
        r.dueAt = now.addingTimeInterval(3600)
        r.earlyAlertMinutes = 15
        r.nag = Nag(everyMinutes: 10, max: 3)
        db.upsertReminder(r)
        let plan = NotificationPlanner.plan(db: db, device: DeviceState(), now: now)
        XCTAssertEqual(plan.map { "\($0.kind.rawValue)\($0.n)" }, ["early0", "due0", "nag1", "nag2", "nag3"])
        XCTAssertEqual(plan[1].id, "\(r.id.uuidString.lowercased())|due|0")
        XCTAssertEqual(plan[0].date, now.addingTimeInterval(45 * 60))
    }

    func testOverdueStillNagsInFuture() {
        var (db, l) = base()
        var r = Reminder(listId: l.id, createdBy: nil, title: "Meds", sortOrder: 1)
        r.dueAt = now.addingTimeInterval(-25 * 60)
        r.nag = Nag(everyMinutes: 10, max: 6)
        db.upsertReminder(r)
        let plan = NotificationPlanner.plan(db: db, device: DeviceState(), now: now)
        XCTAssertEqual(plan.map(\.n), [3, 4, 5, 6])
        XCTAssertTrue(plan.allSatisfy { $0.kind == .nag })
    }

    func testAllDayUsesAlertTime() {
        var (db, l) = base()
        var r = Reminder(listId: l.id, createdBy: nil, title: "Birthday", sortOrder: 1, timeZone: "Europe/Bratislava")
        r.allDay = true
        r.dueAt = WallTime("2026-11-15T00:00")!.instant(in: TimeZone(identifier: "Europe/Bratislava")!)
        db.upsertReminder(r)
        let plan = NotificationPlanner.plan(db: db, device: DeviceState(), now: now, settings: PlannerSettings(allDayAlertMinutes: 9 * 60 + 30))
        XCTAssertEqual(plan.first.map { LynxTime.format($0.date) }, "2026-11-15T08:30:00Z")
    }

    func testAutoAdvanceSchedulesNextSlotsAndCap() {
        var (db, l) = base()
        var r = Reminder(listId: l.id, createdBy: nil, title: "Water", sortOrder: 1, timeZone: "Europe/Bratislava")
        r.dueAt = LynxTime.parse("2026-11-14T07:00:00Z")
        r.repeat = RepeatRule(unit: .minute, interval: 15, anchor: "2026-11-14T08:00", advance: "auto")
        db.upsertReminder(r)
        let plan = NotificationPlanner.plan(db: db, device: DeviceState(), now: now, settings: PlannerSettings(autoLookahead: 100))
        XCTAssertEqual(plan.count, 60, "capped at 60")
        XCTAssertEqual(plan.first?.kind, .auto)
        XCTAssertEqual(plan.first.map { LynxTime.format($0.date) }, "2026-11-14T08:15:00Z")
        XCTAssertEqual(plan, plan.sorted { $0.date < $1.date })
    }

    func testSnoozeReplacesDueAndRestartsNag() {
        var (db, l) = base()
        var r = Reminder(listId: l.id, createdBy: nil, title: "Call", sortOrder: 1)
        r.dueAt = now.addingTimeInterval(-60)
        r.nag = Nag(everyMinutes: 5, max: 2)
        db.upsertReminder(r)
        var device = DeviceState()
        device.snoozes[r.id] = now.addingTimeInterval(600)
        let plan = NotificationPlanner.plan(db: db, device: device, now: now)
        XCTAssertEqual(plan.map { "\($0.kind.rawValue)\($0.n)" }, ["snooze0", "nag1", "nag2"])
        XCTAssertEqual(plan[1].date, now.addingTimeInterval(900))
    }

    func testCompletedAndDeletedAreSkipped() {
        var (db, l) = base()
        var a = Reminder(listId: l.id, createdBy: nil, title: "a", sortOrder: 1)
        a.dueAt = now.addingTimeInterval(60)
        a.completedAt = now
        var b = Reminder(listId: l.id, createdBy: nil, title: "b", sortOrder: 2)
        b.dueAt = now.addingTimeInterval(60)
        b.deletedAt = now
        db.upsertReminder(a)
        db.upsertReminder(b)
        XCTAssertTrue(NotificationPlanner.plan(db: db, device: DeviceState(), now: now).isEmpty)
    }

    func testIdRoundTrip() {
        let id = UUID()
        let s = PlannedNotification.makeId(id, .snooze, 0)
        let p = PlannedNotification.parse(s)
        XCTAssertEqual(p?.reminder, id)
        XCTAssertEqual(p?.kind, .snooze)
    }
}

final class StoreTests: XCTestCase {
    func testPersistsAtomicallyAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lynx-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LynxStore(folder: dir)
        let l = LynxList(ownerId: nil, name: "Persisted", sortOrder: 1)
        store.write { $0.upsertList(l) }
        store.flush()
        let again = LynxStore(folder: dir)
        XCTAssertEqual(again.snapshot.lists[l.id]?.name, "Persisted")
        XCTAssertEqual(again.snapshot.dirtyLists, [l.id])
    }
}

final class QuickAddAITests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/Bratislava")!
    let now = LynxTime.parse("2026-11-14T12:00:00Z")!  // Saturday 13:00 local
    let lists = [LynxList(ownerId: nil, name: "Groceries", sortOrder: 1), LynxList(ownerId: nil, name: "Work Stuff", sortOrder: 2)]

    func r(_ f: QuickAddAI.Fields) -> QuickAddResult { QuickAddAI.result(from: f, original: "typed", lists: lists, now: now, timeZone: tz) }
    func local(_ d: Date?) -> String? { d.map { WallTime($0, in: tz).string } }

    func testUserMessageCarriesNowZoneAndLists() {
        let m = QuickAddAI.userMessage("milk", lists: lists, now: now, timeZone: tz)
        XCTAssertTrue(m.hasPrefix("Now: 2026-11-14 13:00, Saturday (Europe/Bratislava)"), m)
        XCTAssertTrue(m.contains("Lists: Groceries, Work Stuff"))
        XCTAssertTrue(m.hasSuffix("<line>milk</line>"))
    }

    func testDateAndTime() {
        let x = r(.init(title: " Call mom ", date: "2026-11-15", time: "09:00", priority: 7, list: "work stuff"))
        XCTAssertEqual(x.title, "Call mom")
        XCTAssertEqual(local(x.dueAt), "2026-11-15T09:00")
        XCTAssertFalse(x.allDay)
        XCTAssertEqual(x.priority, 3, "clamped")
        XCTAssertEqual(x.listId, lists[1].id, "list matched case-insensitively")
    }

    func testDateOnlyIsAllDayAndUnknownListIsKept() {
        let x = r(.init(title: "Pay rent", notes: "  ", date: "2026-12-01", list: "Home"))
        XCTAssertTrue(x.allDay)
        XCTAssertEqual(local(x.dueAt), "2026-12-01T00:00")
        XCTAssertNil(x.listId)
        XCTAssertEqual(x.unknownListTag, "Home")
        XCTAssertNil(x.notes, "blank notes dropped")
    }

    func testTimeOnlyAlreadyPassedMeansTomorrowAndBadValuesAreIgnored() {
        XCTAssertEqual(local(r(.init(title: "x", time: "09:00")).dueAt), "2026-11-15T09:00")
        let bad = r(.init(title: "", date: "soon", time: "25:00"))
        XCTAssertEqual(bad.title, "typed", "empty title falls back to the typed line")
        XCTAssertNil(bad.dueAt)
    }

    func testRepeatsAreAnchored() {
        let daily = r(.init(title: "Pills", time: "20:00", repeat: .init(unit: "day")))
        XCTAssertEqual(daily.repeat?.unit, .day)
        XCTAssertEqual(daily.repeat?.anchor, "2026-11-14T20:00")
        let weekly = r(.init(title: "Gym", time: "07:00", repeat: .init(unit: "week", weekdays: [3, 1, 1, 9])))
        XCTAssertEqual(weekly.repeat?.weekdays, [1, 3])
        XCTAssertEqual(local(weekly.dueAt), "2026-11-16T07:00", "next Monday")
        let water = r(.init(title: "Water", repeat: .init(unit: "minute", interval: 45)))
        XCTAssertEqual(local(water.dueAt), "2026-11-14T13:45")
        XCTAssertNil(r(.init(title: "x", repeat: .init(unit: "fortnight"))).repeat, "unknown unit dropped")
    }
}

final class QuickAddModelTests: XCTestCase {
    func caps(structured: Bool, low: Bool, adaptive: Bool) -> [String: Any] {
        ["structured_outputs": ["supported": structured],
         "effort": ["supported": low, "low": ["supported": low]],
         "thinking": ["supported": true, "types": ["adaptive": ["supported": adaptive], "enabled": ["supported": !adaptive]]]]
    }

    func testModelOptionsKeepOnlyModelsThatCanReadQuickAdd() {
        let data: [[String: Any]] = [
            ["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "capabilities": caps(structured: true, low: true, adaptive: true)],
            ["id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5", "capabilities": caps(structured: true, low: true, adaptive: true)],
            ["id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5", "capabilities": caps(structured: true, low: false, adaptive: false)],
            ["id": "claude-future-9", "capabilities": caps(structured: true, low: true, adaptive: true)],
            ["id": "no-caps"],
        ]
        XCTAssertEqual(QuickAddAI.modelOptions(data).map(\.id), ["claude-opus-5-5", "claude-haiku-5-5", "claude-future-9"])
        XCTAssertEqual(QuickAddAI.modelOptions(data).last?.name, "claude-future-9", "no display name: the id")
    }

    func testFallbacksOnlyForModelsThatTakeThem() {
        XCTAssertFalse(QuickAddAI.usesServerFallbacks(QuickAddAI.defaultModel))
        XCTAssertTrue(QuickAddAI.usesServerFallbacks("claude-opus-5-5"))
        XCTAssertFalse(QuickAddAI.usesServerFallbacks("claude-future-9"))
    }
}

final class QuickAddReaderTests: XCTestCase {
    func testActiveReader() {
        XCTAssertEqual(QuickAddAI.activeReader(preferred: .claude, claudeConnected: true, deviceAvailable: true), .claude)
        XCTAssertEqual(QuickAddAI.activeReader(preferred: .device, claudeConnected: true, deviceAvailable: true), .device)
        XCTAssertEqual(QuickAddAI.activeReader(preferred: .device, claudeConnected: true, deviceAvailable: false), .claude)
        XCTAssertEqual(QuickAddAI.activeReader(preferred: .claude, claudeConnected: false, deviceAvailable: true), .device)
        XCTAssertNil(QuickAddAI.activeReader(preferred: .claude, claudeConnected: false, deviceAvailable: false))
    }

    func testComingDays() {
        let m = QuickAddAI.userMessage("x", lists: [], now: LynxTime.parse("2026-11-14T12:00:00Z")!, timeZone: TimeZone(identifier: "Europe/Bratislava")!)
        XCTAssertTrue(m.contains("Coming days: Sunday 2026-11-15, Monday 2026-11-16,"), m)
    }
}

/// shared/vectors/secret-seal.json, made with Python's `cryptography`: same bytes on every platform.
final class SecretSealTests: XCTestCase {
    struct Vector: Decodable {
        struct KDF: Decodable { var password: String; var salt: String; var iter: Int; var dk: String }
        var pin: String
        var context: String
        var secret: String
        var sealed: SealedSecret
        var pbkdf2: [KDF]
    }

    var vector: Vector {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/vectors/secret-seal.json")
        return try! JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testPBKDF2MatchesKnownAnswers() {
        for k in vector.pbkdf2 {
            let dk = SecretSeal.pbkdf2(Data(k.password.utf8), salt: Data(k.salt.utf8), iterations: k.iter)
            XCTAssertEqual(dk.map { String(format: "%02x", $0) }.joined(), k.dk)
        }
    }

    func testSealMatchesVectorAndOpens() throws {
        let v = vector
        let sealed = try SecretSeal.seal(v.secret, pin: v.pin, context: v.context, iterations: v.sealed.iter,
                                         salt: Data(base64Encoded: v.sealed.salt)!, nonce: Data(base64Encoded: v.sealed.nonce)!)
        XCTAssertEqual(sealed, v.sealed)
        XCTAssertEqual(try SecretSeal.open(v.sealed, pin: v.pin, context: v.context), v.secret)
        // The PIN is compared after NFC: a decomposed "é" opens it too.
        XCTAssertEqual(try SecretSeal.open(v.sealed, pin: v.pin.decomposedStringWithCanonicalMapping, context: v.context), v.secret)
    }

    func testWrongPINOrOtherAccountFails() {
        let v = vector
        XCTAssertThrowsError(try SecretSeal.open(v.sealed, pin: "000000", context: v.context)) { XCTAssertEqual($0 as? SecretSeal.Failure, .wrongPIN) }
        XCTAssertThrowsError(try SecretSeal.open(v.sealed, pin: v.pin, context: v.context + "x")) { XCTAssertEqual($0 as? SecretSeal.Failure, .wrongPIN) }
        var newer = v.sealed
        newer.v = 2
        XCTAssertThrowsError(try SecretSeal.open(newer, pin: v.pin, context: v.context)) { XCTAssertEqual($0 as? SecretSeal.Failure, .unsupported) }
        XCTAssertThrowsError(try SecretSeal.seal("x", pin: "12345", context: "c")) { XCTAssertEqual($0 as? SecretSeal.Failure, .shortPIN) }
    }

    func testRandomSaltAndNonceRoundTrip() throws {
        let a = try SecretSeal.seal("sk-ant-x", pin: "123456", context: "c", iterations: 1000)
        let b = try SecretSeal.seal("sk-ant-x", pin: "123456", context: "c", iterations: 1000)
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertEqual(try SecretSeal.open(a, pin: "123456", context: "c"), "sk-ant-x")
    }
}
