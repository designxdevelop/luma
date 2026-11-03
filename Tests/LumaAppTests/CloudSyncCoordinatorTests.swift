import Foundation
import Testing
import LumaCore
@testable import LumaUI

@MainActor private final class FakeCloud: CloudSyncExchanging {
    var account = "one"
    var ledger = SyncLedger(account: "one", writer: "server")
    var fail = false
    var uploads: [SyncMutation] = []
    func accountID() async throws -> String { account }
    func exchange(_ pending: [SyncMutation]) async throws -> [SyncMutation] {
        if fail { throw CocoaError(.fileReadUnknown) }
        uploads += pending
        ledger.merge(pending, account: "one")
        return Array(ledger.records.values)
    }
}

@MainActor struct CloudSyncCoordinatorTests {
    @Test func offlineDeletionSurvivesRestartAndAccountChangeNeverUploads() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = FakeCloud()
        var values = ["scene:one/value": Data([1])]
        let make = {
            CloudSyncCoordinator(folder: folder, transport: cloud, snapshot: { values }, apply: { records in
                for (key, mutation) in records { values[key] = mutation.value }
            }, status: { _ in })
        }
        let first = make()
        await first.exchange()
        #expect(cloud.ledger.records["scene:one/value"]?.value == Data([1]))
        cloud.fail = true
        values.removeAll(); first.changed()
        await first.exchange()
        let restarted = make()
        cloud.fail = false
        await restarted.exchange()
        #expect(cloud.ledger.records["scene:one/value"] != nil)
        #expect(cloud.ledger.records["scene:one/value"]?.value == nil)
        let count = cloud.uploads.count
        cloud.account = "two"
        values["scene:private/value"] = Data([2]); restarted.changed()
        await restarted.exchange()
        #expect(cloud.uploads.count == count)
    }
    @Test func newDeviceHonorsRemoteTombstoneAndKeepsIndependentLocalEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = FakeCloud()
        cloud.ledger.edit(entity: "scene:deleted", field: "value", value: nil)
        cloud.ledger.edit(entity: "device:lamp", field: "name", value: Data([5]))
        var values = ["scene:deleted/value": Data([1]), "device:lamp/room": Data([4])]
        let coordinator = CloudSyncCoordinator(folder: folder, transport: cloud, snapshot: { values }, apply: { records in
            for (key, mutation) in records { values[key] = mutation.value }
        }, status: { _ in })
        await coordinator.exchange()
        #expect(values["scene:deleted/value"] == nil)
        #expect(values["device:lamp/name"] == Data([5]))
        #expect(cloud.ledger.records["device:lamp/room"]?.value == Data([4]))
    }
}
