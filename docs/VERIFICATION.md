# Verification ledger

Built on 2026-10-15 with Apple Swift 6.4, arm64, macOS SDK 27.2; deployment target macOS 14.

## Completed

- Native debug and release builds compile. Packaged `.app` is ad-hoc signed; `codesign --verify --deep --strict` passes.
- 34 Swift Testing tests pass and cover cloud request/response contracts, capability enumeration, online/offline telemetry, cancellation and request pacing; LAN discovery/status/control wire formats; HTTP framing/auth/body limits; real NWListener/URLSession loopback traffic; action/schema validation (including segment arrays), schedules, and scene JSON round trips.
- App-level demo journeys verify room-scoped webhook actions, returned run status, invalid-action rejection before execution, saved-scene webhooks, cancellation, and static/dynamic effect preservation.
- Visual QA in the packaged Mac app verifies dashboard rendering, a power toggle updating the light count, a scene applying power/brightness to multiple sample lights, the device inspector, automation settings, and the secure cloud connection sheet.
- All tests use synthetic devices or mocked cloud responses. The localhost integration test required sandbox approval to bind a temporary loopback port and passed outside the restricted shell sandbox.

## Live hardware evidence

- The API key was entered directly into the app and remained in Keychain; no credential was read into the conversation.
- Official enumeration and state reads verified multiple supported models and online/offline status. Account-specific inventory is excluded from this public report.
- A test light (H6056) changed from 100% to 95% brightness; a later cloud state read confirmed 95%. A restore command and read confirmed 100% again. Power and color were preserved. This is cloud telemetry evidence, not independent visual observation of the physical lamp.
- The dynamic-scene endpoint returned structured id/paramId options for the test light. Fetching this catalog did not apply an effect.
- The initial multicast scan failed with EHOSTUNREACH. Read-only route inspection found the multicast route on en0. System Settings showed Luma's Local Network switch enabled. Later scans discovered compatible lights, and brightness edits plus status readbacks were verified over LAN. No OS network settings were changed.

## Remaining model-specific verification

- LAN discovery requires compatible devices with LAN Control enabled and local-network permission. Basic brightness control and status replies are verified; other model-specific LAN behavior still needs hardware checks.
- Segment colors, music/movie modes, DIY choices and individual dynamic effects are exposed from actual schemas but have not all been applied to hardware. API success and UDP send success do not establish hardware behavior.
- Bluetooth-only lights, private-app APIs and per-LED realtime streaming are outside this build. Whole-light LAN Screen Sync was added in 0.3.0 below.

No Govee shipped binary or private capture was provided. No REA binary session was opened, no disassembly conclusions are claimed, and there are no REA Evidence IDs. Protocol findings are documentation/upstream-source observations and explicit inferences in `PROTOCOL-RESEARCH.md`.

## 0.1.1 interaction regressions

The interaction fix shipped as 0.1.1 (build 2). Its full test suite passed, including the real localhost webhook test.

Added eight app-level tests using the real HomeStore/GoveeCloud pipeline and gated URLSession replies. They cover delayed 40% telemetry after a newer 100% request, immediate rapid on/off toggles, coalescing unsent slider edits, preserving order across different controls, failure rollback, older failures preserving newer requests, cancelling an unsent scene command, and an older LAN callback arriving after the latest brightness was confirmed (including differently cased device IDs). Network responses are released at explicit test checkpoints, with no physical lights involved.

The UI keeps a requested-value overlay separate from confirmed/persisted state. Slider drafts ignore telemetry during a drag. Cloud reads carry the device revision from request start. LAN confirmation uses a short settle interval because UDP status has no request identifier. macOS 15+ controls opt into handling the click that activates an inactive window; macOS 14 uses a public AppKit hosting fallback.

Live UI verification sent rapid 40% and 100% edits through the LAN command path on the test light. The final displayed and reported brightness remained 100%. Single-click navigation worked in the updated app. The existing webhook listener was restored after the update using the existing saved token and port.

