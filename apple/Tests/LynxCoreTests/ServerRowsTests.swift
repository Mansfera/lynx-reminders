import XCTest
@testable import LynxCore

/// shared/vectors/server-rows.json: real rows written by both clients (SPEC §11).
/// Android writes absent optionals as explicit nulls, macOS omits them; both must decode either way.
final class ServerRowsTests: XCTestCase {
    static let url = RecurrenceVectorTests.vectorsURL
        .deletingLastPathComponent()
        .appendingPathComponent("server-rows.json")

    private func raw() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Self.url)) as! [String: Any]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        let rows = try raw()[key]!
        let data = try JSONSerialization.data(withJSONObject: rows)
        return try LynxJSON.decoder().decode(T.self, from: data)
    }

    func testListsFromBothClientsDecode() throws {
        let lists = try decode([LynxList].self, "lists")
        let raw = try raw()["lists"] as! [[String: Any]]
        XCTAssertEqual(lists.count, raw.count)
        XCTAssertTrue(raw.contains { $0["_written_by"] as? String == "android" })
        XCTAssertTrue(raw.contains { $0["_written_by"] as? String == "apple" })
    }

    func testRemindersFromBothClientsDecodeWithEveryTrigger() throws {
        let reminders = try decode([Reminder].self, "reminders")
        let raw = try raw()["reminders"] as! [[String: Any]]
        XCTAssertEqual(reminders.count, raw.count)
        for (r, j) in zip(reminders, raw) {
            let who = j["_written_by"] as! String
            func present(_ k: String) -> Bool { !(j[k] is NSNull) && j[k] != nil }
            XCTAssertEqual(r.id.uuidString.lowercased(), j["id"] as? String, who)
            XCTAssertEqual(r.repeat != nil, present("repeat"), "repeat from \(who)")
            XCTAssertEqual(r.nag != nil, present("nag"), "nag from \(who)")
            XCTAssertEqual(r.location != nil, present("location"), "location from \(who)")
            XCTAssertEqual(r.bluetooth != nil, present("bluetooth"), "bluetooth from \(who)")
            XCTAssertEqual(r.appTrigger != nil, present("app_trigger"), "app_trigger from \(who)")
            XCTAssertEqual(r.parentId != nil, present("parent_id"), "parent_id from \(who)")
            XCTAssertEqual(r.completedAt != nil, present("completed_at"), "completed_at from \(who)")
            XCTAssertEqual(r.deletedAt != nil, present("deleted_at"), "deleted_at from \(who)")
            XCTAssertEqual(r.allDay, j["all_day"] as? Bool, who)
        }
    }

    /// Server timestamps carry microseconds and the client writes milliseconds (LynxTime), so the first
    /// encode may truncate; after that, encoding must be stable.
    func testRoundTripIsStable() throws {
        let reminders = try decode([Reminder].self, "reminders")
        let once = try LynxJSON.encoder().encode(reminders)
        let twice = try LynxJSON.encoder().encode(LynxJSON.decoder().decode([Reminder].self, from: once))
        XCTAssertEqual(String(decoding: once, as: UTF8.self), String(decoding: twice, as: UTF8.self))
    }
}
