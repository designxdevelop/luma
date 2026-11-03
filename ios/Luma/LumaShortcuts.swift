import AppIntents
import LumaIntents

// ponytail: identical copy in macos/Luma/LumaShortcuts.swift. Apple wants the App
// Shortcuts provider in the app target, so it can't live in the shared package.

/// Registers the package's intents with this app.
struct LumaAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [LumaIntentsPackage.self] }
}

/// Ready-made Siri phrases. Each phrase may hold one room or scene name; Siri
/// learns the current names when the app calls `updateAppShortcutParameters()`.
struct LumaShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnRoomIntent(), phrases: [
            "Turn on \(\.$room) in \(.applicationName)",
            "Turn on the \(\.$room) lights in \(.applicationName)",
            "\(.applicationName) turn on \(\.$room)"
        ], shortTitle: "Turn On Room", systemImageName: "lightbulb.fill")
        AppShortcut(intent: TurnOffRoomIntent(), phrases: [
            "Turn off \(\.$room) in \(.applicationName)",
            "Turn off the \(\.$room) lights in \(.applicationName)",
            "\(.applicationName) turn off \(\.$room)"
        ], shortTitle: "Turn Off Room", systemImageName: "lightbulb.slash")
        AppShortcut(intent: SetRoomBrightnessIntent(), phrases: [
            "Set \(\.$room) brightness in \(.applicationName)",
            "Dim \(\.$room) in \(.applicationName)"
        ], shortTitle: "Room Brightness", systemImageName: "sun.max")
        AppShortcut(intent: SetRoomColorIntent(), phrases: [
            "Change \(\.$room) color in \(.applicationName)",
            "Set \(\.$room) color in \(.applicationName)"
        ], shortTitle: "Room Color", systemImageName: "paintpalette")
        AppShortcut(intent: RunLumaSceneIntent(), phrases: [
            "Run \(\.$scene) in \(.applicationName)",
            "Start \(\.$scene) in \(.applicationName)"
        ], shortTitle: "Run Scene", systemImageName: "sparkles")
        AppShortcut(intent: ApplyGoveeSceneIntent(), phrases: [
            "Set a Govee scene in \(\.$room) with \(.applicationName)",
            "Apply a scene to \(\.$room) in \(.applicationName)"
        ], shortTitle: "Govee Scene", systemImageName: "wand.and.stars")
    }
}
