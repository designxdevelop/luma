# Audio Sync on Mac, iPhone and iPad (native)

Written 2026-11-02. This report covers the native half of [AUDIO-SYNC.md](AUDIO-SYNC.md), which describes the desktop half and the shared math. It does not edit PARITY.md, README or VERIFICATION.

Evidence levels:

- **tests**: automated tests.
- **build**: compiles.
- **UI**: driven in the running app.

Nothing was sent to a real light. Real OS capture (ScreenCaptureKit audio on the Mac, the microphone on iOS) was **not run** in this pass. See [QA](#qa).

## What shipped

| Piece | What it does | Evidence |
| --- | --- | --- |
| `LumaCore/ScreenSync.swift` | `ScreenSyncMixer.tick(now:targets:)` feeds ready `LightTarget`s through the lanes Screen Sync already uses: per-light rate cap, dead band, lowered-cap override, latest-only, superseded count. Both ticks share one private `route`. Targets above the cap are clamped. The screen path is unchanged. | tests: the new core test, plus all existing mixer and Screen Sync tests unchanged |
| Session kind | Audio Sync is a second kind of the one `ScreenSync` session. `ScreenSource.session` is either `.frames` (the existing grid sessions) or `.levels` (the new `AudioCaptureSession`). The existing `ScreenSource(name:kind:) { … }` init is unchanged. Audio sources come from `ScreenSource.audio(name:kind:_:)`. Both kinds share one-session-at-a-time, the generation guard, pause/resume, manual-control `yield`, Include Again, opt-in restore on Stop, readback, sleep/lock/background pause, and the activity log. | tests |
| Mapping | `receive(levels)` → `AudioMapper.step` → mixer `tick(now:targets:)`. **Spectrum order:** every included light that can sync, sorted by name and then ID. A light taken over by hand keeps its band, so the other lights don't shift. Lights that are yielded or not eligible are dropped only when the mixer receives the targets. | tests (bass light red and brighter; order stable on takeover) |
| No signal | No analysis for 250 ms (`signalTimeout`) clears the meter to "No signal yet". The envelope then steps on silence, so lights ease to the floor and don't freeze at the last beat. These steps are not counted as analyzed frames. Nothing is sent before the first real analysis. | tests |
| `LumaUI/AudioSyncCapture.swift` | `AudioCaptureSession` protocol and `AudioLevelPump`. The pump takes mono samples, analyzes a 2048-sample window (`AudioSpectrum`) every 50 ms of audio, and delivers only the latest result to the main actor. It reports one ending only, and delivers nothing after cancel. It is shared by the Mac and iOS captures. | tests (60 Hz tone → bass band, about 20/s, silent after cancel; synthetic samples through the real analyzer) |
| Mac: `SystemAudioCapture` | Real ScreenCaptureKit audio session (see below). Its stream output now feeds the pump. | build. **Not run live** |
| iOS: `MicrophoneAudioCapture` | Microphone capture through `AVAudioEngine` (see below). | build. **Not run live** |
| UI (`ScreenSyncView`) | Additions: a Screen / Audio segmented switch (disabled while a session runs), a source card for audio, a live meter (8 bands + level, in its own view so only it redraws about 20×/s), a Bass/Mid/Treble label per light in Spectrum, and audio tuning: Style (Pulse/Spectrum), Sensitivity 0.5–2×, Release (the existing smoothing value, shown in seconds), a brightness cap with the floor shown, update rate, threshold, and Restore. The page header, the status pill ("Listening") and the sidebar indicator are labeled by kind. Permission and privacy text is specific to the source. | build only (see [QA](#qa)) |
| Persistence | `screenSync.mode` and `audioSync.options` are separate UserDefaults keys. `ScreenSyncSettings` gains no fields, so older builds still decode it. Sensitivity is clamped on load. Demo mode never saves. `usePreferences` reloads both keys. | tests |
| Demo | Audio Sync always listens to real audio. In the demo home only the lights are simulated, and the source card says so. There is no synthetic audio source. | code |

### Mac capture (ScreenCaptureKit)

- "Listen to Mac Audio…" opens the same system `SCContentSharingPicker` that Screen Sync uses, limited to `.singleDisplay`. Luma's bundle is excluded. The result is `ScreenSource.systemAudio(filter)`, named "Mac audio".
- The session sets `capturesAudio = true` and `excludesCurrentProcessAudio = true`, at 48 kHz stereo, mixed to mono. ScreenCaptureKit needs a video stream, so it runs at 2×2 pixels and 1 fps and Luma never reads it.
- Consent: the picker plus the existing Screen & System Audio Recording privacy grant. No new entitlement is needed. The Mac uses no microphone, because that would need the audio-input entitlement, which the parent owns in `Luma.entitlements`.
- The scope "every app on this Mac except Luma" assumes a display filter includes all apps' audio. Apple's `SCContentFilter` and `capturesAudio` pages do not spell this out. Confirm it in live QA.

### iOS capture (microphone)

- iOS has no API that lets one app hear another app's audio, so the source is honestly "Microphone". It picks up the room, including this device's own speaker.
- Permission: `AVAudioApplication.requestRecordPermission()`. Apple documents that this shows the system prompt the first time, and that the app exits without a purpose string. `NSMicrophoneUsageDescription` is added to both iOS build configurations. If the person denies access, the page says "iOS didn't allow Luma to use the microphone." and points to Settings › Luma › Microphone.
- Audio session: `.playAndRecord` with mode `.measurement`. Measurement mode turns off voice processing and automatic gain, which flatten music. The options are `.mixWithOthers`, `.defaultToSpeaker` and `.allowBluetoothA2DP`. Apple documents that `.playAndRecord` routes to A2DP only with that last option, so without it music would move off a Bluetooth speaker.
- The session refuses to start if the input format has a zero sample rate or no channels ("No microphone is available").
- The tap block is installed from a `nonisolated` function, so it never inherits LumaUI's default MainActor isolation on the audio thread.
- An interruption, or an engine configuration change, ends the session with a message.
- On stop, the session removes the tap, stops the engine, and calls `setActive(false, .notifyOthersOnDeactivation)`.
- There is no background audio mode. The existing background pause applies, and resuming is explicit.

### Mac sleep and lock

System sleep, a user switch and screen lock pause Audio Sync just as they pause Screen Sync. **Display sleep does not pause Audio Sync**, because displays often sleep while music plays. Whether ScreenCaptureKit keeps delivering audio while displays sleep is unverified. If it stops, the no-signal decay eases lights to the floor.
- Watch: nothing was added to LumaCore. All capture code is in LumaUI under `#if os(iOS)` or `#if os(macOS)`. The iOS scheme build, which includes LumaWatch, succeeds.

### Watchdogs

Native Screen Sync has no start or stall watchdog to reuse, and none was added. A start timeout would race the system consent prompt or microphone alert. That would end sessions the person was still approving, or treat a timeout as an answer. Stalls are handled by the no-signal decay above. The desktop keeps its own watchdogs.

## Integration notes for the parent

- The patch contains only post-baseline deltas:
  - Edited: `Sources/LumaCore/ScreenSync.swift`, `Sources/LumaUI/{ScreenSync,ScreenSyncView,ScreenSyncCapture,SystemAudioCapture}.swift`, `Tests/LumaCoreTests/AudioReactiveTests.swift`, and two lines in `ios/Luma.xcodeproj/project.pbxproj`.
  - New: `Sources/LumaUI/{AudioSyncCapture,MicrophoneAudioCapture}.swift`, `Tests/LumaAppTests/AudioSyncTests.swift`, and this doc.
- The pbxproj hunk is made against the parent's file that already has the Bluetooth keys. It adds `NSMicrophoneUsageDescription` after `NSLocalNetworkUsageDescription` in both iOS configurations.
- Untouched: `SettingsView.swift`, the macOS project, `Luma.entitlements`, BLE files, and desktop.
- Left for the parent: the menu-bar wording in `LumaApp.swift` still says "Screen Sync is capturing …" during an audio session. Use `store.screenSync.title`, and "Listening" when `source?.isAudio == true`. `RootView`'s page name stays "Screen Sync"; the page header switches to "Audio Sync".
- Suggested PARITY row: `Music mode | Native: Mac Audio Sync (ScreenCaptureKit system audio) and iOS microphone Audio Sync wired into the Screen Sync session; real capture not yet QA'd on hardware.`

## QA

- `swift test`: **180 Swift Testing tests pass** (94 core + 86 app). That is the 170 baseline plus 10 new. The 4 existing XCTest cases also pass.
- `swift build` is clean.
- `xcodebuild` **BUILD SUCCEEDED** for:
  - `ios/Luma.xcodeproj`, scheme LumaiOS, generic iOS Simulator, includes LumaWatch.
  - `macos/Luma.xcodeproj`, scheme Luma.
  - A simulator build with the microphone purpose string; `Info.plist` contains it.
- Combined check: the patch was applied to a copy of the parent worktree, which includes the Bluetooth integration. There, `swift test` passes **192 Swift Testing tests** (106 core + 86 app) and both `xcodebuild` builds succeed. The built iOS `Info.plist` carries both the Bluetooth and the microphone purpose strings.
- Real vs synthetic:
  - Every new app test drives fake sessions with hand-made `AudioLevels`.
  - The pump test runs a synthetic 60 Hz tone through the real analyzer.
  - None of these exercise OS capture.
- **iOS Simulator UI: blocked.** The three simulators opened through T3 `device_open` were all claimed by other agent sessions:
  - "Luma Shots iPhone 6.9" by `t3-ca5d121f…`, still busy after a 90 s `--wait`.
  - "Luma Shots iPad 13" by `t3-b51c2fb8…`.
  - "iPhone 17 (iOS 27.0)" by the parent worktree's `t3-c2782105…`.

  They were not reused or closed.

  Step to finish: once a simulator is free, `device_open` it, then:
  1. Install `Luma.app` from the LumaiOS simulator build.
  2. Open Screen Sync → Audio → Use Microphone → Start.
  3. Accept the real iOS microphone alert.
  4. Confirm the meter moves and that Stop returns to idle.
  5. Then deny access in Settings and confirm the denial text.
- **Mac UI: blocked.** This session has no native computer-use tool, and the brief forbids further agents. Step to finish:
  1. Run the macOS app and open Screen Sync → Audio → Listen to Mac Audio….
  2. Pick a display, Start, and grant Screen & System Audio Recording in the real macOS prompt.
  3. Play music and confirm the meter and the "Listening" status, and that Luma's own sounds are excluded.
  4. Check whether the stream keeps delivering buffers during silence. If it does not, the no-signal decay covers it.
- Not done:
  - No real light was driven.
  - LAN latency with audio was not measured.
  - The LAN limit noted in AUDIO-SYNC.md applies: about 5 updates per field per second at the 10 Hz cap.
