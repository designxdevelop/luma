import Foundation
import Testing
import LumaCore
@testable import LumaUI

@MainActor struct WatchRelayTests {
    @Test func requestsAndSnapshotsRoundTripThroughMessages() throws {
        let request = WatchRequest.brightness(id: "demo-desk", value: 40)
        #expect(WatchRequest.decode(try request.encoded()) == request)
        let store = HomeStore(demo: true); defer { store.shutdown() }
        #expect(WatchSnapshot.decode(try store.watchSnapshot.encoded()) == store.watchSnapshot)
        #expect(WatchRequest.decode(["request": Data("nope".utf8)]) == nil)
    }

    @Test func watchRequestsDriveTheStoreAndIgnoreUnknownTargets() async throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        store.handleWatch(.power(ids: [], on: false))
        for _ in 0..<100 where store.poweredCount > 0 { await Task.yield() }
        #expect(store.poweredCount == 0)
        store.handleWatch(.brightness(id: "demo-desk", value: 500))
        for _ in 0..<100 where store.devices.first(where: { $0.id == "demo-desk" })?.brightness != 100 { await Task.yield() }
        #expect(store.devices.first { $0.id == "demo-desk" }?.brightness == 100)
        let before = store.devices
        store.handleWatch(.brightness(id: "not-a-light", value: 10))
        store.handleWatch(.runScene(UUID()))
        #expect(store.devices == before)
        #expect(store.runningSceneID == nil)
    }
}
