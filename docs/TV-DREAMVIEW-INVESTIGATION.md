# TV-driven Movie scenes: investigation

## Intended behavior

A Movie scene selects a TV Backlight 3 Pro or 3 Lite as its source and selected lights as followers. Prefer whole-light color for broad compatibility; enable regional/segment mapping only where verified. Stop should support restoration of pre-session states. This feature is not implemented or hardware-verified.

## Findings

Public source inspected at `teh-hippo/ha-govee-led-ble` commit `b845c59bc8971094cde203fab388ebeb9f6967f2`:

- Native DreamView membership uploads use fragmented A3 type `0x50`. The implementation caps H6099 at seven members and H66A0 at ten. Member data includes identity, RGBIC flag, command version, and assigned areas. Command versions require device evidence; do not guess them.
- Module `0x60` controls group enablement, member brightness/connections, saturation, and video options. Movie is a video content option. This offers a candidate route for starting native TV sync without reading camera frames.
- The inspected readbacks contain settings and connection status, not live RGB regions. Camera health is diagnostic information, not camera image access. `camera_status` (`protocol_h6199.py`) decodes to an enum state label, and `camera_health` (`h6099_controls.py`, "without camera calibration") to a health enum — neither is colour or image data.
- Upstream qualification is incomplete: H66A0 has owner-reported capture agreement without attached attributable raw captures; H6099 lacks owner qualification in the inspected schema. Packet construction does not establish successful visible syncing.

### Where the live colours actually travel (receiver path)

The colour-bearing frames are **not** broadcast in module `0x60` and there is **no colour read API**. Instead the public corpus shows a push-to-follower architecture:

- **Members are addressed by BLE identity** — reversed 6-byte MAC or UTF-8 BLE name (`h6099_dreamview_group.ksy`; `dreamview.py:DreamviewMember`).
- **The controller ("sync centre") is the GATT client; each follower is a single-client peripheral.** `coordinator_dreamview.py`: *"DreamView member devices are single-client BLE peripherals claimed directly by the sync centre after `0x50` group upload"*, and Home Assistant must *"confirm physical BLE disconnect before uploading `0x50`"*. After enrolment the controller connects **out** to each follower and writes colours into it, in that follower's own light grammar (20-byte `0x33|opcode|…|XOR`, or the 7-byte `a5 02 83 R G B SUM` push).
- **Link encryption is opt-in per device**, advertised by manufacturer-data flag bit `0x40` (`advertisement.py`). A follower that does not advertise `0x40` should receive plaintext.

Inference (unconfirmed on hardware): a BLE peripheral impersonating a Govee RGBIC light, enrolled by its advertised name, would be connected to by the controller and receive the live per-area colours. Prototype and the exact enrolment/restore constraints are in [`dreamview-receiver/`](./dreamview-receiver/).

**Boundary statement (corrected):** there is no live-colour readback in the inspected **BLE** corpus, which explicitly excludes Wi-Fi/cloud — its silence does not prove a cloud/LAN path absent. The honest blocker is not "no public API"; it is a **gated hardware step**. Enrolling an emulated follower to prove the receiver path needs three concrete inputs: (1) the user's explicit consent to overwrite their DreamView group (no membership readback exists, so a `0x50` upload is destructive and the group must be rebuilt in the Govee app), (2) BLE range to the H66A0 / H6097, and (3) an evidenced `cmd_ver` (sniffed from a genuine enrolment, never guessed). A known unknown: macOS `CBPeripheralManager` cannot advertise manufacturer data, so if the controller filters followers on it, the next input is an ESP32 / BlueZ peripheral.

Sources:

- https://github.com/teh-hippo/ha-govee-led-ble/blob/b845c59bc8971094cde203fab388ebeb9f6967f2/tools/ble/kaitai/speculative/h6099_dreamview_group.ksy
- https://github.com/teh-hippo/ha-govee-led-ble/blob/b845c59bc8971094cde203fab388ebeb9f6967f2/tools/ble/kaitai/speculative/h6099_dreamview_frame.ksy
- https://github.com/teh-hippo/ha-govee-led-ble/blob/b845c59bc8971094cde203fab388ebeb9f6967f2/custom_components/ha_govee_led_ble/dreamview.py

## Official app acquisition

Resolved the official download page's JavaScript to public endpoint `https://app2.govee.com/bff-app/v1/resource/package-download/configs?appType=0`. It returned version 7.7.10 and download URL `https://d1f2504ijhdyjw.cloudfront.net/govee-pack/GoveeHome_V7.7.10_qa.apk`.

