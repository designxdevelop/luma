# Shared schedules ("Run schedules on [computer]")

One computer, the **runner**, keeps the shared scenes and schedules and is the only device that runs them. The runner can be a Mac (native app) or a Windows/Linux PC (Electron app). An iPhone, an iPad or another computer **pairs** with the runner over the home network. A paired device can view, edit, pause, disable and delete schedules. It never runs them. Use this when you want schedules to run while Luma on the iPhone is closed.

Code:

| Part | Native | Electron |
| --- | --- | --- |
| Protocol rules: records, merge, occurrences, pairing | `Sources/LumaCore/ScheduleSync.swift` | `desktop/src/core/schedule-sync.ts` |
| Storage, server, client, hand-off | `Sources/LumaUI/ScheduleSyncController.swift` | `desktop/src/main/schedule-sync.ts` |
| UI | `Sources/LumaUI/ScheduleSyncCard.swift` and a pause menu in `AutomationsView` | `desktop/src/renderer/schedule-sync-view.ts` |
| Tests | `Tests/LumaCoreTests/ScheduleSyncTests.swift`, `Tests/LumaAppTests/ScheduleSyncControllerTests.swift` | `desktop/src/test/schedule-sync.test.ts` |

Both implementations replay `desktop/src/test/fixtures/schedule-sync-vectors.json`. The TypeScript implementation generates this file; its ops and expected results are fixed.

## What is shared, and what is not

- **Shared settings:** scenes, schedules (scene, time, weekdays), on/off (`enabled`) and pause (`pausedUntil`, epoch ms). Pairing shares every scene and schedule. A scene must be shared, because the runner can only run scenes it has.
- **Observed telemetry:** for each schedule, the runner's last run report (`started`, `completed`, `failed`, `missed`, `paused`), and a last-seen time for each paired device. "Completed" means the commands were sent, not that the lights confirmed them.
- **Not shared:** live light state, light names and rooms, API keys, tokens, webhook settings, Screen/Audio Sync settings. Light IDs in scenes are Govee device IDs. A scene that uses a light the runner doesn't know fails when it runs, and the runner reports why.

## Model

- **Records:** each record is `{kind: scene|schedule, id: UUID (uppercase), rev, deleted?, value, updatedBy, updatedAt}`. A scene value uses the same shape as a scene in `luma-home-backup`: `symbol` for native, `icon` for Electron.
- **Revisions:** `rev` is the runner's own sequence number. Device clocks never decide a conflict.
- **Tombstones:** a deleted record stays as a tombstone permanently. Nothing can bring it back.
- **Change types:**
  - `put {baseRev, value}`: create (`baseRev 0`), edit, enable or resume. It applies only when `baseRev` matches the runner's current revision. A stale `put` is refused with `conflict`, and the runner's copy is kept. A `put` on a tombstone is always refused (`conflict`). A `put` with `baseRev > 0` on a record the runner never had is refused (`gone`).
  - `reduce {enabled: false?, pausedUntil?}`: turns a schedule off, or makes a pause longer. It always applies, so a pause or disable made offline is never lost to a newer edit. A `reduce` on a tombstone applies with no effect.
  - `delete`: always applies. Deleting a scene also deletes its schedules, as in both apps.
- **Merging edits:** the paired device combines its unsent edits into one pending change per record. When it sends, it picks `reduce` if the only differences from its copy are on → off or a longer pause. Otherwise it sends `put`.
- **Retries:** each change has a UUID. For each device, the runner keeps the results of its last 500 changes. If a response is lost and the device sends the same change again, it gets the same answer, not a false conflict.
- **Durability:** the runner writes its state atomically to `schedule-sync.json` before it answers. If the save fails, it answers 503 and keeps the old state. A change that has been acknowledged has always been saved.
- **Request size:** request bodies are capped at 64 KB, so a device sends its changes in batches of up to 48 KB. Scenes go before the schedules that use them.

## Execution

