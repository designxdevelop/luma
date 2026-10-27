import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import os
import LumaCore

/// Content the user explicitly chose. Holding a source never captures anything;
/// only `ScreenSync.start()` creates a session from it.
struct ScreenSource {
    enum Kind { case display, window, camera, sample }
    let name: String
    let kind: Kind
    let makeSession: () -> any ScreenCaptureSession
}

/// Counters for the current session. Reset on a fresh start, kept across pause.
struct ScreenSyncStats: Equatable {
    /// Frames ingested; `skipped` of them landed before the previous one ticked and were folded into it.
    var analyzed = 0, skipped = 0, sent = 0, superseded = 0, errors = 0
}

enum ScreenCaptureEnd: Error, Equatable {
    case userStopped, permissionDenied, sourceGone, failed(String)
}

/// Capture and mixer cadence. Capture is downsampled to 160 px, so 30 fps of
/// analysis is cheap; light updates are capped separately per light.
enum ScreenSyncTiming {
    static let fps = 30
}

/// One running capture. Only a coarse grid of color sums and the capture time
/// ever leave it, never pixels.
protocol ScreenCaptureSession: AnyObject {
    func start(onFrame: @escaping @MainActor (ScreenGrid, ContinuousClock.Instant) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws
    func stop()
}

/// Screen Sync session state. Off by default and never restored at launch.
/// Streams whole-device RGB and brightness to local lights through a
/// latest-only path that bypasses HomeStore's queued, confirmed controls.
@Observable final class ScreenSync {
    enum Phase: Equatable { case idle, starting, running, paused }

    private(set) var phase = Phase.idle
    private(set) var source: ScreenSource?
    var message: String?
    private(set) var permissionDenied = false
    private(set) var pauseReason: String?
    /// Bound to range-limited sliders; the mixer clamps again before use.
    var settings: ScreenSyncSettings { didSet { mixer.settings = settings; save() } }
    /// Lights the user included, and the screen region each follows. Persisted.
    private(set) var regions: [String: ScreenRegion]
    /// Included lights sitting out this session, with the reason. Not persisted.
    private(set) var excluded: [String: String] = [:]
    /// Last color streamed to each light. A preview only: never confirmed state.
    private(set) var preview: [String: LightTarget] = [:]
    /// Smoothed region colors, for the on-page color map.
    private(set) var regionPreview: RegionColors?

    private(set) var stats = ScreenSyncStats()

    var isActive: Bool { phase != .idle }

    @ObservationIgnored weak var store: HomeStore?
    /// Sends one update directly to a light. HomeStore installs its LAN path.
    @ObservationIgnored var send: (LightDevice, StreamUpdate) throws -> Void = { _, _ in }
    /// Sends restore commands to one light over LAN. HomeStore installs it.
    @ObservationIgnored var restore: (LightDevice, [CapabilityCommand]) throws -> Void = { _, _ in }
    /// Each light's state when the session began, for restore on Stop.
    @ObservationIgnored private var snapshots: [String: LightDevice] = [:]
    @ObservationIgnored private var supersededBase = 0
    @ObservationIgnored var readback: (LightDevice) async -> Void = { _ in }
    @ObservationIgnored private var mixer: ScreenSyncMixer
    @ObservationIgnored private var session: (any ScreenCaptureSession)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private(set) var generation: UInt64 = 0
    @ObservationIgnored private var defaults: UserDefaults?
    @ObservationIgnored private var readbacks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var readbackGeneration: UInt64 = 0
    @ObservationIgnored private let origin = ContinuousClock.now
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var latestCapture: ContinuousClock.Instant?
    @ObservationIgnored private var frameTickPending = false
    @ObservationIgnored private var latency = ProcessInfo.processInfo.environment["LUMA_LATENCY_LOG"] == "1" ? LatencyLog() : nil

    /// Pass nil defaults to keep settings in memory only (demo and tests).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: "screenSync.settings").flatMap { try? JSONDecoder().decode(ScreenSyncSettings.self, from: $0) }
        let settings = (saved ?? ScreenSyncSettings()).clamped()
        self.settings = settings
        mixer = ScreenSyncMixer(settings: settings)
        let raw = defaults?.dictionary(forKey: "screenSync.regions") as? [String: String] ?? [:]
        regions = raw.compactMapValues(ScreenRegion.init(rawValue:))
    }

    // MARK: Source and session