Downloaded without executing or installing to `/tmp/luma-GoveeHome-7.7.10.apk`.
SHA-256: `5e02d154af8279c00aa8491435e7b75104600383af2db033606857864976fb85`.

REA `inspect_android_package` returned `capability_unavailable`: `Set REA_JADX_MCP_JAR to the absolute path of a caller-supplied jadx-headless-mcp 0.7.1 JAR. REA does not download or install it.` No APK decompilation was completed and there are no successful REA analysis Evidence IDs. Ordinary ZIP inventory found one classes.dex and native libraries. A bounded printable-string search did not locate camera-image or DreamView stream candidates; that does not establish absence of the feature.

## Next investigation

### Loader and runtime follow-up

REA method Evidence `ev_fc9caf1ffd9385b55a95f1be8e21614ec7c7d646c2250a1100971e3768ece0a8` decompiled `v68ae1757.l68ae1757.attachBaseContext`: it loads a native library, calls `I68ae1757_00(context)`, then loads the application class named in manifest metadata. Ordinary native-string inspection found `Virbox Protector` in `lib/arm64-v8a/libl68ae1757.so`. This supports a protection-loader interpretation; no camera algorithm was recovered.

Manifest declarations identify focused future targets: `com.govee.pact_h6099.add.camera.CalibrationAc`, `CameraSettingsAc`, `CheckCameraAc`, and `com.govee.pact_h6099.add.cameraCali3Img.CaliCamera3ImgAc`. Names establish declarations only, not implemented behavior.

Registered Android Studio's existing JBR through user-local symlink `~/Library/Java/JavaVirtualMachines/android-studio-jbr.jdk`. T3 device boot then succeeded for Pixel_10_Pro (`local`, `emulator-5554`, Android 17). Installed and launched the official APK using the returned agent-device command. It returned to the launcher. Crash-buffer evidence records `com.govee.home` receiving SIGBUS/BUS_ADRALN at `0xdead200a`; logs are `/tmp/luma-govee-crash.log`. Root cause is not established. No account login or physical light communication occurred.

Alternative public split-package acquisition was attempted through APKPure and APKMirror and returned HTTP 403. APKMirror lists 7.7.02 build 1138 as a base APK plus 13 splits. A cached upstream research reference mentions decompiling that release, making this a candidate alternative rather than verified analyzable input.

Additional bounded source research: `jwmoss/goveetl` commit `3890402e7fbf93328af4bde4df14af891d0aa1b7` has no camera/DreamView implementation in tracked internal/skills source; its advertised APK endpoint inventory is not committed. `Brady-Woods/govee-ble-local` returned 404. The inspected ha-govee-led-ble contribution guide explicitly excludes Wi-Fi/cloud camera calibration, so its missing camera implementation cannot prove that extraction is impossible.

### Successful REA inspection after installation

The existing MCP connection retained its old environment. A separate REA 6.4.0 CLI process with explicit `REA_JADX_MCP_JAR` and `JAVA_HOME` successfully ran the installed provider without restarting the user application.

- Package Evidence: `ev_ce0748092458fabbfa07133abac1854d02d92e1bc696fa6a2df20a65a2987bca`. Identity is `com.govee.home`, version 7.7.10 (1144), with 19,935 resources and three visible classes.
- Class inventory Evidence: `ev_0d9c88928e8653287669e6f6905f76b196aa63e9126850c7306ed428fc54855d`. Complete visible inventory: `com.govee.home.R`, `kotlin.coroutines.jvm.internal.DebugProbesKt`, `v68ae1757.l68ae1757`.
- Loader inventory Evidence: `ev_db959d36c7d4ecb04cc4b25c270491ac04144338c8a13dfb6a3983bb9cfdce1a`. The last class has application lifecycle hooks, reflection helpers, and opaque methods. Manifest application is this class while `SAPP_NAME` names `com.govee.home.IhApplication`.

Inference: the downloaded distribution uses a loader/protection layer; ordinary static Android class inspection does not expose the camera implementation. This is now the investigation boundary, not missing tooling. Complete CLI records are `/tmp/luma-govee-rea-package.json`, `/tmp/luma-govee-rea-classes.json`, and `/tmp/luma-govee-rea-loader.json`. No APK execution or hardware observation occurred.

Provider installation follow-up: installed checksum-verified `jadx-headless-mcp` 0.7.1 at `/Users/austin/.local/share/rea/android/jadx-headless-mcp-0.7.1-all.jar` (SHA-256 `6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`). Configured the Codex REA environment with this path and Android Studio's existing Java runtime. Direct MCP initialization succeeded and reported provider version 0.7.1. The existing REA server must reload its environment before using the new settings; initialization alone does not verify recovered Govee protocol behavior.