- **Who runs schedules:** only the runner. A device that isn't sharing runs its own schedules, as before. A paired device never runs schedules, even when the runner is offline. It fails closed.
- **Timing:** each schedule time is checked once per scheduled local minute between the previous check (every 15 s) and now, looking back at most a day.
  - A run up to **2 minutes** late (timer jitter, App Nap) still starts.
  - A run later than that is reported as `missed` and doesn't start. Lights don't change hours late.
  - A launch doesn't catch up on earlier times.
- **Crash safety:** before a scene starts, the runner records that its time slot has run (`lastRunMinute`). After a crash, that slot is skipped, never run again.
- **DST and time zones:** times are wall-clock times in the runner's local time zone. The runner reports its zone, and a paired device shows a warning when its own zone is different.
  - A time skipped by a spring-forward change never runs.
  - A time that happens twice in a fall-back change runs once, because both occurrences share one key.
  - Tested with `America/New_York` in both suites.
- **Staying awake:**
  - **Mac:** while it is the runner, it holds `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`, which disables App Nap. "Keep this Mac awake" switches this to `.userInitiated`, which also blocks idle sleep.
  - **Windows/Linux:** the option uses Electron `powerSaveBlocker.start('prevent-app-suspension')`. The Electron docs say: "Keeps system active but allows screen to be turned off."
  - **Limit:** neither option can stop a closed lid or a manual Sleep. Runs that fall while the computer sleeps are skipped, and the UI says so.

## Network, pairing and authentication

- **Server:** the runner opens a separate HTTPS server, port **8788**, on the LAN. It uses the existing strict parser in `WebhookServer`/`core/http.ts`: one request per connection, Bearer token, JSON bodies only, 64 KB limit.
  - **Token:** its own sync token, 128 bits in base32. Native keeps it in the Keychain, Electron in `SecretStore` (DPAPI or a keyring).
  - **TLS identity:** its own self-signed identity (`app.luma.schedule-sync-tls` / `schedule-sync-tls`). When LAN names change, the webhook certificate is replaced, but this identity stays the same.
- **Pairing code:** `luma1/<IPv4>/<port>/<pin>/<token>`, where `pin` is the first 128 bits of the certificate's SHA-256 in base32. Copy it on the runner and paste it on the device. Universal Clipboard works from Mac to iPhone; from a PC the code must be typed (about 70 characters).
- **Checks on the device side:**
  - The pin is checked before the token is sent. iOS/macOS check it in the `URLSession` server-trust challenge. Electron uses raw `tls.connect` and writes the request only after `secureConnect` with a matching `getPeerCertificate().raw` hash.
  - A wrong pin fails with nothing sent. A wrong token gets 401.
  - A different runner ID gets 409 and the device must pair again.
- **Changing or revoking access:**
  - **New pairing code:** every device must pair again. All paired devices share one token, so to revoke one lost phone you replace the code.
  - **Address change:** if the runner's IP address changes, pair again with the new code. Same pin and same runner identity: the device keeps its copy and unsent changes. If the runner was turned off and on, it is a new runner: the device starts from the new copy and says how many unsent changes it dropped.
- **ATS:** in the iOS Simulator, a pinned connection to `127.0.0.1` worked with no ATS exception. Pairing codes use IPv4 addresses, not `.local` names. A real iPhone over Wi-Fi hasn't been tested (see below). iOS shows the existing Local Network permission prompt the first time.
- **No cloud:** no cloud relay is used or implied. A device outside the home network can't reach the runner. Changes made there wait, and the card shows "N changes not yet delivered" and "Not reachable". iCloud isn't used because the Electron app can't read it.

## Moving the runner

- **Normal hand-off:** on a paired computer, choose "Run schedules here instead". It asks the current runner to retire (`POST /v1/sync/retire`, authenticated with the sync token). The old runner saves `retiredTo` and stops running schedules. It then answers 410 "Schedules now run on X", so its devices know to pair again. The new runner starts from the old runner's copy, including revisions and tombstones.
- **Old runner unreachable:** the user can force the hand-off after a confirmation. The new runner then runs nothing until the old one confirms. It retries every 30 s, so the two never run a schedule at the same time.
- **Limit:** if the old runner was off when the hand-off was forced and later starts somewhere the new runner can't reach, it keeps running its own copy until the new runner gets through. Turn sharing off on a computer you no longer use.
- **Turning sharing off:** on a paired or retired device, all its local schedules are turned off first, so they don't run there as well as on the runner. On the active runner, schedules stay as they are.
- **Restoring a backup:** refused while sharing. A restore would replace records outside the change rules and could bring back deleted ones.

