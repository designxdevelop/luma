import SwiftUI
import Observation
import LumaCore

enum Page: String, CaseIterable {
    // Screen Sync is last so ⌘1–⌘5 keep their meaning.
    case lights = "Lights", scenes = "Scenes", automations = "Automations", activity = "Activity", settings = "Settings", screenSync = "Screen Sync"
    var icon: String { switch self { case .lights: "lightbulb.2"; case .scenes: "sparkles.rectangle.stack"; case .automations: "clock.arrow.2.circlepath"; case .activity: "list.bullet.rectangle"; case .settings: "gearshape"; case .screenSync: "display" } }
    var shortcut: KeyEquivalent { switch self { case .lights: "1"; case .scenes: "2"; case .automations: "3"; case .activity: "4"; case .settings: "5"; case .screenSync: "6" } }
}

enum SidebarItem: Hashable {
    case page(Page), room(String)
}

@Observable final class LumaNavigation {
    var selection: SidebarItem? = .page(.lights)
}

struct RootView: View {
    @Bindable var store: HomeStore
    @Bindable var navigation: LumaNavigation
    @State private var connecting = CommandLine.arguments.contains("--connect")
    @AppStorage("appearance") private var appearance = Appearance.system
    var body: some View {
        NavigationSplitView {
            sidebar.frame(minWidth: 210, idealWidth: 224, maxWidth: 280)
                .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if store.demo { demoBanner }
                if let notice = store.notice { noticeBanner(notice) }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.canvas)
            .animation(.easeOut(duration: 0.2), value: store.notice)
        }
        .sheet(isPresented: $connecting) { ConnectionSheet(store: store) }
        .onAppear { appearance.apply() }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .page(.lights) {
        case .page(.lights): LightsView(store: store, room: nil, connecting: $connecting)
        case .room(let room): LightsView(store: store, room: room, connecting: $connecting).id(room)
        case .page(.scenes): ScenesView(store: store)
        case .page(.automations): AutomationsView(store: store)
        case .page(.activity): ActivityView(store: store)
        case .page(.settings): SettingsView(store: store)
        case .page(.screenSync): ScreenSyncView(store: store, sync: store.screenSync)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $navigation.selection) {
            Section {
                ForEach([Page.lights, .scenes, .automations, .activity, .screenSync], id: \.self) { page in
                    Label(page.rawValue, systemImage: page.icon)
                        .badge(badge(for: page))
                        .tag(SidebarItem.page(page))
                }
            }
            if !store.rooms.isEmpty {
                Section("Rooms") {
                    ForEach(store.rooms, id: \.self) { room in
                        let lights = store.devices.filter { $0.room == room }
                        let on = lights.filter { $0.power == true }.count
                        Label(room, systemImage: roomSymbol(room))
                            .badge(on > 0 ? "\(on)/\(lights.count)" : "\(lights.count)")
                            .tag(SidebarItem.room(room))
                            .accessibilityLabel("\(room), \(on) of \(lights.count) lights on")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "lightbulb.led.wide.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [Color(rgb: 0xF2A24A), Color(rgb: 0xB95500)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Luma").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 8)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private func badge(for page: Page) -> Text? {
        switch page {
        case .lights: store.devices.isEmpty ? nil : Text("\(store.poweredCount)/\(store.devices.count)")
        case .scenes: store.home.scenes.isEmpty ? nil : Text("\(store.home.scenes.count)")
        case .automations: store.webhookRunning ? Text("Live") : nil
        case .activity: store.activity.contains(where: \.isError) ? Text("\(store.activity.filter(\.isError).count)") : nil
        case .settings: nil
        case .screenSync: switch store.screenSync.phase { case .running, .starting: Text("Live"); case .paused: Text("Paused"); case .idle: nil }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.screenSync.isActive {
                ScreenSyncIndicator(sync: store.screenSync) { navigation.selection = .page(.screenSync) }
            }
            if let id = store.runningSceneID {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Running").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(store.home.scenes.first { $0.id == id }?.name ?? "Scene").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { store.stopScene() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless).help("Stop scene").accessibilityLabel("Stop running scene")
                }
                .padding(10).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Button { navigation.selection = .page(.settings) } label: {
                HStack(spacing: 9) {
                    Circle().fill(connectionTint).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connectionTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        Text(connectionDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "gearshape").foregroundStyle(navigation.selection == .page(.settings) ? Color.lumaAccent : .secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .background(navigation.selection == .page(.settings) ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings. \(connectionTitle), \(connectionDetail)")
        }
        .padding(10)
    }

    private var localCount: Int { store.devices.filter { $0.ip != nil }.count }
    private var connectionTitle: String {
        if store.demo { return "Demo home" }
        if store.cloudConnected { return "Govee connected" }
        return localCount > 0 ? "Local network only" : "Not connected"
    }
    private var connectionDetail: String {
        if store.demo { return "Sample lights only" }
        if store.scanning { return "Looking for lights…" }
        if store.devices.isEmpty { return "Connect to get started" }
        return "\(localCount) local · \(store.devices.count - localCount) cloud"
    }
    private var connectionTint: Color { store.demo ? .lumaAccent : store.cloudConnected || localCount > 0 ? .success : .secondary }

    // MARK: Banners

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.lumaAccent)
            Text("You're exploring a demo home. These are sample lights; nothing real is controlled.").font(.system(size: 12))
            Spacer()
            Button("Leave Demo") { store.leaveDemo(); connecting = true }.controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.lumaAccent.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warning)
            Text(notice).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if navigation.selection != .page(.activity) { Button("View Activity") { navigation.selection = .page(.activity) }.controlSize(.small) }
            Button { store.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.warning.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A best-guess symbol for common room names.
func roomSymbol(_ room: String) -> String {
    let name = room.lowercased()
    let table: [(String, String)] = [("living", "sofa"), ("lounge", "sofa"), ("family", "sofa"), ("bed", "bed.double"), ("nursery", "teddybear"), ("kid", "teddybear"), ("office", "desktopcomputer"), ("desk", "desktopcomputer"), ("study", "books.vertical"), ("kitchen", "fork.knife"), ("dining", "fork.knife"), ("bath", "shower"), ("garage", "car"), ("patio", "tree"), ("garden", "tree"), ("yard", "tree"), ("porch", "tree"), ("outdoor", "tree"), ("game", "gamecontroller"), ("media", "tv"), ("theater", "tv"), ("tv", "tv"), ("hall", "door.left.hand.open"), ("entry", "door.left.hand.open"), ("stair", "stairs"), ("unassigned", "questionmark.square.dashed")]
    return table.first { name.contains($0.0) }?.1 ?? "square.split.bottomrightquarter"
}

// MARK: - Activity

struct ActivityView: View {
    @Bindable var store: HomeStore
    @State private var problemsOnly = false
    private var entries: [ActivityEntry] { problemsOnly ? store.activity.filter(\.isError) : store.activity }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Activity", subtitle: "What Luma has done this session: commands, connections, scenes, and webhook calls.") {
                    Picker("Show", selection: $problemsOnly) {
                        Text("All").tag(false)
                        Text("Problems").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 170).accessibilityLabel("Show")
                    Button("Clear") { store.activity.removeAll(); store.notice = nil }.disabled(store.activity.isEmpty)
                }
                Card(padding: 0) {
                    if entries.isEmpty {
                        EmptyState(icon: problemsOnly ? "checkmark.seal" : "list.bullet.rectangle", title: problemsOnly ? "No problems" : "Nothing yet", message: problemsOnly ? "Everything this session went through without errors." : "Activity appears here when you connect, control a light, or run a scene.")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "circle.fill")
                                        .font(.system(size: entry.isError ? 12 : 5))
                                        .foregroundStyle(entry.isError ? Color.warning : Color.secondary.opacity(0.6))
                                        .frame(width: 14)
                                        .accessibilityLabel(entry.isError ? "Problem" : "")
                                    Text(entry.message).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(entry.time, format: .dateTime.hour().minute().second()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                if entry.id != entries.last?.id { Divider().padding(.leading, 42) }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Text("Luma keeps the latest 200 events in memory. They are cleared when you quit.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
