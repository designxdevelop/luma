# Audio Sync: lights that follow computer audio

Written 2026-11-02 by the Audio Sync parity pass. It is a standalone report and does not edit PARITY.md, README or VERIFICATION. It closes the PARITY-REMAINING row "Music mode from computer audio".

Govee Home's music mode uses each light's own microphone. Luma already exposes that through the generic `musicMode` capability. This pass adds what Govee Home lacks on a PC: the lights follow the audio the computer itself plays, streamed over LAN through the existing Screen Sync transport.

Evidence levels: **tests** = automated tests. **UI** = driven in the Electron demo build through CDP (argent), with screenshots. **build** = compiles. Hardware response was **not** checked: there is no light on this machine's network, and nothing was sent to a real light.

## What shipped

### Windows/Linux (Electron): complete feature; Windows/Linux capture not run on hardware

| Piece | What it does | Evidence |
| --- | --- | --- |
| Capture: system audio | `getDisplayMedia` is answered with `{ video: <Luma's own page>, audio: 'loopback' }`. This is Electron's documented system-audio loopback (WASAPI loopback on Windows). The video track is Luma's own window, never a screen or another window, and the renderer stops it at once. Plain `loopback` is used, not `loopbackWithMute`, so the music keeps playing | tests (policy). **Windows runtime not exercised here** (macOS host) |
| Capture: Linux | Offered as **experimental**. Electron documents loopback for Windows only. Luma attempts Chromium's PulseAudio/PipeWire loopback; if the result has no audio track, it ends with a clear message that points to Default input | Unverified (no Linux host) |
| Capture: Default input | `getUserMedia({ audio })` with echo cancellation, noise suppression and auto gain **off** (voice processing flattens music). Covers a microphone, line-in, Stereo Mix, VB-Cable, or a Linux monitor routed with pavucontrol → Recording, or `pw-loopback` | UI: pump → IPC → mapping → preview, using a test signal (see QA) |
| Analysis | Web Audio `AnalyserNode` (FFT 2048, no browser smoothing), never connected to the speakers. The renderer sends only 9 numbers 20 times a second: RMS loudness (−60…0 dBFS → 0…1) and 8 log-spaced bands from 40 Hz to 16 kHz (mean bin power, −90…−20 dB → 0…1). Samples never leave the renderer and are never stored | tests (sine and spectrum vectors), UI |
| Mapping (`shared/audio-math.ts`) | **Pulse**: every light gets one color from spectral balance (bass red → treble blue-violet) and one brightness from loudness. **Spectrum**: lights spread bass → treble in the order they were ticked; each takes its band's level and hue. Sensitivity runs 0.5–2× | tests |
| Brightness limits | Noise gate (≈ −55 dBFS), so hiss stays still. Automatic gain: the remembered peak halves every 4 s with a floor, so quiet songs still move. **Floor = a fifth of the cap**, so lights never black out between beats. Never above the Screen Sync brightness cap. The first write to each light is the capped brightness, never a full-scale color | tests: 3000 random frames per style stay within floor…cap |
| Flash safety | 50 ms attack. Release is 0.25–1.2 s (the "Release" slider). A 10 Hz on/off input moves brightness < 30 % of the range; a 1 Hz beat swings > 80 %. Full-depth swings therefore stay well under 3 per second (the WCAG 2.3.1 general flash threshold); this is a design bound, not a photosensitivity certification | tests |
| Session coordination | Audio is a second *kind* of the one `SyncController` session, so everything Screen Sync guarantees applies unchanged: one session at a time (Screen ↔ Audio returns 409), refused while a scene runs, scenes and webhooks refused while streaming, manual control takes a light out after its in-flight datagram, LAN only, latest-only per-light rate cap, start/stall watchdogs, explicit-Stop restore, tray Pause/Stop | tests |
| Permissions and privacy | Electron allows one display-media handler and one permission handler, so `capture.ts` still owns both and asks the pure policy in `main/audio-capture.ts`. An audio session gets loopback **or** an audio-only media grant, single use, tied to its generation, for 10 s. A screen session can never get audio, and an audio session can never get a screen source. The Linux lock observer gates audio starts too. Nothing about audio is logged, only start/stop lines | tests (decision matrix, grants) |
| Release | Stop, the watchdog, renderer reload/crash, tray Stop and quit all stop every track, disconnect the graph and `close()` the AudioContext | UI (stop returns to "No signal yet") |
| Background | Designed so an audio session keeps running with the window hidden in the tray (music plays with Luma closed). Main turns off renderer background throttling (`webContents.setBackgroundThrottling(false)`) only while an audio session is live. Screen Sync keeps pausing on hide/minimize. Display changes stop only screen sessions | **Unverified.** Hiding the window from the page (`window.close()`) destroyed the renderer instead, which correctly hit the renderer-loss stop. Hiding through OS automation was skipped to avoid another permission prompt. Check this on Windows: hide to tray for at least 5 minutes and watch that Analysis frames keep rising by about 20/s |
| UI | Sync page (nav renamed "Sync") with a Screen / Audio switch, a source choice, a live level meter (8 bands + loudness, painted through CSSOM because the CSP forbids inline styles), light selection with bass/mid/treble labels, Pulse/Spectrum, Sensitivity, shared Response sliders (cap, release, update speed, threshold) and the restore choice. A persistent "Audio Sync is live · listening to …" banner on every page. Audio choices persist in the renderer profile | UI screenshots |
| Demo | Audio Sync **always uses real audio**. In demo, only the lights are simulated, and the page says so. There is no synthetic signal. The "demo never captures the screen" rule is unchanged | UI |

