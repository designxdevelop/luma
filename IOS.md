# Luma for iPhone and iPad

The native iOS app shares its SwiftUI pages, controls, scenes, automations, and Govee cloud/LAN code with the [Mac app](MACOS.md). Only the app entry point and a few platform adapters differ.

**Status:** experimental, unsigned development builds. Tested in the iOS Simulator in demo mode; not yet tested on hardware with real lights.

## Build and run

Requires Xcode 26+ with an iOS 17+ SDK.

```sh
open ios/Luma.xcodeproj   # scheme LumaiOS, pick a simulator or your device
```

From the command line (simulator, no signing):

```sh
xcodebuild -project ios/Luma.xcodeproj -scheme LumaiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To run on a device, select your own team under **Signing & Capabilities**. No team ID is committed. Launch with the `--demo` argument (Scheme › Run › Arguments) to explore sample lights without an account.

## What's the same

Lights, rooms, search, power/brightness/color/white, model-specific effects and the advanced JSON editor, app scenes (create, edit, duplicate, import/export JSON through the Files picker), schedules, the authenticated webhook server, activity, appearance, demo mode, and Keychain-stored secrets. iPhone uses a tab bar; iPad keeps the Mac's sidebar with rooms.

## Apple Watch

The iOS app embeds a watchOS 10+ companion (target **LumaWatch**, built with the iOS app). It lists your lights and scenes, turns everything on or off, runs or stops a scene, and toggles or dims one light with taps or the Digital Crown.

The watch never contacts lights or Govee itself: watchOS doesn't allow the UDP sockets LAN control needs, and your API key stays on the phone. Each tap is sent to the iPhone app over WatchConnectivity; iOS wakes Luma in the background to run it through the same controls as the phone, and the reply updates the watch. The iPhone must be nearby. Launch the watch app with `--demo` to try it with sample lights and no phone.

## What's different on iOS

- **Screen Sync uses the camera.** iOS doesn't let apps read other apps' screens without a ReplayKit broadcast extension. Instead, choose **Use Camera** and point the back camera at a TV or monitor; frames go through the same region, smoothing, and LAN pipeline as on the Mac. Frames are reduced on the device to a coarse color grid and never saved or uploaded. Capture pauses when Luma leaves the foreground.
- **Foreground only.** iOS suspends apps in the background, so schedules, running scenes, and the webhook server work only while Luma is open. There is no menu bar equivalent.
- **LAN discovery on a real device** sends a multicast scan to `239.255.255.250`. iOS requires Apple's [multicast networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast) for that; until this app has it, discovery works in the Simulator but not on hardware. Cloud control works everywhere. iOS asks for Local Network permission the first time Luma talks to lights.

## Not yet

- ReplayKit broadcast extension for whole-screen sync.
- Watch complications, widgets, Shortcuts/App Intents, Live Activities.
- App Store or TestFlight distribution.
