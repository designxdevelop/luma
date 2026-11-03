import Foundation

/// The watch's view of the home: the iPhone's last report, plus the requests
/// still in flight drawn on top. Failing a request only drops its own overlay,
/// so a late failure can't undo a newer action. Portable so it runs in `swift test`.
public struct WatchState: Sendable, Equatable {
    public struct Pending: Sendable, Equatable { public let nonce: Int, request: WatchRequest }
    public struct Failure: Sendable, Equatable { public let nonce: Int, request: WatchRequest, message: String }
    public struct Room: Sendable, Equatable, Identifiable {
        public let name: String, lights: [WatchSnapshot.Light]
        public var id: String { name }
    }

    /// Exactly what the iPhone last sent. Never contains watch-side guesses.
    public private(set) var report: WatchSnapshot?
    public private(set) var reportedAt: Date?
    public private(set) var pending: [Pending] = []
    public private(set) var failure: Failure?
    public private(set) var reachable = false
    private var nextNonce = 1
    /// Newest request whose reply became `report`; older replies arriving late are ignored.
    private var reportNonce = 0

    public init(report: WatchSnapshot? = nil, reachable: Bool = false) {
        self.report = report; self.reachable = reachable
    }

    /// `report` with pending requests applied in send order.
    public var display: WatchSnapshot? {
        guard var home = report else { return nil }
        for p in pending { home.apply(p.request) }
        return home
    }

    /// Records a request about to be sent; returns its nonce.
    public mutating func begin(_ request: WatchRequest) -> Int {
        defer { nextNonce += 1 }
        pending.append(.init(nonce: nextNonce, request: request))
        if let failure, overlaps(failure.request.targets, request.targets) { self.failure = nil }
        return nextNonce
    }

    /// The phone replied. A reply with no home in it counts as a failure.
    public mutating func succeed(_ nonce: Int, reply: WatchSnapshot?, at date: Date = .now) {
        guard let reply else { fail(nonce, message: "iPhone didn't send the home back."); return }
        pending.removeAll { $0.nonce == nonce }
        if nonce > reportNonce { report = reply; reportedAt = date; reportNonce = nonce }
        if let failure, failure.nonce < nonce { self.failure = nil }
    }

    public mutating func fail(_ nonce: Int, message: String) {
        guard let p = pending.first(where: { $0.nonce == nonce }) else { return }
        pending.removeAll { $0.nonce == nonce }
        // A newer request for the same lights supersedes this one; say nothing.
        let superseded = pending.contains { $0.nonce > nonce && overlaps($0.request.targets, p.request.targets) }
        if p.request != .refresh, !superseded { failure = .init(nonce: nonce, request: p.request, message: message) }
    }

    /// The phone published its home (application context), independent of any request.
    public mutating func receive(_ home: WatchSnapshot, at date: Date = .now) {
        report = home; reportedAt = date; failure = nil
    }

    /// Returns true when the watch should ask for a fresh home: every time the phone becomes reachable.
    public mutating func setReachable(_ now: Bool) -> Bool {
        defer { reachable = now }
        return now && !reachable
    }

    public mutating func clearFailure() { failure = nil }

    public func isPending(light id: String) -> Bool { pending.contains { $0.request.affects(light: id) } }
    public func isPending(_ request: WatchRequest) -> Bool { pending.contains { $0.request == request } }
    public var scenePending: Bool { pending.contains { $0.request.targets.contains(WatchRequest.sceneTarget) } }

    /// Rooms by name; lights with no room go last under "Other".
    public static func rooms(_ lights: [WatchSnapshot.Light]) -> [Room] {
        // A real room named "Other" shares the bucket, so ids stay unique.
        let byRoom = Dictionary(grouping: lights) { $0.room.trimmingCharacters(in: .whitespaces).isEmpty ? "Other" : $0.room }
        return byRoom.map { Room(name: $0.key, lights: $0.value) }.sorted { a, b in
            if (a.name == "Other") != (b.name == "Other") { return b.name == "Other" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The relay accepts 1…100 for lights that advertise brightness.
    public static func clampBrightness(_ value: Double) -> Int { min(max(Int(value.rounded()), 1), 100) }
}

extension WatchRequest {
    static let allTarget = "*", sceneTarget = "scene"
    /// What a request touches, for supersede checks. `*` = every light.
    var targets: Set<String> {
        switch self {
        case .power(let ids, _): ids.isEmpty ? [Self.allTarget] : Set(ids)
        case .brightness(let id, _): [id]
        case .runScene, .stopScene: [Self.sceneTarget]
        case .refresh: []
        }
    }
    public func affects(light id: String) -> Bool {
        let t = targets
        return t.contains(id) || t.contains(Self.allTarget)
    }
}

/// `*` (every light) overlaps any light target, but not scenes.
private func overlaps(_ a: Set<String>, _ b: Set<String>) -> Bool {
    let all = WatchRequest.allTarget, scene = WatchRequest.sceneTarget
    if a.contains(all), !b.subtracting([scene]).isEmpty { return true }
    if b.contains(all), !a.subtracting([scene]).isEmpty { return true }
    return !a.isDisjoint(with: b)
}

extension WatchSnapshot {
    /// A request's expected effect, for drawing it before the phone answers.
    public mutating func apply(_ request: WatchRequest) {
        switch request {
        case .power(let ids, let on):
            for i in lights.indices where (ids.isEmpty || ids.contains(lights[i].id)) && lights[i].online != false { lights[i].power = on }
        case .brightness(let id, let value):
            if let i = lights.firstIndex(where: { $0.id == id }), lights[i].canDim { lights[i].brightness = min(max(value, 1), 100) }
        case .runScene(let id): runningSceneID = id
        case .stopScene: runningSceneID = nil
        case .refresh: break
        }
    }
}
