import Foundation
import Testing
import LumaCore
@testable import LumaUI

@MainActor private final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

@MainActor private final class LeaseServer {
    var leases: [String: OccurrenceLease] = [:]
    var writes = 0
    /// Reads suspend until this many are waiting, forcing a read/read/write/write interleaving.
    var barrier = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func gate() async {
        guard barrier > 1 else { return }
        await withCheckedContinuation { waiting.append($0); if waiting.count >= barrier { barrier = 0; waiting.forEach { $0.resume() }; waiting = [] } }
    }
}

@MainActor private final class LeaseClient: ScheduleLeaseStore {
    let server: LeaseServer
    var partitioned = false
    var account = "acct"
    init(_ server: LeaseServer) { self.server = server }
    func accountID() async throws -> String { if partitioned { throw URLError(.notConnectedToInternet) }; return account }
    func read(_ id: String) async throws -> OccurrenceLease? {
        if partitioned { throw URLError(.notConnectedToInternet) }
        let value = server.leases[id]
        await server.gate()
        return value
    }
    func write(_ id: String, _ lease: OccurrenceLease, expecting previous: OccurrenceLease?) async throws {
        if partitioned { throw URLError(.notConnectedToInternet) }
        guard server.leases[id] == previous else { throw LeaseConflict() }
        // CloudKit keeps dates at millisecond precision.
        var stored = lease; stored.expiresAt = Date(timeIntervalSince1970: (lease.expiresAt.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        server.leases[id] = stored; server.writes += 1
    }
}

@MainActor private final class Host: ScheduleHost {
    var schedule: SceneSchedule
    var coordination: ScheduleCoordination
    var scene: LightScene
    var deleted = false
    var sent: [SceneStep] = []
    var failure: (any Error)?
    var afterSend: () -> Void = {}
    var ended: [String] = []
    init(_ schedule: SceneSchedule, _ coordination: ScheduleCoordination, _ scene: LightScene) {
        self.schedule = schedule; self.coordination = coordination; self.scene = scene
    }
    func coordinatedSchedule(_ id: UUID) -> (SceneSchedule, ScheduleCoordination, LightScene)? { deleted ? nil : (schedule, coordination, scene) }
    func beginScheduledRun(_ scene: LightScene) -> UUID? { UUID() }
    func endScheduledRun(_ runID: UUID, status: String, error: String?) { ended.append(status) }
    func sendScheduled(_ step: SceneStep) async throws {
        if let failure { sent.append(step); throw failure }
        sent.append(step); afterSend()
    }
}

@MainActor struct ScheduleFailoverTests {
    let zone = TimeZone(identifier: "UTC")!
    // 2026-10-30 is a Friday; the schedule fires 08:00 UTC every day.
    let fire = Date(timeIntervalSince1970: 1_793_347_200)
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func fixture(steps: Int = 2, delay: Int = 0) -> (SceneSchedule, ScheduleCoordination, LightScene) {
        let scene = LightScene(name: "Morning", steps: (0..<steps).map { _ in SceneStep(deviceID: "a", command: .brightness(40), delayMilliseconds: delay) })
        let schedule = SceneSchedule(sceneID: scene.id, hour: 8, minute: 0)
        return (schedule, ScheduleCoordination(primary: "mac", fallback: "phone", timeZone: "UTC"), scene)
    }
    private func device(_ id: String, _ server: LeaseServer, _ clock: Clock, _ host: Host, file: String? = nil) -> (ScheduleCoordinator, LeaseClient) {
        let client = LeaseClient(server)
        let coordinator = ScheduleCoordinator(device: id, store: client, host: host, file: folder.appending(path: file ?? id + ".json"),
                                              now: { clock.now }, sleep: { clock.now += Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 })
        coordinator.expectedAccount = { "acct" }
        return (coordinator, client)
    }
    private var occurrence: (SceneSchedule) -> String { { ScheduleFailover.occurrenceID($0.id, fire: fire) } }

    @Test func fireTimesUseTheSyncedZoneAcrossDST() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let schedule = SceneSchedule(sceneID: UUID(), hour: 2, minute: 30)
        // 2026-03-08: 02:30 does not exist; it runs at 03:00 EDT (07:00Z).
        let spring = ScheduleFailover.fireInstant(schedule, zone: newYork, atOrBefore: Date(timeIntervalSince1970: 1_772_953_500)) // 07:05Z
        #expect(spring == Date(timeIntervalSince1970: 1_772_953_200))
        // 2026-11-01: 01:30 repeats; only the first (05:30Z) counts, even after the second.
        let early = SceneSchedule(sceneID: UUID(), hour: 1, minute: 30)
        let fall = ScheduleFailover.fireInstant(early, zone: newYork, atOrBefore: Date(timeIntervalSince1970: 1_793_517_300)) // 06:35Z
        #expect(fall == Date(timeIntervalSince1970: 1_793_511_000))
        // Weekday filtering uses the zone's local day.
        var weekdays = early; weekdays.weekdays = [2]
        #expect(ScheduleFailover.fireInstant(weekdays, zone: newYork, atOrBefore: Date(timeIntervalSince1970: 1_793_517_300)) == nil)
    }

    @Test func concurrentDevicesRunAnOccurrenceOnce() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(); server.barrier = 2
        let clock = Clock(fire + 100.4567) // past the fallback's takeover delay
        let hostA = Host(s, c, scene), hostB = Host(s, c, scene)
        let (mac, _) = device("mac", server, clock, hostA), (phone, _) = device("phone", server, clock, hostB)
        async let one: Void = mac.tick([(s, c)])
        async let two: Void = phone.tick([(s, c)])
        _ = await (one, two)
        #expect(hostA.sent.count + hostB.sent.count == 2)
        #expect(hostA.sent.isEmpty != hostB.sent.isEmpty)
        #expect(server.leases[occurrence(s)]?.state == .completed)
    }

