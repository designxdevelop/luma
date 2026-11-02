import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import LumaCore

struct ScreenSyncView: View {
    let store: HomeStore
    let sync: ScreenSync

    private static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: sync.mode == .audio ? "Audio Sync" : "Screen Sync", subtitle: audio ? Copy.audioSubtitle : Copy.subtitle) { actions }
                modePicker
                sourceCard
                if sync.phase == .idle { privacyCard }
                if audio && sync.isActive { AudioMeter(sync: sync) }
                if !audio, let colors = sync.regionPreview { colorMap(colors) }
                if sync.isActive { statsRow }
                lightsSection
                if audio { audioTuningSection } else { tuningSection }
            }.pagePadding().frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var audio: Bool { sync.mode == .audio }

    private var modePicker: some View {
        Picker("Follow", selection: Binding(get: { sync.mode }, set: { sync.setMode($0) })) {
            Text("Screen").tag(ScreenSync.Mode.screen)
            Text("Audio").tag(ScreenSync.Mode.audio)
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
        .disabled(sync.isActive)
        .accessibilityLabel("Follow screen or audio")
        .help(sync.isActive ? "Stop first to switch between Screen and Audio." : "Choose whether lights follow the screen or audio.")
    }

    // MARK: Header actions

    @ViewBuilder private var actions: some View {
        switch sync.phase {
        case .idle where sync.source == nil:
            Button(audio ? Copy.chooseAudio : store.demo ? "Use Sample Video" : Copy.choose) { sync.chooseSource() }.buttonStyle(.borderedProminent)
        case .idle:
            Button("Change…") { sync.chooseSource() }
            Button("Start") { Task { await sync.start() } }.buttonStyle(.borderedProminent)
        case .starting:
            Button("Starting…") {}.disabled(true)
            Button("Stop") { sync.stop() }
        case .running:
            Button("Pause") { sync.pause() }
            Button("Stop") { sync.stop() }
        case .paused:
            Button("Stop") { sync.stop() }
            Button("Resume") { Task { await sync.start() } }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: Source and status

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: sourceIcon).font(.system(size: 15)).foregroundStyle(Color.lumaAccent)
                        .frame(width: 28, height: 28).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sync.source?.name ?? (audio ? Copy.noAudioSource : Copy.noSource)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(sourceDetail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    statusPill
                }
                if audio && store.demo {
                    Label("Demo home: the lights are simulated, but Audio Sync listens to real audio.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = sync.pauseReason, sync.phase == .paused {
                    Label(reason, systemImage: "pause.circle").font(.system(size: 12)).foregroundStyle(Color.warning)
                }
                if let message = sync.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if sync.permissionDenied {
                    #if os(iOS)
                    Text(audio ? "Luma needs microphone access to follow music. You can allow it in Settings › Luma › Microphone, then start again."
                               : "Luma needs camera access to follow the colors on your TV or monitor. You can allow it in Settings › Luma › Camera, then start again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    #else
                    Text(audio ? "Luma needs your permission to capture audio. You can allow it in System Settings under Privacy & Security › Screen & System Audio Recording, then start again."
                               : "Luma needs your permission to read a display or window. You can allow it in System Settings under Privacy & Security › Screen & System Audio Recording, then start again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettings) }
                    #endif
                }
            }
        }
    }

    private var sourceIcon: String {
        switch sync.source?.kind {
        case .display: "display"; case .window: "macwindow"; case .camera: "camera"; case .sample: "film"
        case .systemAudio: "speaker.wave.2"; case .microphone: "mic"; case nil: audio ? "waveform" : "rectangle.dashed"
        }
    }

    private var sourceDetail: String {
        switch sync.source?.kind {
        case nil: audio ? "You choose what Luma listens to. Nothing is captured until you start." : "You pick what Luma follows. Nothing is captured until you start."
        case .systemAudio: "Sound apps play on this Mac, except Luma itself."
        case .microphone: "Sound the microphone hears around you, including music from this device's speaker."
        default: "Only the content you chose is used."
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch sync.phase {
        case .running: StatusPill(text: audio ? "Listening" : "Capturing", icon: audio ? "waveform" : "record.circle.fill", tint: .danger)
        case .starting: StatusPill(text: "Starting…", tint: .secondary, busy: true)
        case .paused: StatusPill(text: "Paused", icon: "pause.circle.fill", tint: .warning)
        case .idle: sync.source == nil ? StatusPill(text: "Off", icon: "circle") : StatusPill(text: "Ready", icon: "checkmark.circle.fill", tint: .success)
        }
    }

    private var privacyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Private by design", systemImage: "lock.shield").font(.system(size: 13, weight: .medium))
                Text(audio ? Copy.audioPrivacy : Copy.privacy)
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Color map

    private func colorMap(_ colors: RegionColors) -> some View {
        func tile(_ region: ScreenRegion) -> some View {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(swatch(colors[region]))
        }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Screen colors", detail: "Averages, not a picture")
            Card {
                VStack(spacing: 4) {
                    tile(.top).frame(height: 28)
                    HStack(spacing: 4) {
                        tile(.left).frame(width: 56)
                        tile(.full)
                        tile(.right).frame(width: 56)
                    }.frame(maxHeight: .infinity)
                    tile(.bottom).frame(height: 28)
                }
                .padding(6).frame(maxWidth: 360).aspectRatio(16 / 10, contentMode: .fit)
                .background(Color.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore).accessibilityLabel("Screen colors preview")
            }
        }
    }

    private func swatch(_ c: LinearColor) -> Color {
        Color(red: ScreenColorMath.srgb(c.r) / 255, green: ScreenColorMath.srgb(c.g) / 255, blue: ScreenColorMath.srgb(c.b) / 255)
    }

    // MARK: Session stats

    private var statsRow: some View {
        let s = sync.stats
        let items = [("Analyzed", s.analyzed), ("Skipped", s.skipped), ("Sent", s.sent), ("Superseded", s.superseded), ("Errors", s.errors)]
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Session", detail: "Frames and light updates")
            Card {
                HStack {
                    ForEach(items, id: \.0) { title, value in
                        VStack(spacing: 2) {
                            Text("\(value)").font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(title == "Errors" && value > 0 ? Color.warning : .primary)
                            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Session: \(items.map { "\($0.1) \($0.0.lowercased())" }.joined(separator: ", "))")
            }
        }
    }

    // MARK: Lights

    private var lightsSection: some View {
        let devices = store.devices
        let eligible = devices.filter { $0.screenSyncIssue == nil }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Lights", detail: devices.isEmpty ? nil : "\(devices.filter { sync.regions[$0.id] != nil }.count) included")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    if eligible.isEmpty {
                        EmptyState(icon: "wifi.slash", title: devices.isEmpty ? "No lights yet" : "No lights can sync right now",
                                   message: "\(sync.title) needs lights with LAN Control turned on in the Govee Home app, discovered on this Wi-Fi.") {
                            Button(store.scanning ? "Looking for Lights…" : "Find Lights on Wi-Fi") { store.discover() }.disabled(store.scanning || store.demo)
                        }
                    }
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 || eligible.isEmpty && !devices.isEmpty { Divider() }
                        lightRow(device)
                    }
                }
            }
            Text("Manual changes, scenes, schedules, and webhooks take over a light right away. Stopping leaves lights at their last synced color and brightness unless you turn on Restore previous state.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lightRow(_ device: LightDevice) -> some View {
        let issue = device.screenSyncIssue
        let region = sync.regions[device.id]
        let excluded = sync.excluded[device.id]
        let ownershipIssue = sync.ownershipIssue(for: device.id)
        return HStack(spacing: compactSpacing(12, 8)) {
            LightOrb(device: device, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let issue { Text(issue).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                else if let reason = ownershipIssue ?? excluded { Text(reason).font(.system(size: 12)).foregroundStyle(Color.warning).fixedSize(horizontal: false, vertical: true) }
                else { Text(device.sku).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if issue == nil {
                if excluded != nil { Button("Include Again") { sync.includeAgain(device.id) }.disabled(ownershipIssue != nil) }
                else if region != nil { previewDot(sync.preview[device.id]) }
                if audio {
                    if region != nil, let band = band(for: device.id) {
                        Text(band).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).accessibilityLabel("Follows \(band.lowercased())")
                    }
                } else {
                Picker("Screen region", selection: Binding(get: { region ?? .full }, set: { sync.setRegion($0, for: device.id) })) {
                    ForEach(ScreenRegion.Group.allCases) { group in
                        Section(group.rawValue) { ForEach(group.regions) { Text($0.title).tag($0) } }
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: compactSpacing(190, 120)).disabled(region == nil)
                .accessibilityLabel("Screen region for \(device.name)")
                }
                Toggle(isOn: Binding(get: { region != nil }, set: { sync.setIncluded($0, for: device.id) })) {
                    #if os(macOS)
                    Text("Include")
                    #endif
                }
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Include \(device.name) in \(sync.title)")
            }
        }
        .padding(.horizontal, compactSpacing(16, 12)).padding(.vertical, 10)
        .opacity(issue == nil ? 1 : 0.55)
    }

    /// Spectrum spreads included lights bass → treble in name order (`ScreenSync.audioOrder`).
    private func band(for id: String) -> String? {
        guard sync.audioOptions.style == .spectrum else { return nil }
        let order = sync.audioOrder
        guard let i = order.firstIndex(of: id) else { return nil }
        guard order.count > 1 else { return "All bands" }
        let p = Double(i) / Double(order.count - 1)
        return p < 1.0 / 3 ? "Bass" : p <= 2.0 / 3 ? "Mid" : "Treble"
    }

    @ViewBuilder private func previewDot(_ target: LightTarget?) -> some View {
        Group {
            if let target { Circle().fill(Color(rgb: target.rgb).opacity(max(0.15, Double(target.brightness) / 100))) }
            else { Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5) }
        }
        .frame(width: 16, height: 16).overlay(Circle().strokeBorder(Color.hairline))
        .accessibilityElement(children: .ignore).accessibilityLabel("Last synced color")
        .accessibilityValue(target == nil ? "None yet" : "Sent")
    }

    // MARK: Tuning

    private var tuningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Tuning")
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    tuningRow("Smoothing", low: "Responsive", high: "Smooth", value: "\(Int((sync.settings.smoothing * 100).rounded()))%",
                              range: ScreenSyncSettings.smoothingRange, spoken: "\(Int((sync.settings.smoothing * 100).rounded())) percent",
                              binding: Binding(get: { sync.settings.smoothing }, set: { sync.settings.smoothing = ($0 * 100).rounded() / 100 }))
                    tuningRow("Change threshold", low: "Sensitive", high: "Only big changes", value: String(format: "%.1f%%", sync.settings.threshold * 100),
                              range: ScreenSyncSettings.thresholdRange, spoken: String(format: "%.1f percent", sync.settings.threshold * 100),
                              binding: Binding(get: { sync.settings.threshold }, set: { sync.settings.threshold = ($0 * 1000).rounded() / 1000 }))
                    tuningRow("Update rate", low: "Slower", high: "Faster", value: "\(rate) updates/s",
                              range: ScreenSyncSettings.updateHzRange, spoken: "\(rate) updates per second per light",
                              binding: Binding(get: { sync.settings.updateHz }, set: { sync.settings.updateHz = ($0 * 10).rounded() / 10 }))
                    tuningRow("Brightness cap", low: "Dimmer", high: "Brighter", value: "\(Int(sync.settings.brightnessCap.rounded()))%",
                              range: ScreenSyncSettings.brightnessCapRange, spoken: "\(Int(sync.settings.brightnessCap.rounded())) percent",
                              binding: Binding(get: { sync.settings.brightnessCap }, set: { sync.settings.brightnessCap = $0.rounded() }))
                    tuningRow("Edge depth", low: "Thin", high: "Deep", value: "\(Int((sync.settings.edgeDepth * 100).rounded()))%",
                              range: ScreenSyncSettings.edgeDepthRange, spoken: "\(Int((sync.settings.edgeDepth * 100).rounded())) percent of the picture",
                              binding: Binding(get: { sync.settings.edgeDepth }, set: { sync.settings.edgeDepth = ($0 * 100).rounded() / 100 }))
                    Toggle(isOn: Binding(get: { sync.settings.vivid }, set: { sync.settings.vivid = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vivid colors").font(.system(size: 13, weight: .medium))
                            Text("Favors colorful parts of the picture over gray, white, and text, so lights stay colorful.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    restoreToggle
                    Text("Edge depth sets how far edges, corners, and half edges reach into the picture.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Lights update a few times per second over your local network; hardware timing varies. Capture runs at up to \(ScreenSyncTiming.fps) frames per second; light updates are capped separately.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var restoreToggle: some View {
        Toggle(isOn: Binding(get: { sync.settings.restore }, set: { sync.settings.restore = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore previous state").font(.system(size: 13, weight: .medium))
                Text("When you press Stop, send each synced light back to the brightness and color it had before. Local network only. Lights you changed by hand are left alone, and automatic stops (sleep, lock, errors) don't restore.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    // MARK: Audio tuning

    private var audioTuningSection: some View {
        let sensitivity = String(format: "%.1f×", sync.audioOptions.sensitivity)
        let release = AudioReactive.releaseMinS + sync.settings.smoothing / ScreenSyncSettings.smoothingRange.upperBound * (AudioReactive.releaseMaxS - AudioReactive.releaseMinS)
        let floor = AudioReactive.brightnessRange(cap: sync.settings.brightnessCap).lowerBound
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Tuning")
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Style", selection: Binding(get: { sync.audioOptions.style }, set: { sync.audioOptions.style = $0 })) {
                            Text("Pulse").tag(AudioSyncOptions.Style.pulse)
                            Text("Spectrum").tag(AudioSyncOptions.Style.spectrum)
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 260).accessibilityLabel("Audio Sync style")
                        Text(sync.audioOptions.style == .pulse ? "Every light pulses with the loudness, colored by the balance of bass and treble."
                                                               : "Lights spread from bass to treble in name order; each follows its band.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    tuningRow("Sensitivity", low: "Less", high: "More", value: sensitivity,
                              range: AudioSyncOptions.sensitivityRange, spoken: sensitivity,
                              binding: Binding(get: { sync.audioOptions.sensitivity }, set: { sync.audioOptions.sensitivity = ($0 * 10).rounded() / 10 }))
                    tuningRow("Release", low: "Snappy", high: "Smooth", value: String(format: "%.2f s", release),
                              range: ScreenSyncSettings.smoothingRange, spoken: String(format: "%.2f seconds", release),
                              binding: Binding(get: { sync.settings.smoothing }, set: { sync.settings.smoothing = ($0 * 100).rounded() / 100 }))
                    tuningRow("Brightness cap", low: "Dimmer", high: "Brighter", value: "\(floor)–\(Int(sync.settings.brightnessCap.rounded()))%",
                              range: ScreenSyncSettings.brightnessCapRange, spoken: "\(Int(sync.settings.brightnessCap.rounded())) percent, never below \(floor) percent",
                              binding: Binding(get: { sync.settings.brightnessCap }, set: { sync.settings.brightnessCap = $0.rounded() }))
                    tuningRow("Update rate", low: "Slower", high: "Faster", value: "\(rate) updates/s",
                              range: ScreenSyncSettings.updateHzRange, spoken: "\(rate) updates per second per light",
                              binding: Binding(get: { sync.settings.updateHz }, set: { sync.settings.updateHz = ($0 * 10).rounded() / 10 }))
                    tuningRow("Change threshold", low: "Sensitive", high: "Only big changes", value: String(format: "%.1f%%", sync.settings.threshold * 100),
                              range: ScreenSyncSettings.thresholdRange, spoken: String(format: "%.1f percent", sync.settings.threshold * 100),
                              binding: Binding(get: { sync.settings.threshold }, set: { sync.settings.threshold = ($0 * 1000).rounded() / 1000 }))
                    restoreToggle
                    Text("Lights never drop below a fifth of the cap, so they don't black out between beats. Brightness rises in 50 ms and falls over the release time, which damps fast flashing. Lights update a few times per second over your local network, so this is rhythmic ambience, not beat-exact flashing.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var rate: String { String(format: "%g", sync.settings.updateHz) }

    // No `step:`: macOS draws tick marks for stepped sliders, so setters round instead.
    private func tuningRow(_ title: String, low: String, high: String, value: String, range: ClosedRange<Double>, spoken: String,
                           binding: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(low).font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: binding, in: range)
                    .accessibilityLabel(title).accessibilityValue(spoken)
                Text(high).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact sidebar-footer indicator, shown only while capture is active.
struct ScreenSyncIndicator: View {
    let sync: ScreenSync
    let open: () -> Void

    var body: some View {
        if sync.isActive {
            let paused = sync.phase == .paused, listening = sync.source?.isAudio == true
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Circle().fill(paused ? Color.warning : Color.danger).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sync.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(paused ? "Paused" : "\(listening ? "Listening" : "Capturing") · \(sync.source?.name ?? "Screen")").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Open \(sync.title)")
                .accessibilityLabel(paused ? "\(sync.title) paused" : "\(sync.title) \(listening ? "listening to" : "capturing") \(sync.source?.name ?? "your screen")").accessibilityHint("Opens \(sync.title)")
                if paused {
                    Button { Task { await sync.start() } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Resume \(sync.title)").accessibilityLabel("Resume \(sync.title)")
                } else {
                    Button { sync.pause() } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.borderless).help("Pause \(sync.title)").accessibilityLabel("Pause \(sync.title)")
                }
                Button { sync.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("Stop \(sync.title)").accessibilityLabel("Stop \(sync.title)")
            }
            .padding(10).background((paused ? Color.warning : Color.danger).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Live loudness and 8 bands from the latest real analysis. Its own view so only it
/// re-renders 20 times a second.
private struct AudioMeter: View {
    let sync: ScreenSync

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Audio", detail: "Levels, not a recording")
            Card {
                if let levels = sync.audioLevels {
                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(spacing: 4) {
                            HStack(alignment: .bottom, spacing: 4) { ForEach(Array(levels.bands.enumerated()), id: \.offset) { i, v in bar(v, hue: Double(i) / 7 * AudioReactive.hueSpan) } }
                                .frame(height: 64)
                            HStack { Text("Bass"); Spacer(); Text("Treble") }.font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 4) {
                            bar(levels.level, hue: nil).frame(width: 18, height: 64)
                            Text("Level").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("Audio level")
                    .accessibilityValue("\(Int((levels.level * 100).rounded())) percent loudness")
                } else {
                    Label("No signal yet. Play something, or check that the source is making sound.", systemImage: "waveform.slash")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                }
            }
        }
    }

    private func bar(_ value: Double, hue: Double?) -> some View {
        let color = hue.map { Color(rgb: AudioReactive.hueToRGB($0)) } ?? Color.lumaAccent
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(height: max(2, 64 * value))
        }
        .frame(maxWidth: .infinity)
        .background(Color.well, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private enum Copy {
    #if os(iOS)
    static let subtitle = "Point your camera at a TV or monitor and match local lights to it."
    static let choose = "Use Camera"
    static let noSource = "Camera not started"
    static let privacy = "Luma reads only small color samples from the back camera, here on this device. Nothing is recorded, saved, or uploaded, and audio is never used. Capture stops when you pause, stop, or leave Luma."
    static let audioSubtitle = "Make local lights follow music the microphone hears."
    static let chooseAudio = "Use Microphone"
    static let noAudioSource = "Microphone not started"
    static let audioPrivacy = "iOS asks before Luma can use the microphone. Luma reduces what it hears to a loudness level and eight frequency bands about 20 times a second, here on this device. No audio is recorded, saved, or uploaded, and the camera is never used. Listening stops when you pause, stop, or leave Luma. iOS doesn't let apps hear what other apps play, so the microphone is the source."
    #else
    static let subtitle = "Match local lights to a display or window on this Mac."
    static let choose = "Choose Display or Window…"
    static let noSource = "No display or window chosen"
    static let privacy = "When you choose a display or window, macOS asks you to confirm. Luma reads only small color samples of what you choose, here on this Mac. Nothing is recorded, saved, or uploaded, and audio and camera are never used. Capture stops when you pause, stop, lock, or sleep your Mac."
    static let audioSubtitle = "Make local lights follow the music this Mac plays."
    static let chooseAudio = "Listen to Mac Audio…"
    static let noAudioSource = "No audio source chosen"
    static let audioPrivacy = "macOS asks you to pick a display and to allow audio capture, and shows that Luma is recording. Luma hears what apps on this Mac play, except itself, and reduces it to a loudness level and eight frequency bands about 20 times a second, here on this Mac. No audio is recorded, saved, or uploaded; the picture and microphone are never used. Listening stops when you pause, stop, lock, or sleep your Mac."
    #endif
}
