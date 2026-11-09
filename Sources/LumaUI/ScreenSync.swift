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
    enum Kind { case display, window, camera, sample, systemAudio, microphone }
    enum Session { case frames(() -> any ScreenCaptureSession), levels(() -> any AudioCaptureSession) }
    let name: String
    let kind: Kind
    let session: Session
    init(name: String, kind: Kind, makeSession: @escaping () -> any ScreenCaptureSession) {
        self.name = name; self.kind = kind; session = .frames(makeSession)
    }
    private init(name: String, kind: Kind, session: Session) { self.name = name; self.kind = kind; self.session = session }
    /// An Audio Sync source: its session yields `AudioLevels` instead of color grids.
    static func audio(name: String, kind: Kind, _ make: @escaping () -> any AudioCaptureSession) -> ScreenSource {
        ScreenSource(name: name, kind: kind, session: .levels(make))
    }
    var isAudio: Bool { if case .levels = session { true } else { false } }
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
///
/// Audio Sync is a second kind of the same session (`mode == .audio`): its source yields
/// `AudioLevels`, `AudioMapper` turns them into per-light targets, and the same mixer lanes,
/// exclusivity, manual-control yield, restore and readback apply unchanged.
@Observable final class ScreenSync {
    enum Phase: Equatable { case idle, starting, running, paused }
    /// What the session follows. Persisted; switching is only possible while idle.
    enum Mode: String, CaseIterable { case screen, audio }

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
    private(set) var mode: Mode
    /// Audio Sync style and sensitivity. Persisted separately from `settings`.
    var audioOptions: AudioSyncOptions { didSet { save() } }
    /// Latest analysis from real capture, for the meter. Nil when no audio is arriving.
    private(set) var audioLevels: AudioLevels?

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
    @ObservationIgnored private var mapper = AudioMapper()
    @ObservationIgnored private var audioTargets: [String: LightTarget] = [:]
    @ObservationIgnored private var lastLevelsAt: Double?
    @ObservationIgnored private var lastAudioStep: Double?
    @ObservationIgnored private var stopSession: (() -> Void)?
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
        let audio = Self.audioPreferences(defaults)
        mode = audio.0; audioOptions = audio.1
    }

    private static func audioPreferences(_ defaults: UserDefaults?) -> (Mode, AudioSyncOptions) {
        let mode = defaults?.string(forKey: "screenSync.mode").flatMap(Mode.init(rawValue:)) ?? .screen
        var options = defaults?.data(forKey: "audioSync.options").flatMap { try? JSONDecoder().decode(AudioSyncOptions.self, from: $0) } ?? AudioSyncOptions()
        let range = AudioSyncOptions.sensitivityRange
        options.sensitivity = options.sensitivity.isFinite ? min(max(options.sensitivity, range.lowerBound), range.upperBound) : 1
        return (mode, options)
    }

    /// "Screen Sync" or "Audio Sync", for messages and the activity log.
    var title: String { (source?.isAudio ?? (mode == .audio)) ? "Audio Sync" : "Screen Sync" }

    /// Switches between following the screen and following audio. Idle only; the chosen
    /// source is forgotten because it belongs to the other kind.
    func setMode(_ mode: Mode) {
        guard !isActive, mode != self.mode else { return }
        self.mode = mode
        source = nil; message = nil; permissionDenied = false
        #if os(macOS)
        ScreenSourcePicker.shared.deactivate()
        #endif
        save()
    }

    // MARK: Source and session

    /// Opens the system picker. Nothing is enumerated or captured before the
    /// person picks; in the demo home a synthetic sample stands in.
    func chooseSource() {
        guard !isActive else { return }
        message = nil; permissionDenied = false
        // Audio Sync always listens to real audio, also in the demo home (only the lights
        // are simulated there). There is no synthetic audio source.
        if mode == .audio {
            #if os(iOS)
            select(.microphone)
            #else
            presentPicker(audio: true)
            #endif
            return
        }
        if store?.demo == true { select(.sample); return }
        #if os(iOS)
        // iOS can't read other apps' screens without a broadcast extension; the
        // camera pointed at a TV or monitor is the source instead.
        select(.camera)
        #else
        presentPicker(audio: false)
        #endif
    }

    #if os(macOS)
    private func presentPicker(audio: Bool) {
        ScreenSourcePicker.shared.present(audio: audio) { [weak self] result in
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
    #endif

    #if os(macOS)
    /// A camera aimed at the TV: the way to follow DRM video, which screen capture sees
    /// as black. Bypasses the demo sample, since only the lights are simulated there.
    func useCamera(_ camera: ScreenSource) {
        guard !isActive else { return }
        ScreenSourcePicker.shared.deactivate()
        select(camera)
    }
    #endif

    func select(_ source: ScreenSource) {
        guard !isActive else { return }
        self.source = source; message = nil; permissionDenied = false
        mode = source.isAudio ? .audio : .screen
    }

    /// Starts or resumes capture from the chosen source. Explicit user action only.
    func start() async {
        guard let source, phase == .idle || phase == .paused else { return }
        if phase == .idle {
            stats = ScreenSyncStats(); supersededBase = mixer.superseded
            snapshots = [:]; mapper = AudioMapper()
            for id in regions.keys { snapshot(id) }
        }
        cancelReadbacks()
        generation &+= 1
        let g = generation
        phase = .starting; message = nil; permissionDenied = false; pauseReason = nil
        let onEnd: @MainActor (ScreenCaptureEnd) -> Void = { [weak self] end in self?.ended(end, generation: g) }
        let stopSession: () -> Void
        do {
            switch source.session {
            case .frames(let make):
                let session = make()
                stopSession = { session.stop() }
                self.stopSession = stopSession
                try await session.start(onFrame: { [weak self] grid, capturedAt in self?.receive(grid, generation: g, capturedAt: capturedAt) }, onEnd: onEnd)
            case .levels(let make):
                let session = make()
                stopSession = { session.stop() }
                self.stopSession = stopSession
                try await session.start(onLevels: { [weak self] levels in self?.receive(levels, generation: g) }, onEnd: onEnd)
            }
        } catch {
            guard g == generation else { return }
            ended(error as? ScreenCaptureEnd ?? .failed(error.localizedDescription), generation: g)
            return
        }
        guard g == generation else { stopSession(); return }
        phase = .running
        startTicker(g)
        store?.log("\(title) started.")
    }

    /// Stops capture but keeps the source, so Resume needs no new choice.
    func pause(reason: String? = nil) {
        guard phase == .starting || phase == .running else { return }
        halt()
        phase = .paused; pauseReason = reason
        store?.log(reason.map { "\(title): \($0)" } ?? "\(title) paused.")
    }

    /// Ends the session and forgets the source. Lights keep their last color unless restore is on.
    func stop() {
        guard isActive || source != nil else { return }
        let wasActive = isActive, title = title
        let restored = wasActive && settings.restore ? restoreLights() : []
        resetAfterRestore(restored)
        if wasActive {
            store?.log(restored.isEmpty ? "\(title) stopped. Lights keep their last synced color and brightness."
                                        : "\(title) stopped. Restored \(restored.count) \(restored.count == 1 ? "light" : "lights") to their earlier color and brightness.")
        }
    }

    /// An immediate readback could catch a light before it applies the restore
    /// and record the streamed color as confirmed; ask once it has settled.
    private func resetAfterRestore(_ restored: [LightDevice]) {
        reset(refreshLights: restored.isEmpty)
        guard !restored.isEmpty else { return }
        let generation = readbackGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.readbackGeneration == generation else { return }
            for device in restored { self.requestReadback(device) }
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
        // Quitting is a deliberate stop too. LAN sends are fire-and-forget UDP, so they go out before exit.
        if isActive && settings.restore { restoreLights() }
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
        stopSession?(); stopSession = nil
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
        latestCapture = nil; blackSince = nil
        if message == Self.protectedVideoHint { message = nil }
        mapper.reset(); audioTargets = [:]; audioLevels = nil; lastLevelsAt = nil; lastAudioStep = nil
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
        let audio = Self.audioPreferences(defaults)
        mode = audio.0; audioOptions = audio.1
        self.defaults = defaults
    }

    #if os(iOS)
    static let permissionMessage = "iOS didn't allow Luma to use the camera."
    #else
    static let permissionMessage = "macOS didn't allow Luma to capture your screen."
    #endif

    #if os(iOS)
    private static let osName = "iOS"
    #else
    private static let osName = "macOS"
    #endif

    static func permissionMessage(for kind: ScreenSource.Kind?) -> String {
        switch kind {
        case .microphone: "iOS didn't allow Luma to use the microphone."
        case .systemAudio: "macOS didn't allow Luma to capture audio."
        case .camera: "\(osName) didn't allow Luma to use the camera."
        default: permissionMessage
        }
    }

    private func ended(_ end: ScreenCaptureEnd, generation g: UInt64) {
        guard g == generation else { return }
        let keepsSource = end == .permissionDenied
        let source = self.source, title = title
        // Stopping from the macOS menu bar is the person's choice, like Stop; other endings aren't.
        resetAfterRestore(end == .userStopped && phase == .running && settings.restore ? restoreLights() : [])
        if keepsSource { self.source = source }
        switch end {
        case .userStopped: message = "\(title) stopped from the macOS menu bar."
        case .permissionDenied: permissionDenied = true; message = Self.permissionMessage(for: source?.kind)
        case .sourceGone: message = source?.isAudio == true ? "The audio source you chose is no longer available. Choose it again to continue."
                                  : source?.kind == .camera ? "The camera you chose is no longer connected. Choose it again to continue."
                                                            : "The window or display you chose is no longer available. Choose it again to continue."
        case .failed(let text): message = "\(title) stopped: \(text)"
        }
        store?.log(message ?? "\(title) stopped.", error: { if case .failed = end { true } else { false } }())
    }

    // MARK: Frames and streaming

    func receive(_ grid: ScreenGrid, generation g: UInt64, capturedAt: ContinuousClock.Instant = .now) {
        guard g == generation, phase == .starting || phase == .running else { return }
        // Region colors use the current settings, so depth and vivid apply from the next frame.
        let colors = grid.colors(depth: settings.edgeDepth, vivid: settings.vivid)
        mixer.ingest(colors)
        latestCapture = capturedAt
        noteBlack(colors[.full])
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

    static let protectedVideoHint = "The picture has been black for a few seconds. Streaming services like Netflix and YouTube TV hide protected video from screen capture, so Screen Sync sees only black. Aim a camera at the TV and choose Use Camera… instead."
    @ObservationIgnored private var blackSince: Double?

    /// A screen that stays fully black is usually DRM-protected video, which macOS blanks for capture.
    private func noteBlack(_ full: LinearColor) {
        guard source?.kind == .display || source?.kind == .window else { return }
        if max(full.r, full.g, full.b) > 1.0 / 4096 {
            blackSince = nil
            if message == Self.protectedVideoHint { message = nil }
        } else if let since = blackSince {
            if elapsed - since > 3, message == nil { message = Self.protectedVideoHint }
        } else { blackSince = elapsed }
    }

    /// Audio Sync analysis from real capture. Maps to per-light targets at once and streams
    /// them; the ticker keeps rate-limited lights converging between analyses.
    func receive(_ levels: AudioLevels, generation g: UInt64, now: Double? = nil) {
        guard g == generation, phase == .starting || phase == .running else { return }
        let now = now ?? elapsed
        audioLevels = levels; lastLevelsAt = now
        stats.analyzed += 1
        stepAudio(levels, now: now)
        if phase == .running { tick(now: now) }
    }

    /// No analysis for this long means capture delivered nothing (some sources go quiet
    /// with the music): the meter shows no signal and lights ease to the floor.
    static let signalTimeout = 0.25
    private static let silence = AudioLevels(level: 0, bands: Array(repeating: 0, count: AudioLevels.bandCount))!

    /// Bass → treble order for Spectrum: every included light that can sync, by name then ID.
    /// A light taken over by hand keeps its band, so the others don't shift.
    var audioOrder: [String] {
        (store?.devices ?? []).filter { regions[$0.id] != nil && $0.screenSyncIssue == nil }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }.map(\.id)
    }

    private func stepAudio(_ levels: AudioLevels, now: Double) {
        let dt = lastAudioStep.map { now - $0 } ?? 0.05
        lastAudioStep = now
        let order = audioOrder
        let targets = mapper.step(levels, count: order.count, settings: settings, options: audioOptions, dt: dt)
        audioTargets = Dictionary(uniqueKeysWithValues: zip(order, targets))
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
        let updates: [StreamUpdate]
        if source?.isAudio == true {
            if let last = lastLevelsAt, now - last > Self.signalTimeout {
                audioLevels = nil
                stepAudio(Self.silence, now: now)
            }
            let lights = streamingLights
            updates = mixer.tick(now: now, targets: audioTargets.filter { lights[$0.key] != nil })
        } else {
            updates = mixer.tick(now: now, lights: streamingLights)
        }
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
                MainActor.assumeIsolated { self?.systemPause(name, reason: reason) }
            }
            observers.append((center, token))
        }
    }

    func systemPause(_ event: Notification.Name, reason: String) {
        // Displays sleeping don't stop Audio Sync or a camera; neither uses this Mac's picture.
        #if os(macOS)
        if event == NSWorkspace.screensDidSleepNotification && (source?.isAudio == true || source?.kind == .camera) { return }
        #endif
        pause(reason: reason)
    }

    private func save() {
        guard let defaults, store?.demo != true else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "screenSync.settings") }
        defaults.set(regions.mapValues(\.rawValue), forKey: "screenSync.regions")
        defaults.set(mode.rawValue, forKey: "screenSync.mode")
        if let data = try? JSONEncoder().encode(audioOptions) { defaults.set(data, forKey: "audioSync.options") }
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
