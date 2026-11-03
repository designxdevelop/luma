# DreamView receiver prototype

Goal: get the **live, camera-derived colours** a Govee TV Backlight 3 Pro
(H66A0) / 3 Lite (H6097) computes, so Luma can relay them to additional
(including non-Govee) lights. This directory holds the receiver path — the only
route that, on current evidence, actually carries those colours off the
controller.

## What the evidence says (observation)

From the public RE corpus `teh-hippo/ha-govee-led-ble @ b845c59` (read-only, no
Govee code shipped here):

- **Members are addressed by BLE identity.** A DreamView group member record is
  `is_rgbic | identity_kind | cmd_ver | (reversed MAC | name) | area_count | areas`
  (`h6099_dreamview_group.ksy`, `dreamview.py:DreamviewMember`). Identity is a
  reversed 6-byte MAC or a UTF-8 BLE name.
- **The controller is the GATT client; the follower is the peripheral.**
  `coordinator_dreamview.py`: *"DreamView member devices are single-client BLE
  peripherals claimed directly by the sync centre after `0x50` group upload"*,
  and Home Assistant must *"confirm physical BLE disconnect before uploading
  `0x50`"* because the member accepts only one client. So after enrolment the
  **controller connects out to each follower and writes colours into it.**
- **The colour-bearing module `0x60` has no colour frame.** Module `0x60`
  (`h6099_dreamview_frame.ksy`) only carries group switch, member brightness,
  connection, saturation, video settings (Game/Movie, All/Part) and sound. No
  per-area RGB. This is consistent with colours being written to each follower
  in that follower's *own* light grammar, not broadcast in `0x60`.
- **Standard Govee GATT** (`transport.py`): service `00010203-…-1910`,
  WRITE `…2b11`, READ/notify `…2b10`, ENCRYPTION `…2b12`. Control frames are the
  20-byte `0x33|opcode|17-body|XOR` envelope (`command_write.ksy`) or the 7-byte
  music push `a5 02 83 R G B SUM` (`music_stream.ksy`).
- **Link encryption is opt-in per device**, advertised by manufacturer-data
  flag bit `0x40` (`advertisement.py`). An emulated follower that does not
  advertise `0x40` should receive plaintext writes.

## The hypothesis (inference — needs hardware)

If we stand up a BLE peripheral that looks like a Govee RGBIC light and enrol it
in the group by the name it advertises, the sync centre will connect to it and
stream the live per-area colours it would send a real follower. The exact
opcode it uses to a follower is the one unknown; the WRITE characteristic and
frame envelope are known, so the logger captures whatever arrives.

## Files

- `GoveeDreamViewReceiver.swift` — CoreBluetooth `CBPeripheralManager` (no deps).
  Advertises the Govee service + a chosen name (default `Luma-Bridge`), exposes
  the three characteristics, does **not** advertise the `0x40` encryption flag,
  and logs + best-effort-parses every write. Run: `swift GoveeDreamViewReceiver.swift [name]`.
- `build_member_record.py` — stdlib-only builder for the name-addressed `0x50`
  group upload that enrols the bridge. Byte-faithful to `transport.fragment_a3`.
  Self-check: `python3 -I build_member_record.py`.

## How to try it (gated — read first)

1. Run the Swift receiver on a Mac in BLE range of the TV backlight.
2. Enrol the advertised name as a group member — either from the **Govee phone
   app** (add the bridge as a DreamView member) or by feeding
   `build_member_record.py` output through the HA integration's
   `replace_dreamview_group`. **`cmd_ver` must come from real device evidence**
   (sniff a genuine member enrolment, or read it off a supported device). Do not
   guess it.
3. Put the controller in DreamView **Movie** mode and watch the log for colour
   writes.

### Gate / necessary inputs (this is the real boundary, not "no public API")

- **Group replacement is destructive.** A `0x50` upload replaces the entire
  group and there is **no membership readback**, so the user's existing
  DreamView group cannot be restored programmatically — they rebuild it in the
  Govee app afterwards. **Explicit user consent required before enrolling.**
- **BLE range** to the H66A0 / H6097.
- **An evidenced `cmd_ver`** for the member record.
- **Known unknown:** macOS `CBPeripheralManager` cannot set BLE manufacturer
  data. If the controller filters followers on Govee manufacturer data, the next
  input is an ESP32 or Linux/BlueZ peripheral that can advertise it.

Nothing here has been run against hardware. Whether the controller streams
colour to an emulated follower, and in which opcode, is unconfirmed until the
log above shows it.
