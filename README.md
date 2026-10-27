# Luma

An experimental app for controlling Govee lights on Mac, iPhone/iPad, Apple Watch, Windows, and Linux, programming scenes, and connecting lighting to local automations.

**An open-source project built by Design X Develop LLC.** Licensed under [MIT](LICENSE) and provided **as is, without warranty**. Luma is an independent project and is not affiliated with or endorsed by Govee.

## What we're exploring

We're exploring how much useful control can live in a desktop app: schema-driven Govee cloud controls, direct LAN control where supported, scenes and schedules, authenticated webhook triggers, and lights that follow the colors on a selected display or window.

Screen Sync processes frames locally, with explicit source selection, region mapping, smoothing, brightness caps, and bounded LAN updates. It does not upload screen pixels or use an AI model to watch your screen. Model support varies; this is an evolving experiment, not a promise of parity with every Govee Home feature.

## Platforms

| Platform | Implementation | Source and instructions | Verification status |
| --- | --- | --- | --- |
| macOS 14+ | Native SwiftUI / Swift / ScreenCaptureKit | [Mac guide](MACOS.md), `Sources/`, `Tests/` | 133 automated tests and synthetic Screen Sync UI checks; basic cloud/LAN controls tested with hardware |
| iOS / iPadOS 17+, watchOS 10+ | Native SwiftUI, shares the Mac app's code (`Sources/LumaUI`); the watch relays through the iPhone | [iOS guide](IOS.md), `ios/` | Builds in CI; demo mode checked in the iOS Simulator; Screen Sync uses the camera; not yet tested with hardware |
| Windows 11 x64 | Electron / TypeScript | [Desktop guide](desktop/README.md), `desktop/` | Unsigned installer built; 204 portable contracts pass; actual Windows runtime, installer, DPAPI, capture, and light response still need testing |
| Linux x64 / arm64 | Electron / TypeScript | [Linux guide](desktop/docs/LINUX.md), `desktop/` | Archives built; 204 contracts on Linux and 19 synthetic arm64 app checks; real X11/Wayland capture and keyring integration still need testing |

The native Mac and Electron apps have different version numbers and some behavior differences. Real screen-capture-to-light response remains unverified on every platform. Linux capture is experimental and requires supported GNOME/KDE lock monitoring.

## Build and try it

On macOS, install Swift 6.2+ / Xcode Command Line Tools:

```sh
./scripts/verify.sh
./scripts/build-app.sh
open dist/Luma.app
```

For iPhone and iPad, open `ios/Luma.xcodeproj` (scheme **LumaiOS**); see the [iOS guide](IOS.md).

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

## Issues and pull requests

Found a bug, an unsupported model, or an idea worth trying? [File an Issue](https://github.com/designxdevelop/luma/issues). Include your app/OS version, Govee model, LAN or cloud connection, and steps to reproduce. **Do not include API keys, webhook tokens, personal device inventories, or private screen captures.**

[Pull requests](https://github.com/designxdevelop/luma/pulls) are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md), describe the behavior change, and include relevant verification. Improvements to model compatibility, desktop capture, accessibility, platform testing, and documentation are especially useful.

## Details

- [Native Mac usage, webhooks, and build instructions](MACOS.md)
- [iPhone and iPad](IOS.md)
- [Windows/Linux usage and webhooks](desktop/README.md)
- [Screen Sync behavior and limits on Windows/Linux](desktop/docs/SCREEN-SYNC.md)
- [Protocol research](docs/PROTOCOL-RESEARCH.md)
- [Mac verification record](docs/VERIFICATION.md) · [Desktop verification record](desktop/docs/VERIFICATION.md)

Copyright © 2026 Design X Develop LLC. See the [MIT License](LICENSE) for the full as-is warranty disclaimer.