    @Test func fallbackWaitsAndHealthyPrimaryKeepsItsLease() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 30)
        let host = Host(s, c, scene)
        let (phone, _) = device("phone", server, clock, host)
        await phone.tick([(s, c)])
        #expect(server.leases.isEmpty) // inside the takeover delay
        server.leases[occurrence(s)] = OccurrenceLease(holder: "mac", nonce: "n", state: .running, expiresAt: fire + 200)
        clock.now = fire + 120
        await phone.tick([(s, c)])
        #expect(host.sent.isEmpty)
        #expect(server.leases[occurrence(s)]?.holder == "mac")
    }

    @Test func expiredClaimFailsOverButExpiredRunIsNeverResumed() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 200)
        let host = Host(s, c, scene)
        server.leases[occurrence(s)] = OccurrenceLease(holder: "mac", nonce: "n", state: .claimed, expiresAt: fire + 60)
        let (phone, _) = device("phone", server, clock, host)
        await phone.tick([(s, c)])
        #expect(host.sent.count == 2)
        #expect(server.leases[occurrence(s)]?.holder == "phone")

        let (s2, c2, scene2) = fixture()
        let host2 = Host(s2, c2, scene2)
        let id2 = ScheduleFailover.occurrenceID(s2.id, fire: fire)
        server.leases[id2] = OccurrenceLease(holder: "mac", nonce: "n", state: .running, expiresAt: fire + 60, step: 1)
        let (phone2, _) = device("phone", server, clock, host2, file: "phone2.json")
        await phone2.tick([(s2, c2)])
        #expect(host2.sent.isEmpty)
        #expect(server.leases[id2]?.state == .uncertain)
    }

    @Test func partitionedPrimaryCannotExecuteAndFallbackRuns() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 5)
        let macHost = Host(s, c, scene), phoneHost = Host(s, c, scene)
        let (mac, macClient) = device("mac", server, clock, macHost)
        macClient.partitioned = true
        await mac.tick([(s, c)])
        #expect(macHost.sent.isEmpty)
        clock.now = fire + 120
        let (phone, _) = device("phone", server, clock, phoneHost)
        await phone.tick([(s, c)])
        #expect(phoneHost.sent.count == 2)
        // The primary reconnects later and must not run it again.
        macClient.partitioned = false
        await mac.tick([(s, c)])
        #expect(macHost.sent.isEmpty)
    }

    @Test func holderStopsWhenItLosesTheLeaseMidRun() async {
        let (s, c, scene) = fixture(steps: 2, delay: 120_000)
        let server = LeaseServer(), clock = Clock(fire + 1)
        let host = Host(s, c, scene)
        let (mac, client) = device("mac", server, clock, host)
        host.afterSend = { client.partitioned = true }
        await mac.tick([(s, c)])
        #expect(host.sent.count == 1)
        #expect(host.ended == ["uncertain"])
    }

    @Test func ambiguousSendIsNotRetriedEvenAfterRestart() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 1)
        let host = Host(s, c, scene)
        host.failure = URLError(.timedOut)
        let (mac, _) = device("mac", server, clock, host)
        await mac.tick([(s, c)])
        #expect(host.sent.count == 1)
        #expect(server.leases[occurrence(s)]?.state == .uncertain)
        host.failure = nil
        let (restarted, _) = device("mac", server, clock, host)
        await restarted.tick([(s, c)])
        #expect(host.sent.count == 1)
    }

    @Test func unsentStepRetriesAreBoundedByAttemptsAndDeadline() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 1)
        let host = Host(s, c, scene)
        host.failure = CommandNotSent(underlying: LumaError.message("No route"))
        let (mac, _) = device("mac", server, clock, host)
        await mac.tick([(s, c)])
        #expect(host.sent.count == FailoverPolicy().maxAttempts)
        #expect(server.leases[occurrence(s)]?.state == .failed)

        let (s2, c2, scene2) = fixture()
        let late = Host(s2, c2, scene2)
        late.failure = host.failure
        clock.now = fire + 599 // a 2 s retry would cross the 10-minute deadline
        let (mac2, _) = device("mac", server, clock, late, file: "mac2.json")
        await mac2.tick([(s2, c2)])
        #expect(late.sent.count == 1)
    }

    @Test func lateOccurrencesAndDeletedSchedulesDoNotRun() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 601)
        let host = Host(s, c, scene)
        let (mac, _) = device("mac", server, clock, host)
        await mac.tick([(s, c)])
        #expect(host.sent.isEmpty && server.leases.isEmpty)

        clock.now = fire + 1
        host.afterSend = { host.deleted = true }
        await mac.tick([(s, c)])
        #expect(host.sent.count == 1)
        #expect(server.leases[occurrence(s)]?.state == .cancelled)
    }

    @Test func accountSwitchStopsTheRun() async {
        let (s, c, scene) = fixture(steps: 2, delay: 60_000)
        let server = LeaseServer(), clock = Clock(fire + 1)
        let host = Host(s, c, scene)
        let (mac, client) = device("mac", server, clock, host)
        host.afterSend = { client.account = "other" }
        await mac.tick([(s, c)])
        #expect(host.sent.count == 1)
        #expect(host.ended == ["uncertain"])
    }

    @Test func otherAppleAccountNeverClaimsAndUnsignedBuildsStayLocal() async {
        let (s, c, scene) = fixture()
        let server = LeaseServer(), clock = Clock(fire + 1.234)
        let host = Host(s, c, scene)
        let (mac, client) = device("mac", server, clock, host)
        client.account = "different"
        await mac.tick([(s, c)])
        #expect(host.sent.isEmpty && server.leases.isEmpty)
        #expect(CloudAvailability.isEntitled == false) // unsigned test binary: SecTask gate returns false without trapping
    }

    @Test func scheduledRunsShareTheWatchRelaysBusyAndStopBehavior() throws {
        let store = HomeStore(demo: true); defer { store.shutdown() }
        let scene = try #require(store.home.scenes.first)
        let runID = try #require(store.beginScheduledRun(scene))
        #expect(store.runningSceneID == scene.id)
        #expect(store.watchSnapshot.runningSceneID == scene.id)
        #expect(throws: (any Error).self) { try store.runScene(scene) }
        store.handleWatch(.stopScene)
        store.endScheduledRun(runID, status: "cancelled", error: nil)
        #expect(store.runningSceneID == nil)
        #expect(WatchSnapshot.decode(try store.watchSnapshot.encoded()) == store.watchSnapshot)

        // Coordinated schedules never take the legacy local path, even when due.
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let schedule = SceneSchedule(sceneID: scene.id, hour: comps.hour!, minute: comps.minute!)
        store.home.schedules = [schedule]
        store.setCoordination(ScheduleCoordination(primary: store.thisSchedulerID), for: schedule.id)
        let before = store.runs.count
        store.tickSchedules(now: now)
        #expect(store.runs.count == before)
        #expect(store.scheduleStatus[schedule.id]?.contains("Paused") == true)
    }
}
