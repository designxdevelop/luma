# Govee Home parity: remaining work and this pass

A companion to `docs/PARITY.md`, written by the non-Siri/non-scene parity pass on 2026-11-02. It records what this pass built, what is still missing from Govee Home, and what blocks each gap. It does not edit the shared roadmap. Scene browsing and Siri/App Intents belong to a separate pass and are only mentioned here where they connect.

Evidence levels match PARITY.md: **live** = checked against a real account or light, **tests** = automated tests with synthetic fixtures, **source** = public client source only, **UI** = driven in the Electron demo build through CDP (argent) with screenshots.

This pass made **no live account or hardware changes** and read no credentials. Live sign-in needs an emailed code, so it requires the user to be present.

## Correction to PARITY.md

PARITY.md says non-light devices "control through the generic capability form; readings not shown". Both clients actually **dropped** every non-light from `GET user/devices` (`type != devices.types.light`), so appliances and sensors were never listed. Electron now lists them (below). Native lists them only once `integration/native-integration.patch` is applied.

## What this pass shipped

### Windows/Linux (Electron, `desktop/`)

| Feature | Before | Now | Evidence |
| --- | --- | --- | --- |
| Whole-home backup and restore | Missing | Same `luma-home-backup` v1 file as the native app. Export goes through a save dialog in main. Restore validates the file structurally, so scenes for lights that aren't connected yet are kept and counted. Mac-length names and rooms are shortened, not refused. Native DreamView drafts are shape-checked and kept, so a Mac → Windows → Mac round trip doesn't lose them. A 0600 `home-before-restore.json` is written before anything is replaced. Never includes keys, tokens, IPs or webhook settings | tests both ways: an Electron-written file decodes and restores in Swift (`CrossPlatformBackupTests`), and a real Swift encoder output decodes in TS (`fixtures/native-backup.json`) |
| Restore lights after a scene | Missing | Confirmed state (power, brightness, color, white) of the scene's lights is captured before its first write. One level, as on native | tests |
| Room brightness and white | All on/off only | "Adjust ‹room›": a brightness slider and white presets. Each light is clamped to its own advertised range | tests, UI |
| Compatibility report | Missing | Copied to the clipboard: models, capability names and types, and paths only. No names, IDs, rooms or addresses | tests |
| Renames survive a cloud reconnect | **Bug**: `mergeCloudDevices` overwrote the name | `customName` is persisted, as on native | tests |
| DreamView start/stop | Missing (only a generic toggle) | Dedicated Start/Stop block with the reported `dreamViewToggle` state, read again 3 s after a change | tests (state parse), UI |
| Appliances and sensors | Dropped from the device list | Listed with their `deviceType`. They are excluded from every bulk path: tray All on/off, room On/Off and Adjust, webhook `all` / `room:`, Screen Sync eligibility, the capture default and the Alt+arrow shortcut. **New behavior:** an explicit device ID (UI switch or webhook `target: "<id>"`) can now reach an appliance, because it couldn't be listed before | tests |
| Sensor and appliance readout | Missing | Readings parsed from `device/state` for capabilities with no dedicated control (temperature, humidity, modes, filter life…). Units come only from the advertised capability. Readings stay in memory and are dropped when the device reports offline | tests, UI (demo hygrometer) |
| Segment painter | Generic struct form only | Paint segments with a color, brightness or rainbow. Segments that share a value become one command, split at `size.max` and ordered by segment. Every command is validated before the first send and sent **uncoalesced** in order (`controlBatch`). "Save as scene" opens the editor | tests (3 groups → 3 sends; invalid → nothing sent), UI (15 commands sent) |
| Govee Home account sign-in (read-only) | Missing | Email + password + emailed code, ported from native `GoveeAccount`. Same headers, `redirect: 'error'`, a stable `clientId`. The token sits in DPAPI or the keyring and the password is never stored. Reads rooms (preview and apply, with Unassigned preselected), control groups (DreamView badge, reported count, main light) and automations, plus conflict hints on Luma schedules matched by the Govee name. The firmware version (`versionSoft`) appears in Details | tests with a fake account API. **Not live-verified on Electron**; the native contract was live-checked on 2026-11-02 |

Desktop suite: **221 tests pass** (baseline 204), and `npm run typecheck` is clean.

### Native (Mac/iPhone/iPad), standalone modules only

