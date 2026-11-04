# Luma for Android

A native Android client in [`android/`](../android): Kotlin, Jetpack Compose, Material 3, Gradle Kotlin DSL.
`applicationId` is `com.designxdevelop.luma`, `minSdk` is 26, and `targetSdk` is 36. `versionName` stays `1.0`: only `versionCode` goes up.

## Build and test

```bash
cd android
export JAVA_HOME=$(/usr/libexec/java_home)   # Android Studio's JBR works
./gradlew test assembleDebug
```

The build needs an Android SDK with platform `android-36.1`. Set `sdk.dir` in `android/local.properties`, which is gitignored, or set `ANDROID_HOME`.
The unit tests read the shared fixtures from `desktop/src/test/fixtures` through the `luma.fixtures` system property. The files are not copied.

Toolchain: AGP 9.4.1 (with built-in Kotlin), Gradle 9.7.1, Kotlin 2.4.10 and Compose BOM 2025.12.01.
Newer Compose BOMs need compileSdk 37.

## Layout

| File | What it is |
| --- | --- |
| `core/Model.kt` | Port of `Models.swift`: devices, commands, scenes, schedules (Apple weekday numbering), and JSON helpers with Swift-style number equality |
| `core/Capabilities.kt` | `CommandValidation`, `DreamView`, the Govee scene library and device readings |
| `core/Lan.kt` | `LanPacket` (wire format, byte-identical to the TS and Swift clients) and `GoveeLan`: UDP multicast scan to 239.255.255.250:4001, replies on 4002, status and control to 4003 |
| `core/Cloud.kt` | `GoveeCloud`: the same pacing (84 ms per account, 1 s per device, 2 s per repeated read, a pause on 429), reads retried once, commands never retried, errors that never echo the key |
| `core/Backup.kt` | The `luma-home-backup` v1 codec and restore rules, plus the shared schedule-sync helpers (base32, certificate pin, `luma1/…` pairing codes) |
| `core/Demo.kt` | The same demo home as `HomeStore.loadDemo()` on iOS |
| `core/SyncClient.kt` | The paired-device half of schedule sync, with a pinned-TLS transport |
| `core/Streaming.kt` | Screen Sync and Audio Sync math: grid, letterbox, smoothing, mixer, audio mapper and FFT (same constants as Mac and desktop) |
| `core/Ble.kt` | The Govee BLE frames, status parsing, profiles, and V1/V2 link encryption and session |
| `core/GoveeHome.kt` | Govee Home account sign-in and the parsers for rooms, groups and automations |
| `HomeStore.kt` | App state (an `AndroidViewModel`): discovery, control, scenes, schedules, sync, floor plans, backups |
| `Schedules.kt` | Exact-alarm schedules and the headless scene runner |
| `ScheduleSync.kt` | Pairing state and sync loop for schedule sync |
| `KeyStore.kt` | Secrets (API key, pairing token, Govee Home session), encrypted with AES-GCM under an Android Keystore key |
| `MainActivity.kt`, `LightsUi.kt`, `ScenesUi.kt`, `FloorPlanUi.kt`, `SyncUi.kt`, `BluetoothUi.kt`, `GoveeHomeUi.kt` | The Compose UI |
| `Shortcuts.kt` | The Quick Settings tile, the home-screen widget (Glance), and the shared headless power control |
| `Wear.kt` and the `wear/` module | The Wear OS companion and its phone relay |

## Implemented

- **Onboarding:** the Govee API key is optional. There are three options: connect your account (with a "Get a free API key ↗" link), add local control (LAN Control lights on the same Wi-Fi need no key), or try the demo. The copy matches iOS, macOS and desktop.
  - The key is encrypted with a non-exportable Android Keystore AES-GCM key. Only the ciphertext is stored, in private SharedPreferences.
  - `allowBackup` is off, so the key is never put in a cloud backup.
- **Home (Lights by room):**
  - A room switch for power, and Adjust for room brightness and white.
  - "All off".
  - Tiles tinted with each light's color. Tap a tile to toggle the light.
  - The chevron opens the light's controls. Long-press opens a menu: Controls…, Rename…, Move to room….
  - A "Name it" chip on lights with SKU-style names.
  - Offline and off states.
