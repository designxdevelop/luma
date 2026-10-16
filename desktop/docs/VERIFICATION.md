# 0.2.0 Screen Sync and Linux verification

Date: 2026-10-16. Shared Windows/Linux Electron 44.8.0 app. The historical 0.1.0 record follows below.

## Automated checks

`npm test` passes **189/189** synthetic/loopback contracts on macOS Node 26.7.0; the same compiled suite passes **189/189** on offline Linux Node 24. Both TypeScript configurations pass `npm run typecheck`.

Coverage includes region mapping, linear-light averaging and black bars, smoothing/caps/thresholds, paced latest-only LAN backpressure, stop/drain and manual override barriers, confirmed-state separation, automation conflicts and LAN-only restoration. Capture tests use fakes for source-grant revocation races, late media/play/bitmap results, Pause/Stop/new-session identity, stale worker callbacks, paused renderer reload/crash cleanup, and Linux lock observation/unknown/failure gates. Original stale 40→100, fast-toggle, ordered controls, cloud/LAN, strict webhook auth/framing and scene-validation contracts remain passing.

## Independent review

Opus 5.5 led implementation and UI, with Sonnet 5.5 workers for portable tests and Linux support. Fresh GPT-6 Astra reviews identified and fixed pending source revocation, late media/play completion, paused renderer reload cleanup, Linux lock-event coverage and a delayed-bitmap sampling-loop leak. The final fresh follow-up verified the delayed-bitmap fix and passed 9/9 focused lifecycle tests with **no remaining actionable P1/P2 findings**. Reviews were source/fake-runtime checks, not Windows or real desktop capture QA.

Linux uses a read-only systemd-logind monitor on GNOME/KDE with fresh unlocked checks before real Choose/Start, immediate observed lock revocation, owner-loss refusal and bounded reads. Other desktops or unavailable monitoring refuse real capture. The gdbus startup grace is a heuristic, not a subscription acknowledgement; polling cannot detect an entirely missed Lock→Unlock pair. This path is experimental and has not been verified on a real desktop.

## Actual runtime QA and limits

The local Linux arm64 Electron app ran under Xvfb through the real renderer, FramePump and OffscreenCanvas worker. The synthetic flow passed **19/19** checks: sandboxed preload, no Node renderer, no demo listener, real capture requests refused, explicit synthetic source/light selection, worker output, Pause/Resume, Stop/stale-token behavior, unchanged confirmed state and a real page reload ending a paused session. The final rebuilt arm64 packaged bundle passed the same **19/19** checks.

Earlier isolated macOS Electron demo UI QA checked region previews, manual exclusion, automation conflict, optional restoration, tickless controls and a 720×568 layout. No actual capture APIs were invoked by the demo. No host screens, permissions, secret stores, native Mac source/runtime or lights were accessed.

Linux QA used the existing local OrbStack Linux/aarch64 daemon and `qa/linux/Dockerfile` (official Node 24 Debian base, runtime libraries and Xvfb). Containers had no network, ran as USER node, and mounted app/scripts read-only. Container-only seccomp relaxation and `--disable-setuid-sandbox` enabled Chromium's user-namespace sandbox. `--no-sandbox` was never used. The bounded wrapper is `scripts/linux-container-smoke.sh`.

**Not verified:** Windows runtime/installer/DPAPI/tray/capture; real Linux X11/Wayland portal capture, GNOME/KDE lock reporting and keyring integration; real LAN lights/model compatibility, HDR fidelity or end-to-end latency. The Windows/Linux workflows were prepared before publication; their results are recorded by GitHub Actions. Native Mac feature work lives at the repository root.

## Packages

Built and inspected: unsigned Windows x64 `Luma Setup 0.2.0.exe`, Linux `luma-0.2.0-linux-x64.tar.gz` and `luma-0.2.0-linux-arm64.tar.gz`. Checksums are in `release/SHA256SUMS.txt` (local build output) and `release-linux/SHA256SUMS.txt` (local build output). PE inspection confirms the x64 app, expected 32-bit NSIS stub and empty certificate directories (unsigned). ELF inspection confirms x64 and arm64. All three ASARs contain identical app bytes matching 31 compiled source files, including capture, lock guard, stream, worker and preload; tests, runtime data, secrets and build dependencies are excluded. Both Linux archives pass gzip CRC and embedded ASAR/ELF checks. Before public release, execute [Windows runtime QA](WINDOWS-QA.md) and [Linux desktop gates](LINUX.md).