## 0.2.0 interface overhaul

Opus led the adaptive theme and native navigation overhaul, with three Sonnet delegates implementing scenes, automations, and the device inspector. GPT-6 Astra reviewed the integrated result and its fixes, with no remaining P1/P2 code findings. Its review was read-only; hardware and GUI evidence are recorded separately.

All 45 Swift Testing tests pass, including the real authenticated localhost webhook integration and the existing delayed-telemetry control regressions. New regression coverage checks extreme numeric values before returning from scene JSON to visual editing, duplicate step IDs, repair of legacy IDs without losing commands, and model-specific white-temperature bounds. The demo RGB workflow also verifies that switching from white clears the previous temperature mode.

Visual QA in an isolated demo app verified light and dark appearance, continuous slider tracks without dotted tick marks, brightness 40% → 100%, color/white presets, Light and Details tabs, scene capture with icon selection, visual delay editing and saving, scene execution, schedule creation, and the About attribution/warranty text. Demo testing did not control real lights or use account credentials.

Closing the main window and invoking Settings initially reopened Lights. Shared navigation state now records the destination before opening the single main window; the same GUI sequence visibly reopened Settings after the fix.

The app's Settings/About and Help links use the intended `designxdevelop/luma` GitHub address. At the time of the interface review, the repository had not yet been published. The included MIT license is bundled inside the app. macOS 14 runtime layout has not been independently tested on a macOS 14 machine.

The reviewed 0.2.0 build (3) was copied to the requested project folder. Its installed executable hash matched the verified release artifact, strict code-signature verification passed, and the bundled license matched the source license. First launch waited for a local Keychain prompt; subsequent inspection verified that the cloud connection was active.

## 0.2.1 webhook accessibility fix

Starting the webhook server and querying accessibility crashed 0.2.0 twice. Local crash stacks showed recursive SwiftUI/AppKit accessibility-label resolution. Removing token text selection alone passed a demo check but did not resolve the live failure. Build 5 also removes the custom token text label and selectable status/code-block text. Ordinary masked text, Show/Hide, and dedicated Copy buttons remain. The precise SwiftUI recursion trigger is unproven; this broader workaround passed the previously failing live path. Astra's focused closure review found no P1/P2 findings.

An isolated demo build started a loopback listener on port 18787, returned a readable accessibility tree with its token hidden, survived Show and Hide with the temporary demo token redacted from tool output, and stopped normally. No account credentials or real lights were involved. The 0.2.1 release build and strict code-signature verification passed.

Installed build 5 successfully restored the existing listener on LAN port 8787 using its saved token, with the token remaining hidden. The accessibility tree remained readable after startup and page navigation. An unauthenticated `GET /health` returned HTTP 401, confirming authentication is enforced. A subsequent read-only scan rediscovered compatible LAN lights without sending lighting commands. No credential was exposed or rotated.

## 0.3.0 native Mac Screen Sync

Opus led the native Mac Screen Sync implementation. Two Sonnet 5.5 delegates owned separate files: the Screen Sync page UI, and the core math tests. The core test delegate found a crash in color targeting when the green or blue channel was NaN; the guard now covers all channels, with a regression test. The Windows/Linux Electron port was read only to align defaults and color math; no file there was changed.

Capture uses ScreenCaptureKit. The API surface was checked against the macOS SDK headers and Apple's `SCContentSharingPicker` documentation. A real source is chosen only through the system content-sharing picker (macOS 14+). Luma never calls `SCShareableContent` or the CoreGraphics capture-permission preflight/request functions; a source grep and a release-binary symbol check found none. Window and display names use `#available(macOS 15.2, *)`; macOS 14 shows "Selected window" or "Selected display". Apple's documentation does not state whether picker-based capture skips the Screen Recording permission on every macOS version, so the app treats a declined stream as a normal, explained state.

