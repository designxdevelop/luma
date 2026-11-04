# Windows/Linux parity with the Mac and iPhone apps

This is a feature-by-feature check of the native apps (`Sources/LumaCore`, `Sources/LumaUI`) against the Electron app in `desktop/src`. It was written on 2026-11-02 against main `cd6b662`.

Status values:

- **Done**: shipped on Windows/Linux before this pass.
- **Added**: built in this pass.
- **Windows equivalent**: the Apple feature doesn't exist on Windows, and Luma does the same job another way.
- **N/A**: doesn't apply to Windows, with the reason.

Every release ships as version 1.0. The desktop package is now `1.0.0` (it was `0.2.0`), and the installer is `release/Luma Setup 1.0.0.exe`.

## Lights and rooms

| Feature | Mac/iPhone source | Mac/iPhone | Windows/Linux | Notes |
| --- | --- | --- | --- | --- |
| Light list, search, online state, rename, rooms | `LightsView`, `HomeStore` | Yes | Done | `renderer/app.ts` `lightsView` |
| Room header: "N of M on" and an On/Off switch for the room | `LightsView.roomHeader` | Yes | **Added** | A switch with the live count replaces the separate On/Off buttons. Only lights with a power switch are touched, never appliances |
| Room Adjust: brightness 10/25/50/75/100 and white presets | `LightsView.roomHeader` menu | Yes | **Added** (presets) / Done (slider, white) | Each light is clamped to its own range in main (`Home.roomAction`) |
| All on / All off | `LightsView`, menu bar | Yes | Done | Lights only |
| Scan for LAN lights on every launch | `HomeStore` launch | Yes | Done | `main/main.ts`: `home.discover()` runs on every launch that has a saved home |
| Appliances and sensors listed, with readings | `DeviceReadings`, `DeviceReadingsCard` | Yes | Done | `core/readings.ts` |

## Light sheet (`DeviceSheet`)

| Feature | Mac/iPhone | Windows/Linux | Notes |
| --- | --- | --- | --- |
| Power, brightness, color, white, presets | Yes | Done | Inspector › Light |
| Readings card | Yes | Done | `readingsList` |
| DreamView Start/Stop and reported state | Yes | Done | |
| DreamView **Save Movie scene** (power on first, then the toggle last) | Yes | **Added** | |
| DreamView group readback from Govee Home (name, reported count, enabled) | Yes | **Added** | Matched by the group's main device. Uses the Govee Home sign-in that was already there |
| DreamView partner draft (members, screen areas 1–10, model limits; never sent) | Yes | **Added** | Same `{members:[{deviceID, areas}]}` shape as native and in backups. Main validates it: model limit, at least one area, not the main light itself. Apply stays disabled, with the native explanation |
| "Save this look as a scene" | Yes | **Added** | Opens Capture with that one light |
| Govee scene list for one light (search, type filter, apply, save as scene) | Yes (`GoveeSceneList`) | **Added** | Inspector › Effects. The existing per-capability forms stay below it |
| Segment painter | Yes | Done | |
| Generic capability form / advanced JSON | Yes | Done | |
| Details (model, ID, firmware) | Yes | Done | |

## Scenes, schedules and automation

| Feature | Mac/iPhone | Windows/Linux | Notes |
| --- | --- | --- | --- |
| Luma scenes: editor, JSON, import/export, capture, duplicate | Yes | Done | |
| Restore lights after a scene | Yes | Done | |
| **Govee scene browser** (by room or light; one name applied across a room; skipped lights named) | Yes (`GoveeSceneBrowser`, `RoomActions.applyGoveeScene`) | **Added** | Scenes › Govee scenes. `shared/library.ts` ports `GoveeSceneLibrary`: dedupe, placeholder names, accent-insensitive search, kind+name match |
| Schedules (weekdays, pause, enable) | Yes | Done | |
| Shared schedules over the LAN (`ScheduleSync`, runner/paired) | Yes | Done | Same records and vectors (`desktop/src/test/fixtures/schedule-sync-vectors.json`) |
| Same-account schedule failover (`ScheduleFailover`, `ScheduleCoordinator`) | Yes (iCloud) | **Windows equivalent** | Failover runs on CloudKit leases between devices on one Apple ID, and Windows can't join them. On Windows, LAN schedule sync does the same job: one runner, devices that pair with it never run schedules, and a forced take-over waits until the old runner confirms. These don't conflict. Coordination isn't part of the LAN records (`ScheduleSync.swift` has no coordination field). While a Mac shares schedules over the LAN, `HomeStore.tickSchedules` returns before the coordinated path, so a schedule can't run on both |
| Webhooks (local HTTPS, token, SPKI pin) | Yes | Done | |
| Doorbell alert, Alexa relay | Yes | Done | |
| Govee Home sign-in, room import, automation conflict hints | Yes | Done | |

