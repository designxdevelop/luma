import SwiftUI
import LumaCore

struct DeviceSheet: View {
    let store: HomeStore
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var mode = Mode.color
    @State private var instance = ""
    @State private var json = "1"
    @State private var effectMessage: (text: String, isError: Bool)?
    @State private var loadingScenes = false
    @State private var loadingDIY = false
    @State private var sending = false
    @State private var refreshing = false
    @State private var showAdvanced = false
    @State private var savingLook = false
    @State private var lookName = ""
    @State private var lookMessage: (text: String, isError: Bool)?

    private enum Mode: String { case color = "Color", white = "White" }
    enum Route: Hashable { case effects, name, details }

    var device: LightDevice? { store.devices.first { $0.id == deviceID } }
    /// Features beyond the four basic controls, which live on the main page.
    private func features(_ device: LightDevice) -> [Capability] { device.capabilities.filter { !basicInstances.contains($0.instance) } }
    private var cap: Capability? { device.flatMap { features($0).first { $0.instance == instance } } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let device {
                    ScrollView { main(device).padding(compactSpacing(24, 16)) }
                        .navigationDestination(for: Route.self) { route in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    switch route {
                                    case .effects: effectsTab(device)
                                    case .name: NameRoomForm(store: store, deviceID: deviceID) { path.removeLast() }
                                    case .details: detailsTab(device)
                                    }
                                }.padding(compactSpacing(24, 16))
                            }
                            .background(Color.canvas)
                            .navigationTitle(route == .effects ? "Effects" : route == .name ? "Name & room" : "About this light")
                            .inlineNavigationTitle()
                        }
                } else {
                    EmptyState(icon: "lightbulb.slash", title: "This light is no longer available", message: "It may have been removed from your account or the network.")
                        .frame(maxHeight: .infinity)
                }
            }
            .background(Color.canvas)
            #if os(macOS)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) } }
            #endif
        }
        .sheetFrame(width: 560, height: 720)
        #if os(iOS)
        // Paper 02: a grabber, no Done button; swipe down to dismiss.
        .presentationDragIndicator(.visible)
        #endif
        .onAppear {
            guard let device else { return }
            mode = (device.colorTemperature ?? 0) > 0 || !device.supports("colorRgb") ? .white : .color
            instance = features(device).first?.instance ?? ""; resetValue()
        }
        .onChange(of: instance) { _, _ in resetValue() }
        .onChange(of: device.map { features($0).map(\.instance) }) { _, list in
            if let list, !list.contains(instance) { instance = list.first ?? "" }
        }
        .alert("Save this look as a scene", isPresented: $savingLook) {
            TextField("Scene name", text: $lookName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveLook() }
        } message: { Text("Saves this light's current power, brightness, and color.") }
    }

    // MARK: Main page

    @ViewBuilder private func main(_ device: LightDevice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(device)
            VStack(alignment: .leading, spacing: 6) {
                BrightnessBar(store: store, device: device)
                Text(device.connection == .local ? "Drag anywhere on the bar · confirmed by the light" : "Drag anywhere on the bar")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            let color = device.supports("colorRgb"), white = device.supports("colorTemperatureK")
            if color && white {
                Picker("Light mode", selection: $mode) { Text("Color").tag(Mode.color); Text("White").tag(Mode.white) }
                    .pickerStyle(.segmented).labelsHidden()
            }
            if color && (mode == .color || !white) { ColorCard(store: store, device: device) }
            if white && (mode == .white || !color) { WhiteCard(store: store, device: device) }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    row(.effects, icon: "wand.and.stars", title: "Effects", detail: "Govee scenes, music, segments")
                    Divider().padding(.leading, 60)
                    row(.name, icon: "pencil", title: "Name & room", detail: "Rename it, move it to a room")
                    Divider().padding(.leading, 60)
                    row(.details, icon: "info.circle", title: "About this light", detail: "Model, connection, device ID, refresh")
                }
            }
            VStack(spacing: 6) {
                Button { lookName = device.name; savingLook = true } label: {
                    Label("Save this look as a scene", systemImage: "plus").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(Color.lumaAccent)
                if let lookMessage { InlineMessage(text: lookMessage.text, isError: lookMessage.isError) }
            }
        }
    }

    private func header(_ device: LightDevice) -> some View {
        HStack(spacing: 14) {
            LightOrb(device: device, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Button { path.append(.name) } label: {
                    HStack(spacing: 6) {
                        Text(device.name).font(.system(size: 22, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .help("Rename").accessibilityLabel("\(device.name). Rename")
                HStack(spacing: 6) {
                    Text(device.room).lineLimit(1)
                    Text("·")
                    Label(device.connection.label, systemImage: device.connection.icon).labelStyle(.titleAndIcon)
                        .foregroundStyle(device.connection == .offline ? Color.danger : .secondary)
                    if let status = store.controlStatus(for: deviceID) { StatusPill(text: status, tint: .lumaAccent, busy: true) }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary).help(device.connection.help)
            }
            Spacer(minLength: 8)
            Toggle("Power", isOn: Binding(get: { store.devices.first { $0.id == deviceID }?.power ?? false },
                                          set: { value in store.perform(.power(value), ids: [deviceID]) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!device.supports("powerSwitch"))
                .help("Turn \(device.name) on or off")
                .accessibilityLabel("Power for \(device.name)")
        }
    }

    private func row(_ route: Route, icon: String, title: String, detail: String) -> some View {
        Button { path.append(route) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.primary)
                    .frame(width: 32, height: 32).background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).frame(minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func saveLook() {
        let name = lookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { lookMessage = ("Give the scene a name.", true); return }
        do { try store.captureScene(name: name, ids: [deviceID]); lookMessage = ("Saved “\(name)” to Scenes", false) }
        catch { lookMessage = (error.localizedDescription, true) }
    }

    // MARK: Effects

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

    // MARK: Details

    @ViewBuilder private func detailsTab(_ device: LightDevice) -> some View {
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
                        Button { copyToPasteboard(device.id) } label: { Image(systemName: "doc.on.doc").frame(width: 32, height: 32) }
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
    @State private var send: Task<Void, Never>?
    private static let presets: [(name: String, rgb: Int)] = [
        ("Red", 0xFF3B30), ("Orange", 0xFF9500), ("Yellow", 0xFFD60A), ("Green", 0x34C759),
        ("Teal", 0x00C7BE), ("Blue", 0x0A84FF), ("Purple", 0xAF52DE), ("Pink", 0xFF2D95),
    ]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if device.supports("colorRgb") {
                    HStack(spacing: 0) {
                        ForEach(Self.presets, id: \.rgb) { preset in
                            let selected = colorActive && device.rgb == preset.rgb
                            Button { store.perform(.rgb(preset.rgb), ids: [device.id]) } label: {
                                Circle().fill(Color(rgb: preset.rgb)).frame(width: 32, height: 32)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(preset.name)
                            .accessibilityLabel(preset.name).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    Divider()
                    // Paper 02: "Custom · Now showing". "Now showing" only once the light reports it;
                    // while a change is unconfirmed the row shows the pending status instead.
                    let isCustom = colorActive && !Self.presets.contains { $0.rgb == device.rgb }
                    HStack(spacing: 12) {
                        Circle().fill(Color(rgb: device.rgb ?? 0xFFAA66)).frame(width: 30, height: 30)
                            .padding(3).overlay(Circle().strokeBorder(isCustom ? Color.primary : Color.primary.opacity(0.12), lineWidth: isCustom ? 2 : 1))
                            .accessibilityHidden(true)
                        Text("Custom").font(.body)
                        if colorActive {
                            Text(store.controlStatus(for: device.id) ?? "Now showing").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Not active").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        ColorPicker("Custom color", selection: Binding(get: { custom }, set: { custom = $0; choose($0) }), supportsOpacity: false).labelsHidden()
                            .frame(minWidth: 44, minHeight: 44)
                            .help("Choose any color")
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("This light doesn't support color.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { custom = Color(rgb: device.rgb ?? 0xFFAA66) }
    }
    /// White mode reports a temperature; a zero or missing one means color mode.
    /// Only the person's picks reach here (not onAppear). Picker drags fire continuously; send the color it settles on.
    private func choose(_ color: Color) {
        send?.cancel()
        guard let rgb = rgbValue(of: color), rgb != device.rgb else { return }
        send = Task { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { store.perform(.rgb(rgb), ids: [device.id]) } }
    }
    private var colorActive: Bool { device.rgb != nil && (device.colorTemperature ?? 0) <= 0 }
}

// MARK: - White

/// Kelvin slider follows `BrightnessBar`'s draft pattern: a local draft while
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
                                VStack(spacing: 2) {
                                    Text(preset.name).font(.system(size: 14, weight: .semibold))
                                    Text("\(value) K").font(.system(size: 12)).monospacedDigit().opacity(0.75)
                                }
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(selected ? Color.lumaAccentFill : Color.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("\(preset.name) white, \(value) K")
                            .accessibilityLabel("\(preset.name), \(value) kelvin").accessibilityAddTraits(selected ? .isSelected : [])
                        }
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

// MARK: - Name & room

/// Standalone sheet for long-press Rename…/Move to room and the "Name it" chip.
struct NameRoomSheet: View {
    let store: HomeStore
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { NameRoomForm(store: store, deviceID: deviceID) { dismiss() }.padding(compactSpacing(24, 16)) }
                .background(Color.canvas)
                .navigationTitle("Name & room").inlineNavigationTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheetFrame(width: 480, height: 560)
    }
}

/// Local-only name (max 64 characters) and room. Saves on Save; Cancel leaves both alone.
struct NameRoomForm: View {
    let store: HomeStore
    let deviceID: String
    let done: () -> Void
    @State private var name = ""
    @State private var room = ""
    @State private var addingRoom = false
    @State private var newRoom = ""
    @FocusState private var nameFocused: Bool
    static let limit = 64
    private var own: LightDevice? { store.home.devices.first { $0.id == deviceID } }
    private var saveDisabled: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && own?.customName == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NAME").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Name", text: $name).font(.system(size: 17, weight: .semibold)).textFieldStyle(.plain).focused($nameFocused)
                        .onSubmit(save).accessibilityLabel("Light name")
                    Text("\(name.count)/\(Self.limit)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("\(name.count) of \(Self.limit) characters")
                    if !name.isEmpty {
                        Button { name = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 32, height: 32) }
                            .buttonStyle(.plain).accessibilityLabel("Clear name")
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(nameFocused ? Color.lumaAccent : Color.hairline, lineWidth: nameFocused ? 1.5 : 1))
                .onChange(of: name) { _, value in if value.count > Self.limit { name = String(value.prefix(Self.limit)) } }
                if let own {
                    Label { Text("Only Luma uses this name. Govee Home still calls it **\(own.name)**.") } icon: { Image(systemName: "info.circle") }
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if own.customName != nil {
                        Button { store.rename("", id: deviceID); name = own.name } label: {
                            Label("Use original name", systemImage: "arrow.counterclockwise").font(.system(size: 14, weight: .semibold)).frame(minHeight: 44)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.lumaAccent)
                        .help("Go back to \(own.name)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("ROOM").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                FlowRow(spacing: 8) {
                    ForEach(Array(Set(store.rooms + [room]).filter { !$0.isEmpty }).sorted(), id: \.self) { option in
                        let selected = option == room
                        Button { room = option } label: {
                            Label { Text(option) } icon: { Image(systemName: selected ? "checkmark" : roomSymbol(option)) }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(selected ? Color.lumaAccentFill : Color.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.hairline))
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Button { addingRoom = true } label: {
                        Label("New room", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
                Text("Rooms group your lights on Home and let you switch a whole room at once.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            #if os(macOS)
            Button(action: save) { Text("Save").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
            #endif
        }
        #if os(iOS)
        // Paper 04: Save sits in the navigation bar on iPhone and iPad.
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold).disabled(saveDisabled) } }
        #endif
        .onAppear {
            guard let own else { return }
            name = own.customName ?? own.name; room = own.room
        }
        .alert("New room", isPresented: $addingRoom) {
            TextField("Room name", text: $newRoom)
            Button("Cancel", role: .cancel) { newRoom = "" }
            Button("Add") {
                let value = newRoom.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { room = String(value.prefix(Self.limit)) }
                newRoom = ""
            }
        } message: { Text("Rooms are just names. Type one to group lights.") }
    }

    private func save() {
        store.rename(name, id: deviceID)
        if !room.isEmpty, room != own?.room { store.assignRoom(room, id: deviceID) }
        done()
    }
}

/// Wraps children onto new lines, left-aligned.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

extension View {
    /// Inline titles for pushed sheet pages on iOS; the Mac has no title display modes.
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