All 94 Swift Testing tests pass: the 45 earlier tests (including the real authenticated localhost webhook and delayed-telemetry control regressions), 36 synthetic-frame math contracts, and 13 controller/HomeStore integration tests. The frame tests build 32BGRA buffers with padded rows and garbage padding. They cover channel order, symmetric letterbox and pillarbox cropping with a 25% cap, dark scenes, encoder noise, invalid and oversized frames, capped brightness, dead bands, smoothing, per-light rate caps, latest-only sends, and eligibility reasons. Integration tests use a fake capture session and cover: no capture before an explicit Start; Stop and Pause ending capture; stale frames and endings from an old session being ignored; Stop during a pending start; permission denied, source gone, user-stopped and failed endings; manual controls and webhook actions releasing a light synchronously before their write; streamed colors never reaching confirmed state, pending controls, activity, or `/v1/devices`; skipping cloud-only, offline, off and unknown lights; and settings persisting while the source and running state never do. Removing the ownership hook from `HomeStore.prepare` made two of those tests fail, as expected. A Stop or Pause that arrives while ScreenCaptureKit is still starting, such as during the consent alert, stops the stream again once start completes. That path was reviewed but not exercised against real ScreenCaptureKit.

The 0.3.0 (6) release build compiled and passed strict ad-hoc signature verification. It was assembled outside `dist/` and was not installed or launched.

GPT-6 Astra's final review found and closed stale targets surviving Pause/Resume, ordinary writes competing with streaming, shutdown readbacks reopening LAN, preferences lost after leaving startup demo, real capture surviving entry into demo, and initial frames discarded during startup. It also identified a brightness-cap reduction being suppressed by the dead band and missing readback on removal; both are fixed. Regression tests cover those paths, including a gated in-flight ordinary command and isolated preferences through both demo transitions. Astra's closure review reported no remaining actionable objections in this scope.

The parent independently reran the final full suite: **104 tests passed** (45 earlier contracts, 37 math contracts, 22 Screen Sync integration tests), including the real localhost webhook integration. The parent rebuilt `dist/Luma.app` as 0.3.0 (6), and strict signature verification passed. SwiftPM emitted its existing native-build deprecation and restricted user-cache warnings; there were no Swift source warnings.

GUI checks in an isolated preview verified the synthetic source, Start, Pause, explicit Resume, Stop forgetting the source, manual brightness taking a light out of sync, and the visible capture indicator. The revised page exposes all four tuning sliders through accessibility. A 40% → 100% brightness-cap edit remained at 100%; the continuous tracks have no dotted tick marks or duplicated slider titles. Keyboard navigation with ⌘6 opened Screen Sync. These were synthetic demo checks, not hardware observations.

Not verified: no real capture source or permission was selected by the agent. Hardware behavior, perceived latency, and per-model `colorwc`/brightness pacing are unknown. Exact 1020×700 layout, dark appearance for this new page, full VoiceOver navigation, and the macOS 14 picker flow still need runtime QA. Native source reuse, window closure, consent cancellation, and rapid stop/start behavior also remain runtime checks. The demo **Sample video** source exercises the UI path without capture.

The reviewed app and source were copied to the requested `Code/dxd/luma` folder. The installed executable SHA-256 matched the reviewed artifact (`93ea7bbf6e7e903f7528d5a9dd068e5a80bebd7750aa9bdeae4d4ae8cca10e4d`), and strict signature verification passed. Startup waited on a local Keychain access prompt (`SecItemCopyMatching` in a process sample); the user cleared it locally. The older process was closed, the updated app launched, and its interface showed the new Screen Sync page and the existing cloud connection. The saved home and Keychain were not replaced or reset.

The existing webhook listener was restored on LAN port 8787 with its saved token hidden. Its accessibility tree remained readable, and an unauthenticated `GET /health` returned HTTP 401. A read-only Wi-Fi scan rediscovered compatible local lights. The final Screen Sync page showed Off, no chosen source, and zero included lights; no real capture or Screen Sync light traffic was started by the agent. A separate Govee HTTP 400 notice appeared during the connected session; the triggering request and model were not established, so this does not verify every cloud operation.
