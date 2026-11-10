# Luma

An experimental app for controlling Govee lights on Mac, iPhone/iPad, Apple Watch, Android, Windows, and Linux, programming scenes, and connecting lighting to local automations.

**An open-source project built by Design X Develop LLC.** Licensed under [MIT](LICENSE) and provided **as is, without warranty**. Luma is an independent project and is not affiliated with or endorsed by Govee.

## What we're exploring

We're exploring how much useful control can live in a desktop app: schema-driven Govee cloud controls, direct LAN control where supported, scenes and schedules, authenticated webhook triggers, and lights that follow the colors on a selected display or window.

Screen Sync processes frames locally, with explicit source selection, region mapping, smoothing, brightness caps, and bounded LAN updates. It does not upload screen pixels or use an AI model to watch your screen. Model support varies; this is an evolving experiment, not a promise of parity with every Govee Home feature.

## Platforms

| Platform | Implementation | Source and instructions | Verification status |
| --- | --- | --- | --- |
| macOS 14+ | Native SwiftUI / Swift / ScreenCaptureKit | [Mac guide](MACOS.md), `Sources/`, `Tests/` | 252 automated tests and synthetic Screen Sync UI checks; basic cloud/LAN controls tested with hardware |
| iOS / iPadOS 17+, watchOS 10+ | Native SwiftUI, shares the Mac app's code (`Sources/LumaUI`); the watch relays through the iPhone | [iOS guide](IOS.md), `ios/` | Builds in CI; demo mode checked in the iOS Simulator; Screen Sync uses the camera; not yet tested with hardware |
| Android 8+ (API 26), Wear OS companion | Native Kotlin / Jetpack Compose / Material 3 | [Android guide](docs/ANDROID.md), [Play internal testing](docs/PLAY.md), `android/` | Unit tests and a debug build pass in CI; demo mode checked on an API 37 emulator; Bluetooth, Govee Home sign-in, the widget, the Wear app and light response not yet tested with hardware |
| Windows 11 x64 | Electron / TypeScript | [Desktop guide](desktop/README.md), `desktop/` | Unsigned installer built; 294 portable contracts pass; actual Windows runtime, installer, DPAPI, capture, and light response still need testing |
| Linux x64 / arm64 | Electron / TypeScript | [Linux guide](desktop/docs/LINUX.md), `desktop/` | Archives built; 294 contracts on Linux and 19 synthetic arm64 app checks; real X11/Wayland capture and keyring integration still need testing |

The native Mac and Electron apps have different version numbers and some behavior differences. Real screen-capture-to-light response remains unverified on every platform. Linux capture is experimental and requires supported GNOME/KDE lock monitoring.

## Build and try it

On macOS, install Swift 6.2+ / Xcode Command Line Tools:

```sh
./scripts/verify.sh
./scripts/build-app.sh
open dist/Luma.app
```

For iPhone and iPad, open `ios/Luma.xcodeproj` (scheme **LumaiOS**); see the [iOS guide](IOS.md).

For Android, install JDK 21 and an Android SDK with platform `android-36.1` (see the [Android guide](docs/ANDROID.md)):

```sh
cd android
./gradlew test assembleDebug
```

For Windows or Linux, install Node.js 22.12+ (Node 24 is used in CI):

```sh
cd desktop
npm ci
npm run runtime:install
npm test
npm run demo
```

Build an unsigned Windows installer with `npm run dist:win`, or Linux archives with `npm run dist:linux`, from `desktop/`. Build outputs are ignored by Git. These are development builds; signing and notarization are not configured.

Connect with your own Govee developer API key through the app. For compatible local lights, enable **LAN Control** in Govee Home and discover them on the same network. Credentials and personal home data stay outside this repository. Screen Sync and the webhook listener start off; enable them explicitly in the app.