| Module | What | Evidence |
| --- | --- | --- |
| `LumaCore/SegmentPaint.swift` | Segment schema reader and painting-to-commands logic, with the same rules as Electron | `ParityModulesTests` |
| `LumaCore/DeviceReadings.swift` | Readings parser and `isLight(type:)` | `ParityModulesTests` |
| `LumaUI/SegmentPainterCard.swift` | SwiftUI painter. It uses only the existing `HomeStore.send` / `saveScene`, so its integration is one line | Builds for macOS and the iOS Simulator. Not rendered yet: the native demo lights don't advertise `segmentedColorRgb`, so the card appears only for a real RGBIC light |
| `LumaUI/DeviceReadingsCard.swift` | Readings card | Builds for macOS and iOS. Rendered only once patch 2 lists non-lights |
| `Tests/LumaAppTests/CrossPlatformBackupTests.swift` | Decodes and restores a real Electron-written backup | passes |

Swift suite: the baseline plus 4 new tests pass. Neither the owned files nor the Xcode project were edited: the app links the `LumaCore` package product, so new files need no registration.

## Integration the parent must do (not done here)

1. **Main patch** (`luma-parity-4ac954e2.patch`): new files, `desktop/`, this doc and tests. It touches no owned file, `Package.swift` or the Xcode projects. It applies cleanly to the baseline snapshot and to the parent's **finished** tree (Siri/scenes done, with `LumaIntents`).
2. **`integration/native-integration.patch`** (apply after 1; touches files owned by the scenes/Siri agent). Rebased onto the parent's finished tree. On parent + patch 1 + patch 2:
   - `swift build` passes, and **166 Swift tests pass** (the parent's 160, plus 4 module tests and 2 integration tests).
   - `xcodebuild` passes for `ios/Luma.xcodeproj` (scheme LumaiOS, iOS Simulator, no signing) and for `macos/Luma.xcodeproj` (scheme Luma).
   - `Models.swift`: optional `deviceType` on `LightDevice`. Older homes still decode, and a test covers that.
   - `GoveeCloud.swift`: lists non-lights with their type. Adds `stateAndReadings(for:)`; `state(for:)` keeps its signature.
   - `HomeStore.swift`: `lights` (bulk-safe list) and in-memory `readings`. The refresh path stores readings, and `merge` keeps `deviceType`.
   - Bulk paths skip non-lights: `AutomationAction` (`all` / `room:`), `LumaApp` menu All on/off, the `WatchRelay` all-power request, `LightsView` room buttons, `screenSyncIssue` ("Not a light"), and `HomeStore.lights(inRoom:)` in `RoomActions.swift`, which every Siri/Shortcuts room and All Lights action uses.
   - `DeviceSheet.swift`: `DeviceReadingsCard` on the Light tab and `SegmentPainterCard` on the Effects tab.
   - The patch preserves the parent's `LumaIntents` target, `HomeStore.shared`, `resumeOnAccept` and the Siri tests. It doesn't touch `Package.swift`, `IOS.md` or the shortcut entry points.
   - If the patch stops applying because the parent moved again, re-apply the per-file edits listed above. They are small and anchored on stable lines.
3. Suggested PARITY.md row updates for the doc owner: Electron backup/restore, restore lights, compatibility report, sign-in, DreamView and rooms are now Implemented. Segments are Implemented (painter). Non-light devices: Electron Implemented, native pending patch 2.

## Everything still missing from Govee Home

| Govee Home area | Status | Blocker / feasibility | Value |
| --- | --- | --- | --- |
| Onboarding: add/pair lights (BLE + Wi-Fi provisioning, Matter commissioning) | Missing on both | Govee's provisioning is BLE-encrypted and undocumented. Matter devices could be commissioned through Apple Home / the OS Matter stack, but that adds them to Apple Home, not to Govee's cloud. Luma assumes Govee Home did the setup | Low (one-time) |
| Firmware updates | Version shown (Electron Details after Govee Home sign-in); update missing | No verified update API in this investigation; Govee Home handles OTA. Native has `versionSoft` in its import entries but doesn't show it in Details yet (a one-line addition for the DeviceSheet owner) | Low |
| Shared home / family sharing | Missing | A private account API. Only a `share` field has been seen; no endpoint is known | Low |
| Govee Home automations (edit) | Read-only on both | goveetl live-verified **writes** (`automations set`, H706C at 60 % / 2700 K) and documents that null fields cause status 500. Feasible, but it changes a household's live automations: build only with explicit consent, readback and a backup. `ecology/resource/automation/details` would also give full actions (read-only, unverified in Luma) | Medium |
| Tap-to-Run / sensor triggers | Luma scenes + webhooks | Sensor *events* (lack of water, motion) are pushed over Govee's AWS IoT MQTT. goveetl live-verified the MQTT certificate, topic, state messages and control. Feasible next step: a read-only MQTT event listener feeding Luma triggers. Needs the account session (now on both platforms) | Medium |
| Real-time state push | Polling/confirm reads | Same MQTT channel. It would replace confirmation polling | Medium |
| Govee control groups (group commands) | Luma rooms instead | `general-control/iot-control` exists in goveetl source but is **unverified live**, and it acts on lights. Not built | Medium |
| DreamView member lights and screen areas | Group name, count and main light readable | No member-detail endpoint identified yet: `general-control/group-devices` is empty for the DreamView group (live), and the 7.7.10 APK's feast endpoints are Virbox-encrypted. **User step:** a HAR/mitmproxy capture of Govee Home opening the group. Writes need BLE `0x50`, `cmd_ver` and probably the encryption these controllers advertise. **The working "Bedroom Dream View" H6097 group must not be overwritten** without a backup and readback | High |
| DreamView Movie/Game, All/Part, saturation | Missing | BLE `0x60` (ha-govee-led-ble), with the same encryption question. Not in the cloud API | Medium |
| Token refresh | Not implemented (sign in again) | **Blocked by evidence:** goveetl README/SKILL say Govee rejects `POST bff-app/v2/account/refresh-token` with 401 on the verified login. One unresolved lead: goveetl's request struct has a `type` field its `Refresh()` never sets. Testing it needs a live session and the user present | Low |
| Built-in scene catalog beyond the official list | Owned by the scenes pass | Lead for them: `GET app2.govee.com/appsku/v1/light-effect-libraries?sku=…`, used by ha-govee-led-ble's catalogue refresher, may include app-only scenes. Unverified here | — |
| DIY scene / animation **creation** | Missing | Not exposed by the official API inspected here. Creation uses BLE/private paths; ha-govee-led-ble has a BLE effect compiler for specific models | Medium |
| Music mode from computer audio | Missing (the light's own mic via `musicMode` works) | **Not built this pass, for scope only; no external blocker.** Plan: ScreenCaptureKit audio (macOS), WASAPI loopback (Windows) or PipeWire (Linux) feeding the existing Screen Sync LAN stream, with brightness/color from loudness and spectrum. Needs a real light to tune latency | Medium |
| Per-segment real-time streaming (DreamView-PC-style) | Whole-light LAN stream only | The LAN `razer`/`ptReal` modes (PROTOCOL-RESEARCH.md §2, undocumented, OpenRGB/community sources) are model-specific; needs hardware verification per model | Medium |
| On-device timers, auto-off, LAN toggle, camera calibration, night light schedules | Missing | BLE or private endpoints. Luma schedules cover timers while Luma runs | Low–medium |
| Appliance-specific UIs (heater target temperature, purifier modes, humidifier mist) | Generic capability form + readings | Electron lists appliances now (native after patch 2), so their advertised capabilities work through the validated generic form. Dedicated widgets are optional polish. **No appliance on the evidenced account** (16 lights only), so nothing was hardware-checked | Medium |
| Energy / power readings for plugs | Shown only if the plug reports them as properties | Same readings path. Unverified (no plug on the account) | Low |
| Alexa / Google / IFTTT / SmartThings | Not replicated | Luma offers local authenticated webhooks. Shortcuts/App Intents belong to the Siri pass | Medium |
| iOS widgets, Live Activities | Missing | Siri/App Intents pass territory (WidgetKit needs the same intents) | Medium |
| Notifications (offline, lack of water, away mode) | Missing | Needs the MQTT events above | Low–medium |
| BLE-only lights | Not controllable | No BLE stack in Luma. ha-govee-led-ble proves it per model, with encryption on newer ones | Low–medium |
| Community feed, DIY sharing, shop, rewards, AI bot | Excluded | Not device control. Scene and backup files cover sharing between Luma users | — |

## Where Luma now goes further (both platforms)

Cross-platform backups that restore between Windows/Linux and Mac/iPhone. Segment painting that sends the fewest validated commands. Room-wide white clamped per light. Bulk actions that can never reach a heater or a socket. Readings with only advertised units. A redacted compatibility report. Govee Home automation conflict hints against Luma schedules.

## Artifacts

- Baseline: `/tmp/luma-parity-baseline-20261102.tar.gz` (sha256 `0b945107…24e2e`), extracted over HEAD `9884624`, tree `7cd1832f`. The baseline tree is HEAD plus the snapshot, so files the parent deleted aren't represented.
- Main patch: `luma-parity-4ac954e2.patch` (`git diff 7cd1832f <worktree tree>`, `integration/` excluded).
- Native integration patch: `integration/native-integration.patch`.
- UI evidence (Electron demo, CDP screenshots): `electron-lights-sensor-rooms.png`, `electron-segment-painter.png`, `electron-settings.png`.