## Platform notes

- **iOS:**
  - Never a runner. iOS doesn't keep a scheduler running in the background.
  - It syncs on launch, after each edit, and every 30 s while open.
  - It catches every scene/schedule edit in `HomeStore.persist()` by comparing against the shared copy. Edits from any view are shared without per-view changes.
- **Demo mode:** schedule sync is off on both platforms.
- **Electron on macOS:** Electron runs real mode only on Windows/Linux. The Mac uses the native app.
- **Headless:** the same Windows/Linux runner also runs with no window, as a service on a Mac, PC or Raspberry Pi. See [LOCAL-BRIDGE.md](LOCAL-BRIDGE.md).

## Verification (2026-11-02)

**Automated:**
- Desktop: 253 tests pass (238 before, plus 15 new). Swift: 196 tests pass (14 new). `npm run typecheck` is clean. With both patches applied to the parent tree (including native Audio Sync): desktop 253 and Swift 206 pass.
- `xcodebuild` passes for LumaiOS (iOS Simulator) and Luma (macOS).
- What the tests cover:
  - Shared vectors on both sides.
  - A pause from a phone survives a runner restart and blocks the run until it ends.
  - Two computers run a shared schedule once, and a hand-off moves it.
  - A forced hand-off waits for confirmation.
  - An offline device can't bring back a deleted schedule or re-enable a disabled one.
  - Edits reach the runner and other paired devices.
  - A lost response is retried without a false conflict.
  - A paired computer queues changes while offline and never runs schedules.
  - Restore is refused while sharing. An unreadable sync file fails closed.
  - DST skip and repeat. Grace and missed runs.
  - Real TLS: wrong pin refused before sending, wrong token 401, 64 KB batching.
  - `Home` and `HomeStore` integration.
  - A scene created on Windows/Linux (with `icon`) isn't rewritten by a native runner or a paired iPhone. iOS QA found this bug; it is fixed.
  - A runner turned off and on again can be paired again with the same code.

**Live interop, real TLS:**
- An Electron runner (Node, built `dist`) was paired with the Swift `URLSession` pinned client (`LUMA_SYNC_INTEROP_CODE=… swift test --filter liveElectronRunner`).
- Pull worked. A pause was applied on the runner. A wrong token got 401. A wrong pin was refused.

**iOS Simulator** (dedicated "Luma Schedule Sync QA", iPhone 17 Pro, iOS 27.2, T3 agent-device), built with a QA-only ad-hoc entitlements file so the simulator Keychain works (`CODE_SIGNING_ALLOWED=NO` builds have no Keychain access, which surfaced as "A required entitlement is not present"):
- Paired with an Electron runner by pasting the code.
- "Pause Until Tomorrow" reached the runner (`pausedUntil` saved).
- After the runner restarted, its tick at the next 07:00 reported `paused` and ran nothing. The phone showed "Skipped on … paused".
- With the runner stopped, turning the schedule off showed "Not reachable" and "1 change not yet delivered". After the runner restarted, Sync Now delivered it (`enabled:false` on the runner).

**Not verified:**
- The native Mac runner's real NWListener/Keychain path at runtime. No native computer-use tool was available in this session to drive the Mac app. The handler is covered by `ScheduleSyncControllerTests`, and the listener is the existing `WebhookServer`.
- The Electron renderer UI at runtime: real mode can't run on macOS, and demo mode turns sync off.
- A real iPhone on Wi-Fi to a LAN IP (ATS and Local Network prompt).
- Windows/Linux firewall prompts for port 8788.
- `powerSaveBlocker` behavior on each OS.
- Physical lights responding to a scheduled run.
