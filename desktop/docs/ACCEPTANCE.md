# Windows acceptance checks

Use only synthetic fixtures until an operator explicitly tests on Windows with their own lights. This is a verification plan, not a claim that each check has passed.

## Control correctness

- A confirmed brightness of 40, then requests 70 and 100, must display 100 immediately. A read started before 100 cannot move the display backwards. Only confirmed telemetry belongs in persisted data or webhook GET responses.
- Toggle on/off/on rapidly: keep per-device submission order and the latest display intent. Coalesce only unsent writes to the same control without moving them across intervening controls. Do not retry an ambiguous failed write automatically.
- Failure of an older write cannot roll back a newer intent. Failure of the newest write rolls back to last confirmed state with an actionable error. Unconfirmed overlays expire within a bounded interval.
- Delayed unversioned LAN status after a write must not immediately overwrite latest intent. Pointer drafts remain steady during telemetry; pointer release, keyboard adjustments, assistive input, and wheel interactions commit correctly.
- Model-specific min/max/step applies to white temperature, brightness, segment indices and all schema fields. Reject nonfinite, fractional integer, out-of-range, unknown and malformed values before wire submission.

## Automation and HTTP

- Validate every scene step before executing the first. Reject duplicate step IDs, unknown device/capability, invalid delays, malformed structures, 1e100, duplicate segment indices, and unsupported values. Cancellation cannot undo applied commands.
- One automation at a time. Accepted HTTP actions return 202 + run ID before completion. Expose bounded run history and accurate failed/cancelled/completed status.
- Require Bearer auth on every route, including health; reject URL token auth, duplicate auth/framing headers, query strings, chunked/conflicting lengths, invalid UTF-8/JSON, oversized/slow requests and unsupported content types. Limit request JSON to 64KiB.
- Server is off on startup, loopback port8787 by default. LAN binding requires explicit selection. Tokens and API keys are not included in logs, home data, exports, diagnostics or normal snapshots.
- Schedules show next occurrence, honor weekday/timezone choices, avoid duplicate firing within a minute, and skip missed times while asleep/closed.

## Desktop and design

- Demo launches without credential store/network/user-data writes and cannot accidentally enable real transport or local listener. Verify dark/light, narrow layout, keyboard focus, dialogs, continuous sliders and empty/error states.
- Light inspector contains Light/Effects/Details, schema-based effects including structures and segments; raw JSON is only under Advanced. Scene editing supports visual capture, icons, ordered steps, delays, import/export.
- Windows runtime: fresh install/uninstall, x64 launch, tray restore/quit, close-window behavior, DPAPI encrypted storage and failure handling, LAN UDP4002 bind conflicts, cloud refresh, listener port conflicts, restart persistence, and Windows Defender prompts. Do not automate OS/firewall changes.
- About contains required Design X Develop attribution, warranty statement, MIT copyright and intended repository/issue links without claiming a published repository.

## Screen Sync

- Explicit monitor/window and light selection precede Start; no automatic source choice or capture at startup/resume. Demo/non-Windows cannot enumerate or capture this Mac, even through IPC. Grant capture only to the selected current source and trusted top-level renderer, with no audio, camera, arbitrary file or network access.
- Sample generated frames off the UI thread. Verify full/left/right/top/bottom mappings, contiguous black-letterbox trimming, dark-scene behavior, smoothing, change threshold, finite bounds, brightness cap and continuous tickless settings. Preview values are not hardware confirmation.
- LAN-only bounded latest-value streaming, with a conservative per-device frequency cap and no cloud/readback fallback. Prove a slow sender does not accumulate frames, Stop drops pending work, old-session results are rejected, and no pixels/source titles are written to logs/disk or uploaded.
- Manual control excludes a mapped light before its command. Scenes/schedules/webhooks cannot fight an active stream. Handoff and explicit optional restoration drain old work first; never restore a manually excluded light or invent original state. Default Stop leaves the last sent colors.
- Release tracks, workers and pending frames on Stop/quit/interruption; handle source/monitor changes, ended/muted capture, renderer loss, lock/sleep and processing stalls. Resume requires fresh explicit consent. Windows source/capture behavior, HDR approximation and measured model latency remain platform runtime gates.
