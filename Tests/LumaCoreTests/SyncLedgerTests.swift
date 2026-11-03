import XCTest
@testable import LumaCore

final class SyncLedgerTests: XCTestCase {
    func testIndependentFieldsAndDeletionConverge() throws {
        var a = SyncLedger(account: "one", writer: "a")
        var b = SyncLedger(account: "one", writer: "b")
        a.edit(entity: "light", field: "name", value: Data("Desk".utf8))
        b.edit(entity: "light", field: "room", value: Data("Office".utf8))
        a.merge(Array(b.records.values), account: "one")
        b.merge(Array(a.records.values), account: "one")
        XCTAssertEqual(a.records, b.records)
        a.edit(entity: "light", field: "name", value: nil)
        b.merge(Array(a.records.values), account: "one")
        XCTAssertNil(b.records["light/name"]?.value)
        let restored = try JSONDecoder().decode(SyncLedger.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(restored.outbox, a.outbox)
    }
    func testWrongAccountAndStaleAcknowledgement() {
        var ledger = SyncLedger(account: "one")
        ledger.edit(entity: "scene", field: "name", value: Data([1]))
        let sent = ledger.outbox.values.first!
        ledger.edit(entity: "scene", field: "name", value: nil)
        ledger.acknowledge(sent)
        XCTAssertEqual(ledger.outbox.count, 1)
        ledger.merge([SyncMutation(entity: "other", field: "name", value: Data(), counter: 999, writer: "x")], account: "two")
        XCTAssertNil(ledger.records["other/name"])
    }
}
