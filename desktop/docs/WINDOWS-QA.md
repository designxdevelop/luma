# Windows release gate

This checklist is for a Windows operator. It has not been executed on this macOS development host. No real-light test is implied by passing the offline suite.

1. **Install and demo** — On a clean Windows 11 x64 user profile, install the CI-produced NSIS artifact. Launch demo, try dark/light mode, keyboard-only navigation, a light inspector, scene editing and weekday schedules. Restart demo and verify its edits did not persist. Check that demo did not bind UDP4002 or HTTP8787.
2. **Connect securely** — Use an existing API key in the app's secure entry. Verify that encrypted secrets are stored outside the source tree and exports. Restart and confirm decrypt works under the same Windows user. Check the UI's failure path if encrypted storage is unavailable; plaintext fallback is forbidden. Do not regenerate a working key just for this app.
3. **Verify controlled writes** — Choose one expendable light with permission. Read its current state, submit one brightness change and restore it. Then exercise rapid brightness/toggle changes and confirm the final intent wins. Test refresh and failure handling without assuming a successful HTTP response confirms the hardware state.
4. **Verify networking and automation** — Enable LAN Control in Govee Home for a compatible light. Test discovery, UDP4002 port conflict reporting, cloud-only capabilities, authenticated loopback requests, invalid/oversized requests, listener port conflicts, scene cancellation and sleep/resume schedule behavior. Enabling LAN listener access and any Windows Firewall change must be deliberate operator actions.
5. **Verify desktop lifecycle** — Close and restore from the tray, quit explicitly, restart and inspect saved home/rooms/scenes/schedules. Install an update over the same version, uninstall, and check displayed publisher/signature status. Unsigned artifacts require a separate signing/release step; do not describe them as signed or SmartScreen-approved.

Record Windows version/architecture, artifact SHA256, application version, pass/fail evidence, and model SKUs (no device IDs, API keys or bearer tokens in shared reports). Report hardware results by model; do not generalize one working model to all Govee lights.

## Screen Sync Windows gate

This additional gate is unexecuted on the Mac host. Test with permission to capture the selected content and control the chosen lights.

1. **Consent and privacy** — Launch with Screen Sync off; choose a monitor/window explicitly, map only chosen LAN lights, then Start. Verify a persistent active indicator and Pause/Stop. Denying permission or selecting a vanished source must fail closed. Confirm no audio track, recording, thumbnails, pixel logs or uploads. Test source selection again after restart, without auto-capture.
2. **Lifecycle** — Stop, Pause, close/minimize as implemented, renderer reload/crash, lock/unlock, sleep/resume, window closure, unplug/reconfigure a monitor, and capture track end/mute. Verify capture tracks and pending frames stop, no stale colors follow Stop, and capture requires a new explicit Start.
3. **Color** — Use controlled SDR test patterns with known left/right/top/bottom colors, then letterboxed, black, bright and HDR content. Record approximation/clipping, and verify the cap/smoothing/threshold controls. No claim of HDR correctness follows from synthetic SDR tests.
4. **Ownership and recovery** — Exercise a manual change, a scene, schedule and webhook during sync; verify there is one owner per light and no stream command arrives after the manual handoff. Test Leave versus explicit restoration using a previously confirmed state; manually excluded lights must not be restored. Cloud-only lights must remain unavailable without fallback.
5. **Measure and release** — Record Windows build, display/HDR mode, model SKU, source type, configured rate, processed/sent/dropped counters, observed update interval and measured end-to-end capture-to-light latency. Include slow-network/backpressure/failure tests. Successful UDP send counters are not hardware latency or confirmation. Validate the final unsigned installer separately before signing/public release.