- **Light controls:**
  - Power and a 64 dp brightness bar.
  - A Color / White segmented choice: 8 color presets plus a custom hue, and Warm 2700 K / Neutral 4000 K / Daylight 6500 K plus a kelvin slider limited to the device's range.
  - Effects: a Govee built-in and DIY scene browser with search and kind filters. Lists are loaded from the cloud on demand.
  - A DreamView toggle (the cloud `dreamViewToggle`).
  - Readings (sensor values and appliance modes).
  - Details.
  - "Save this look as a scene".
  - Rename with "Use original name". Names are limited to 64 characters and used only by Luma.
- **Scenes:**
  - Run and Stop. One scene runs at a time, and its steps are validated before any is sent.
  - Delete. This also deletes the scene's schedules.
  - New scene from the current lighting of the lights you select.
- **Schedules:** time, days and scene, with an enable switch, edit and delete. They use the same `SceneSchedule` model and `lastRunMinute` de-duplication as the other clients.
  - They run with Luma closed. One `AlarmManager` alarm is armed for the next run across all schedules, and it is re-armed after a run, a reboot, an app update, a clock or time-zone change, or a change to alarm access.
  - With "Alarms & reminders" access (`SCHEDULE_EXACT_ALARM`) the alarm is exact. Without it the alarm is inexact, and a run delivered more than 2 minutes late is logged as missed, the same grace as `ScheduleSync.runGrace`. Automations shows an "Allow exact alarms" button.
  - If the app is alive, the scene runs through it. Otherwise a receiver sends the steps headlessly: LAN for basic controls, the cloud for the rest.
  - The demo home never arms alarms. Its schedules tick in-app.
- **Schedule sync (paired device):** Settings → Schedule sync → Pair, using a `luma1/…` code from a Mac or PC running Luma.
  - The runner runs the schedules, and the phone arms no alarms of its own.
  - The phone mirrors shared scenes and schedules and sends its edits as operations: `put` with a base revision, `reduce` for turning off or pausing, and `delete`. This is a port of the paired-device functions in `desktop/src/core/schedule-sync.ts`.
  - It syncs every 30 s while Luma is open, and after each edit.
  - HTTPS requests are checked against the pairing pin in the TLS handshake, before the bearer token is sent. The token is sealed in the Keystore.
  - Turning sync off turns this phone's schedules off, so nothing runs twice. Restoring a backup is refused while paired, as on iOS.
- **Segment painter:** for lights that advertise `segmentedColorRgb` or `segmentedBrightness`.
  - Select segments (all, every other, or none), then paint them with presets, a rainbow or a brightness level.
  - Apply sends one command per value, in segment order. Save as scene is also offered.
  - This is a port of `SegmentPaint.swift`. The demo strip has the documented schema, so you can try it.
- **Floor plan:** Home → Rooms / Plan.
  - Add floors from a photo. The image is re-encoded as a PNG of at most 4096 px, with no metadata.
  - Tap a pin to toggle the light; long-press it to open the light's controls.
  - Edit mode: drag pins (each light has one pin), add lights from the tray, remove pins, rename, replace the image, or delete a floor.
  - Missing and offline lights get their own pin style.
  - The demo includes a drawn sample plan.
- **Screen & audio sync:** Settings → Sync & Bluetooth.
  - Camera: the back camera, aimed at a TV, through CameraX. Frames are reduced to a 30×18 grid on the phone, and nothing is stored.
  - Microphone: 48 kHz mono, analysed into loudness plus 8 bands. No audio is kept.
  - Pulse or Spectrum style, sensitivity, a brightness cap, smoothing and vivid mode. Each light can follow its own region (thirds, edges or corners).
  - It sends latest-only LAN updates, at most 5 a second per light, and never turns lights on or off.
  - The demo adds a Sample source.
  - The math is a port of `ScreenSync.swift` and `AudioReactive.swift`, checked against the desktop vectors.
- **Bluetooth lights:** Govee TV backlights (H6097, H6099, H66A0) over BLE.
  - Scan and connect. Luma reads the encryption marker, then negotiates V1 or V2 encryption, failing closed.
  - Controls: power, brightness, color, Movie/Game video mode, and DreamView on/off, each only where the model profile allows it.
  - Readback: power, brightness and firmware.
  - Other Govee lights are listed but can't be controlled.
- **Govee Home account (read-only):** sign in (email, password, and the emailed code when Govee asks for one), or import a saved device-list file.
  - Room changes are offered with checkboxes and applied only to lights Luma already knows.
  - DreamView group names and light counts appear on the TV light.
  - Govee automations are listed on Automations, with a warning when one fires at the same minute as a Luma schedule on the same light.
  - The password isn't stored. The session token is sealed in the Keystore.