    /// Opens the system picker. Nothing is enumerated or captured before the
    /// person picks; in the demo home a synthetic sample stands in.
    func chooseSource() {
        guard !isActive else { return }
        message = nil; permissionDenied = false
        if store?.demo == true { select(.sample); return }
        #if os(iOS)
        // iOS can't read other apps' screens without a broadcast extension; the
        // camera pointed at a TV or monitor is the source instead.
        select(.camera)
        #else
        ScreenSourcePicker.shared.present { [weak self] result in
            guard let self, !self.isActive else { return }
            switch result {
            case .picked(let source): self.select(source)
            case .cancelled: if self.source == nil { ScreenSourcePicker.shared.deactivate() }
            case .failed(let text):
                self.message = "The screen picker couldn't open: \(text)"
                if self.source == nil { ScreenSourcePicker.shared.deactivate() }
            }
        }
        #endif
    }

    func select(_ source: ScreenSource) {
        guard !isActive else { return }
        self.source = source; message = nil; permissionDenied = false
    }

    /// Starts or resumes capture from the chosen source. Explicit user action only.
    func start() async {
        guard let source, phase == .idle || phase == .paused else { return }
        if phase == .idle {
            stats = ScreenSyncStats(); supersededBase = mixer.superseded
            snapshots = [:]
            for id in regions.keys { snapshot(id) }
        }
        cancelReadbacks()
        generation &+= 1
        let g = generation
        phase = .starting; message = nil; permissionDenied = false; pauseReason = nil
        let session = source.makeSession()
        self.session = session
        do {
            try await session.start(onFrame: { [weak self] grid, capturedAt in self?.receive(grid, generation: g, capturedAt: capturedAt) },
                                    onEnd: { [weak self] end in self?.ended(end, generation: g) })
        } catch {
            guard g == generation else { return }
            ended(error as? ScreenCaptureEnd ?? .failed(error.localizedDescription), generation: g)
            return
        }
        guard g == generation else { session.stop(); return }
        phase = .running
        startTicker(g)
        store?.log("Screen Sync started.")
    }

    /// Stops capture but keeps the source, so Resume needs no new choice.
    func pause(reason: String? = nil) {
        guard phase == .starting || phase == .running else { return }
        halt()
        phase = .paused; pauseReason = reason
        store?.log(reason.map { "Screen Sync: \($0)" } ?? "Screen Sync paused.")
    }