## Sync

| Feature | Mac/iPhone | Windows/Linux | Notes |
| --- | --- | --- | --- |
| Screen Sync with regions | Yes | Done | |
| Screen Sync from the iPhone camera (`ScreenSyncCamera`) | iPhone | **N/A** | The camera is there because an iPhone can't capture a TV. A PC captures its own screen directly |
| Audio Sync (system audio / microphone) | Yes | Done | WASAPI loopback / PipeWire |

## Floor plans

| Feature | Mac/iPhone | Windows/Linux | Notes |
| --- | --- | --- | --- |
| Floors from an image, named, renamed, replaced, deleted | Yes | **Added** | Floor plan page. Main re-encodes the image as PNG with `nativeImage`, at most 4096 px on the long side, which drops EXIF/GPS. The limit is 20 MB, PNG or JPEG |
| Pins: one place per light across all floors; click toggles; open the light's controls | Yes | **Added** | Click toggles power if the light is online. Double-click opens its controls |
| Edit mode: place from the tray, drag, remove | Yes | **Added** | Drag pins, drop tray chips onto the plan, drag a pin back to the tray. **Keyboard:** arrow keys nudge (Shift for a bigger step), Delete removes |
| List view (accessible alternative, top to bottom) | Yes | **Added** | Also shown when the image can't be read |
| Missing or offline lights keep their place | Yes | **Added** | Shown with a dashed marker |
| Zoom / pan | Yes | **Not built** | `ponytail:` the plan scales to the window. Add zoom if big plans need it |
| Storage format | `floor-plans/plans.json` + `<UUID>.png` | **Added**, same format | `main/floor-plans.ts` in `userData/floor-plans`. Files are 0600 in a 0700 folder. A `plans.json` that can't be read is preserved and nothing is saved over it, as on native |
| Floor plans in iCloud sync | Yes | **N/A** | No iCloud on Windows. Native backups don't contain floor plans either (`HomeBackup` has no floor field), so the backup format is unchanged |

## Backup and restore

| Field | Mac/iPhone | Windows/Linux |
| --- | --- | --- |
| `format`, `version`, `exportedAt` (ISO-8601 without fractional seconds) | Yes | Done |
| `scenes` (with `symbol` and `icon`), `schedules`, `lights` (`id`, `sku`, `customName`, `room`) | Yes | Done |
| `dreamViewDrafts` | Yes | Done. Windows now edits drafts too, in the same shape |
| Floor plans, coordinations | Not in the backup | Not in the backup (matches) |

Round trips are covered by `fixtures/native-backup.json` and the Swift `CrossPlatformBackupTests`.

## Tray (Mac menu bar)

