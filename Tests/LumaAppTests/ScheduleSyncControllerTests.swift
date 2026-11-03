import Foundation
import Testing
import LumaCore
@testable import LumaUI

/// Native schedule sync end to end with a fake clock, temp folders, in-memory secrets and an
/// in-process network routing requests to the runner's real request handler.
@MainActor struct ScheduleSyncControllerTests {
    @MainActor final class Memory {
        var values: [String: String] = [:]
        var secrets: ScheduleSyncController.Secrets {
            .init(read: { self.values[$0] }, save: { self.values[$0] = $1 }, delete: { self.values[$0] = nil })
        }
    }
    final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }
    /// Routes `host` to a runner. `down` hosts are unreachable.
    @MainActor final class Network {
        var hosts: [String: ScheduleSyncController] = [:]
        var tokens: [String: String] = [:]
        var down: Set<String> = []
        nonisolated var transport: ScheduleSyncController.Transport {
            { [self] target, path, body in
                try await MainActor.run {
                    guard let host = self.hosts[target.host], !self.down.contains(target.host) else { throw ScheduleSync.SyncError.http(503, "Can't reach the runner.") }
                    guard self.tokens[target.host] == target.token else { return (401, Data(#"{"error":"Bearer authentication required"}"#.utf8)) }
                    let r = host.handle(.init(method: "POST", path: path, body: body))
                    return (r.status, r.body)
                }
            }
        }
    }
    /// A device: a controller over an in-memory home.
    @MainActor final class Device {
        var scenes: [LightScene] = []
        var schedules: [SceneSchedule] = []
        var runs: [UUID] = []
        let sync: ScheduleSyncController
        let folder: URL
        let memory: Memory
        init(_ host: String, network: Network, clock: Clock, folder: URL? = nil, memory: Memory = Memory(), calendar: Calendar) {
            self.folder = folder ?? FileManager.default.temporaryDirectory.appending(path: "luma-ss-\(UUID().uuidString)")
            self.memory = memory
            sync = ScheduleSyncController(folder: self.folder, secrets: memory.secrets, transport: network.transport, now: { clock.now }, calendar: calendar, serves: false)
            sync.scenes = { [unowned self] in self.scenes }
            sync.schedules = { [unowned self] in self.schedules }
            sync.apply = { [unowned self] in self.scenes = $0; self.schedules = $1; self.sync.reconcile() }
            sync.run = { [unowned self] id in self.runs.append(id); return UUID() }
            network.hosts[host] = sync
        }
        func becomeRunner(_ host: String, network: Network) throws {
            try sync.becomeRunner()
            network.tokens[host] = memory.values[ScheduleSyncController.tokenKey]
        }
        func code(_ host: String) -> String { ScheduleSync.PairingCode(host: host, port: 8788, pin: String(repeating: "A", count: 26), token: memory.values[ScheduleSyncController.tokenKey]!).text }
    }

    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
    static let scene = LightScene(id: UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!, name: "Evening", symbol: "moon.stars",
                                  steps: [SceneStep(id: UUID(uuidString: "C3C3C3C3-0000-4000-8000-000000000003")!, deviceID: "AA:BB", command: .power(true))])
    static let schedule = SceneSchedule(id: UUID(uuidString: "B2B2B2B2-0000-4000-8000-000000000002")!, sceneID: scene.id, hour: 7, minute: 0)

    @Test func phonePauseSurvivesRunnerRestartAndBlocksTheRun() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 3, 2, 6, 0))
        let mac = Device("mac", network: network, clock: clock, calendar: Self.calendar)
        defer { try? FileManager.default.removeItem(at: mac.folder) }
        mac.scenes = [Self.scene]; mac.schedules = [Self.schedule]
        try mac.becomeRunner("mac", network: network)
        let phone = Device("phone", network: network, clock: clock, calendar: Self.calendar)
        defer { try? FileManager.default.removeItem(at: phone.folder) }
        try await phone.sync.pair(mac.code("mac"))
        #expect(phone.schedules.count == 1)
        #expect(phone.sync.mayExecute == false)
        // The phone pauses until tomorrow noon. Its edit goes through reconcile, as in the app.
        phone.schedules[0].pausedUntil = Self.at(2026, 3, 3, 12, 0)
        phone.sync.reconcile()
        await phone.sync.syncNow()
        #expect(phone.sync.unsent == 0)

        // Restart the Mac: a new controller reads only what was saved before the phone got its answer.
        let restarted = Device("mac", network: network, clock: clock, folder: mac.folder, memory: mac.memory, calendar: Self.calendar)
        restarted.sync.start()
        #expect(restarted.schedules.first?.pausedUntil == Self.at(2026, 3, 3, 12, 0))
        _ = restarted.sync.tick(Self.at(2026, 3, 2, 7, 0, 20))
        _ = restarted.sync.tick(Self.at(2026, 3, 3, 6, 59, 50)); _ = restarted.sync.tick(Self.at(2026, 3, 3, 7, 0, 20))
        #expect(restarted.runs.isEmpty)
        #expect(restarted.sync.runReports[Self.schedule.id.uuidString]?.status == "paused")
        _ = restarted.sync.tick(Self.at(2026, 3, 4, 6, 59, 50)); _ = restarted.sync.tick(Self.at(2026, 3, 4, 7, 0, 10))
        #expect(restarted.runs == [Self.scene.id])
    }

    @Test func twoMacsRunASharedScheduleOnceAndHandOff() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 6, 1, 6, 0))
        let a = Device("a", network: network, clock: clock, calendar: Self.calendar), b = Device("b", network: network, clock: clock, calendar: Self.calendar)
        defer { for d in [a, b] { try? FileManager.default.removeItem(at: d.folder) } }
        a.scenes = [Self.scene]; a.schedules = [Self.schedule]
        try a.becomeRunner("a", network: network)
        try await b.sync.pair(a.code("a"))
        for d in [Self.at(2026, 6, 1, 6, 59, 50), Self.at(2026, 6, 1, 7, 0, 5), Self.at(2026, 6, 1, 7, 0, 40)] { _ = a.sync.tick(d); _ = b.sync.tick(d) }
        #expect(a.runs.count == 1); #expect(b.runs.isEmpty)
        clock.now = Self.at(2026, 6, 1, 12, 0)
        try await b.sync.takeOver(force: false)
        #expect(a.sync.mayExecute == false); #expect(b.sync.mayExecute == true)
        for d in [Self.at(2026, 6, 2, 6, 59, 50), Self.at(2026, 6, 2, 7, 0, 5)] { _ = a.sync.tick(d); _ = b.sync.tick(d) }
        #expect(a.runs.count == 1); #expect(b.runs.count == 1)
        a.sync.turnOff()
        #expect(a.schedules.allSatisfy { !$0.enabled }, "a handed-off Mac must not resume running them locally")
    }

    @Test func pairedDeviceQueuesOfflineEditsAndNeverRuns() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 6, 1, 6, 0))
        let mac = Device("mac", network: network, clock: clock, calendar: Self.calendar), phone = Device("phone", network: network, clock: clock, calendar: Self.calendar)
        defer { for d in [mac, phone] { try? FileManager.default.removeItem(at: d.folder) } }
        mac.scenes = [Self.scene]; mac.schedules = [Self.schedule]
        try mac.becomeRunner("mac", network: network)
        try await phone.sync.pair(mac.code("mac"))
        network.down.insert("mac")
        phone.schedules[0].hour = 8
        phone.sync.reconcile()
        await phone.sync.syncNow()
        #expect(phone.sync.unsent == 1)
        #expect(phone.sync.client?.lastError?.contains("reach") == true)
        _ = phone.sync.tick(Self.at(2026, 6, 1, 7, 59, 50)); _ = phone.sync.tick(Self.at(2026, 6, 1, 8, 0, 10))
        #expect(phone.runs.isEmpty)
        network.down.remove("mac")
        await phone.sync.syncNow()
        #expect(phone.sync.unsent == 0)
        #expect(mac.schedules.first?.hour == 8)
    }

    @Test func electronScenesAreNotRewrittenByNativeDevices() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 6, 1, 6, 0))
        let mac = Device("mac", network: network, clock: clock, calendar: Self.calendar), phone = Device("phone", network: network, clock: clock, calendar: Self.calendar)
        defer { for d in [mac, phone] { try? FileManager.default.removeItem(at: d.folder) } }
        try mac.becomeRunner("mac", network: network)
        // A Windows/Linux device adds a scene with its own icon field.
        let sceneID = "D7D7D7D7-0000-4000-8000-000000000007"
        let body = #"{"protocol":1,"client":{"id":"E8E8E8E8-0000-4000-8000-000000000008","name":"PC","platform":"windows"},"since":0,"ops":[{"opID":"F9F9F9F9-0000-4000-8000-000000000009","type":"put","kind":"scene","id":"\#(sceneID)","baseRev":0,"value":{"id":"\#(sceneID)","name":"Party","symbol":"party.popper","icon":"party","steps":[{"id":"C3C3C3C3-0000-4000-8000-00000000000A","deviceID":"AA:BB","command":{"type":"devices.capabilities.on_off","instance":"powerSwitch","value":1},"delayMilliseconds":0}]}}]}"#
        let response = mac.sync.handle(.init(method: "POST", path: ScheduleSync.syncPath, body: Data(body.utf8)))
        #expect(response.status == 200)
        let rev = try #require(mac.sync.runnerDoc?.records["scene:\(sceneID)"]?.rev)
        mac.sync.reconcile()
        #expect(mac.sync.runnerDoc?.records["scene:\(sceneID)"]?.rev == rev, "the Mac runner must not rewrite it")
        if case .scene(let value)? = mac.sync.runnerDoc?.records["scene:\(sceneID)"]?.value { #expect(value.icon == "party") } else { Issue.record("scene missing") }
        try await phone.sync.pair(mac.code("mac"))
        phone.sync.reconcile()
        #expect(phone.sync.unsent == 0, "the phone must not stage an edit it didn't make")
    }

    @Test func runnerTurnedOffAndOnCanBePairedAgain() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 6, 1, 6, 0))
        let mac = Device("mac", network: network, clock: clock, calendar: Self.calendar), phone = Device("phone", network: network, clock: clock, calendar: Self.calendar)
        defer { for d in [mac, phone] { try? FileManager.default.removeItem(at: d.folder) } }
        mac.scenes = [Self.scene]; mac.schedules = [Self.schedule]
        try mac.becomeRunner("mac", network: network)
        try await phone.sync.pair(mac.code("mac"))
        mac.sync.turnOff()
        try mac.becomeRunner("mac", network: network)
        try await phone.sync.pair(mac.code("mac"))
        #expect(phone.sync.client?.lastError == nil)
        #expect(phone.schedules.count == 1)
    }

    @Test func wrongTokenIsRefused() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 6, 1, 6, 0))
        let mac = Device("mac", network: network, clock: clock, calendar: Self.calendar), phone = Device("phone", network: network, clock: clock, calendar: Self.calendar)
        defer { for d in [mac, phone] { try? FileManager.default.removeItem(at: d.folder) } }
        try mac.becomeRunner("mac", network: network)
        let bad = ScheduleSync.PairingCode(host: "mac", port: 8788, pin: String(repeating: "A", count: 26), token: String(repeating: "B", count: 26)).text
        await #expect(throws: ScheduleSync.SyncError.self) { try await phone.sync.pair(bad) }
        #expect(phone.sync.role == .off)
    }

    @Test func homeStoreDefersToSyncAndRefusesRestoreWhilePaired() async throws {
        let network = Network(), clock = Clock(Self.at(2026, 6, 1, 6, 0))
        let mac = Device("mac", network: network, clock: clock, calendar: Self.calendar)
        defer { try? FileManager.default.removeItem(at: mac.folder) }
        mac.scenes = [Self.scene]; mac.schedules = [Self.schedule]
        try mac.becomeRunner("mac", network: network)
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "luma-ss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let paired = ScheduleSyncController(folder: folder, secrets: Memory().secrets, transport: network.transport, now: { clock.now }, calendar: Self.calendar, serves: false)
        store.attachScheduleSync(paired)
        try await paired.pair(mac.code("mac"))
        #expect(store.home.schedules.map(\.id) == [Self.schedule.id])
        let before = store.runs.count
        store.tickSchedules(now: Self.at(2026, 6, 1, 7, 0, 10))
        #expect(store.runs.count == before, "a paired device never runs shared schedules")
        #expect(throws: (any Error).self) { try paired.assertMayReplaceAll() }
    }
}