### Mac/iPhone/iPad (native): core and capture building blocks

| Piece | What | Evidence |
| --- | --- | --- |
| `LumaCore/AudioReactive.swift` | Port of the mapping with identical constants and rounding: `AudioMapper`, band and loudness math, and `AudioSpectrum` (Accelerate vDSP Blackman FFT scaled like Web Audio's AnalyserNode, so Mac bands equal desktop bands) | `AudioReactiveTests`: **byte-identical light values to vectors produced by the TypeScript module**, tone → band placement, floor/cap bounds, flash damping |
| `LumaUI/SystemAudioCapture.swift` (macOS) | ScreenCaptureKit audio capture (`capturesAudio`, `excludesCurrentProcessAudio`, 48 kHz stereo → mono, 2×2/1 fps video never read). Analyzed on a private queue about 20 times a second; latest-only delivery to the main actor; `stop()` releases | build (`swift build`, macOS app). **Not run live** (would need a capture permission prompt on this machine). **Not wired into the UI yet** |

## Integration (exact, minimal)

### Electron: already in the patch

All changes are in `desktop/`. New files: `src/shared/audio-math.ts`, `src/main/audio-capture.ts`, `src/renderer/audio-sync.ts`, `src/renderer/audio-view.ts` and `src/test/audio-sync.test.ts`. Small, anchored edits to shared files:

- `shared/types.ts`: `SyncKind`, `AudioSource`, `AudioOptions`, `AudioSupport`, `AudioGrant`. `SyncView` gains `kind`, `audio` and `audioSupport`. `LumaBridge` gains `audioStart`, `audioLevels` and `audioOptions`.
- `main/sync.ts`:
  - `start(lights, sourceName, kind = 'screen')`.
  - The frame gate is factored into a private `admit()`, shared by `frame()` and the new `levels()`; `offer()` and `emitStats()` are extracted unchanged.
  - New `setAudio()`. Labels follow the kind. `view()` gains the new fields, and `synthetic` is true only for screen sessions.
  - Screen behavior is unchanged, and all existing sync tests pass.
- `main/capture.ts`:
  - The display-media and permission handlers branch on session kind through `displayMediaDecision` / `audioOnly`.
  - New `startAudio()`. `revoke()` clears both grant types.
  - Display changes stop only screen sessions.
- `main/main.ts`:
  - `audioSupportFor(process.platform)` feeds `Home` (via the existing `syncOptions`) and the capture adapter.
  - Three IPC handlers.
  - Tray and `syncEnded` wording per kind.
  - Hide/minimize pauses only screen sessions.
  - Background throttling is off while audio is live.
- `main/preload.ts`: three bridge entries.
- `renderer/app.ts`:
  - Import and `initAudioSync()`.
  - Route the Sync page by mode.
  - Mode switch in the Screen Sync header.
  - Audio banner branch.
  - `audio|` slider commits.
  - `paintAudio()` after render.
  - `followAudio()` on snapshots.
  - Nav label "Sync".
- `renderer/static/styles.css`: meter styles (appended).
- `home.ts`, `storage.ts` and `sync-math.ts` are **not** touched. Audio options are not added to the persisted `SyncSettings`, so an older build can still read a newer home file. The renderer keeps them in its profile and sends them with Start.

### Native: to do (needs the ScreenSync owner)

1. `LumaCore/ScreenSync.swift`: add `ScreenSyncMixer.tick(now:targets: [String: LightTarget])`, the same lane logic as `tick(now:lights:)` (rate cap, threshold, dim-first, cap override) fed with ready targets instead of region colors.
2. `LumaUI/ScreenSync.swift`:
   - Add `ScreenSource.Kind.audio`, whose session is a `SystemAudioCapture` built from the picker's filter.
   - In `start()`, use `start(onLevels:onEnd:)` for audio sources.
   - In `receive(levels)`, call `AudioMapper.step` (light order = `regions` keys, sorted by name) and then the new mixer `tick(now:targets:)`.
   - Persist `AudioSyncOptions` beside `screenSync.settings`.
   - The existing exclusivity, `yield`, restore and readback stay as they are.
3. `LumaUI/ScreenSyncView.swift`: add a Screen/Audio picker, a style and sensitivity control, and a meter.
4. Privacy: Screen Sync's existing ScreenCaptureKit consent covers it. The Mac App Store entitlements need nothing new (no microphone).
5. iOS: no system-audio capture API for other apps, the same reason iOS Screen Sync uses the camera. A microphone source (`AVAudioEngine` input tap feeding `AudioSpectrum`) would be the iOS analogue. It would need `NSMicrophoneUsageDescription`; not built.

## QA performed

- `npm test` (desktop): **238 pass** (221 baseline + 17 new). `npm run typecheck` is clean.
- `swift test`: **170 Swift Testing tests pass** (166 baseline + 4 new), plus the 4 existing XCTest cases. `swift build` is clean. `xcodebuild` **BUILD SUCCEEDED** for `ios/Luma.xcodeproj` (scheme LumaiOS, generic iOS Simulator, no signing) and `macos/Luma.xcodeproj` (scheme Luma).
- UI, Electron demo on macOS, driven over CDP:
  1. Sync → Audio shows "Computer audio (Windows and Linux)" disabled and Default input selected. Correct for macOS. → `electron-audio-sync-idle-macos-demo.png`
  2. **Real microphone path:** Start asked macOS for microphone access for the development Electron binary (TCC `not-determined`). By policy, the prompt was **not** clicked. `getUserMedia` waited, and the 15 s start watchdog ended the session with "Capture did not start". This verifies the stuck-capture lifecycle, not capture itself.
  3. **Pipeline:** `getUserMedia` was replaced, from the test harness only, by a Web Audio test signal (a 60 Hz tone gated at 1 Hz, plus a quiet 3 kHz tone). That exercises the real pump → IPC validation → mapping → stream → preview path, but **not OS capture**. Observed:
     - 20 analysis frames/s and 0 dropped.
     - The meter showed bass and 1.7–3.6 kHz energy.
     - Pulse brightness followed the 1 Hz gate between 70 and 80 % under the 80 % cap.
     - Switching to Spectrum live gave bass light red at 79 %, mid green, and treble violet at the 16 % floor.
     - Stop returned the page to idle and "No signal yet". → `electron-audio-sync-live-pulse.png`, `electron-audio-sync-live-spectrum.png`
- Display-media plumbing probe, Electron 44 on macOS 27, shown window:
  - `{ video: frame }` resolved in 410 ms (1 video track).
  - `{ video: frame, audio: frame }` resolved in 141 ms (1 video + 1 audio track).
  - `{ video: frame, audio: 'loopback' }` did not resolve within 12 s.
  - So the frame-as-video shape Luma uses works, and only loopback is unavailable on macOS, matching Electron's Windows-only documentation. macOS stays input-only in the Electron build.
- The parent worktree's copies of every baseline file are byte-identical to the snapshot this was built on, and the parent has no other changes, so these results carry over. `git apply --check` passes there.
- The iOS scheme build includes the LumaWatch target, which compiles `LumaCore` (now importing Accelerate) for watchOS.

## Limitations

- **Not verified on Windows or Linux hardware**, and **not verified with a real light**. Windows loopback is Electron's documented path but was not exercised here. Linux loopback is experimental by design.
- LAN rate: Govee LAN takes color and brightness as separate datagrams, and the per-light cap is 10/s, so each field updates at about 5/s at best. Audio Sync is rhythmic ambience, not frame-accurate beat flashing. Per-segment real-time modes (`razer`/`ptReal`) remain unverified (PARITY-REMAINING).
- Latency is analysis (≤ 50 ms) + IPC + the rate cap + the light's own fade. It was not measured on hardware.
- Pause on hide/minimize does not apply to audio. A minimized Luma keeps listening, which the tray tooltip, the tray menu and the banner show.
- Native: core and capture only; the UI wiring above is pending.

## Suggested PARITY.md row (for the doc owner)

`Music mode | Partial → Implemented (Windows; Linux experimental): computer-audio Audio Sync over LAN, Pulse/Spectrum, brightness floor and cap. Native: core + ScreenCaptureKit capture built, UI wiring pending.`