- **Quick Settings tile ("Lights"):** turns every light off, or all back on when they're all off. It shows how many lights are on.
- **Home-screen widget:** up to 5 rooms, each with an on/off toggle.
- **Wear OS app** (`wear/`): All off, room switches and scenes. It relays through the phone over the Wearable Data Layer, as the Apple Watch relays through the iPhone.
- **Restore point:** after a scene runs, Scenes offers "Before …" → Restore, which puts the lights back to the power, brightness and color they had before. This is one level deep, as on iOS.
- **LAN scan on every launch** (outside demo mode), plus "Scan now" in Settings.
  - Uses `CHANGE_WIFI_MULTICAST_STATE` and holds a `WifiManager.MulticastLock`.
  - Lights found on the LAN merge with cloud lights by ID.
  - Power, brightness, color and white go over LAN when a light has an address. Everything else goes through the cloud.
- **Settings:**
  - Govee key: add, change or remove.
  - Local network status.
  - Enter or leave the demo.
  - Backup export and import through the system file picker.
  - An activity log.
  - The version (`1.0 (versionCode)`).
- **Backup interop:**
  - The iOS-exported `native-backup.json` fixture restores on Android, and Android's export decodes in the other clients' format (integers stay integers, ISO-8601 dates, uppercase UUIDs, null fields omitted).
  - A safety copy (`home-before-restore.json`) is written before a restore.
  - DreamView drafts in a backup are kept as opaque data.
- **Demo mode** loads the same sample lights, scene lists and scenes as iOS.
  - It never starts LAN discovery or cloud requests. Commands only change the preview.
  - Demo changes aren't saved, as on iOS.

## Not implemented yet

| Feature | Why |
| --- | --- |
| **Long scenes from a closed app** | The headless alarm receiver has about 10 s, so a scheduled scene whose step delays add up to more than 9 s is cut short when Luma isn't running. The upgrade path is an expedited WorkManager job. |
| **Being the schedule runner** | A phone can pair with a runner but can't be one. A runner needs an always-on LAN HTTPS server, and Android stops background servers. The hub replay in `schedule-sync-vectors.json` is the runner's role, so it isn't run here. Taking over as runner and retiring a runner are runner features too. |
| **Syncing the phone's own screen** | Sync uses the camera, as on iPhone. Mirroring what plays on the phone needs MediaProjection plus a foreground service of type `mediaProjection`. |
| **Sync in the background** | Sync runs while its screen is open; closing the screen stops it. |
| **DreamView group editing, BLE capture decoding** | Writing group members needs each member's `cmd_ver`, which can't be read, so iOS blocks it too (`DreamViewDraft.applyBlocker`). `GoveeBLECapture` is a research tool for packet captures and wasn't ported. |
| **Verifying Bluetooth and Govee Home against real hardware** | Both are unit-tested against the Swift vectors and response shapes. Bluetooth wasn't exercised: the emulator has no BLE, and QA sends no commands to real lights. Govee Home sign-in wasn't exercised either, because it needs a real account password. |
| **Verifying the widget and Wear app on a device** | The widget and Wear module build, but neither has been tried on a launcher or watch yet. No Wear AVD is installed here. The Quick Settings tile was tested. |
| **Pan and zoom on floor plans** | The plan fits the screen width. A pinch-zoom (`transformable`) layer is the upgrade. |
| **iCloud sync, doorbell alerts, webhooks, Alexa relay** | Apple-only or desktop-server features. Android has no iCloud; webhooks and the Alexa relay need an always-on local server. |

## QA

Screenshots in [`qa/android/`](qa/android) were taken in demo mode on the `Pixel_10_Pro` emulator (API 37) using the argent tools:

- onboarding;
- Home;
- light controls (Color + DreamView, and White);
- the effects browser;
- Scenes;
- Settings after importing the iOS `native-backup.json` fixture;
- Automations, where the imported `[2,3,4]` schedule shows as Mon, Tue, Wed;
- room Adjust;
- schedule sync paired with a real desktop runner;
- floor plan;
- segment painter;
- Sample and camera sync;
- the Quick Settings tile;
- Bluetooth.

No real light was contacted. The demo disables LAN and cloud. The schedule-sync and alarm tests used a fake light at 192.0.2.10, an unroutable documentation address. Bluetooth was never scanned or connected.
