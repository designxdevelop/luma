import SwiftUI
import LumaCore

struct DeviceSheet: View {
    let store: HomeStore
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.light
    @State private var room = ""
    @State private var name = ""
    @State private var roomMessage: String?
    @State private var instance = ""
    @State private var json = "1"
    @State private var effectMessage: (text: String, isError: Bool)?
    @State private var loadingScenes = false
    @State private var sending = false
    @State private var refreshing = false
    @State private var showAdvanced = false

    private enum Tab: String, CaseIterable, Identifiable {
        case light = "Light", effects = "Effects", details = "Details"
        var id: Self { self }
    }

    var device: LightDevice? { store.devices.first { $0.id == deviceID } }
    /// Features beyond the four basic controls, which live on the Light tab.
    /// Scene lists have their own browser above, so they aren't repeated here.
    private func features(_ device: LightDevice) -> [Capability] {
        device.capabilities.filter { !basicInstances.contains($0.instance) && GoveeSceneOption.Kind(rawValue: $0.instance) == nil }
    }
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
            room = device.room; name = device.name
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
        DeviceReadingsCard(readings: store.readings[device.id]?.list ?? [], readAt: store.readings[device.id]?.at)
        if DreamView.capability(of: device) != nil { DreamViewCard(store: store, device: device) }
        Card { BrightnessSlider(store: store, device: device) }
        ColorCard(store: store, device: device)
        WhiteCard(store: store, device: device)
    }

    // MARK: Effects tab

    @ViewBuilder private func effectsTab(_ device: LightDevice) -> some View {
        if GoveeSceneLibrary.advertisesScenes(device) {
            // Built-in, DIY, and snapshot scenes: searchable, one tap applies.
            Card { GoveeSceneList(store: store, lights: [device], target: device.name) }
                // Built-in scenes download once on first visit when the model has them but none are loaded.
                .task(id: device.id) {
                    let empty = device.capabilities.first { $0.instance == "lightScene" }?.parameters?["options"]?.array?.isEmpty ?? true
                    guard store.cloudConnected, !device.isDemo, device.supports("lightScene"), empty, !loadingScenes else { return }
                    loadingScenes = true; await store.loadDeviceScenes(device, diy: false); loadingScenes = false
                }
        }
        SegmentPainterCard(store: store, device: device)
        let list = features(device)
        if list.isEmpty {
            Card {
                EmptyState(icon: "wand.and.stars", title: GoveeSceneLibrary.advertisesScenes(device) ? "No other effects" : "No effects available yet",
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

    // MARK: Details tab

    @ViewBuilder private func detailsTab(_ device: LightDevice) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Name")
                HStack(spacing: 8) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { saveName() }
                        .onChange(of: name) { _, value in if value.count > 64 { name = String(value.prefix(64)) } }
                    Button("Save") { saveName() }
                    if let own = store.home.devices.first(where: { $0.id == deviceID }), own.customName != nil {
                        Button("Reset") { store.rename("", id: deviceID); name = own.name }.help("Use the name \(own.name) from the light")
                    }
                }
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
            if !device.isDemo { Button("Copy Compatibility Report") { copyToPasteboard(CompatibilityReport.text(for: [device], app: "Luma \(Links.version)")) }
                .help("Copy this model's features for an issue report. No device ID, name, or network address is included.") }
        }
    }

    private func saveName() {
        store.rename(name, id: deviceID)
        name = device?.name ?? name
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

/// DreamView has its own card on the Light tab, so it is not repeated as a generic feature.
private let basicInstances = ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK", DreamView.instance]

// MARK: - DreamView

/// Starts or stops the DreamView group set up in Govee Home through Govee's
/// documented cloud toggle. Members and video settings stay in Govee Home:
/// the cloud API cannot read or change them.
private struct DreamViewCard: View {
    let store: HomeStore
    let device: LightDevice
    @State private var sending: Bool?
    @State private var message: (text: String, isError: Bool)?

    private var available: Bool { device.isDemo || store.cloudConnected }
    private var stateText: String {
device.dreamView.map { $0 ? "On" : "Off" } ?? "Not reported"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "DreamView TV sync", detail: nil) {
                    Text(stateText).font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityLabel("DreamView sync state: \(stateText)")
                }
                Text("Starts or stops the DreamView group you set up in Govee Home, so its lights follow this backlight's camera.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    syncButton(on: true).buttonStyle(.borderedProminent)
                    syncButton(on: false)
                    Spacer()
                }.disabled(!available || sending != nil)
                Button("Save Movie Scene") { saveMovieScene() }
                    .disabled(!available)
                    .help("Save a scene that turns this light on, then starts DreamView sync")
                if let message { InlineMessage(text: message.text, isError: message.isError) }
                if !available {
                    Text("Connect your Govee account in Settings. DreamView is only available through Govee's cloud.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DreamViewPartners(store: store, device: device)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Set up in Govee Home", systemImage: "info.circle").font(.system(size: 11, weight: .medium))
                    Text("Movie or Game, All or Part, and saturation are set in Govee Home. Govee accepting a command doesn't confirm the lights are syncing.")
                    if device.supports("movieMode") {
                        Text("Movie mode under Effects is this light's own video effect, not DreamView, and choosing it may stop a running group.")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func syncButton(on: Bool) -> some View {
        Button { send(on: on) } label: {
            HStack(spacing: 6) { if sending == on { ProgressView().controlSize(.small) }; Text(on ? "Start Sync" : "Stop Sync") }
        }.help(on ? "Start the DreamView group set up in Govee Home" : "Stop DreamView sync")
    }

    private func send(on: Bool) {
        sending = on
        Task {
            do {
                try await store.send(try DreamView.command(on: on, for: device), to: device.id)
                let verb = on ? "Start Sync" : "Stop Sync"
                message = (device.isDemo ? "Sample light updated: \(verb)" : "Govee accepted \(verb)", false)
            } catch { message = (error.localizedDescription, true) }
            sending = nil
        }
    }

    private func saveMovieScene() {
        do { try store.saveScene(try DreamView.movieScene(for: device)); message = ("Saved to Scenes", false) }
        catch { message = (error.localizedDescription, true) }
    }
}

/// Partner lights, kept in two clearly separate parts: what Govee Home reports
/// for the group (name and light count; members aren't shared) and a local Luma
/// draft that is never sent. Apply stays disabled with the reason.
private struct DreamViewPartners: View {
    let store: HomeStore
    let device: LightDevice
    @State private var draft = DreamViewDraft()
    @State private var checking = false
    @State private var checkError: String?

    private var candidates: [LightDevice] { store.devices.filter { $0.id != device.id && $0.isDemo == device.isDemo } }
    private var limit: Int? { DreamViewDraft.memberLimit(sku: device.sku) }
    private var group: GoveeHomeImport.HomeGroup? { store.dreamViewGroup(for: device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label("On your lights", systemImage: "checkmark.seal").font(.system(size: 12, weight: .medium))
                if let group {
                    Text(group.name).font(.system(size: 12, weight: .semibold))
                    Text(groupText(group)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(store.accountGroups.isEmpty
                         ? (store.accountSignedIn ? "Check Govee Home to show the DreamView group set up for this light." : "Sign in to Govee Home in Settings to show the DreamView group set up for this light.")
                         : "No imported DreamView group lists this light as its main light.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if store.accountSignedIn && !device.isDemo {
                    Button { check() } label: {
                        HStack(spacing: 6) { if checking { ProgressView().controlSize(.small) }; Text(store.accountGroups.isEmpty ? "Check Govee Home" : "Check Again") }
                    }.controlSize(.small).disabled(checking)
                }
                if let checkError { InlineMessage(text: checkError) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Luma draft", systemImage: "pencil.and.list.clipboard").font(.system(size: 12, weight: .medium))
                    Text("Not sent to lights").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                    Spacer()
                    Text("\(draft.members.count)/\(limit.map(String.init) ?? "?") members").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(limit == nil ? "This model's member limit isn't known" : "Member limit for \(device.sku)")
                }
                if candidates.isEmpty { Text("No other lights in Luma yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(candidates) { light in memberRow(light) }
                Button("Apply to Lights") {}.disabled(true).help(DreamViewDraft.applyBlocker)
                Text(DreamViewDraft.applyBlocker).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .onAppear { draft = store.dreamViewDraft(for: device.id) }
    }

    private func groupText(_ group: GoveeHomeImport.HomeGroup) -> String {
        let count = group.reportedLightCount.map { "Govee Home reports \($0) light\($0 == 1 ? "" : "s") in this group" } ?? "Light count not reported"
        return count + (group.enabled ? "" : " · turned off in Govee Home") + ". Luma can't read which lights are in it, or their screen areas, yet."
    }
    private func check() {
        checking = true; checkError = nil
        Task {
            do { try await store.refreshAccountGroups() } catch { checkError = error.localizedDescription }
            checking = false
        }
    }

    @ViewBuilder private func memberRow(_ light: LightDevice) -> some View {
        let index = draft.members.firstIndex { $0.deviceID == light.id }
        let entry = store.accountEntries[light.id]
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { index != nil }, set: { toggle(light, on: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name).font(.system(size: 12, weight: .medium))
                    Text(entry == nil ? "\(light.sku) · Bluetooth identity unknown" : (entry?.bleName ?? entry?.bleAddress) != nil ? "\(light.sku) · Bluetooth identity from Govee Home" : "\(light.sku) · no Bluetooth identity in Govee Home")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .disabled(index == nil && limit.map { draft.members.count >= $0 } == true)
            if let index {
                HStack(spacing: 3) {
                    ForEach(Array(DreamViewDraft.areas), id: \.self) { area in
                        let on = draft.members[index].areas.contains(area)
                        Button("\(area)") { setArea(area, on: !on, at: index) }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium, design: .rounded))
                            .frame(width: 22, height: 20)
                            .background(on ? Color.lumaAccent : Color.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .accessibilityLabel("Screen area \(area) for \(light.name)").accessibilityValue(on ? "On" : "Off")
                    }
                }.padding(.leading, 20)
                .help("Screen areas 1–10 use ha-govee-led-ble's numbering; their positions on screen aren't verified")
            }
        }
    }

    private func toggle(_ light: LightDevice, on: Bool) {
        if on { draft.members.append(.init(deviceID: light.id, areas: [1])) } else { draft.members.removeAll { $0.deviceID == light.id } }
        store.saveDreamViewDraft(draft, for: device.id)
    }
    private func setArea(_ area: Int, on: Bool, at index: Int) {
        var areas = Set(draft.members[index].areas)
        if on { areas.insert(area) } else if areas.count > 1 { areas.remove(area) }
        draft.members[index].areas = areas.sorted()
        store.saveDreamViewDraft(draft, for: device.id)
    }
}

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