| Feature | Mac menu bar (`LumaApp.MenuBarView`) | Windows/Linux tray | Notes |
| --- | --- | --- | --- |
| Header "Luma · N of M lights on" | Yes | **Added** | |
| All lights on/off | Yes | Done | |
| Per-room On/Off submenus "‹room› · N of M on" (when there's more than one room) | Yes | **Added** | `shared/library.ts` `roomPower`: lights with a power switch only, and Unassigned last |
| Lights by room (opens the light) | — | Done | Kept, Windows-only |
| Run / stop a scene; Screen/Audio Sync pause and stop; Settings; About; Quit | Yes | Done | |

## Apple-only features

| Feature | Decision | Reason |
| --- | --- | --- |
| Siri / App Intents / Shortcuts (`RoomActions`, `LumaIntents`) | **Windows equivalent** | The authenticated local webhooks (`all`, `room:`, scenes) and the `luma-bridge` CLI cover scripting and voice assistants. The tray covers quick room control |
| Apple Watch (`WatchLink`, `WatchState`, `WatchRelay`) | **N/A** | There's no watch platform for Windows/Linux |
| iCloud configuration sync (`CloudSync*`, `SyncLedger`) | **Windows equivalent** | Scenes and schedules: LAN schedule sync. Everything else: backup files. A LAN or file mirror of floor plans wasn't built because native backups don't carry them either |
| Same-account schedule failover | **Windows equivalent** | LAN schedule sync (see above) |
| `ActivationClicks` (macOS first-click behavior) | **N/A** | An AppKit detail. Electron windows already accept the first click |

## Bluetooth lights

| Feature | Mac/iPhone source | Windows/Linux | Notes |
| --- | --- | --- | --- |
| Protocol: frames, advertisement, model from name, commands, queries, replies, A3 reassembly, profiles | `GoveeBLE` | **Added** | `core/ble.ts`, byte-exact against the `GoveeBLETests.swift` vectors (`test/ble.test.ts`) |
| Encryption V1/V2 and the fail-closed session | `GoveeBLECrypto` | **Added** | `core/ble-crypto.ts` (Node crypto, hand-written RC4), the same vectors |
| Capture decoder (DreamView members, `cmd_ver`) | `GoveeBLECapture` | **Added** | Settings › Bluetooth › Read capture… |
| Scan, connect to one profiled light, keep-alive, idle/silence drop, 60 ms pacing | `BluetoothLights` | **Added** | `main/bluetooth.ts` runs the protocol in main. The renderer carries GATT bytes over Electron Web Bluetooth (`renderer/bluetooth-view.ts`). The person picks the light from Luma's own list (Electron `select-bluetooth-device`) |
| Power, brightness, color, Video mode, DreamView group sync/content/area/saturation, member slots; each enabled only after readback | `BluetoothLightsView` | **Added** | Same rules as native |
| Govee Home match by Bluetooth name | `BluetoothLightsView.accountName` | **Added** | `bleName` is now read from `deviceExt.deviceSettings` |

Platform differences (Web Bluetooth instead of CoreBluetooth):

- **Advertisement.** The advertisement (encryption flag, Pact) is read after the light is chosen, with `watchAdvertisements`, behind a Blink flag Luma turns on. If it can't be read, the session falls back to the `2b12` marker, and then fails closed as native does. The chooser shows no signal strength until a light is chosen.
- **Services.** Only Govee's documented service `00010203-…-1910` (ha-govee-led-ble `transport.py`) is opened. Native discovers every service.
- **Packet size.** The ATT MTU isn't exposed, so V2 lights assume Chromium negotiated a large one. A write the light refuses ends the connection with a message.
- **Not hardware-verified.** Native isn't either (`docs/BLUETOOTH-DREAMVIEW.md`).

## Icons

| Item | Decision |
| --- | --- |
| App, window, installer and tray icon | **Reused**: copied from `macos/Luma/Assets.xcassets/AppIcon.appiconset` by `scripts/make-icons.mjs`. The sidebar brand uses it too |
| In-app glyphs (SF Symbols) | **Can't be reused.** Apple's SF Symbols license allows them only in apps for Apple platforms. Windows keeps its open line icons, drawn to the same shapes (lightbulb, map, gear, wand, film…) |

## Tests

`desktop/src/test/windows-parity.test.ts`, `ble.test.ts` (Swift vectors) and `bluetooth.test.ts` (controller with fake GATT) cover:

- the scene library (dedupe, placeholders, accent-insensitive search, room rows, skip reasons);
- tray rooms (lights with a power switch only, Unassigned last);
- floor-plan rules: one pin per light, bounds, strict native decode, owner-only files, re-encoding, a damaged file preserved, and the in-memory demo store;
- DreamView draft validation;
- the Bluetooth protocol, encryption and capture vectors, and the controller's connection order, readback gating, pacing and silence drop.

The desktop suite has 294 tests, and `npm run typecheck` is clean.

## UI evidence

Checked in the Electron demo build through CDP (argent), not on Windows hardware:

- room headers with count and switch, and the Adjust presets;
- the floor plan empty state;
- the TV backlight sheet: Save Movie scene, the group readback message, and a partner draft with a member and its area chips;
- Scenes › Govee scenes: "Applied Aurora to 2 lights."

**Not checked:** the floor-plan image path, end to end. The macOS open panel can't be driven in the background, so the image picker, the canvas and pin dragging are covered only by unit tests at the store/IPC level.