    /// Ends the session and forgets the source. Lights keep their last color.
    func stop() {
        guard isActive || source != nil else { return }
        let wasActive = isActive
        let restored = wasActive && settings.restore ? restoreLights() : []
        // An immediate readback could catch a light before it applies the restore
        // and record the streamed color as confirmed; ask once it has settled.
        reset(refreshLights: restored.isEmpty)
        if !restored.isEmpty {
            let generation = readbackGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.readbackGeneration == generation else { return }
                for device in restored { self.requestReadback(device) }
            }
        }
        if wasActive {
            store?.log(restored.isEmpty ? "Screen Sync stopped. Lights keep their last synced color and brightness."
                                        : "Screen Sync stopped. Restored \(restored.count) \(restored.count == 1 ? "light" : "lights") to their earlier color and brightness.")
        }
    }

    /// Remembers a light's last confirmed state; the first snapshot of a session wins,
    /// since later readbacks of streamed colors are not the person's state.
    private func snapshot(_ id: String) {
        guard snapshots[id] == nil, let device = store?.home.devices.first(where: { $0.id == id }), device.screenSyncIssue == nil else { return }
        snapshots[id] = device
    }

    /// Only lights this session actually streamed to, and that nothing took over.
    @discardableResult private func restoreLights() -> [LightDevice] {
        var restored: [LightDevice] = []
        for (id, saved) in snapshots where regions[id] != nil && excluded[id] == nil && preview[id] != nil {
            guard let device = store?.home.devices.first(where: { $0.id == id }) else { continue }
            let commands = Self.restoreCommands(saved)
            guard !commands.isEmpty else { continue }
            do { try restore(device, commands); restored.append(device) }
            catch { store?.log("\(device.name) was not restored: \(error.localizedDescription)", error: true) }
        }
        return restored
    }

    /// Brightness, then the previous color mode. Power is never changed: only lights that were on stream.
    static func restoreCommands(_ saved: LightDevice) -> [CapabilityCommand] {
        var commands: [CapabilityCommand] = []
        if let brightness = saved.brightness, brightness >= 1 { commands.append(.brightness(brightness)) }
        if let kelvin = saved.colorTemperature, kelvin > 0 { if (2000...9000).contains(kelvin) { commands.append(.kelvin(kelvin)) } }
        else if let rgb = saved.rgb { commands.append(.rgb(rgb)) }
        return commands
    }

    func shutdown() {
        reset(refreshLights: false)
        cancelReadbacks()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func reset(refreshLights: Bool = true) {
        halt(refreshLights: refreshLights)
        phase = .idle; source = nil; pauseReason = nil
        excluded.removeAll(); preview.removeAll(); regionPreview = nil; snapshots = [:]
        mixer.reset()
        #if os(macOS)
        ScreenSourcePicker.shared.deactivate()
        #endif
    }

    /// Cancels the ticker and capture. Bumping the generation makes every
    /// in-flight frame and tick from the old session a no-op.
    private func halt(refreshLights: Bool = true) {
        generation &+= 1
        ticker?.cancel(); ticker = nil
        session?.stop(); session = nil
        // Streamed colors were never recorded as confirmed; ask local lights
        // what they now show so the Lights page catches up.
        if refreshLights, let store, phase == .running {
            for device in store.home.devices where preview[device.id] != nil && device.ip != nil && !device.isDemo {
                requestReadback(device)
            }
        }
        // Resume must wait for a fresh frame from its new capture session.
        mixer.reset()
        regionPreview = nil
        latestCapture = nil
    }

    private func requestReadback(_ device: LightDevice) {
        let id = UUID(), generation = readbackGeneration
        readbacks[id] = Task { [weak self] in
            guard let self, !Task.isCancelled, self.readbackGeneration == generation else { return }
            defer { self.readbacks[id] = nil }
            await self.readback(device)
        }
    }

    private func cancelReadbacks() {
        readbackGeneration &+= 1
        for task in readbacks.values { task.cancel() }
        readbacks.removeAll()
    }

    /// Rebind after leaving a demo. Demo settings must neither replace the real
    /// preferences nor leave a formerly demo-only controller unable to save.
    func usePreferences(_ defaults: UserDefaults?) {
        reset(refreshLights: false)
        cancelReadbacks()
        self.defaults = nil
        settings = defaults?.data(forKey: "screenSync.settings").flatMap { try? JSONDecoder().decode(ScreenSyncSettings.self, from: $0) }?.clamped() ?? ScreenSyncSettings()
        let raw = defaults?.dictionary(forKey: "screenSync.regions") as? [String: String] ?? [:]
        regions = raw.compactMapValues(ScreenRegion.init(rawValue:))
        self.defaults = defaults
    }

    #if os(iOS)
    static let permissionMessage = "iOS didn't allow Luma to use the camera."
    #else
    static let permissionMessage = "macOS didn't allow Luma to capture your screen."
    #endif

    private func ended(_ end: ScreenCaptureEnd, generation g: UInt64) {
        guard g == generation else { return }
        let keepsSource = end == .permissionDenied
        let source = self.source
        reset()
        if keepsSource { self.source = source }
        switch end {
        case .userStopped: message = "Screen Sync stopped from the macOS menu bar."
        case .permissionDenied: permissionDenied = true; message = Self.permissionMessage
        case .sourceGone: message = "The window or display you chose is no longer available. Choose it again to continue."
        case .failed(let text): message = "Screen Sync stopped: \(text)"
        }
        store?.log(message ?? "Screen Sync stopped.", error: { if case .failed = end { true } else { false } }())
    }

    // MARK: Frames and streaming

    func receive(_ grid: ScreenGrid, generation g: UInt64, capturedAt: ContinuousClock.Instant = .now) {
        guard g == generation, phase == .starting || phase == .running else { return }
        // Region colors use the current settings, so depth and vivid apply from the next frame.
        mixer.ingest(grid.colors(depth: settings.edgeDepth, vivid: settings.vivid))
        latestCapture = capturedAt
        // Tick as soon as a frame lands instead of waiting for the ticker.
        // Coalesced: frames arriving before it runs just replace the target.
        stats.analyzed += 1
        guard phase == .running else { return }
        if frameTickPending { stats.skipped += 1; return }
        frameTickPending = true
        Task { [weak self] in
            guard let self else { return }
            self.frameTickPending = false
            guard self.generation == g else { return }
            self.tick(now: self.elapsed)
        }
    }

    private var elapsed: Double {
        let e = ContinuousClock.now - origin
        return Double(e.components.seconds) + Double(e.components.attoseconds) / 1e18
    }

    private func startTicker(_ g: UInt64) {
        ticker = Task { [weak self] in
            // Frames tick on arrival; this keeps smoothing converging and releases
            // rate-limited lights when frames pause (a static screen sends none).
            // The mixer stays latest-only and caps each light's update rate.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1) / ScreenSyncTiming.fps)
                guard let self, self.generation == g, self.phase == .running else { return }
                self.tick(now: self.elapsed)
            }
        }
    }

    /// Lights that receive updates right now: included, not excluded, eligible.
    var streamingLights: [String: ScreenRegion] {
        var lights: [String: ScreenRegion] = [:]
        for device in store?.devices ?? [] where excluded[device.id] == nil && device.screenSyncIssue == nil && ownershipIssue(for: device.id) == nil {
            if let region = regions[device.id] { lights[device.id] = region }
        }
        return lights
    }

    func tick(now: Double) {
        guard phase == .running, let store else { return }
        let updates = mixer.tick(now: now, lights: streamingLights)
        if regionPreview != mixer.smoothed { regionPreview = mixer.smoothed }
        if stats.superseded != mixer.superseded - supersededBase { stats.superseded = mixer.superseded - supersededBase }
        for update in updates {
            guard let device = store.home.devices.first(where: { $0.id == update.deviceID }) else { continue }
            do {
                try send(device, update)
                preview[update.deviceID] = update.target
                stats.sent += 1
                if let latestCapture, let summary = latency?.record(ContinuousClock.now - latestCapture) {
                    Logger(subsystem: "app.luma.govee", category: "screen-sync-latency").notice("\(summary, privacy: .public)")
                }
            } catch {
                stats.errors += 1
                excluded[update.deviceID] = "Couldn't reach this light"
                mixer.forget(update.deviceID)
                store.log("Screen Sync skipped \(device.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Light selection and ownership

    func setIncluded(_ included: Bool, for id: String) {
        if included { regions[id] = regions[id] ?? .full; if isActive { snapshot(id) } }
        else {
            if preview[id] != nil, let device = store?.home.devices.first(where: { $0.id == id }), device.ip != nil, !device.isDemo { requestReadback(device) }
            regions[id] = nil; excluded[id] = nil; preview[id] = nil; mixer.forget(id)
        }
        save()
    }

    func setRegion(_ region: ScreenRegion, for id: String) {
        guard regions[id] != nil else { return }
        regions[id] = region; mixer.forget(id); save()
    }

    func ownershipIssue(for id: String) -> String? {
        store?.hasOrdinaryControl(for: id) == true ? "Waiting for manual control to finish" : nil
    }

    func includeAgain(_ id: String) {
        guard ownershipIssue(for: id) == nil else { return }
        excluded[id] = nil
        mixer.forget(id)
    }

    /// Manual controls, scenes, schedules and webhooks call this before their
    /// write is queued. The light leaves this session at once, so no later
    /// frame can override what the person or automation asked for.
    func yield(_ id: String) {
        guard isActive, regions[id] != nil, excluded[id] == nil else { return }
        excluded[id] = "Paused for manual control"
        preview[id] = nil
        mixer.forget(id)
    }

    // MARK: System lifecycle

    /// Sleep, display sleep, a user switch, or screen lock pause capture. Resuming
    /// is always an explicit choice; nothing restarts on wake or unlock.
    func observeSystem() {
        guard observers.isEmpty else { return }
        #if os(iOS)
        // iOS stops camera capture in the background; pause so resuming stays explicit.
        let events: [(NotificationCenter, Notification.Name, String)] = [
            (.default, UIApplication.didEnterBackgroundNotification, "Paused while Luma was in the background.")
        ]
        #else
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "Paused while your Mac slept."),
            (workspace, NSWorkspace.screensDidSleepNotification, "Paused while your displays slept."),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "Paused while you switched users."),
            // ponytail: undocumented lock notification, paired with the session events above.
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), "Paused while your Mac was locked.")
        ]
        #endif
        for (center, name, reason) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause(reason: reason) }
            }
            observers.append((center, token))
        }
    }

    private func save() {
        guard let defaults, store?.demo != true else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "screenSync.settings") }
        defaults.set(regions.mapValues(\.rawValue), forKey: "screenSync.regions")
    }
}

/// Opt-in QA timing (`LUMA_LATENCY_LOG=1`): age of the newest captured frame
/// when its update is handed to the OS as LAN datagrams. UDP is unacknowledged,
/// so this is capture → send, not capture → light. Aggregates only; no colors
/// or pixels are logged.
struct LatencyLog {
    private var samples: [Double] = []
    let every: Int
    init(every: Int = 50) { self.every = every }

    /// Returns a summary every `every` samples, then starts a new window.
    mutating func record(_ age: Duration) -> String? {
        samples.append(Double(age.components.seconds) * 1000 + Double(age.components.attoseconds) / 1e15)
        guard samples.count >= every else { return nil }
        let s = samples.sorted()
        samples.removeAll()
        func ms(_ q: Double) -> Int { Int(s[min(s.count - 1, Int(Double(s.count) * q))].rounded()) }
        return "Screen Sync capture→send ms: n=\(s.count) p50=\(ms(0.5)) p95=\(ms(0.95)) max=\(ms(1))"
    }
}
