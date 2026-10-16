import Foundation
import AppKit
import Observation
import LumaCore

/// Content the user explicitly chose. Holding a source never captures anything;
/// only `ScreenSync.start()` creates a session from it.
struct ScreenSource {
    enum Kind { case display, window, sample }
    let name: String
    let kind: Kind
    let makeSession: () -> any ScreenCaptureSession
}

enum ScreenCaptureEnd: Error, Equatable {
    case userStopped, permissionDenied, sourceGone, failed(String)
}

/// One running capture. Only five region colors ever leave it, never pixels.
protocol ScreenCaptureSession: AnyObject {
    func start(onFrame: @escaping @MainActor (RegionColors) -> Void, onEnd: @escaping @MainActor (ScreenCaptureEnd) -> Void) async throws
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

    var isActive: Bool { phase != .idle }

    @ObservationIgnored weak var store: HomeStore?
    /// Sends one update directly to a light. HomeStore installs its LAN path.
    @ObservationIgnored var send: (LightDevice, StreamUpdate) throws -> Void = { _, _ in }
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
    }

    func select(_ source: ScreenSource) {
        guard !isActive else { return }
        self.source = source; message = nil; permissionDenied = false
    }

    /// Starts or resumes capture from the chosen source. Explicit user action only.
    func start() async {
        guard let source, phase == .idle || phase == .paused else { return }
        cancelReadbacks()
        generation &+= 1
        let g = generation
        phase = .starting; message = nil; permissionDenied = false; pauseReason = nil
        let session = source.makeSession()
        self.session = session
        do {
            try await session.start(onFrame: { [weak self] colors in self?.receive(colors, generation: g) },
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
        reset()
        if wasActive { store?.log("Screen Sync stopped. Lights keep their last synced color and brightness.") }
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
        excluded.removeAll(); preview.removeAll(); regionPreview = nil
        mixer.reset()
        ScreenSourcePicker.shared.deactivate()
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

    private func ended(_ end: ScreenCaptureEnd, generation g: UInt64) {
        guard g == generation else { return }
        let keepsSource = end == .permissionDenied
        let source = self.source
        reset()
        if keepsSource { self.source = source }
        switch end {
        case .userStopped: message = "Screen Sync stopped from the macOS menu bar."
        case .permissionDenied: permissionDenied = true; message = "macOS didn't allow Luma to capture your screen."
        case .sourceGone: message = "The window or display you chose is no longer available. Choose it again to continue."
        case .failed(let text): message = "Screen Sync stopped: \(text)"
        }
        store?.log(message ?? "Screen Sync stopped.", error: { if case .failed = end { true } else { false } }())
    }

    // MARK: Frames and streaming

    func receive(_ colors: RegionColors, generation g: UInt64) {
        guard g == generation, phase == .starting || phase == .running else { return }
        mixer.ingest(colors)
    }

    private func startTicker(_ g: UInt64) {
        ticker = Task { [weak self] in
            // Smoothing runs at a fixed 10 Hz, independent of capture frame rate;
            // the mixer separately caps each light's update rate.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.generation == g, self.phase == .running else { return }
                let elapsed = ContinuousClock.now - self.origin
                self.tick(now: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
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
        for update in updates {
            guard let device = store.home.devices.first(where: { $0.id == update.deviceID }) else { continue }
            do {
                try send(device, update)
                preview[update.deviceID] = update.target
            } catch {
                excluded[update.deviceID] = "Couldn't reach this light"
                mixer.forget(update.deviceID)
                store.log("Screen Sync skipped \(device.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Light selection and ownership

    func setIncluded(_ included: Bool, for id: String) {
        if included { regions[id] = regions[id] ?? .full }
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
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "Paused while your Mac slept."),
            (workspace, NSWorkspace.screensDidSleepNotification, "Paused while your displays slept."),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "Paused while you switched users."),
            // ponytail: undocumented lock notification, paired with the session events above.
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), "Paused while your Mac was locked.")
        ]
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