1. Supply/configure the existing REA Android provider or acquire the required analysis engine, then inspect this exact APK's camera calibration and DreamView setup paths.
2. **(Primary lead — prototype built.)** Emulate a receiving DreamView member to capture the live per-follower colour writes. Runnable prototype and enrolment builder are in [`dreamview-receiver/`](./dreamview-receiver/) (`GoveeDreamViewReceiver.swift`, byte-faithful `build_member_record.py`). Still a hypothesis until a hardware run logs colour writes; gated on the three inputs in the boundary statement above. A separately worth-testing coarse fallback: Luma's existing `GoveeLAN` `devStatus` returns a single whole-device colour — on hardware, poll it while the backlight is in Movie mode to see whether it updates live (observation, not yet made; no device contacted).
3. Validate native membership and Movie start/stop on hardware before integrating scene controls. Preserve the source controller's camera mode; sending Razer streaming commands to it is an output-control path, not a color-read API.
4. If live colors become accessible, feed them into Luma's existing region mixer and bounded local output, with stale-source shutdown and per-model validation. Do not promise all lights or route continuous TV frames through cloud control.

No physical device was contacted, no lights were changed, and no production feature code was added during this investigation.

## Implemented in Luma (cloud toggle only)

Luma now exposes Govee's documented cloud `dreamViewToggle` as a DreamView TV sync card (Start/Stop, Save Movie Scene) for lights that advertise it, plus reported-state readback when the cloud returns 0/1. This starts and stops the group already configured in Govee Home; it is not membership configuration. The BLE `0x50`/`0x60` paths above remain unimplemented for the reasons in the boundary statement. Govee Home room import (saved `/bff-app/v1/device/list`) was added separately; no DreamView membership read was found in goveetl @ 3890402, which does not prove the private API lacks one. See `docs/VERIFICATION.md`.

## Direct account import and partner editing (current)

Luma now signs in to Govee Home directly (see `docs/VERIFICATION.md`) and reads the account device list. This is the only measured route that could recover existing members without a destructive BLE upload: ha-govee-led-ble states that *previous device membership cannot be read* over BLE, so if the Govee Home app syncs groups across phones, the data lives in the cloud. Whether `bff-app/v1/device/list` carries it is unknown until a real account is read. The import preview prints the names of row and `deviceExt` fields whose names look like group data (for example goveetl's top-level `subDeviceNum`). A miss on that word list is not proof of absence; the decisive check is a full key-name dump of a real response, which the read-only probe `/tmp/luma-measure-scripts/measure.py` (outside the repo; prints names and counts only) produces.

Paths to completion, in order:

1. **Measure** (needs the user's sign-in): sign in on Mac or iPhone, open Import from Govee Home, and read the "DreamView data in your account" lines. If fields are listed, decode them against ha-govee-led-ble's member record (identity, `is_rgbic`, `cmd_ver`, areas) and show them under **On your lights**.
2. **If not in the device list**: the group lives behind another private endpoint. The 7.7.10 APK is Virbox-protected, so the endpoint must come from a decompilable split build (APKMirror 7.7.02 build 1138 was 403 here) or from the user's own Govee Home traffic (a HAR or mitmproxy capture of opening the DreamView page; REA `inspect_web_network_capture` reads it). Nothing is guessed meanwhile.
3. **Writing members** additionally needs evidenced `cmd_ver` per member (from step 1/2 or a sniffed genuine enrolment), a BLE writer (CoreBluetooth on Mac/iPhone), and the user's explicit go-ahead with the current group backed up, since `0x50` replaces the whole group. The working Lite group must be preserved. Until then the editor is a labelled local draft and Apply is disabled.

## Live account read (2026-11-02)

Decisive results from one read-only sign-in (details in [PARITY.md](./PARITY.md)): `device/list` has **no** DreamView fields on the H6097/H66A0 rows, so step 1 above is answered. The group is in `general-control/list` (observed `type` 10 with a `sceneFeastId`: name, `enable`, `deviceCount`, `mainDevice`), which Luma now shows. Member identities are not there, and `general-control/group-devices` is empty for it. "Feast" is Govee's internal name for DreamView; the member endpoint is behind the Virbox-encrypted dex. Both TV backlights report `supportEnc: true` (so do other lights in the account); a BLE writer would likely have to handle encryption, which isn't evidenced for these models. Next input: a HAR/mitmproxy capture of Govee Home opening the DreamView group page.