---

# Verification record

Date: 2026-10-16. Application version: 0.1.0.

## Environment and boundaries

Development host: macOS arm64 (Darwin 27.2.0), Node 26.7.0. No Windows host/VM, PowerShell, Wine or usable Windows runtime was available. The lockfile selects Electron 44.8.0, electron-builder 26.15.3 and TypeScript 5.9.3.

All automated transport tests use fakes or loopback. No Mac app source/runtime, installed Mac app, Keychain entry, OS/network setting or real light was modified. The port was developed against sanitized Mac source/spec/test references; the current native implementation is at the repository root. Demo uses synthetic inventory, in-memory home data and a throwaway Chromium profile; real cloud, LAN, secrets and listener objects are disabled.

## Automated verification

`npm test` passed **113/113**, with zero failures, skips or cancellations. `npm run typecheck` passed for main/core and renderer. The test command compiles both targets and copies renderer assets before execution. The suite covers stale 40→100 responses, fast power toggles, per-device order/coalescing, latest-failure rollback, bounded confirmation expiry, scene validation (including 1e100 and duplicate IDs), model white bounds, cloud/LAN wire contracts, strict webhook authentication/framing/limits, storage and integration journeys.

Loopback listener tests require sandbox network permission on this host. The initial unprivileged run hit EPERM; the authorized loopback-only run passed. This is a sandbox restriction, not a Windows test result.

## Independent review

Opus 5.5 led implementation and UI; Sonnet 5.5 children owned transports, webhook HTTP/API and integration coverage. A fresh GPT-6 Astra review found three P2 issues (effect-switch refresh, opposite color settle state, and disconnect during connect). Fixes added regression coverage. A second fresh Astra review caught cached RGB being treated as confirmation; root fixed fresh-field and mode checks and added two more regressions. Final independent review reported **no remaining P1/P2 findings**. Review was source-only, not Windows QA.

## Demo UI checks on macOS Electron

Argent drove only isolated port demo processes using accessibility-derived element positions. Checks included:

- Continuous sliders with no ticks: pointer, arrow-key and focused-wheel commits, matching card/inspector values.
- Light/Effects/Details, white presets/model ranges, schema-driven segment controls, and applying the displayed required RGB default.
- Scene capture/icon choice, structured reorder preserving values/delays, strict Advanced JSON validation through preload, and weekday selection/next occurrence.
- Narrow 720×568 renderer with no horizontal overflow; dark system palette and in-memory forced light palette (no OS appearance change).
- Effect toggle on/off remains correct across snapshots; a 250 ms scene delay passes native validity and saves into the demo scene.
- Demo restart restoring synthetic defaults and discarding scene/control edits. Webhook/discovery remain disabled in demo.

A [dark demo screenshot](screenshots/demo-dark.png) and [light demo screenshot](screenshots/demo-light.png) record the renderer on macOS, not a Windows runtime.

These checks establish renderer behavior on macOS Electron. They do not establish Windows control rendering, native picker behavior, tray lifecycle, DPAPI, firewall prompts, installer execution or real hardware operation.

## Packaging and release status

An unsigned x64 Windows NSIS installer was cross-built on macOS. Final artifact hashes live in `release/SHA256SUMS.txt`. Final installer: `Luma Setup 0.1.0.exe`, 111,690,348 bytes. SHA256: `6574ceed5ac0b4b76b4e7d31ea92630b33fd0d968286204302e1d3abb79586ee`. PE inspection found x64 machine `0x8664` for the application and the expected 32-bit NSIS stub (`0x14c`). Both certificate directories are zero: unsigned. The ASAR contains compiled app/core/preload/renderer and icon/tray assets, with no tests, runtime home, secret files or build dependencies. Windows CI is prepared in `.github/workflows/windows.yml`; it has not run in a published repository.

Before public release, execute [the Windows runtime gate](WINDOWS-QA.md), test supported light models, configure publisher signing and verify the resulting signature. Intended repository links do not establish publication.

The build-only dependency audit found 8 moderate advisories through electron-builder → @electron/get → global-agent → roarr → sprintf-js 1.1.3 (GHSA-hp3w-g68c-fv3c). No patched sprintf-js version was available at inspection. These tools are excluded from the packaged application; no forced dependency rewrite was applied.
