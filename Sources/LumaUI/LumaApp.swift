#if os(macOS)
import SwiftUI
import AppKit
import LumaCore

public struct LumaApp: App {
    @State private var store = HomeStore()
    @State private var navigation = LumaNavigation()
    public init() {}
    public var body: some Scene {
        Window("Luma", id: "main") {
            RootView(store: store, navigation: navigation)
                .acceptsActivationClicks()
                .frame(minWidth: 1020, minHeight: 700)
                .tint(.lumaAccentFill)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.shutdown() }
        }
        .defaultSize(width: 1220, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands { LumaCommands(store: store, navigation: navigation) }
        MenuBarExtra {
            MenuBarView(store: store, navigation: navigation)
        } label: {
            // The capture indicator stays visible even with the main window closed.
            Image(systemName: store.screenSync.phase == .running ? "record.circle" : store.poweredCount > 0 ? "lightbulb.led.wide.fill" : "lightbulb.led.wide")
        }
    }
}

private func presentMainWindow(_ openWindow: OpenWindowAction, navigation: LumaNavigation, page: Page? = nil) {
    if let page { navigation.selection = .page(page) }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}

struct LumaCommands: Commands {
    let store: HomeStore
    let navigation: LumaNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) { Button("About Luma") { showAboutPanel() } }
        CommandGroup(replacing: .appSettings) { Button("Settings…") { presentMainWindow(openWindow, navigation: navigation, page: .settings) }.keyboardShortcut(",") }
        CommandGroup(before: .sidebar) {
            ForEach(Page.allCases, id: \.self) { page in
                Button(page.rawValue) { presentMainWindow(openWindow, navigation: navigation, page: page) }.keyboardShortcut(page.shortcut)
            }
            Divider()
        }
        CommandMenu("Lights") {
            Button("Turn All Lights On") { store.perform(.power(true), ids: store.devices.filter { $0.supports("powerSwitch") }.map(\.id)) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(store.devices.isEmpty)
            Button("Turn All Lights Off") { store.perform(.power(false), ids: store.devices.filter { $0.supports("powerSwitch") }.map(\.id)) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(store.devices.isEmpty)
            Divider()
            Button("Find Lights on Wi-Fi") { store.discover() }.disabled(store.scanning || store.demo)
            Button("Stop Running Scene") { store.stopScene() }.keyboardShortcut(".", modifiers: .command).disabled(store.runningSceneID == nil)
            Button("Stop Screen Sync") { store.screenSync.stop() }.disabled(!store.screenSync.isActive)
        }
        CommandGroup(replacing: .help) {
            Link("Luma Source Code", destination: Links.source)
            Link("Report an Issue…", destination: Links.issues)
        }
    }
}

struct MenuBarView: View {
    let store: HomeStore
    let navigation: LumaNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.devices.isEmpty ? "Luma · No lights yet" : "Luma · \(store.poweredCount) of \(store.devices.count) lights on")
        Button("Open Luma") { presentMainWindow(openWindow, navigation: navigation) }
        if store.screenSync.isActive {
            Divider()
            Text(store.screenSync.phase == .paused ? "Screen Sync paused" : "Screen Sync is capturing \(store.screenSync.source?.name ?? "your screen")")
            if store.screenSync.phase == .paused { Button("Resume Screen Sync") { Task { await store.screenSync.start() } } }
            else { Button("Pause Screen Sync") { store.screenSync.pause() } }
            Button("Stop Screen Sync") { store.screenSync.stop() }
        }
        Divider()
        Button("Turn All Lights On") { store.perform(.power(true), ids: store.devices.filter { $0.supports("powerSwitch") }.map(\.id)) }.disabled(store.devices.isEmpty)
        Button("Turn All Lights Off") { store.perform(.power(false), ids: store.devices.filter { $0.supports("powerSwitch") }.map(\.id)) }.disabled(store.devices.isEmpty)
        if !store.home.scenes.isEmpty {
            Section("Scenes") {
                ForEach(store.home.scenes) { scene in
                    Button(scene.name) { do { try store.runScene(scene) } catch { store.log(error.localizedDescription, error: true) } }
                        .disabled(store.runningSceneID != nil)
                }
            }
        }
        if store.runningSceneID != nil { Button("Stop Running Scene") { store.stopScene() } }
        Divider()
        Button("Settings…") { presentMainWindow(openWindow, navigation: navigation, page: .settings) }
        Button("About Luma") { showAboutPanel() }
        Divider()
        Button("Quit Luma") { store.shutdown(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
