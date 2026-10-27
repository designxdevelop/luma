import SwiftUI
import LumaCore

struct DeviceSheet: View {
    let store: HomeStore
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.light
    @State private var room = ""
    @State private var roomMessage: String?
    @State private var instance = ""
    @State private var json = "1"
    @State private var effectMessage: (text: String, isError: Bool)?
    @State private var loadingScenes = false
    @State private var loadingDIY = false
    @State private var sending = false
    @State private var refreshing = false
    @State private var showAdvanced = false

    private enum Tab: String, CaseIterable, Identifiable {
        case light = "Light", effects = "Effects", details = "Details"
        var id: Self { self }
    }

    var device: LightDevice? { store.devices.first { $0.id == deviceID } }
    /// Features beyond the four basic controls, which live on the Light tab.
    private func features(_ device: LightDevice) -> [Capability] { device.capabilities.filter { !basicInstances.contains($0.instance) } }
    private var cap: Capability? { device.flatMap { features($0).first { $0.instance == instance } } }

    var body: some View {
        VStack(spacing: 0) {
            if let device {
                header(device)
                Picker("Section", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, compactSpacing(24, 16)).padding(.bottom, 16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch tab {
                        case .light: lightTab(device)
                        case .effects: effectsTab(device)
                        case .details: detailsTab(device)
                        }
                    }.padding(compactSpacing(24, 16))
                }
            } else {
                EmptyState(icon: "lightbulb.slash", title: "This light is no longer available", message: "It may have been removed from your account or the network.") {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }.frame(maxHeight: .infinity)
            }
        }
        .sheetFrame(width: 660, height: 720).background(Color.canvas)
        .onAppear {
            guard let device else { return }
            room = device.room
            instance = features(device).first?.instance ?? ""; resetValue()
        }
        .onChange(of: instance) { _, _ in resetValue() }
        .onChange(of: device.map { features($0).map(\.instance) }) { _, list in
            if let list, !list.contains(instance) { instance = list.first ?? "" }
        }
    }

    // MARK: Header

    private func header(_ device: LightDevice) -> some View {
        HStack(spacing: 16) {
            LightOrb(device: device, size: compactSpacing(52, 44))
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.system(size: 19, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text("\(device.room) · \(device.sku)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    StatusPill(text: device.connection.label, icon: device.connection.icon, tint: device.connection.tint).help(device.connection.help)
                    if let status = store.controlStatus(for: deviceID) { StatusPill(text: status, tint: .lumaAccent, busy: true) }
                }
            }
            Spacer(minLength: 12)
            Toggle("Power", isOn: Binding(get: { store.devices.first { $0.id == deviceID }?.power ?? false },
                                          set: { store.perform(.power($0), ids: [deviceID]) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!device.supports("powerSwitch"))
                .help("Turn \(device.name) on or off")
                .accessibilityLabel("Power for \(device.name)")
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(.horizontal, compactSpacing(24, 16)).padding(.top, 20).padding(.bottom, 16)
    }

    // MARK: Light tab

    @ViewBuilder private func lightTab(_ device: LightDevice) -> some View {
        Card { BrightnessSlider(store: store, device: device) }
        ColorCard(store: store, device: device)
        WhiteCard(store: store, device: device)
    }

    // MARK: Effects tab

    @ViewBuilder private func effectsTab(_ device: LightDevice) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Effect lists")
                Text("Download the scenes and DIY scenes available for this light from your Govee account.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    loadButton("Load Scenes", loading: loadingScenes) { loadingScenes = true; await store.loadDeviceScenes(device, diy: false); loadingScenes = false }
                    loadButton("Load DIY Scenes", loading: loadingDIY) { loadingDIY = true; await store.loadDeviceScenes(device, diy: true); loadingDIY = false }
                    Spacer()
                }
                if !store.cloudConnected { Text("Connect your Govee account in Settings to load effect lists.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        let list = features(device)
        if list.isEmpty {
            Card {
                EmptyState(icon: "wand.and.stars", title: "No effects available yet",
                           message: "Effects, music modes, and segments come from your Govee account — connect it in Settings. Some models only support basic control on your local network.")
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Feature")
                    Picker("Feature", selection: $instance) { ForEach(list) { Text(capabilityTitle($0.instance)).tag($0.instance) } }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    if let cap {
                        if let parameters = cap.parameters {
                            CapabilityValueForm(parameters: parameters, value: jsonValue(defaultingTo: parameters)).id(cap.id)
                        } else {
                            Text("This feature has no options to choose. Use Apply to send it, or open Advanced to adjust the value.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button { sendAdvanced(cap, to: device) } label: {
                                HStack(spacing: 6) { if sending { ProgressView().controlSize(.small) }; Text("Apply") }
                            }.buttonStyle(.borderedProminent)
                            Button("Save as Scene") { saveAdvanced(cap, device: device) }
                            Spacer()
                        }
                        if let effectMessage { InlineMessage(text: effectMessage.text, isError: effectMessage.isError) }
                        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Value (JSON)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                TextEditor(text: $json).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                                    .padding(6).frame(height: 110).background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .accessibilityLabel("Value in JSON")
                                Text("What this light reports").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Text(cap.parameters?.pretty ?? "This feature doesn't describe its options.")
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }.padding(.top, 8)
                        }.font(.system(size: 13))
                    }
                }
            }
        }
        Text("Only features this model reports are shown. Some Govee app features aren't available through Govee's API.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func loadButton(_ title: String, loading: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 6) { if loading { ProgressView().controlSize(.small) }; Text(title) }
        }
        .disabled(!store.cloudConnected)
        .help(store.cloudConnected ? "Download from your Govee account" : "Connect your Govee account in Settings first")
    }

    // MARK: Details tab

    @ViewBuilder private func detailsTab(_ device: LightDevice) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Room")
                HStack(spacing: 8) {
                    TextField("Room", text: $room).textFieldStyle(.roundedBorder).onSubmit { saveRoom() }
                    Menu {
                        ForEach(store.rooms, id: \.self) { name in Button(name) { room = name; saveRoom() } }
                    } label: { Label("Rooms", systemImage: "chevron.down") }
                        .menuStyle(.button).fixedSize().help("Choose an existing room")
                    Button("Save") { saveRoom() }
                }
                if let roomMessage { InlineMessage(text: roomMessage, isError: false) }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("About this light")
                LabeledContent("Model") { Text(device.sku).textSelection(.enabled) }
                LabeledContent("Connection") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(device.connection.label)
                        Text(device.connection.help).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                if let ip = device.ip { LabeledContent("Network address") { Text(ip).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) } }
                if let seen = device.lastSeen { LabeledContent("Last seen") { Text(seen.formatted(.relative(presentation: .named))) } }
                LabeledContent("Device ID") {
                    HStack(spacing: 6) {
                        Text(device.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Button { copyToPasteboard(device.id) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy device ID").accessibilityLabel("Copy device ID")
                    }
                }
            }.font(.system(size: 13))
        }
        HStack {
            Button {
                Task { refreshing = true; await store.refresh(device); refreshing = false }
            } label: {
                HStack(spacing: 6) { if refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }; Text("Refresh State") }
            }.help("Ask the light for its current state")
            Spacer()
        }
    }

    private func saveRoom() {
        let name = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.assignRoom(name, id: deviceID)
        roomMessage = "Moved to \(name)"
    }

    // MARK: Effect values

    /// Stays in sync with the raw JSON editor: the form reads and writes the same text.
    private func jsonValue(defaultingTo parameters: JSONValue) -> Binding<JSONValue> {
        Binding(get: { (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? defaultCapabilityValue(parameters) },
                set: { json = $0.pretty })
    }

    private func resetValue() {
        let fallback: String
        switch instance {
        case "powerSwitch": fallback = "1"
        case "brightness": fallback = String(device?.brightness ?? 50)
        case "colorRgb": fallback = String(device?.rgb ?? 0xFFAA66)
        case "colorTemperatureK": fallback = String(device?.colorTemperature ?? 3000)
        default: fallback = "{}"
        }
        if let parameters = cap?.parameters { json = defaultCapabilityValue(parameters).pretty }
        else { json = fallback }
        effectMessage = nil
    }

    private func command(_ cap: Capability) throws -> CapabilityCommand {
        do { return .init(type: cap.type, instance: cap.instance, value: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) }
        catch { throw LumaError.message("That value isn't valid. Check the options above or the JSON under Advanced.") }
    }

    private func sendAdvanced(_ cap: Capability, to device: LightDevice) {
        let cmd: CapabilityCommand
        do { cmd = try command(cap) } catch { effectMessage = (error.localizedDescription, true); return }
        sending = true
        Task {
            do { try await store.send(cmd, to: deviceID); effectMessage = ("Sent to \(device.name)", false) }
            catch { effectMessage = (error.localizedDescription, true) }
            sending = false
        }
    }

    private func saveAdvanced(_ cap: Capability, device: LightDevice) {
        do {
            try store.saveScene(.init(name: "\(device.name) · \(capabilityTitle(cap.instance))", steps: [.init(deviceID: deviceID, command: try command(cap))]))
            effectMessage = ("Saved to Scenes", false)
        } catch { effectMessage = (error.localizedDescription, true) }
    }
}

