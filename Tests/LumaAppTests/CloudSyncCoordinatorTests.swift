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
    /// LAN status packets save home.json once per burst and never build a sync snapshot; a new light
    /// (its room is synced) and configuration edits still take the full path.
    @Test func telemetryBurstSavesOnceWithoutSyncAndConfigurationEditsStillSync() async throws {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HomeStore(demo: true, folder: folder); defer { store.shutdown() }
        store.leaveDemo()
        var captures = 0
        let coordinator = CloudSyncCoordinator(folder: folder, transport: FakeCloud(), snapshot: { captures += 1; return try store.syncSnapshot() }, apply: { _ in }, status: { _ in })
        store.configurationSync = coordinator
        await coordinator.exchange()
        let file = folder.appending(path: "home.json")
        func inode() throws -> Int { try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! Int }
        func savedBrightness() throws -> Int? { try HomeStorage(folder: folder).load().devices.first?.brightness }
        func packet(_ brightness: Int) -> LightDevice { LightDevice(id: "lamp", sku: "H1", name: "Lamp", ip: "192.0.2.5", power: true, brightness: brightness, online: true) }

        var before = captures
        store.lanStatus(packet(1))
        #expect(captures == before + 1, "a newly found light changes the synced snapshot")
        let first = try inode()

        before = captures
        for b in 2...50 { store.lanStatus(packet(b)) }
        #expect(try inode() == first && savedBrightness() == 1, "nothing written during the burst")
        store.flushTelemetry()
        let second = try inode()
        #expect(try second != first && savedBrightness() == 50, "one write with the latest state")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try inode() == second, "the cancelled debounce never writes again")

        store.lanStatus(packet(7))
        for _ in 0..<60 where try savedBrightness() != 7 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try savedBrightness() == 7, "the debounced save fires on its own")
        #expect(captures == before, "telemetry never builds a sync snapshot")

        store.rename("Desk", id: "lamp")
        #expect(captures == before + 1)
        #expect(try HomeStorage(folder: folder).load().devices.first?.customName == "Desk")
    }
    /// HomeStore's snapshot throws while home.json, floor plans or a schedule sidecar is unreadable.
    @Test func throwingSnapshotPausesSyncWithoutUploadingTombstones() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = FakeCloud()
        var values = ["scene:one/value": Data([1]), "schedule:one/owner": Data([2])]
        var unreadable = false
        let coordinator = CloudSyncCoordinator(folder: folder, transport: cloud, snapshot: {
            if unreadable { throw CocoaError(.fileReadCorruptFile) }
            return values
        }, apply: { _ in }, status: { _ in })
        await coordinator.exchange()
        let count = cloud.uploads.count
        unreadable = true; values.removeAll()
        coordinator.changed()
        await coordinator.exchange()
        #expect(cloud.uploads.count == count)
        #expect(cloud.ledger.records["scene:one/value"]?.value == Data([1]))
        #expect(cloud.ledger.records["schedule:one/owner"]?.value == Data([2]))
    }
    /// HomeStore.applySync skips records it can't decode and keeps the local value; that must not
    /// become an upload (tombstone or stale value) on later exchanges.
    @Test func skippedUndecodableRecordIsNeverUploaded() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = FakeCloud()
        var values = ["scene:a/value": Data([1])]
        let skipped: Set<String> = ["scene:a/value", "scene:b/value"]
        let coordinator = CloudSyncCoordinator(folder: folder, transport: cloud, snapshot: { values }, apply: { records in
            for (key, mutation) in records where !skipped.contains(key) { values[key] = mutation.value }
        }, status: { _ in })
        await coordinator.exchange()
        // A newer client changes one scene and adds another that this build can't read.
        cloud.ledger.edit(entity: "scene:a", field: "value", value: Data([2]))
        cloud.ledger.edit(entity: "scene:b", field: "value", value: Data([3]))
        let count = cloud.uploads.count
        await coordinator.exchange()
        values["scene:c/value"] = Data([4]); coordinator.changed()
        await coordinator.exchange()
        let later = cloud.uploads.dropFirst(count)
        #expect(!later.contains { $0.entity == "scene:a" || $0.entity == "scene:b" })
        #expect(later.contains { $0.entity == "scene:c" })
        #expect(cloud.ledger.records["scene:a/value"]?.value == Data([2]))
        #expect(cloud.ledger.records["scene:b/value"]?.value == Data([3]))
        #expect(values["scene:a/value"] == Data([1]) && values["scene:b/value"] == nil)
    }
}
