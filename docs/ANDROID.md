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
| `HomeStore.kt` | App state (an `AndroidViewModel`): discovery, control, scenes, the schedule ticker, backups |
| `KeyStore.kt` | The Govee API key, encrypted with AES-GCM under an Android Keystore key |
| `MainActivity.kt`, `LightsUi.kt`, `ScenesUi.kt` | The Compose UI |

## Implemented

- **Onboarding:** connect a Govee API key, use the local network only, or try the demo.
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
| **Reliable background schedules** | Schedules run from an in-app ticker (checked every 15 s) while Luma's process is alive: open, or recently in the background. Android can kill the process, so a run can be missed. WorkManager can't be used because its minimum interval is 15 minutes and it doesn't run at an exact minute. The upgrade path is exact alarms (`SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`) that start a short foreground service. |
| **Schedule sync with a computer runner** | Only the shared pure helpers are ported (base32, pin, pairing-code parsing, tested against `schedule-sync-vectors.json`). The phone-side client (`stage`/`buildBatches`/`applyResponse`) and the pinned-TLS transport still need porting. The hub replay in the vectors is the runner's role, which Android doesn't take. |
| **Camera / screen sync, audio sync** | They need MediaProjection or camera capture and a streaming loop. No Android capture code exists yet. |
| **Bluetooth (BLE) control** | Govee's BLE protocol and encryption (`GoveeBLE*.swift`) aren't ported. They would also need the `BLUETOOTH_SCAN`/`CONNECT` runtime permissions. |
| **DreamView group editing, segment painting** | Not ported. The iOS app also blocks writing DreamView members (see `DreamViewDraft.applyBlocker`). |
| **Floor plan, iCloud sync, Govee Home sign-in import, doorbell alerts, webhooks, Alexa relay, Watch** | Apple-platform or desktop features that this first Android version leaves out. Android has no iCloud, and webhooks need a local server. |
| **Restore point after a scene** | iOS saves a "Before …" scene. Android doesn't yet. |
| **429 `Retry-After`** | The cloud client always pauses for 60 s after a 429 instead of reading the header (marked `ponytail:` in `Cloud.kt`). |
| **Effect feedback inside sheets** | The "sent" snackbar appears behind the light sheet. |

## QA

Screenshots in [`qa/android/`](qa/android) were taken in demo mode on the `Pixel_10_Pro` emulator (API 37) using the argent tools:

- onboarding;
- Home;
- light controls (Color + DreamView, and White);
- the effects browser;
- Scenes;
- Settings after importing the iOS `native-backup.json` fixture;
- Automations, where the imported `[2,3,4]` schedule shows as Mon, Tue, Wed;
- room Adjust.

No real light was contacted: the demo disables LAN and cloud.
