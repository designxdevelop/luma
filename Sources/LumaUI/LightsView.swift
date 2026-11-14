import SwiftUI
import LumaCore

enum HomeMode: String { case rooms, plan }

struct LightsView: View {
    let store: HomeStore
    let room: String?
    @Binding var connecting: Bool
    @State private var selected: LightDevice?
    @State private var naming: LightDevice?
    @State private var search = ""
    @AppStorage("homeMode") private var mode = HomeMode.rooms
    @FocusState private var searchFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    private var columns: [GridItem] {
        compact ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                : [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]
    }
    private var showsPlan: Bool { room == nil && mode == .plan && !store.devices.isEmpty }

    var shown: [LightDevice] {
        store.devices.filter { (room == nil || $0.room == room) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.sku.localizedCaseInsensitiveContains(search) || $0.room.localizedCaseInsensitiveContains(search)) }
    }
    /// Lights grouped by room; a room page is one group.
    private var groups: [(room: String, lights: [LightDevice])] {
        let lights = shown
        guard room == nil else { return [(room ?? "", lights)] }
        return Dictionary(grouping: lights, by: \.room).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }

    private var glowColors: [Color] {
        if store.devices.isEmpty { return [0xFF9500, 0xFF2D95, 0xAF52DE, 0x0A84FF, 0x00C7BE].map { Color(rgb: $0) } }
        return shown.filter(\.isLit).flatMap { $0.hasPalette ? $0.lookColors.enumerated().filter { $0.offset.isMultiple(of: 5) }.map(\.element) : [$0.displayColor] }
    }

    var body: some View {
        Group {
            if showsPlan {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    FloorPlanView(store: store) { selected = $0 }
                }
                .pagePadding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if store.devices.isEmpty { onboarding } else { roomsContent }
                    }.pagePadding()
                }
                // The lights that are on wash the top of the page in their colors.
                .background(alignment: .top) { AmbientGlow(colors: glowColors).frame(height: 420).ignoresSafeArea(edges: .top) }
            }
        }
        .background { Button("Find") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true) }
        .sheet(item: $selected) { device in DeviceSheet(store: store, deviceID: device.id) }
        .sheet(item: $naming) { device in NameRoomSheet(store: store, deviceID: device.id) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: room ?? "Home", subtitle: subtitle) {
                if !store.devices.isEmpty {
                    if !compact && !showsPlan { searchField }
                    allPowerButton
                }
                if !compact {
                    Button { store.discover() } label: {
                        Label(store.scanning ? "Looking…" : "Find Lights", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(store.scanning || store.demo)
                    .help(store.demo ? "Leave the demo home to find real lights." : "Look for LAN-enabled Govee lights on this Wi-Fi network")
                }
            }
            if room == nil && !store.devices.isEmpty {
                Picker("View", selection: $mode) {
                    Text("Rooms").tag(HomeMode.rooms)
                    Text("Plan").tag(HomeMode.plan)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel("Show lights by room or on the floor plan")
            }
        }
    }

    private var allPowerButton: some View {
        let lights = shown.filter { $0.supports("powerSwitch") }
        let anyOn = lights.contains { $0.power == true }
        return Button { store.perform(.power(!anyOn), ids: lights.map(\.id)) } label: {
            Label(anyOn ? "All off" : "All on", systemImage: "power").fontWeight(.semibold)
                .padding(.horizontal, 6).frame(minHeight: 32)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .disabled(lights.isEmpty)
        .help(anyOn ? "Turn off every light shown (⌥⌘↓)" : "Turn on every light shown (⌥⌘↑)")
    }

    private var subtitle: String {
        let lights = room == nil ? store.devices : store.devices.filter { $0.room == room }
        if lights.isEmpty { return store.scanning ? "Looking for lights on your Wi-Fi…" : "Bring your Govee lights together in one place." }
        let on = lights.filter { $0.power == true }.count
        let offline = lights.filter { $0.online == false }.count
        var parts = ["\(on) of \(lights.count) \(lights.count == 1 ? "light" : "lights") on"]
        if room == nil && store.rooms.count > 1 { parts.append("\(store.rooms.count) rooms") }
        if offline > 0 { parts.append("\(offline) offline") }
        if store.scanning { parts.append("Looking for more…") }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search", text: $search).textFieldStyle(.plain).focused($searchFocused).onExitCommandIfAvailable { search = ""; searchFocused = false }
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

    // MARK: Rooms

    @ViewBuilder private var roomsContent: some View {
        if room == nil && !store.home.scenes.isEmpty && search.isEmpty { scenesStrip }
        ForEach(groups, id: \.room) { group in
            VStack(alignment: .leading, spacing: 10) {
                if room == nil { roomHeader(group.room, lights: group.lights) }
                LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 12 : 14) {
                    ForEach(group.lights) { device in
                        LightTile(store: store, device: device, open: { selected = device }, rename: { naming = device })
                    }
                }
            }
        }
        if shown.isEmpty {
            EmptyState(icon: "magnifyingglass", title: "No matching lights", message: "Nothing matches “\(search)”. Try a light's name, model, or room.") {
                Button("Clear Search") { search = "" }
            }
        }
        Label("\(PlatformCopy.tapVerb) a light to switch it. Use › for color and brightness. Cloud lights confirm once Govee reports back.", systemImage: "info.circle")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func roomHeader(_ name: String, lights: [LightDevice]) -> some View {
        let lights = lights.filter { DeviceReadings.isLight(type: $0.deviceType) } // room actions never switch appliances
        let ids = lights.filter { $0.supports("powerSwitch") }.map(\.id)
        let dimmable = lights.filter { $0.supports("brightness") }.map(\.id)
        let white = lights.filter { $0.supports("colorTemperatureK") }.map(\.id)
        let on = lights.filter { $0.power == true }.count
        return HStack(alignment: .center, spacing: 8) {
            Text(name).font(.system(size: 19, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("\(on) of \(lights.count) on").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            let lit = lights.filter(\.isLit)
            if !lit.isEmpty { LookStrip(colors: lit.count == 1 ? lit[0].lookColors : lit.map(\.displayColor), height: 6).frame(width: 44) }
            Spacer(minLength: 8)
            if !dimmable.isEmpty || !white.isEmpty {
                Menu {
                    if !dimmable.isEmpty {
                        Section("Brightness") {
                            ForEach([10, 25, 50, 75, 100], id: \.self) { level in Button("\(level)%") { store.perform(.brightness(level), ids: dimmable) } }
                        }
                    }
                    if !white.isEmpty {
                        // Each light's own range limits the value, as in the light's controls.
                        Section("White") {
                            Button("Warm 2700 K") { store.performWhite(2700, ids: white) }
                            Button("Neutral 4000 K") { store.performWhite(4000, ids: white) }
                            Button("Daylight 6500 K") { store.performWhite(6500, ids: white) }
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).fixedSize()
                    .help("Brightness and white for \(name)").accessibilityLabel("Adjust lights in \(name)")
            }
            Toggle(isOn: Binding(get: { on > 0 }, set: { value in store.perform(.power(value), ids: ids) })) {
                Text(on > 0 ? "On" : "Off").font(.system(size: 13, weight: .semibold)).foregroundStyle(on > 0 ? Color.lumaAccent : .secondary)
            }
            .toggleStyle(.switch).fixedSize()
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .background((on > 0 ? Color.lumaAccent.opacity(0.12) : Color.primary.opacity(0.06)), in: Capsule())
            .disabled(ids.isEmpty)
            .accessibilityLabel("All lights in \(name)")
        }
    }

    private var scenesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set the mood").font(.system(size: 19, weight: .bold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.home.scenes) { scene in SceneChip(store: store, scene: scene) }
                }.padding(1)
            }
        }
    }

    // MARK: First run

    private var onboarding: some View {
        Card(padding: compact ? 20 : 32) {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(AngularGradient(colors: [0xFF9500, 0xFF2D95, 0xAF52DE, 0x0A84FF, 0x00C7BE, 0xFFD60A, 0xFF9500].map { Color(rgb: $0) }, center: .center))
                            .frame(width: 96, height: 96).blur(radius: 26).opacity(0.7)
                        Image(systemName: "lightbulb.led.wide.fill").font(.system(size: 44, weight: .medium)).foregroundStyle(.white)
                            .shadow(color: Color(rgb: 0xFF9500).opacity(0.9), radius: 12)
                            .frame(width: 84, height: 84)
                            .background(LinearGradient(colors: [Color(rgb: 0xFFB347), Color(rgb: 0xB95500)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }.frame(height: 140).accessibilityHidden(true)
                    Text("Welcome to Luma").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                    Text("Control your Govee lights from your \(PlatformCopy.device): quick power and brightness, color, scenes, schedules, and automations.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                    #if os(iOS)
                    Text("Used Luma on another device? Connect with the same Apple Account and your names, rooms, and scenes come back from iCloud.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                    #endif
                }
                let layout = compact ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                layout {
                    step(1, icon: "cloud", title: "Connect your account", text: "A free Govee API key adds cloud actions like effects and segments, and controls your lights when you're not on the same network.") {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Connect Account…") { connecting = true }.buttonStyle(.borderedProminent)
                            Link("Get a free API key ↗", destination: Links.goveeAPIKey).font(.system(size: 12)).tint(Color.lumaAccent)
                        }
                    }
                    step(2, icon: "wifi", title: "Add local control", text: "No API key needed. Turn on LAN Control for each light in the Govee Home app, then look for lights on this Wi-Fi.") {
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
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.lumaAccent).frame(width: 26, height: 26).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                SceneSwatch(scene: scene, size: 36, glowing: running)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scene.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(running ? "Running · \(PlatformCopy.tapVerb.lowercased()) to stop" : "^[\(Set(scene.steps.map(\.deviceID)).count) light](inflect: true)").font(.system(size: 12)).foregroundStyle(running ? Color.lumaAccent : .secondary)
                }
            }
            .padding(.leading, 8).padding(.trailing, 14).frame(minHeight: 56)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(running ? Color.lumaAccent.opacity(0.7) : hovering ? Color.primary.opacity(0.18) : Color.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(TilePressStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: running)
        .disabled(store.runningSceneID != nil && !running)
        .onHover { hovering = $0 }
        .help(running ? "Stop \(scene.name)" : "Run \(scene.name)")
        .accessibilityLabel(running ? "Stop \(scene.name)" : "Run \(scene.name)")
    }
}

/// A light tinted with its own color. Tap switches it; › opens its controls.
struct LightTile: View {
    let store: HomeStore
    let device: LightDevice
    let open: () -> Void
    let rename: () -> Void
    @State private var hovering = false
    @State private var taps = 0
    private var isOn: Bool { device.isLit }
    private var canSwitch: Bool { device.supports("powerSwitch") && device.online != false }
    private var needsName: Bool {
        guard let own = store.home.devices.first(where: { $0.id == device.id }), own.customName == nil else { return false }
        return looksLikeModelName(own.name, sku: own.sku)
    }
    private var stateText: String {
        if let status = store.controlStatus(for: device.id) { return status }
        if device.online == false { return "Offline" }
        switch device.power {
        case true?: return device.brightness.map { "\($0)%" } ?? "On"
        case false?: return "Off"
        case nil: return "No status yet"
        }
    }

    var body: some View {
        Button { taps += 1; canSwitch ? store.perform(.power(!(device.power ?? false)), ids: [device.id]) : open() } label: {
            VStack(alignment: .leading, spacing: 0) {
                LightOrb(device: device, size: 44)
                Spacer(minLength: 14)
                Text(device.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    .padding(.trailing, needsName ? 64 : 0)
                Text(stateText).font(.system(size: 13)).monospacedDigit().contentTransition(.numericText())
                    .foregroundStyle(device.online == false ? Color.danger : .secondary).lineLimit(1)
                // The light itself in miniature: its colors, as long as it is bright.
                LookStrip(colors: device.lookColors, fraction: isOn ? Double(device.brightness ?? 100) / 100 : 0).padding(.top, 10)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .overlay(alignment: .topTrailing) {
            Button(action: open) {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(.thinMaterial, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(4)
            .help("Color, brightness, and details").accessibilityLabel("Controls for \(device.name)")
        }
        .overlay(alignment: .bottomTrailing) {
            if needsName {
                Button(action: rename) {
                    Text("Name it").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lumaAccent)
                        .padding(.horizontal, 10).frame(height: 26).background(Color.lumaAccent.opacity(0.12), in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.trailing, 8).padding(.bottom, 16)
                .help("Give this light a name only Luma uses").accessibilityLabel("Name \(device.name)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(device.power == true ? "Turn Off" : "Turn On", systemImage: "power") { store.perform(.power(!(device.power ?? false)), ids: [device.id]) }
                .disabled(!device.supports("powerSwitch"))
            Button("Open Controls", systemImage: "slider.horizontal.3", action: open)
            Divider()
            Button("Rename…", systemImage: "pencil", action: rename)
            Menu("Move to Room") {
                ForEach(store.rooms.filter { $0 != device.room }, id: \.self) { name in
                    Button(name) { store.assignRoom(name, id: device.id) }
                }
                Divider()
                Button("New Room…", systemImage: "plus", action: rename)
            }
            Button("Refresh State", systemImage: "arrow.clockwise") { Task { await store.refresh(device) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name), \(device.room)")
        .accessibilityValue(stateText)
        .accessibilityHint(canSwitch ? "Switches the light \(device.power == true ? "off" : "on")" : "Opens controls")
        .accessibilityAction(named: "Open controls", open)
        .accessibilityAction(named: "Rename", rename)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let color = device.displayColor
        return ZStack {
            Color.surface
            if isOn {
                LinearGradient(colors: device.lookColors, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.5)
                // Fades to the card so the name and state stay readable over any color.
                LinearGradient(colors: [Color.surface.opacity(0), Color.surface.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(shape)
        .overlay {
            if device.online == false { shape.strokeBorder(Color.danger.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            else if isOn { shape.strokeBorder(LinearGradient(colors: device.lookColors.map { $0.opacity(0.6) }, startPoint: .topLeading, endPoint: .bottomTrailing)) }
            else { shape.strokeBorder(hovering ? Color.primary.opacity(0.16) : Color.hairline) }
        }
        .shadow(color: isOn ? color.opacity(hovering ? 0.4 : 0.28) : .black.opacity(0.03), radius: isOn ? 16 : 3, y: isOn ? 6 : 2)
        .animation(.easeOut(duration: 0.3), value: isOn)
        .animation(.easeOut(duration: 0.3), value: device.rgb)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}

/// A scene's icon on a gradient of the colors it sets.
struct SceneSwatch: View {
    let scene: LightScene
    var size: CGFloat = 44
    var glowing = false
    var body: some View {
        let found = sceneColors(scene)
        let colors = found.isEmpty ? [Color(rgb: 0xFFB347), Color(rgb: 0xB95500)] : found.count == 1 ? [found[0].hueShifted(-25), found[0], found[0].hueShifted(25)] : found
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        let gradient = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        Image(systemName: scene.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .frame(width: size, height: size)
            .background(gradient, in: shape)
            .background(shape.fill(gradient).blur(radius: size * 0.28).opacity(glowing ? 0.9 : 0.45))
            .animation(.easeInOut(duration: 0.4), value: glowing)
            .accessibilityHidden(true)
    }
}

struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1).animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}
