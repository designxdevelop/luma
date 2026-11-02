# Native Bluetooth control and the DreamView critical path

This pass (2026-11-02) owns the native Bluetooth protocol layer and the DreamView configuration path. It does not edit PARITY.md, README or VERIFICATION.md. Proposed edits to those files are under [Integration](#integration).

Evidence levels: **source** means public client source. **Vectors** means byte-exact tests against that source's own test vectors. **Independent** means crypto vectors produced by a second library. **Build** means it compiles for macOS and iOS. **Live** means it ran against real hardware; nothing in this pass reached that level.

**Safety:** this pass made no live account calls and wrote nothing to a light or group. It read no credentials. The protected "Bedroom Dream View" H6097 group was not touched.

## What shipped

| Piece | File | What it does | Evidence |
| --- | --- | --- | --- |
| Protocol | `Sources/LumaCore/GoveeBLE.swift` | GATT UUIDs and 20-byte XOR frames. Parses advertisements (flags, encryption bit `0x40`, Pact). Reads the model from the local name. Builds H6099-grammar commands: power, brightness, whole-device RGB, and the backlight's own Video mode (Movie/Game, All/Part, saturation, with sound settings preserved). Builds queries for power, brightness, mode, firmware and hardware, and parses their replies. Joins A3 multi-frame payloads back together. | vectors (`test_h6099.py`) |
| DreamView module `0x60` | same file, `GoveeBLE.DreamView` | Individual reads: group switch, member brightness, same brightness, member connection, saturation, video settings, sound. Writes: group sync on/off, group All/Part and Movie/Game, group saturation. **Not built:** group upload (A3 `0x50`) and delete (`0x0d`). They have no builder and no send path. | vectors (`test_h6099_dreamview.py`) |
| Profiles | same file, `GoveeBLEProfile` | **H6097:** full feature set only for Pact 1/1 or 2/1 (`device_profile`). An unknown or other Pact gets power and brightness only, with the reason shown. **H6099:** full. **H66A0:** power, brightness, colour and DreamView. Its own Video mode is left out because its video and status grammars differ. Every other recognised Govee name is listed but cannot connect. | source (`const.py`: all three are `SUPPORTED`, confirmation issues 445, 446 and 450) |
| Encryption | `Sources/LumaCore/GoveeBLECrypto.swift` | **V1:** AES-ECB with an RC4 tail and a two-phase handshake. **V2:** AES-GCM handshake, a device key from the SKU and MAC, sealed frames with a counter and replay rejection, and a 50-byte write minimum. `GoveeBLESession` is a fail-closed selection state machine, ported rule for rule from `session.py`. | independent (Python `cryptography`) plus the selection table from `test_govee_encryption.py` |
| Capture decoder | `Sources/LumaCore/GoveeBLECapture.swift` | Decodes a capture of Govee Home's traffic (lines of `W <hex>` / `N <hex>`) offline, **including encrypted ones**. Both handshakes are protected only by vendor-global keys, so session keys can be recovered passively. Rebuilds every A3 `0x50` group upload into member records: `cmd_ver`, RGBIC flag, identity and areas. Its summary redacts identities. | vectors (the source's group record bytes) plus round-trip tests |
| CoreBluetooth transport | `Sources/LumaUI/BluetoothLights.swift` (macOS/iOS only; the watch target doesn't link it) | Passive scan for 15 s. Connects only on request, and only to profiled models. Setup runs in the source's order: services → `2b12` marker → notify on `2b10` → handshake (6 s limit) → reads. Keep-alive is a power query every 5 s. It drops after 20 s without a reply, after 3 min idle, or when the page closes. Writes are paced 60 ms apart without response. Encryption requirements are tracked per light. | build |
| UI | `Sources/LumaUI/BluetoothLightsView.swift` | Nearby list: model, encryption lock, RSSI, and a Govee Home match by the account's stored `bleName`. On the connected light: power, brightness, colour and Video mode, plus DreamView group sync, All/Part, Movie/Game, saturation and raw member slots. **Each control except colour is enabled only after the light reported that value in this session.** Colour has no readback in the ported grammar (the mode reply carries Kelvin only), so the picker is a write-only control. A "Read Capture…" card shows the decoded `cmd_ver` summary. | build. Simulator QA: see [Verification](#verification) |
| Tests | `Tests/LumaCoreTests/GoveeBLETests.swift` | 12 tests | pass |

## Why DreamView membership writes are still off

- **`cmd_ver` is not evidenced for any member.** ha-govee-led-ble's group schema says "cmd_ver is supplied externally, never inferred" and "No membership readback exists". Its own tests use arbitrary values (1, 7, 9, 12). goveetl has an MQTT `cmdVersion`, which is a different field, and has no feast or DreamView code.
- **The cloud doesn't give members back.** The account reads from the earlier live pass are unchanged: `device/list` has no group fields, `general-control/list` has the group without members, and `group-devices` is empty.
- **The feast detail endpoint wasn't found.** This pass scanned all 457 non-dex entries of the 7.7.10 APK (assets, native libraries, `resources.arsc`) for `bff-app`, `feast` paths and `appsku`. The scan found only class and resource names (`MovieFeastDetailAc`, `AcCreateFeast`, `app_feast_force_unbind_affect_tips`) and no endpoint strings. The endpoint sits behind the Virbox-encrypted dex. The Android 17 SIGBUS and the 403 split downloads were not retried.
- **`0x50` replaces the whole group, and members are single-client.** The controller claims each member after the upload. An upload with a wrong `cmd_ver` could break the working group, and Luma cannot read it back to check.

**Caveat:** the source qualifies official-app `0x50` captures for H66A0 only; for H6097 the upload route is unqualified, and a Wi-Fi-connected controller could receive its group another way. Capture with the phone next to the H6097. A capture without a `0x50` upload means "not sent over Bluetooth in this capture", not "no group".

**The shortest evidenced path, now built:** capture Govee Home saving the Bedroom group once, then open the capture in Luma under Bluetooth › Read Capture…. The decoder prints each member's `cmd_ver`, area list and identity kind; the capture is taken from Govee Home's own traffic, so Luma writes nothing. With that evidence, enabling writes becomes a small, separate change:
1. Re-send the **exact** captured upload. That is a byte-identical restore, so no value is guessed.
2. Read back the group switch and member connection.
3. Keep the decoded group as the backup.

`GoveeBLECapture.encodeGroup` already reproduces the source's record bytes. Only the A3 fragmenter (about 10 lines, in the test file today) and a confirmation UI are missing. The bar for that change: it needs the user's explicit consent, and it never runs against the Bedroom group without that capture in hand.

**How to capture:**
- **iPhone running Govee Home:** use Apple's Bluetooth logging profile and PacketLogger on a Mac.
- **Android:** use Developer options › Bluetooth HCI snoop log, then Wireshark.

Either way, export the ATT write and notification values as `W`/`N` hex lines.

## Pairing, Wi-Fi provisioning, firmware

Feasibility only; nothing was built.
- **Provisioning:** ha-govee-led-ble has an H6199 Wi-Fi provisioning schema (`h6199_wifi_provision.ksy`) and an H6099 body (`h6099_wifi_provision_body.ksy`), both labelled speculative or unqualified. Sending them would change a light's network setup. Leave this out until an owner-qualified capture exists.
- **Firmware:** no OTA protocol appears in either public source. Luma can now show firmware and hardware versions read over Bluetooth for a connected profiled light. Updates stay in Govee Home.

## Verification

- `swift build`: clean, with no warnings in the new files.
- `swift test`: **178 Swift tests pass** (baseline 166 plus 12). Neither the 4 XCTest cases nor any other suite changed.
- `xcodebuild`:
  - `macos/Luma.xcodeproj` scheme Luma: **succeeded**.
  - `ios/Luma.xcodeproj` scheme LumaiOS with `-destination 'generic/platform=iOS Simulator'`: **succeeded**, with the integration patch applied.
  - The same iOS build without a destination failed on the LumaWatch `AppIcon` asset for an implicit watch destination. That asset is unchanged by this pass.
- **Live Bluetooth was not observed.** A passive-scan probe, built both as a CLI and as an ad-hoc-signed `.app` with a Bluetooth usage string, never received a CoreBluetooth state callback within 20 s. That is consistent with a macOS Bluetooth permission prompt waiting for the user. It was not retried. No connection was attempted.
- **UI:** every iOS simulator was held by another agent's session, including after two waits of 90 s or more, and no session was closed. Instead, the real `BluetoothLightsView` was rendered offscreen on macOS through `NSHostingView`, using a temporary test that was deleted afterwards, in light and dark appearance (`/tmp/luma-ble-qa-light.png`, `/tmp/luma-ble-qa-dark.png`). That shows the initial state: header, Nearby with Scan and the access hint, and the capture card. Scanned, connected and capture-result states need a Mac or iPhone with Bluetooth access granted. The iOS Simulator has no Bluetooth radio, so it can only show the "doesn't support Bluetooth LE" state.

## Limitations

- Only the TV-backlight family is profiled. ha-govee-led-ble also marks several strips and bulbs as supported, but many of them change capabilities by Pact or firmware (H6125, H6102, H60A6). Porting them needs those gates, not just their frames.
- Status covers power, brightness, mode, firmware and hardware. The 14-zone segment pages, scenes and music aren't read or written over Bluetooth.
- H6097 colour temperature isn't sent. The source uses a device-table companion RGB that isn't ported.
- Joining a nearby light to a Govee Home light uses the account's `bleName`. CoreBluetooth hides MAC addresses. V2 handshakes reveal the MAC (`GoveeBLESession.deviceMAC`), but it isn't matched against `bleAddress` yet.
- V2 needs a 50-byte write payload. A link that negotiates less fails closed; the fragmented E719/E71A layout isn't implemented, because the source doesn't implement it either.
- The 60 ms write pacing and the 3-minute idle release are untuned on hardware. Each is marked in the code.
- Export compliance: Luma now contains AES-GCM, AES-ECB and RC4 for device interoperability, while both Xcode projects set `ITSAppUsesNonExemptEncryption = NO`. Check that declaration before an App Store submission. This pass did not change it.

## Integration

1. **Main patch** `/tmp/luma-ble-dreamview.patch`: the 5 new source and test files and this doc. It touches no existing file and applies to the baseline snapshot.
2. **Integration patch** `/tmp/luma-ble-integration.patch`, applied after 1:
   - `Sources/LumaUI/SettingsView.swift`: a "Bluetooth" row and a "Bluetooth Lights…" button in Connections that open `BluetoothLightsView` as a sheet. Adjusted Bluetooth sentence in "How Luma runs".
   - `macos/Luma.xcodeproj/project.pbxproj` and `ios/Luma.xcodeproj/project.pbxproj`: `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription` in the Debug and Release app configurations. **Required:** iOS terminates an app that creates a `CBCentralManager` without this key. Luma creates one only when Scan is pressed.
   - `macos/Luma.entitlements`: `com.apple.security.device.bluetooth`. Without it the sandboxed Mac app gets no Bluetooth.
3. Suggested PARITY.md rows for the doc owner:
   - **"BLE-only lights":** native Partial, covering H6097/H6099/H66A0 power, brightness, colour, Video mode and status, with encryption V1/V2. Electron Missing.
   - **"DreamView Movie/Game, All/Part, saturation":** native Implemented over Bluetooth for those models, gated on readback, not live-verified.
   - **"DreamView membership editing":** still blocked on `cmd_ver`. Unblocked by one capture, using the new decoder.
   - **"Device settings (firmware)":** firmware and hardware versions readable over Bluetooth.