**DreamView TV sync** (native Mac and iOS app). A TV backlight that reports Govee's cloud `dreamViewToggle` gets a **DreamView TV sync** card: Start/Stop the group you set up in Govee Home, and **Save Movie Scene** (power on, then sync on). Group members, Movie/Game, All/Part, and saturation stay in Govee Home; Luma does not read or change them.

**Govee Home sign-in** (native Mac and iOS app, optional, read-only). Your API key already imports lights, names, and features; rooms, DreamView groups, and Govee Home automations aren't in Govee's public API. Settings › **Sign In to Govee Home…** uses the Govee Home app's private email sign-in (with the emailed code when Govee asks), keeps only the session token in the Keychain, and reads the device list, control groups, and automations. A preview lists room changes (lights you moved in Luma start unselected; unknown lights are listed, never created), your DreamView groups, and your automations. The last import is saved with your home, so Luma schedules that run at the same minute as an enabled Govee automation on the same light stay flagged until you sign out. **Import Saved File…** accepts a saved device-list response instead. Govee publishes no contract for this API and can change it; there is no token refresh, so sign in again when it expires.

**DreamView partners.** The DreamView card shows the group from your Govee Home account (name and the light count Govee reports) and a separate **Luma draft** of members and screen areas, labelled *Not sent to lights*. Luma can't yet read which lights are in the group or their command versions, and the TV backlights report Bluetooth encryption support that a writer would have to handle, so Apply stays disabled.

**Govee scenes, one tap** (native). Scenes › Govee scenes › **Browse** (or a light's Effects tab) lists each light's built-in, DIY, and snapshot scenes with search. Tap one to send it; pick a room to apply a scene name to every light there that lists it. Nothing is saved unless you choose **Save as Luma Scene**. The list is what Govee's public API returns for the model, which can be shorter than Govee Home's.

**Siri and Shortcuts** (native iPhone and iPad, and the Mac app built with Xcode; the `scripts/build-app.sh` package doesn't include them). Say "Turn on Bedroom in Luma", "Turn off the Office lights in Luma", "Set Bedroom brightness in Luma", "Change Bedroom color in Luma", "Run Movie night in Luma", or "Apply a scene to Bedroom in Luma", or use the same actions in the Shortcuts app. Rooms are looked up when the action runs, so a light you add to a room is included without editing any shortcut. Actions run in Luma in the background through the Govee cloud (LAN only when Luma is already open and has found the light). See [verification](docs/VERIFICATION.md#siri-shortcuts-and-one-tap-govee-scenes-2026-11-02) for what was tested.

**Also in the native app:** room brightness and white, **Restore** after a scene, whole-home **Export/Restore Backup**, and a redacted **Compatibility Report** for issues. See [Govee Home parity and roadmap](docs/PARITY.md).

## Issues and pull requests

Found a bug, an unsupported model, or an idea worth trying? [File an Issue](https://github.com/designxdevelop/luma/issues). Include your app/OS version, Govee model, LAN or cloud connection, and steps to reproduce. **Do not include API keys, webhook tokens, personal device inventories, or private screen captures.**

[Pull requests](https://github.com/designxdevelop/luma/pulls) are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md), describe the behavior change, and include relevant verification. Improvements to model compatibility, desktop capture, accessibility, platform testing, and documentation are especially useful.

## Details

- [Native Mac usage, webhooks, and build instructions](MACOS.md)
- [iPhone and iPad](IOS.md)
- [Android](docs/ANDROID.md) and [Google Play internal testing](docs/PLAY.md)
- [Windows/Linux usage and webhooks](desktop/README.md)
- [Screen Sync behavior and limits on Windows/Linux](desktop/docs/SCREEN-SYNC.md)
- [Protocol research](docs/PROTOCOL-RESEARCH.md)
- [Mac verification record](docs/VERIFICATION.md) · [Desktop verification record](desktop/docs/VERIFICATION.md)

Copyright © 2026 Design X Develop LLC. See the [MIT License](LICENSE) for the full as-is warranty disclaimer.
