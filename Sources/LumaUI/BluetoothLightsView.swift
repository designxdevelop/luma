#if os(macOS) || os(iOS)
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

/// Nearby Govee lights over Bluetooth: scan, connect to a profiled TV backlight,
/// read its state, control it, and read a Govee Home capture for DreamView
/// member details. Only models with a source-evidenced profile can connect.
struct BluetoothLightsView: View {
    let store: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var ble = BluetoothLights()
    @State private var importingCapture = false
    @State private var capture: Result<GoveeBLECapture.Report, any Error>?
    @State private var color = Color.white
    @State private var brightness = 50.0
    @State private var colorSend: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Bluetooth", subtitle: "Control supported Govee lights near this \(PlatformCopy.device) without Wi-Fi or the cloud. Luma connects only to the light you choose and lets go when you close this page.") {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                nearbySection
                if ble.connectedID != nil || ble.phase != .idle { connectedSection }
                captureSection
            }.pagePadding().frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onDisappear { ble.stopScan(); ble.disconnect() }
        .fileImporter(isPresented: $importingCapture, allowedContentTypes: [.plainText, .text, .data]) { readCapture($0) }
    }

    // MARK: Nearby

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Nearby", detail: ble.nearby.isEmpty ? nil : "\(ble.nearby.count)") {
                Button(ble.scanning ? "Scanning…" : "Scan") { ble.scan() }.disabled(ble.scanning || ble.connectedID != nil)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    switch ble.availability {
                    case .unauthorized: InlineMessage(text: "Bluetooth access is off for Luma. Turn it on in System Settings › Privacy & Security › Bluetooth.")
                    case .unsupported: InlineMessage(text: "This \(PlatformCopy.device) doesn't support Bluetooth LE.")
                    case .off: InlineMessage(text: "Bluetooth is turned off.")
                    case .notStarted: Text("Scan to find Govee lights in Bluetooth range. Your \(PlatformCopy.device) may ask for Bluetooth access first.").font(.system(size: 12)).foregroundStyle(.secondary)
                    case .ready:
                        if ble.nearby.isEmpty {
                            Text(ble.scanning ? "Looking for Govee lights…" : "No Govee lights found. Bluetooth reaches about 10 m; a light connected to a phone may not advertise.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ble.nearby.sorted { $0.rssi > $1.rssi }) { row($0) }
                }
            }
        }
    }

    private func row(_ light: BluetoothLights.Nearby) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: light.advertisement?.supportsEncryption == true ? "lock.fill" : "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.lumaAccent).frame(width: 22)
                .accessibilityLabel(light.advertisement?.supportsEncryption == true ? "Advertises encryption" : "Bluetooth light")
            VStack(alignment: .leading, spacing: 2) {
                Text(light.profile.map { "\($0.name) · \($0.model)" } ?? light.model ?? "Govee device").font(.system(size: 13, weight: .medium))
                Text([light.localName, accountName(light).map { "Govee Home: \($0)" }, "\(light.rssi) dBm"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if light.profile == nil {
                    Text("Recognised, but Luma has no verified Bluetooth profile for this model yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let limit = light.profile?.limitation {
                    Text(limit).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if light.profile != nil {
                Button(ble.connectedID == light.id ? "Connected" : "Connect") { ble.connect(light.id) }
                    .disabled(ble.connectedID != nil)
            }
        }
    }

    /// Joined by the Bluetooth name Govee Home stores for each light.
    private func accountName(_ light: BluetoothLights.Nearby) -> String? {
        guard !light.localName.isEmpty,
              let id = store.accountEntries.first(where: { $0.value.bleName?.caseInsensitiveCompare(light.localName) == .orderedSame })?.key else { return nil }
        return store.devices.first { $0.id == id }.map { $0.customName ?? $0.name }
    }

    // MARK: Connected light

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: ble.connected?.profile?.name ?? "Light", detail: phaseText) {
                if ble.connectedID != nil { Button("Disconnect") { ble.disconnect() } }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    if case .failed(let message) = ble.phase { InlineMessage(text: message) }
                    if ble.phase == .ready, let profile = ble.profile {
                        Text([ble.encryptionLabel, ble.readback.firmware.map { "Firmware \($0)" }, ble.readback.hardware.map { "Hardware \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let limit = profile.limitation { Text(limit).font(.system(size: 11)).foregroundStyle(.secondary) }
                        controls(profile)
                        if profile.supports(.videoMode) { videoMode }
                        if profile.supports(.dreamView) { dreamView(profile) }
                    } else if ble.connectedID != nil {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(phaseText).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var phaseText: String {
        switch ble.phase {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .securing: "Securing the connection…"
        case .reading: "Reading state…"
        case .ready: "Connected"
        case .failed: "Disconnected"
        }
    }

    @ViewBuilder private func controls(_ profile: GoveeBLEProfile) -> some View {
        Toggle("Power", isOn: Binding(get: { ble.readback.power ?? false }, set: { ble.send(GoveeBLE.power($0), thenRead: GoveeBLE.Query.power.frame) }))
            .disabled(ble.readback.power == nil)
        VStack(alignment: .leading, spacing: 4) {
            Text("Brightness \(ble.readback.brightness.map { "\($0)%" } ?? "—")").font(.system(size: 12))
            Slider(value: $brightness, in: 1...100, step: 1) { editing in
                if !editing, let frame = try? GoveeBLE.brightness(Int(brightness)) { ble.send(frame, thenRead: GoveeBLE.Query.brightness.frame) }
            }
            .disabled(ble.readback.brightness == nil)
            .onChange(of: ble.readback.brightness) { _, value in if let value { brightness = Double(max(value, 1)) } }
        }
        if profile.supports(.color) {
            ColorPicker("Color", selection: $color, supportsOpacity: false)
                .onChange(of: color) { _, value in
                    guard let rgb = rgbValue(of: value) else { return }
                    // Dragging in the picker sends only where it settles.
                    colorSend?.cancel()
                    colorSend = Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        ble.send(GoveeBLE.color(red: UInt8(rgb >> 16 & 0xFF), green: UInt8(rgb >> 8 & 0xFF), blue: UInt8(rgb & 0xFF), mask: profile.wholeMask),
                                 thenRead: GoveeBLE.Query.colorMode.frame)
                    }
                }
        }
    }

    /// The backlight's own camera mode. Editable only once the light reports it is
    /// in video mode, so sound settings Luma doesn't show are sent back unchanged.
    @ViewBuilder private var videoMode: some View {
        Divider()
        Text("Video mode").font(.system(size: 13, weight: .semibold))
        if case .video(let source?, let whole?, let saturation, let sound, let softness)? = ble.readback.mode {
            let apply = { (s: GoveeBLE.VideoSource, w: Bool, sat: Int) in
                if let frame = try? GoveeBLE.videoMode(s, wholeScreen: w, saturation: sat, soundEffects: sound, softness: softness) { ble.send(frame, thenRead: GoveeBLE.Query.colorMode.frame) }
            }
            Picker("Content", selection: Binding(get: { source }, set: { apply($0, whole, max(saturation, 1)) })) {
                Text("Movie").tag(GoveeBLE.VideoSource.movie); Text("Game").tag(GoveeBLE.VideoSource.game)
            }.pickerStyle(.segmented)
            Picker("Area", selection: Binding(get: { whole }, set: { apply(source, $0, max(saturation, 1)) })) {
                Text("All").tag(true); Text("Part").tag(false)
            }.pickerStyle(.segmented)
            Stepper("Saturation \(saturation)", value: Binding(get: { max(saturation, 1) }, set: { apply(source, whole, $0) }), in: 1...100, step: 5)
        } else {
            Text("Start Video mode in Govee Home or with the light's button; Luma then shows Movie/Game, All/Part and saturation here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// DreamView group settings on the controller. Each control appears only after
    /// the light reported that setting in this session.
    @ViewBuilder private func dreamView(_ profile: GoveeBLEProfile) -> some View {
        let r = ble.readback
        Divider()
        Text("DreamView group").font(.system(size: 13, weight: .semibold))
        Text("Settings for the group already set up in Govee Home. Members can't be read or changed over Bluetooth yet.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        if let enabled = r.groupEnabled {
            Toggle("Group sync", isOn: Binding(get: { enabled }, set: { ble.send(GoveeBLE.DreamView.setEnabled($0), thenRead: GoveeBLE.DreamView.query(.switchGroup)) }))
        }
        if let area = r.groupApplyArea, let content = r.groupContentMode, area <= 1, content <= 1 {
            let set = { (whole: Bool, movie: Bool) in ble.send(GoveeBLE.DreamView.setVideo(wholeScreen: whole, movie: movie), thenRead: GoveeBLE.DreamView.query(.videoSettings)) }
            Picker("Group content", selection: Binding(get: { content == 1 }, set: { set(area == 0, $0) })) { Text("Movie").tag(true); Text("Game").tag(false) }.pickerStyle(.segmented)
            Picker("Group area", selection: Binding(get: { area == 0 }, set: { set($0, content == 1) })) { Text("All").tag(true); Text("Part").tag(false) }.pickerStyle(.segmented)
        } else if r.groupApplyArea != nil {
            Text("The light reported group video values Luma doesn't recognise, so they aren't editable.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let saturation = r.groupSaturation {
            Stepper("Group saturation \(saturation)", value: Binding(get: { saturation }, set: { v in (try? GoveeBLE.DreamView.setSaturation(v)).map { ble.send($0, thenRead: GoveeBLE.DreamView.query(.saturation)) } }), in: 0...100, step: 5)
        }
        if let slots = r.memberSlots {
            Text("Member connection slots (raw, up to \(profile.dreamViewMemberLimit) used): " + slots.map { String(format: "%02X", $0) }.joined(separator: " "))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    // MARK: Capture

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "DreamView members from a capture") {
                Button("Read Capture…") { importingCapture = true }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Govee Home sends the whole member list, with each light's command version, when it saves a DreamView group. Capture that Bluetooth traffic (PacketLogger or Wireshark), export one line per frame as W <hex> for writes and N <hex> for notifications, and Luma decodes it here, encrypted or not. Nothing is sent to your lights.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    switch capture {
                    case .success(let report)?: CodeBlock(text: report.summary)
                    case .failure(let error)?: InlineMessage(text: error.localizedDescription)
                    case nil: EmptyView()
                    }
                }
            }
        }
    }

    private func readCapture(_ result: Result<URL, any Error>) {
        capture = Result {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 16 * 1024 * 1024 else { throw LumaError.message("That capture is too large.") }
            return try GoveeBLECapture.decode(String(decoding: data, as: UTF8.self))
        }
    }
}
#endif
