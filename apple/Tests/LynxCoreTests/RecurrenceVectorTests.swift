import Foundation
import XCTest
@testable import LynxCore

/// Every case in shared/vectors/recurrence.json (SPEC §5, §11).
final class RecurrenceVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Next: Decodable { let name: String; let time_zone: String; let `repeat`: RepeatRule; let after: String; let expect: [String] }
        struct Effective: Decodable { let name: String; let time_zone: String; let `repeat`: RepeatRule; let due_at: String; let now: String; let expect: String }
        struct Complete: Decodable {
            struct Expect: Decodable { let completed: Bool; let due_at: String; let `repeat`: RepeatRule }
            let name: String; let time_zone: String; let `repeat`: RepeatRule; let due_at: String; let completed_at: String; let expect: Expect
        }
        struct NagCase: Decodable { let name: String; let nag: Nag; let fired_at: String; let expect: [String] }
        let next: [Next]
        let effective_due: [Effective]
        let complete: [Complete]
        let nag: [NagCase]
    }

    static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LynxCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("shared/vectors/recurrence.json")

    func load() throws -> Vectors {
        let data = try Data(contentsOf: Self.vectorsURL)
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func instant(_ s: String) -> Date { LynxTime.parse(s)! }
    func tz(_ s: String) -> TimeZone { TimeZone(identifier: s)! }

    func testVectorFileHasAllSections() throws {
        let v = try load()
        XCTAssertEqual(v.next.count, 14)
        XCTAssertEqual(v.effective_due.count, 4)
        XCTAssertEqual(v.complete.count, 10)
        XCTAssertEqual(v.nag.count, 3)
    }

    func testNext() throws {
        for c in try load().next {
            let got = Recurrence.upcoming(c.repeat, in: tz(c.time_zone), after: instant(c.after), limit: 6).map(LynxTime.format)
            XCTAssertEqual(got, c.expect, "next: \(c.name)")
        }
    }

    func testNextOneByOneMatchesUpcoming() throws {
        // `next` chained from each result must walk the same series (the reference's upcoming() does exactly this).
        for c in try load().next {
            var t = instant(c.after)
            var got: [String] = []
            while got.count < 6, let n = Recurrence.next(c.repeat, in: tz(c.time_zone), after: t) {
                got.append(LynxTime.format(n))
                t = n
            }
            XCTAssertEqual(got, c.expect, "next chain: \(c.name)")
        }
    }

    func testEffectiveDue() throws {
        for c in try load().effective_due {
            let got = Recurrence.effectiveDue(c.repeat, in: tz(c.time_zone), dueAt: instant(c.due_at), now: instant(c.now))
            XCTAssertEqual(LynxTime.format(got), c.expect, "effective_due: \(c.name)")
        }
    }

    func testComplete() throws {
        for c in try load().complete {
            let got = Recurrence.complete(c.repeat, in: tz(c.time_zone), dueAt: instant(c.due_at), completedAt: instant(c.completed_at))
            XCTAssertEqual(got.completed, c.expect.completed, "complete.completed: \(c.name)")
            XCTAssertEqual(LynxTime.format(got.dueAt), c.expect.due_at, "complete.due_at: \(c.name)")
            XCTAssertEqual(got.rule, c.expect.repeat, "complete.repeat: \(c.name)")
        }
    }

    func testNag() throws {
        for c in try load().nag {
            let got = Recurrence.nagTimes(c.nag, firedAt: instant(c.fired_at)).map(LynxTime.format)
            XCTAssertEqual(got, c.expect, "nag: \(c.name)")
        }
    }

    /// The reminder-level completion uses the same rules and keeps a repeating reminder open.
    func testReminderCompletionAdvancesRepeat() {
        var db = LocalDatabase()
        let list = LynxList(ownerId: nil, name: "Home", sortOrder: 1)
        db.upsertList(list)
        var r = Reminder(listId: list.id, createdBy: nil, title: "Water plants", sortOrder: 1, timeZone: "Europe/Bratislava")
        r.dueAt = instant("2026-11-10T08:00:00Z")
        r.repeat = RepeatRule(unit: .day, interval: 1, anchor: "2026-11-10T09:00")
        db.upsertReminder(r)
        let outcome = db.complete(r.id, by: nil, now: instant("2026-11-10T08:05:00Z"))
        XCTAssertEqual(outcome, .advanced(instant("2026-11-11T08:00:00Z")))
        XCTAssertNil(db.reminders[r.id]?.completedAt)
        XCTAssertEqual(db.reminders[r.id]?.repeat?.completedCount, 1)
    }

    func testWallTimeGapAndOverlap() {
        let bratislava = tz("Europe/Bratislava")
        // 2026-03-29 02:30 does not exist (clocks jump 02:00 → 03:00): resolves forward to 03:30 CEST = 01:30Z.
        XCTAssertEqual(LynxTime.format(WallTime("2026-03-29T02:30")!.instant(in: bratislava)), "2026-03-29T01:30:00Z")
        // 2026-10-25 02:30 happens twice: the earlier one (CEST, +2) = 00:30Z.
        XCTAssertEqual(LynxTime.format(WallTime("2026-10-25T02:30")!.instant(in: bratislava)), "2026-10-25T00:30:00Z")
    }

    func testOldSeriesIsFast() {
        // A 1-minute series anchored years ago must not walk every minute from the anchor.
        let rule = RepeatRule(unit: .minute, interval: 1, anchor: "2020-01-01T00:00")
        let t0 = Date()
        let n = Recurrence.next(rule, in: tz("Europe/Bratislava"), after: instant("2026-11-14T08:00:30Z"))
        XCTAssertEqual(n.map(LynxTime.format), "2026-11-14T08:01:00Z")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }
}
