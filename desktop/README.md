# Luma for Windows and Linux

An Electron and TypeScript desktop app for Govee lights on Windows and Linux. The original SwiftUI Mac app cannot run on Windows; this project reuses its protocol and validation contracts behind a new desktop interface.

Luma is an open-source project built by Design X Develop LLC.

Provided as is, without warranty.

MIT · Copyright (c) 2026 Design X Develop LLC. [Source repository](https://github.com/designxdevelop/luma) · [Issue tracker](https://github.com/designxdevelop/luma/issues). Issues and pull requests are welcome. See [Contributing](../CONTRIBUTING.md).

## Build from source

Targets: Windows 11 x64 and Linux x64/arm64, with Node 22.12 or newer for source builds. This source is developed on macOS; see [actual verification](docs/VERIFICATION.md) and the [Windows runtime release gate](docs/WINDOWS-QA.md).

```powershell
npm ci
npm run runtime:install
npm test
npm run demo
```

Electron44 requires the explicit runtime installation above. The demo uses synthetic lights and is intended to avoid real networking, credential storage, and persisted edits. Enter real credentials only in the connected Windows/Linux app; never put them in chat, source files, scene exports, or shell history.

To build an unsigned Windows installer:

```powershell
npm run dist:win
```

The installer output goes to `release/`. Publishing a signed release requires publisher signing credentials configured separately. Source compilation and an unsigned artifact are not evidence that the installer, Windows tray, or DPAPI have been tested on Windows.

## Scope

The port implements official Govee cloud capability controls, basic LAN control for compatible lights with LAN Control enabled, rooms, local scenes/sequences, schedules while the app is running and awake, tray access, and an authenticated local webhook listener.

Model-specific capabilities and bounds come from the advertised schema. Some Govee Home features are unavailable through the public API. This project does not implement Bluetooth, private Govee account login, MQTT, per-LED streaming, audio sync, creation/editing of Govee DIY animations, or Govee Tap-to-Run import.

Use an existing developer API key from Govee Home. [Govee's key policy](https://developer.govee.com/changelog/important-policy-update-important-notice-regarding-api-key-security-management) says generating a new key invalidates older account keys. Windows credentials use Electron safeStorage/DPAPI. Linux requires a recognized libsecret/KWallet backend and refuses basic_text/unknown storage. Secrets remain outside the project; see [Linux prerequisites](docs/LINUX.md). DPAPI protects against other Windows users; programs running as your user can still access your secrets.

A cloud success means a command was accepted, not that a light changed. LAN sends are unacknowledged. Control feedback needs readback, stale-response protection, and bounded confirmation handling. Never treat pending UI values as confirmed telemetry.

## Using the app

1. Try **Demo** first (`npm run demo`, or `Luma.exe --demo` from the installed app folder). It uses synthetic lights, temporary Chromium preferences, and in-memory changes. It cannot start network control or the webhook listener.
2. On Windows, run `npm start` or install the `.exe`; on Linux, follow the [Linux runtime guide](docs/LINUX.md). In **Settings**, enter an existing Govee developer API key securely, then connect. Compatible LAN lights also need **LAN Control** enabled in Govee Home; use **Discover** in Luma.
3. Open a light for **Light / Effects / Details**. Available controls and white ranges depend on its schema. Effect toggles remember the latest action for this session; they are not live effect telemetry.
4. Use **Scenes** to capture confirmed light values, choose an icon, edit ordered steps/delays, or import/export validated JSON. Only one sequence runs at a time; stopping leaves commands already sent in place.
5. Use **Automations** for local weekday schedules and optional webhooks. The app must remain running and awake. Closing its window keeps it in the tray; **Quit** stops it.

Connected data lives in `%APPDATA%\LumaWindows` on Windows and Electron's app-data path under `LumaLinux` on Linux. Home data contains devices, rooms, scenes and schedules; encrypted secret files are separate. Scene exports contain device IDs and commands, so review them before sharing. Do not copy a runtime home into this source project.

## Screen Sync

Screen Sync maps a selected screen/window to compatible LAN lights. Cloud-only lights are unavailable in this mode; no cloud fallback or per-frame cloud readback is used.

1. Open **Screen Sync**, choose a screen/window explicitly, then select lights that are already on and reachable through LAN Control. Demo offers generated sources only.
2. Map each light to the whole picture or its left/right/top/bottom region. Choose smoothing, change threshold, brightness cap and update speed (continuous sliders, maximum 10 LAN packets/second per light; default 5).
3. Press **Start**. The persistent indicator and tray controls show the session. Swatches show requested, unconfirmed colors; the normal light cards/API/storage keep reported state.
4. **Pause** suspends processing and light updates; **Stop** releases capture. Hiding/minimizing the window pauses the session and requires Resume. Lock/sleep, display changes, capture interruptions and stalls stop it; Start again explicitly after those interruptions.
5. Choose **Leave lights as they are** (default) or explicit **Restore previous state** for Stop. Restoration uses last confirmed brightness/color over LAN only. Manual changes remove the light from the stream and it will not be restored. Scenes, schedules and webhooks cannot issue competing commands to lights participating in sync.

Frames are processed locally in a bounded worker path; no audio, AI vision, screenshots, recording, pixel logs or uploads. Black edge bands are trimmed; all-dark frames remain a dark scene. Color is an SDR approximation, and actual frame rate/end-to-end light latency must be measured on hardware. [Screen Sync design and limits](docs/SCREEN-SYNC.md).

Linux packaging is separate and preserves the Windows NSIS configuration:

```sh
npm run dist:linux
```

This produces architecture-labeled portable tar archives in `release-linux/`. Sandbox and keyring prerequisites are documented in [the Linux guide](docs/LINUX.md); real Wayland portal and X11 capture require desktop validation.

## Local webhook API

The listener is off by default. Start it explicitly in Automations; default binding is `127.0.0.1:8787`. LAN binding is a separate explicit choice. **HTTPS only:** the listener uses TLS 1.2 or newer, with no plain HTTP fallback. Luma stores a self-signed P-256 identity in encrypted OS storage and renews it before expiry. Export `luma.pem` in Automations and use a client that supports a custom CA file, such as `curl --cacert luma.pem`, or configure the exported PEM as an OS trust anchor. Clients that support SPKI pins can also use the displayed curl pin; curl still needs to trust the PEM.

In LAN mode the certificate covers this machine’s current non-loopback, non-link-local network addresses and, for a hostname without a dot, `hostname.local`. Luma regenerates the identity when those names or addresses change, so re-export the PEM and update any SPKI pins. Clients that can only toggle verification, including Home Assistant `rest_command` and iOS Shortcuts, should run on the same machine via `127.0.0.1` or trust the PEM at the OS level. Trust is still required for local connections; never disable verification. **Upgrading from HTTP:** update existing callers to HTTPS and trust the exported certificate.

Every endpoint, including `/health`, requires `Authorization: Bearer …`. Tokens are masked in the UI and copied by the main process.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/v1/devices`, `/v1/scenes` | Confirmed inventory or local scenes |
| GET | `/v1/runs`, `/v1/runs/:id` | Recent execution status |
| POST | `/v1/actions` | Basic actions for `all`, an exact device ID, or `room:Name` |
| POST | `/v1/scenes/:id/run` | Execute a saved scene |
| POST | `/v1/devices/:id/commands` | Schema-validated `{type, instance, value}` |

Export `luma.pem` from Automations and copy the token into an environment variable. For example:

```sh
curl --cacert luma.pem https://127.0.0.1:8787/v1/actions \
  -H "Authorization: Bearer $LUMA_TOKEN" -H "Content-Type: application/json" \
  -d '{"target":"all","power":true,"brightness":40}'
```

POST success returns HTTP 202 with `runID` and `statusURL`. Completion means commands were submitted, not hardware-confirmed. Busy execution returns 409. Requests use strict HTTP framing and bounded JSON bodies (64 KiB); chunked encoding is unsupported. Clear the clipboard after using a token. Rotating it invalidates previous copies.

## Documentation

- [Port choices and rough effort](docs/PORT-DECISIONS.md)
- [Acceptance requirements](docs/ACCEPTANCE.md)
- [Verification results](docs/VERIFICATION.md)
- [Windows release checks](docs/WINDOWS-QA.md)
- [Linux build/runtime checks](docs/LINUX.md)
- [Screen Sync](docs/SCREEN-SYNC.md)
- [Sanitized protocol research](../docs/PROTOCOL-RESEARCH.md)

No real lights, Mac runtime homes, installed Mac app, macOS Keychain entries, or OS/network settings are modified by this port's automated verification. The original native Mac implementation lives at the repository root; user inventory and credentials are not included.

### Navigation and preferences

Settings offers System, Light, and Dark appearance. The Lights page includes search; use Ctrl+F (Cmd+F on macOS) to focus it. Ctrl+1–6 opens Lights, Scenes, Automations, Activity, Settings, and Screen Sync. Ctrl+, opens Settings, Ctrl+Alt+Up/Down turns all lights on/off, and Ctrl+. stops a scene (use Cmd in place of Ctrl on macOS). Activity can be filtered to problems or cleared; its badge counts errors in the current session.

Scenes can be duplicated, schedules offer day presets, and a light's Details tab shows available network and identification information. Screen Sync response settings and per-light inclusion and regions are saved for the next launch; the capture source must be chosen each time. On an empty home, **Explore Demo** restarts Luma with an isolated temporary demo profile. Exit and launch normally to return to your home.
