# Luma

A native macOS controller for your Govee home. Built with SwiftUI, no Electron and no external packages.

An **open-source project built by Design X Develop LLC**, licensed under [MIT](LICENSE). Provided **as is, without warranty**. Report problems in [GitHub Issues](https://github.com/designxdevelop/luma/issues); see [Contributing](CONTRIBUTING.md) for what to include.

## Start here

1. Open `dist/Luma.app` (or run `./scripts/run.sh`).
2. Use the welcome screen or **Settings → Connect Account**, enter your existing developer API key, and connect.
3. For local control, enable **LAN Control** in each compatible light's Govee Home settings, then click **Find Lights** while on the same Wi-Fi.
4. Open a light for room assignment, RGB, white temperature, refresh, and model-specific effects/commands.
5. Save a scene, then open **Automations** to schedule it or start the webhook server.

Your API key goes only to `https://openapi.api.govee.com` and is saved in macOS Keychain. Existing keys work; there is no need to regenerate one. Govee's [key policy](https://developer.govee.com/changelog/important-policy-update-important-notice-regarding-api-key-security-management) says generating a new key invalidates previous account keys.

## Controls

- Power, brightness, RGB color, and white temperature use discovered LAN when possible; cloud is used for other capabilities.
- Rooms and all-light actions; menu-bar access even after closing the main window.
- Advanced controls come from Govee's returned schemas. Use segment-selection buttons, color pickers, value fields, and menus for music/movie modes, toggles, and other advertised capabilities. A JSON editor remains available for scripts and custom values.
- Open a light's **Effects** tab to load scenes or DIY options; existing preset options are preserved. Save any advanced command as a scene step.
- Capture selected lights into a named scene with an icon, edit its ordered steps and delays visually, and import/export scene JSON. The raw editor lives under **Advanced**.
- Daily/weekday schedules run in your Mac's current time zone, while Luma is running and the Mac is awake. Missed schedules are skipped.
- **Screen Sync** matches local lights to a display or window you choose. See [Screen Sync](#screen-sync).

Choose **System**, **Light**, or **Dark** appearance in Settings. Brightness and white-temperature sliders have continuous tracks with no tick marks. Use **⌘1–⌘6** to switch pages, **⌘,** for Settings, **⌘F** to search lights, and **⌘.** to stop a running scene. Menu commands reopen the main window at the requested page.

Cloud commands are serialized and conservatively paced, then state is read back with bounded confirmation retries. A cloud success means Govee accepted the request. LAN sends are unacknowledged; actual state updates come from `devStatus` replies. Use **Refresh state** if another controller changed a light. There is no continuous cloud polling or light-state push subscription. When a saved home exists, Luma reconnects using the saved Keychain key on launch; macOS may request permission after a rebuild.

Controls immediately display your requested value with **Updating…** or **Waiting for light…** until confirmed. Writes run in order per light, and unsent slider edits collapse to the latest value. Older readbacks cannot replace a newer request, and telemetry cannot move the slider during a drag. If a write fails, the control returns to the last reported value and shows an error. Confirmation retries are bounded; an unconfirmed request expires after 30 seconds. Pending display values are never saved as confirmed state or returned by `/v1/devices`.

## Screen Sync

Screen Sync is off by default and never starts on its own, including after relaunch, wake, or unlock. Open **Screen Sync** (⌘6), choose **Choose Display or Window…**, pick content in the macOS picker, include lights, then click **Start**.

- **Privacy:** macOS asks you to confirm the display or window. Luma does not list your windows or check permission before you choose. Frames are reduced on this Mac to five average colors; pixels are never saved, logged, uploaded, or shown. Audio, microphone, and camera are not used. If macOS denies capture, the page explains how to allow Luma in System Settings › Privacy & Security.
- **Lights:** only lights with LAN Control that are online and on can be included. Cloud-only, offline, and off lights are listed with the reason and skipped. Screen Sync never turns a light on or off. Find lights on Wi-Fi first; saved lights have no local address until they are discovered again.
- **Regions:** each light follows one area of the picture: the whole picture; the left, right, top, or bottom third; an edge (left, right, top, bottom); a corner; or half of an edge (for example, the top edge's left half, for lights behind one side of a TV). **Edge depth** (5–33%, default 15%) sets how far edges, corners, and half edges reach into the picture; thirds are unaffected. Black letterbox and pillarbox bars are ignored. A dark scene dims lights to 1% rather than turning them off.
- **Vivid colors:** off by default. Normally a region's color is its average, so a white page or gray interface washes lights out. Vivid gives colorful pixels more weight than gray, white, and text, so a red logo on a white page still reads as red. A picture with no color at all keeps its average.
- **How sampling works:** each frame is reduced on this Mac to a grid of at most 30 × 18 cells of color sums; region colors come from that grid. Edge depth therefore moves in steps of one cell (about 3% across, 6% down). Changing a region, edge depth, or Vivid takes effect on the next frame.
- **Tuning:** smoothing (default 40%), change threshold (default 2%), update rate (0.5–10 updates per second per light, default 5), and a brightness cap (default 80%). Capture runs at up to 30 frames per second, downsampled to 160 pixels on the long side, and is separate from the light update rate. Smoothing is measured per 100 ms, so it feels the same at any frame rate, and it eases off on large color jumps so scene cuts land at once while small flicker stays filtered. Settings you already changed keep their saved values.
- **Network load:** LAN commands are unacknowledged UDP. Screen Sync sends only the newest value, never retries, and skips changes inside the threshold, so a dropped datagram is replaced by the next one instead of piling up. An update can carry a color and a brightness datagram, so 10 updates per second means at most 20 small datagrams per second per light. If a light lags or misses changes, lower its update rate.
- **Latency:** capture-to-light time varies with the Mac, the light model, and Wi-Fi; no number is promised. For local QA, launch with `LUMA_LATENCY_LOG=1` and run `log stream --predicate 'subsystem == "app.luma.govee" AND category == "screen-sync-latency"'`. Every 50 sends, Luma logs p50/p95/max milliseconds from the frame's capture timestamp to the datagram being handed to macOS. Only timings are logged, never colors or pixels. UDP has no acknowledgment, so this does not include the light's own delay.
- **Control:** a capture indicator appears in the sidebar and the menu bar. Pause stops capture and keeps your choice for Resume. Stop ends capture and forgets the choice. Sleep, display sleep, screen lock, and switching users pause capture; resuming is always your choice.
- **Ownership:** a manual change, scene, schedule, or webhook on a synced light takes it out of Screen Sync before the command is sent. Use **Include Again** after the ordinary command finishes to return it. Starting Screen Sync also waits for pending commands on each light.
- **On stop:** lights keep their last synced color and brightness. Luma then asks each light for its state. Streamed colors are a preview only; they are never saved as confirmed state or returned by `/v1/devices`.

Screen Sync sends whole-light color and brightness with the documented LAN commands. It is not per-LED streaming and does not match DreamView or Govee's sync boxes.

## Webhook API

The server starts **off**, binds to `127.0.0.1:8787` by default, and requires `Authorization: Bearer <token>` on every endpoint. Start it in Automations and copy its token. The non-demo token is stored in Keychain separately from your Govee key. Rotate the token to revoke callers. Port and LAN preference persist; the server must be started explicitly after relaunch.

All POSTs require `Content-Type: application/json` and Content-Length (curl sets it automatically). Bodies are limited to 64 KiB. No query strings, chunked requests, browser CORS, or token-in-URL authentication. Successful mutations return **202** and a run ID immediately. Only one automation sequence can run at a time; a second is rejected.

```sh
# Read your token interactively; don't put it in shell history.
read -r -s LUMA_TOKEN
export LUMA_TOKEN

curl http://127.0.0.1:8787/v1/devices \
  -H "Authorization: Bearer $LUMA_TOKEN"

curl -X POST http://127.0.0.1:8787/v1/actions \
  -H "Authorization: Bearer $LUMA_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"target":"all","power":true,"brightness":40,"color":"#FFB870"}'
```

Targets: `all`, an exact device ID, or `room:Living room` (room names are case sensitive). Choose `color` or `kelvin` in one action. Brightness is 1–100; use `power:false` for off. Each device's advertised range can be narrower. Actions and saved scenes allow at most 200 commands and five minutes of explicit delays. Cloud pacing can add time. The entire sequence is validated before starting; network failures can still leave earlier steps applied. Stopping a run does not undo earlier commands.

```sh
curl http://127.0.0.1:8787/v1/scenes -H "Authorization: Bearer $LUMA_TOKEN"

# Substitute the scene UUID from the response.
curl -X POST http://127.0.0.1:8787/v1/scenes/SCENE_UUID/run \
  -H "Authorization: Bearer $LUMA_TOKEN" -H 'Content-Type: application/json' -d '{}'

# Every accepted action returns {accepted:true, runID:..., statusURL:...}.
curl http://127.0.0.1:8787/v1/runs/RUN_UUID -H "Authorization: Bearer $LUMA_TOKEN"
```

Run status is `running`, `completed`, `failed`, or `cancelled`. Completion means all commands were submitted; hardware confirmation is separate. Run history keeps the latest 100 entries in memory. `/v1/runs` lists them. `/health` reports status and demo mode. API dates use Foundation's seconds since 2001-01-01 UTC.

For raw model-specific commands, POST `/v1/devices/DEVICE_ID/commands` (URL-encode the ID) with a capability from the device list:

```json
{"type":"devices.capabilities.segment_color_setting","instance":"segmentedColorRgb","value":{"segment":[0,1,2],"rgb":16711680}}
```

Only send capabilities advertised by that device. In macOS Shortcuts, use **Get Contents of URL** with POST, JSON body, and the Authorization header. Home Assistant's `rest_command`, Stream Deck scripts, and other HTTP callers can use the same API.

**Remote webhook services:** localhost is reachable only from this Mac. Explicit LAN mode listens on all interfaces over HTTP. Use a trusted LAN or a separately configured authenticated HTTPS tunnel/VPN; do not port-forward this HTTP port directly. This build does not provision a public webhook URL or keep the Mac awake.

## Coverage and known limits

Luma supports the capabilities exposed by each model, with cloud and LAN control verified on compatible hardware. This does not imply complete parity with the Govee Home app. Dynamic scene discovery and brightness control/readback have been tested. Enable LAN Control in Govee Home on compatible models before discovery.

Supported: official cloud and basic LAN controls; capabilities reported by the API; applying returned dynamic/DIY effects; local scenes/sequences; schedules; inbound authenticated webhooks.

Not implemented: Bluetooth-only lights, private Govee account login, per-LED real-time streaming (DreamView/Razer), audio sync, creating/editing Govee DIY animations, Govee Tap-to-Run import, MQTT, outbound event webhooks, or automatic launch at login. Some Govee app features are unavailable through the public API. DIY response formats and effect support can vary by model.

No Govee app binary was supplied or analyzed. The requested reverse-engineer-anything workflow was used to scope evidence: this implementation uses official protocol documentation and primary upstream code research, not decompilation or a captured private login. See [protocol research](docs/PROTOCOL-RESEARCH.md) for source links, observations, inferences, and unresolved model-specific questions.

## Build and verify

Requires macOS 14+ and Swift 6.2+ / Xcode Command Line Tools. The included local app was compiled for Apple Silicon. No third-party package downloads are needed.

```sh
./scripts/verify.sh
./scripts/build-app.sh
./scripts/run.sh
./scripts/run.sh --demo
```

The native SwiftPM build path works around this installed toolchain's unsigned XCTest bundle loader. It currently emits a deprecation warning. A normal `swift build` can also be used on other toolchains. Build scripts produce an ad-hoc signed local app, not a notarized distribution. A rebuild can trigger another Keychain permission prompt.

Data: `~/Library/Application Support/Luma/home.json`, with owner-only permissions. Demo changes do not persist and never contact lights. `LUMA_DATA_DIR` can override the data folder for isolated local QA. The app preserves unreadable configuration rather than overwriting it. Activity logs stay in memory and exclude credentials.

Source layout: `LumaCore` contains cloud/LAN transports, HTTP parser/server, command validation, automation models, and Screen Sync color math. `Luma` contains SwiftUI screens, Keychain/persistence, run execution, scheduling, and the ScreenCaptureKit adapter. Tests include mocked cloud wire contracts, LAN packet contracts, real localhost HTTP authentication, demo-home automation journeys, and synthetic-frame Screen Sync contracts.

In demo mode (`./scripts/run.sh --demo`), Screen Sync offers a synthetic **Sample video** source instead of the macOS picker, so the flow can be tried without capturing the screen.