// MARK: - Color

private let basicInstances = ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK"]

private struct ColorCard: View {
    let store: HomeStore
    let device: LightDevice
    @State private var custom = Color.orange
    private static let presets: [(name: String, rgb: Int)] = [
        ("Red", 0xFF3B30), ("Orange", 0xFF9500), ("Yellow", 0xFFD60A), ("Green", 0x34C759),
        ("Teal", 0x00C7BE), ("Blue", 0x0A84FF), ("Purple", 0xAF52DE), ("Pink", 0xFF2D95),
    ]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Color", detail: colorActive ? device.rgb.map { String(format: "#%06X", $0) } : nil) {
                    if device.supports("colorRgb") && !colorActive { Text("Not active").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                if device.supports("colorRgb") {
                    HStack(spacing: compactSpacing(12, 6)) {
                        ForEach(Self.presets, id: \.rgb) { preset in
                            let selected = colorActive && device.rgb == preset.rgb
                            Button { store.perform(.rgb(preset.rgb), ids: [device.id]) } label: {
                                Circle().fill(Color(rgb: preset.rgb)).frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain).help(preset.name)
                            .accessibilityLabel(preset.name).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                        Spacer()
                        Button("Apply Color") {
                            if let rgb = rgbValue(of: custom) { store.perform(.rgb(rgb), ids: [device.id]) }
                        }.help("Send the chosen color to the light")
                    }
                } else {
                    Text("This light doesn't support color.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { custom = Color(rgb: device.rgb ?? 0xFFAA66) }
    }
    /// White mode reports a temperature; a zero or missing one means color mode.
    private var colorActive: Bool { device.rgb != nil && (device.colorTemperature ?? 0) <= 0 }
}

// MARK: - White

/// Kelvin slider follows `BrightnessSlider`'s draft pattern: a local draft while
/// dragging, immediate commits for non-drag edits, and a release commit only
/// if the freshest requested value differs. A missing or zero temperature means
/// the light is in color mode: the draft keeps its last usable value and nothing
/// is sent until the person changes white.
private struct WhiteCard: View {
    let store: HomeStore
    let device: LightDevice
    @State private var kelvin = 4000.0
    @State private var editing = false
    private static let presets: [(name: String, kelvin: Int)] = [("Warm", 2700), ("Neutral", 4000), ("Daylight", 6500)]

    private var range: ClosedRange<Double> {
        let r = device.capabilities.first { $0.instance == "colorTemperatureK" }?.parameters?["range"]
        let lo = r?["min"]?.number ?? 2000, hi = r?["max"]?.number ?? 9000
        return lo < hi ? lo...hi : 2000...9000
    }
    private func clamped(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
    /// The reported (or requested) temperature, only when white mode is active.
    private var activeKelvin: Int? { device.colorTemperature.flatMap { $0 > 0 ? $0 : nil } }
    private var valueText: String {
        if editing { return "\(Int(kelvin)) K" }
        if let activeKelvin { return "\(activeKelvin) K" }
        return device.rgb != nil ? "Color mode" : "Not active"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "White", detail: nil) {
                    Text(valueText).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                if device.supports("colorTemperatureK") {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.kelvin) { preset in
                            let value = Int(clamped(Double(preset.kelvin)))
                            let selected = activeKelvin == value
                            Button { kelvin = Double(value); store.perform(.kelvin(value), ids: [device.id]) } label: {
                                HStack(spacing: 4) {
                                    Text(preset.name).fontWeight(.medium)
                                    Text("\(value) K").monospacedDigit().opacity(0.75)
                                }
                                .font(.system(size: 12)).foregroundStyle(selected ? Color.white : Color.primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(selected ? Color.lumaAccentFill : Color.well, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain).help("\(preset.name) white, \(value) K")
                            .accessibilityLabel("\(preset.name), \(value) kelvin").accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 4) {
                        // No `step:` — it draws tick marks. Round to 50 K in the setter.
                        Slider(value: Binding(get: { kelvin }, set: { proposed in
                            let value = clamped((proposed / 50).rounded() * 50)
                            kelvin = value
                            if !editing { requestKelvin(value) }
                        }), in: range) { isEditing in
                            editing = isEditing
                            if !isEditing { requestKelvin(kelvin) }
                        }
                        .opacity(activeKelvin == nil && !editing ? 0.55 : 1)
                        .accessibilityLabel("White temperature for \(device.name)")
                        .accessibilityValue(activeKelvin.map { "\($0) kelvin" } ?? "Not active, light is in color mode")
                        LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { kelvinColor(Int(range.lowerBound + ($0 * (range.upperBound - range.lowerBound)))) },
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 6).clipShape(Capsule()).accessibilityHidden(true)
                        HStack {
                            Text("Warm"); Spacer(); Text("Cool")
                        }.font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    if activeKelvin == nil {
                        Text("The light is showing a color. Pick a preset or move the slider to switch to white.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("This light doesn't support adjustable white.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { if let activeKelvin { kelvin = clamped(Double(activeKelvin)) } }
        .onChange(of: device.colorTemperature) { _, value in
            if !editing, let value, value > 0 { kelvin = clamped(Double(value)) }
        }
    }

    private func requestKelvin(_ value: Double) {
        guard store.devices.first(where: { $0.id == device.id })?.colorTemperature != Int(value) else { return }
        store.perform(.kelvin(Int(value)), ids: [device.id])
    }
}

private func capabilityTitle(_ instance: String) -> String {
    let titles = ["powerSwitch": "Power", "brightness": "Brightness", "colorRgb": "Color", "colorTemperatureK": "White temperature", "segmentedBrightness": "Segment brightness", "segmentedColorRgb": "Segment color", "lightScene": "Scenes", "musicMode": "Music mode", "movieMode": "Movie mode", "diyScene": "DIY scenes", "snapshot": "Snapshots", "dreamViewToggle": "DreamView", "gradientToggle": "Gradient"]
    if let title = titles[instance] { return title }
    let text = instance.replacingOccurrences(of: "Toggle", with: "").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    return text.prefix(1).uppercased() + text.dropFirst()
}
