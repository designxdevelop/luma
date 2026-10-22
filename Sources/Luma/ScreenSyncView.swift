import SwiftUI
import AppKit
import LumaCore

struct ScreenSyncView: View {
    let store: HomeStore
    let sync: ScreenSync

    private static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Screen Sync", subtitle: "Match local lights to a display or window on this Mac.") { actions }
                sourceCard
                if sync.phase == .idle { privacyCard }
                if let colors = sync.regionPreview { colorMap(colors) }
                lightsSection
                tuningSection
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    // MARK: Header actions

    @ViewBuilder private var actions: some View {
        switch sync.phase {
        case .idle where sync.source == nil:
            Button(store.demo ? "Use Sample Video" : "Choose Display or Window…") { sync.chooseSource() }.buttonStyle(.borderedProminent)
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
                        Text(sync.source?.name ?? "No display or window chosen").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(sync.source == nil ? "You pick what Luma follows. Nothing is captured until you start." : "Only the content you chose is used.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    statusPill
                }
                if let reason = sync.pauseReason, sync.phase == .paused {
                    Label(reason, systemImage: "pause.circle").font(.system(size: 12)).foregroundStyle(Color.warning)
                }
                if let message = sync.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if sync.permissionDenied {
                    Text("Luma needs your permission to read a display or window. You can allow it in System Settings under Privacy & Security › Screen & System Audio Recording, then start again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettings) }
                }
            }
        }
    }

    private var sourceIcon: String {
        switch sync.source?.kind { case .display: "display"; case .window: "macwindow"; case .sample: "film"; case nil: "rectangle.dashed" }
    }

    @ViewBuilder private var statusPill: some View {
        switch sync.phase {
        case .running: StatusPill(text: "Capturing", icon: "record.circle.fill", tint: .danger)
        case .starting: StatusPill(text: "Starting…", tint: .secondary, busy: true)
        case .paused: StatusPill(text: "Paused", icon: "pause.circle.fill", tint: .warning)
        case .idle: sync.source == nil ? StatusPill(text: "Off", icon: "circle") : StatusPill(text: "Ready", icon: "checkmark.circle.fill", tint: .success)
        }
    }

    private var privacyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Private by design", systemImage: "lock.shield").font(.system(size: 13, weight: .medium))
                Text("When you choose a display or window, macOS asks you to confirm. Luma reads only small color samples of what you choose, here on this Mac. Nothing is recorded, saved, or uploaded, and audio and camera are never used. Capture stops when you pause, stop, lock, or sleep your Mac.")
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
                                   message: "Screen Sync needs lights with LAN Control turned on in the Govee Home app, discovered on this Wi-Fi.") {
                            Button(store.scanning ? "Looking for Lights…" : "Find Lights on Wi-Fi") { store.discover() }.disabled(store.scanning || store.demo)
                        }
                    }
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 || eligible.isEmpty && !devices.isEmpty { Divider() }
                        lightRow(device)
                    }
                }
            }
            Text("Manual changes, scenes, schedules, and webhooks take over a light right away. Stopping leaves lights at their last synced color and brightness.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lightRow(_ device: LightDevice) -> some View {
        let issue = device.screenSyncIssue
        let region = sync.regions[device.id]
        let excluded = sync.excluded[device.id]
        let ownershipIssue = sync.ownershipIssue(for: device.id)
        return HStack(spacing: 12) {
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
                Picker("Screen region", selection: Binding(get: { region ?? .full }, set: { sync.setRegion($0, for: device.id) })) {
                    ForEach(ScreenRegion.Group.allCases) { group in
                        Section(group.rawValue) { ForEach(group.regions) { Text($0.title).tag($0) } }
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 190).disabled(region == nil)
                .accessibilityLabel("Screen region for \(device.name)")
                Toggle("Include", isOn: Binding(get: { region != nil }, set: { sync.setIncluded($0, for: device.id) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Include \(device.name) in Screen Sync")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .opacity(issue == nil ? 1 : 0.55)
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
                    Text("Edge depth sets how far edges, corners, and half edges reach into the picture.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Lights update a few times per second over your local network; hardware timing varies. Capture runs at up to \(ScreenSyncTiming.fps) frames per second; light updates are capped separately.")
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
            let paused = sync.phase == .paused
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Circle().fill(paused ? Color.warning : Color.danger).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Screen Sync").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(paused ? "Paused" : "Capturing · \(sync.source?.name ?? "Screen")").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Open Screen Sync")
                .accessibilityLabel(paused ? "Screen Sync paused" : "Screen Sync capturing \(sync.source?.name ?? "your screen")").accessibilityHint("Opens Screen Sync")
                if paused {
                    Button { Task { await sync.start() } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Resume Screen Sync").accessibilityLabel("Resume Screen Sync")
                } else {
                    Button { sync.pause() } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.borderless).help("Pause Screen Sync").accessibilityLabel("Pause Screen Sync")
                }
                Button { sync.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("Stop Screen Sync").accessibilityLabel("Stop Screen Sync")
            }
            .padding(10).background((paused ? Color.warning : Color.danger).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
