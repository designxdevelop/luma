# Windows port decisions

## Platform

Electron + TypeScript separates a sandboxed local renderer from Node networking and desktop integration. The frontend is new; SwiftUI cannot run on Windows. The API and validation contracts are ported from sanitized Mac source references, not a copied runtime home.

Official references checked 2026-10-16:

- [Electron security](https://www.electronjs.org/docs/latest/tutorial/security): keep Node out of the renderer, use context isolation and sandboxing, validate IPC senders, restrict navigation and external links, and serve only packaged code.
- [Electron safeStorage](https://www.electronjs.org/docs/latest/api/safe-storage): Windows storage uses DPAPI. This protects secrets at rest from other Windows users, not other programs running as the same user. Never fall back to plaintext. Do not exercise macOS Keychain during this port's QA.
- [Windows packaging](https://www.electron.build/win.html): build the Windows installer in Windows CI; signing requires separately configured publisher credentials. An unsigned build is not a signed public release.
- [Govee device enumeration](https://developer.govee.com/reference/get-you-devices) and [control](https://developer.govee.com/reference/control-you-devices): use the official router API and each device's advertised capability schema. An accepted control request is not hardware confirmation.

The design follows the Mac app's neutral surfaces, amber accents, color orbs, compact cards, normal form controls, and adaptive light/dark appearance. Sliders have continuous tracks without visible ticks. Keyboard input must commit controls as reliably as pointer input.

## Testing boundaries

Automated tests use synthetic fixtures and loopback-only HTTP. Demo mode must not contact devices or persist user changes. Actual capture, secret-store integration, installation, and hardware behavior require checks on the target platform; see [Verification](VERIFICATION.md).

## Release scope

The initial Windows implementation covers public cloud capabilities, compatible basic LAN controls, app-owned scenes, schedules while running/awake, authenticated inbound webhooks, tray access, and encrypted secrets. It does not promise private Govee app parity, Bluetooth, MQTT, screen/audio streaming, or editing Govee DIY animations.

No Windows runtime was found during initial host inspection. macOS compilation, pure TypeScript tests, and a demo renderer inspection do not replace Windows runtime QA, DPAPI testing, firewall checks, tray behavior testing, or installer validation. See VERIFICATION.md for actual results when available.

## Screen Sync 0.2.0

Screen Sync adds a portable color-processing and bounded-streaming core behind Windows and Linux capture adapters. It uses current Electron desktopCapturer/getDisplayMedia APIs with explicit source selection; the application's capture grant must not follow the docs' automatic-first-screen example. Source enumeration disables thumbnails. No Govee Desktop shipped artifact is needed or analyzed: this MVP sends documented whole-device LAN RGB only.

Pixels remain inside the local capture/worker path; only derived color summaries reach the main process. The stream has separate ownership/queues from confirmed controls, avoiding frame backlogs and per-frame cloud traffic. Manual controls and automations must take ownership before ordinary commands. No capture begins in the synthetic demo on this development Mac.

Linux capture/session policy and packaging are included, with real compositor capture verification still pending. The native Mac implementation lives at the repository root. The pure sampler, smoothing, region selection and LAN queue remain portable. See [Screen Sync](SCREEN-SYNC.md) for platform and evidence boundaries.
