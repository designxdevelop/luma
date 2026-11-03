import XCTest
@testable import LumaCore

final class WatchStateTests: XCTestCase {
    private func light(_ id: String, room: String = "Office", on: Bool = false, online: Bool = true) -> WatchSnapshot.Light {
        .init(id: id, name: id, room: room, power: on, brightness: 50, rgb: nil, online: online, canDim: true)
    }
    private func home(_ lights: [WatchSnapshot.Light]) -> WatchSnapshot { WatchSnapshot(lights: lights) }

    func testRoomsSortedWithOtherLast() {
        let rooms = WatchState.rooms([light("a", room: "living room"), light("b", room: " "), light("c", room: "Bedroom"), light("d", room: "living room")])
        XCTAssertEqual(rooms.map(\.name), ["Bedroom", "living room", "Other"])
        XCTAssertEqual(rooms[1].lights.map(\.id), ["a", "d"])
        XCTAssertEqual(WatchState.rooms([light("x", room: "Other"), light("y", room: "")]).map(\.lights.count), [2])
    }

    func testPendingOverlaysReportWithoutChangingIt() {
        var s = WatchState(report: home([light("a")]), reachable: true)
        _ = s.begin(.power(ids: ["a"], on: true))
        XCTAssertEqual(s.display?.lights[0].power, true)
        XCTAssertEqual(s.report?.lights[0].power, false, "report stays the phone's word")
        XCTAssertTrue(s.isPending(light: "a"))
    }

    func testFailureDropsOnlyItsOverlayAndKeepsNewerAction() {
        var s = WatchState(report: home([light("a")]))
        let first = s.begin(.brightness(id: "a", value: 20))
        _ = s.begin(.brightness(id: "a", value: 80))
        s.fail(first, message: "timeout")
        XCTAssertEqual(s.display?.lights[0].brightness, 80)
        XCTAssertNil(s.failure, "superseded failure is silent")
    }

    func testFailureRevertsAndRecordsTryAgain() {
        var s = WatchState(report: home([light("a")]))
        let n = s.begin(.power(ids: ["a"], on: true))
        s.fail(n, message: "timeout")
        XCTAssertEqual(s.display?.lights[0].power, false)
        XCTAssertEqual(s.failure?.request, .power(ids: ["a"], on: true))
        _ = s.begin(.power(ids: ["a"], on: true))
        XCTAssertNil(s.failure, "retrying the same light clears it")
    }

    func testLateOlderReplyDoesNotReplaceNewerReport() {
        var s = WatchState(report: home([light("a")]))
        let old = s.begin(.power(ids: ["a"], on: true))
        let new = s.begin(.power(ids: ["a"], on: false))
        s.succeed(new, reply: home([light("a", on: false)]))
        s.succeed(old, reply: home([light("a", on: true)]))
        XCTAssertEqual(s.report?.lights[0].power, false)
        XCTAssertTrue(s.pending.isEmpty)
    }

    func testEmptyReplyIsAFailure() {
        var s = WatchState(report: home([light("a")]))
        let n = s.begin(.runScene(UUID()))
        s.succeed(n, reply: nil)
        XCTAssertNotNil(s.failure)
        XCTAssertNil(s.display?.runningSceneID)
    }

    func testContextNewerThanRequestKeepsPendingOverlay() {
        var s = WatchState(report: home([light("a"), light("b")]))
        _ = s.begin(.power(ids: [], on: false))
        s.receive(home([light("a", on: true), light("b", on: true), light("c", on: true)]))
        XCTAssertEqual(s.display?.lights.map(\.power), [false, false, false])
        XCTAssertTrue(s.isPending(light: "c"), "All off covers lights the phone added since")
    }

    func testOfflineLightsAreNotDrawnAsChanged() {
        var s = WatchState(report: home([light("a", online: false)]))
        _ = s.begin(.power(ids: [], on: true))
        XCTAssertEqual(s.display?.lights[0].power, false)
    }

    func testRefreshOnEveryReconnect() {
        var s = WatchState(report: home([light("a")]))
        XCTAssertTrue(s.setReachable(true))
        XCTAssertFalse(s.setReachable(true))
        XCTAssertFalse(s.setReachable(false))
        XCTAssertTrue(s.setReachable(true), "not only when the home is missing")
    }

    func testRefreshFailureIsNotShownAsDidntChange() {
        var s = WatchState()
        s.fail(s.begin(.refresh), message: "x")
        XCTAssertNil(s.failure)
    }

    func testBrightnessClamp() {
        XCTAssertEqual(WatchState.clampBrightness(-4), 1)
        XCTAssertEqual(WatchState.clampBrightness(54.6), 55)
        XCTAssertEqual(WatchState.clampBrightness(140), 100)
    }
}
