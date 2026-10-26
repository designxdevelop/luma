import SwiftUI
import LumaCore

struct LightsView: View {
    let store: HomeStore
    let room: String?
    @Binding var connecting: Bool
    @State private var selected: LightDevice?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 236, maximum: 360), spacing: 14)]

    var shown: [LightDevice] {
        store.devices.filter { (room == nil || $0.room == room) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.sku.localizedCaseInsensitiveContains(search) || $0.room.localizedCaseInsensitiveContains(search)) }
    }
    /// Group by room on the overview when there's more than one room.
    private var groups: [(room: String, lights: [LightDevice])] {
        let lights = shown
        guard room == nil, Set(lights.map(\.room)).count > 1 else { return [(room ?? "", lights)] }
        return Dictionary(grouping: lights, by: \.room).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: room ?? "Lights", subtitle: subtitle) {
                    if !store.devices.isEmpty {
                        searchField
                        powerButtons(for: shown, label: room == nil ? "all lights" : "lights in \(room!)")
                    }
                    Button { store.discover() } label: {
                        Label(store.scanning ? "Looking…" : "Find Lights", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(store.scanning || store.demo)
                    .help(store.demo ? "Leave the demo home to find real lights." : "Look for LAN-enabled Govee lights on this Wi-Fi network")
                }
                if store.devices.isEmpty { onboarding }
                else {
                    if room == nil && !store.home.scenes.isEmpty && search.isEmpty { scenesStrip }
                    ForEach(groups, id: \.room) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            if groups.count > 1 {
                                SectionHeader(title: group.room, detail: "\(group.lights.filter { $0.power == true }.count) of \(group.lights.count) on") {
                                    powerButtons(for: group.lights, label: "lights in \(group.room)").controlSize(.small)
                                }
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(group.lights) { device in
                                    LightCard(store: store, device: device, showsRoom: room == nil && groups.count == 1 && store.rooms.count > 1) { selected = device }
                                }
                            }
                        }
                    }
                    if shown.isEmpty {
                        EmptyState(icon: "magnifyingglass", title: "No matching lights", message: "Nothing matches “\(search)”. Try a light's name, model, or room.") {
                            Button("Clear Search") { search = "" }
                        }
                    }
                    Label("Local lights confirm changes directly. Cloud lights confirm once Govee reports back, which can take a few seconds.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .background { Button("Find") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true) }
        .sheet(item: $selected) { device in DeviceSheet(store: store, deviceID: device.id) }
    }

    private var subtitle: String {
        let lights = room == nil ? store.devices : store.devices.filter { $0.room == room }
        if lights.isEmpty { return store.scanning ? "Looking for lights on your Wi-Fi…" : "Bring your Govee lights together on your Mac." }
        let on = lights.filter { $0.power == true }.count
        let offline = lights.filter { $0.online == false }.count
        var parts = [on == 0 ? "All \(lights.count) off" : on == lights.count ? "All \(lights.count) on" : "\(on) of \(lights.count) on"]
        if offline > 0 { parts.append("\(offline) offline") }
        if store.scanning { parts.append("Looking for more…") }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search", text: $search).textFieldStyle(.plain).focused($searchFocused).onExitCommand { search = ""; searchFocused = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).frame(width: 190, height: 28)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(searchFocused ? Color.lumaAccent.opacity(0.6) : Color.hairline))
        .help("Search lights (⌘F)")
        .accessibilityLabel("Search lights")
    }

    private func powerButtons(for lights: [LightDevice], label: String) -> some View {
        let ids = lights.filter { $0.supports("powerSwitch") }.map(\.id)
        return HStack(spacing: 6) {
            Button { store.perform(.power(true), ids: ids) } label: { Label("All On", systemImage: "lightbulb.max") }
                .help("Turn on \(label)").accessibilityLabel("Turn on \(label)")
            Button { store.perform(.power(false), ids: ids) } label: { Label("All Off", systemImage: "lightbulb.slash") }
                .help("Turn off \(label)").accessibilityLabel("Turn off \(label)")
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .disabled(ids.isEmpty)
    }

    private var scenesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Scenes", detail: "Click to set the mood")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.home.scenes) { scene in SceneChip(store: store, scene: scene) }
                }.padding(1)
            }
        }
    }

    private var onboarding: some View {
        Card(padding: 32) {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(RadialGradient(colors: [Color(rgb: 0xFFB866).opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: 70)).frame(width: 140, height: 140)
                        Image(systemName: "lightbulb.led.wide.fill").font(.system(size: 44, weight: .medium)).foregroundStyle(Color.lumaAccent)
                    }.accessibilityHidden(true)
                    Text("Welcome to Luma").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                    Text("Control your Govee lights from your Mac: quick power and brightness, color, scenes, schedules, and automations.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                HStack(alignment: .top, spacing: 14) {
                    step(1, icon: "cloud", title: "Connect your account", text: "Use a Govee API key to find every light on your account, including effects and segments.") {
                        Button("Connect Account…") { connecting = true }.buttonStyle(.borderedProminent)
                    }
                    step(2, icon: "wifi", title: "Add local control", text: "Turn on LAN Control for each light in the Govee Home app, then look for lights on this Wi-Fi.") {
                        Button(store.scanning ? "Looking…" : "Find Lights") { store.discover() }.disabled(store.scanning)
                    }
                    step(3, icon: "sparkles", title: "Just looking?", text: "Explore a demo home with sample lights. Nothing real is controlled.") {
                        Button("Explore Demo") { store.demo = true; store.loadDemo() }
                    }
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private func step<Action: View>(_ n: Int, icon: String, title: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.lumaAccent).frame(width: 26, height: 26).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Step \(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action()
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SceneChip: View {
    let store: HomeStore
    let scene: LightScene
    @State private var hovering = false
    var body: some View {
        let running = store.runningSceneID == scene.id
        Button {
            if running { store.stopScene() }
            else { do { try store.runScene(scene) } catch { store.log(error.localizedDescription, error: true) } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: scene.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.lumaAccent)
                    .frame(width: 30, height: 30).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(scene.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(running ? "Running…" : "^[\(Set(scene.steps.map(\.deviceID)).count) light](inflect: true)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 10)).foregroundStyle(running ? Color.lumaAccent : .secondary).padding(.leading, 4)
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(running ? Color.lumaAccent.opacity(0.7) : hovering ? Color.primary.opacity(0.18) : Color.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.runningSceneID != nil && !running)
        .onHover { hovering = $0 }
        .help(running ? "Stop \(scene.name)" : "Run \(scene.name)")
        .accessibilityLabel(running ? "Stop \(scene.name)" : "Run \(scene.name)")
    }
}

struct LightCard: View {
    let store: HomeStore
    let device: LightDevice
    var showsRoom = false
    let open: () -> Void
    @State private var hovering = false
    private var isOn: Bool { device.power == true && device.online != false }
    private var stateText: String {
        if device.online == false { return "Offline" }
        switch device.power { case true?: return device.colorTemperature.map { $0 > 0 ? "On · \($0) K" : "On" } ?? "On"; case false?: return "Off"; case nil: return "No status yet" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: open) { LightOrb(device: device, size: 42) }
                    .buttonStyle(.plain).help("Open controls").accessibilityLabel("Open \(device.name) controls")
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(showsRoom ? "\(device.room) · \(stateText)" : stateText).font(.system(size: 11.5)).foregroundStyle(device.online == false ? Color.danger : .secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Opens controls")
                Toggle("Power for \(device.name)", isOn: Binding(get: { device.power ?? false }, set: { store.perform(.power($0), ids: [device.id]) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!device.supports("powerSwitch"))
            }
            BrightnessSlider(store: store, device: device)
            HStack(spacing: 6) {
                StatusPill(text: device.connection.label, icon: device.connection.icon, tint: device.connection.tint).help(device.connection.help)
                if let status = store.controlStatus(for: device.id) {
                    StatusPill(text: status, tint: .lumaAccent, busy: true).transition(.opacity)
                }
                Spacer(minLength: 4)
                Button(action: open) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Color, effects, and details").accessibilityLabel("More controls for \(device.name)")
            }
            .animation(.easeOut(duration: 0.15), value: store.controlStatus(for: device.id))
        }
        .padding(16)
        .background {
            ZStack {
                Color.surface
                if isOn { LinearGradient(colors: [device.displayColor.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .center) }
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Color.primary.opacity(0.16) : Color.hairline))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 8 : 3, y: hovering ? 3 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Turn On") { store.perform(.power(true), ids: [device.id]) }.disabled(!device.supports("powerSwitch"))
            Button("Turn Off") { store.perform(.power(false), ids: [device.id]) }.disabled(!device.supports("powerSwitch"))
            Divider()
            Button("Open Controls…", action: open)
            Button("Refresh State") { Task { await store.refresh(device) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name), \(stateText), \(device.connection.label)")
    }
}
