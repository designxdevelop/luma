# Same-account iCloud sync — implementation and rollout

## Current rollout status — October 30, 2026

CloudKit Console confirmed **“The schema is deployed to Production.”** Imported and deployed `docs/cloudkit/luma.ckdb` in team `2CKK5ZNTJG`, container `iCloud.com.designxdevelop.luma`. Deployment preview contained only creation of `LumaMutation` and `LumaScheduleLease`, with zero index or security-role changes. Existing Users schema was preserved. No management token was needed. Private zones are created by the app at runtime, not deployed as schema.

iOS and Mac 0.1.0 (5) uploads succeeded. Signed provisioning is resolved. Earlier blocker entries below are historical; real same-account two-device sync and failover remain unverified.

## Implemented

- Govee API key migrates to synchronizable Keychain storage, copying successfully before removing the old device-local key. Migration failure preserves the usable original. Webhook secrets and TLS keys stay local.
- `CloudSyncTransport`: private CloudKit `LumaConfig` zone in `iCloud.com.designxdevelop.luma`, paginated record-zone reads, per-field compare-and-swap writes, Lamport/writer conflict ordering, persistent tombstones, CKAsset transfer for larger values with bounded private temporary files.
- `CloudSyncCoordinator`: atomic durable ledger/outbox, offline retry every 30 seconds while running and on foreground, restart recovery, deletion propagation and stale-acknowledgement protection. Initial fetch precedes local migration. Account identity is checked before transfers and after fetch; account changes PAUSE sync while preserving the previous local home. Automatic migration to a different Apple Account is intentionally unsupported.
- HomeStore syncs local device names/rooms, scenes, schedule definitions/owner, floor-plan names, sanitized raster images and normalized pins. Pin identity is the device, enforcing one location across floors. Receiving configuration never issues lighting commands or imports live power/brightness/IP/online observations. Cloud discovery populates devices using the synced Keychain key; metadata is reapplied when devices become available.
- Legacy schedules stay on the originating installation unless failover is enabled (see Schedule failover below). Imported schedule owners are persisted across launches. There is no ownership-transfer UI yet. Webhook listeners remain local.
- iOS Settings shows sync status and Sync Now. Demo mode stays local. Sync starts only on builds whose signed entitlements include the Luma container (see Entitlement gate below).

## Verified

Stable Xcode (`/Applications/Xcode.app`) unsigned **LumaiOS** simulator build passes. The earlier `LumaApp` build failure used the macOS Swift package executable scheme `Luma` for iOS; it is not an iOS source failure.

Six focused tests pass: 2 ledger tests, 2 coordinator tests (offline deletion/restart/account change and remote tombstone/independent local field preservation), and 2 floor-plan tests. Transport also passed the stable Swift package build. No live CloudKit or two-physical-device success is claimed.

## Concrete provisioning blocker

An actual signed LumaiOS build with the new iCloud entitlement reports:

- `No Accounts: Add a new account in Accounts settings.`
- The current iOS team provisioning profile does not include iCloud capability or `com.apple.developer.icloud-container-identifiers` / `com.apple.developer.icloud-services`.

The attempted container identifier is app-specific, **not verified registered**. Entitlements preserve multicast and request `iCloud.com.designxdevelop.luma` / CloudKit. Before release, sign back into Xcode Accounts, register/select that container for team `2CKK5ZNTJG`, enable it on this App ID, and regenerate signing profiles. Build log: `/private/tmp/luma-cloud-provisioning.log`.

Develop and verify the `LumaMutation` record schema (`entity`, `field`, `counter`, `writer`, `deleted`, `value`, `asset`) in the container development environment, then deploy its schema to production before TestFlight. Validate migration, key propagation, offline edits, foreground refresh and images on two real devices using the same Apple Account with iCloud Keychain enabled. No release build uploaded for these changes.

## Remaining limitations

No push/background CloudKit notification integration: sync runs while Luma is active, with foreground refresh. Large image projection/ledger serialization is currently synchronous; profile and move costly work off the UI actor before large-home rollout. Account change is a safe pause, not an automatic account-switch workflow. No household sharing across different Apple Accounts. Mac entitlement/configuration and schedule-owner transfer UI are still outstanding. Floor-plan UI and broader redesign are separate work in progress.

Official references: [synchronizable Keychain](https://developer.apple.com/documentation/security/ksecattrsynchronizable), [CloudKit account changes](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange), [Apple sync sample](https://github.com/apple/sample-cloudkit-sync-engine).

## Apple portal inspection — 2026-10-30

Using the authorized MacBook Pro Chrome session, verified the Luma App ID edit page (`Q7QSG6WT68`), explicit bundle ID `com.designxdevelop.luma`, team `2CKK5ZNTJG`, and enabled Multicast Networking. iCloud initially showed disabled. Selected its checkbox; no Save confirmation or registered container association was verified. Chrome then changed to an unrelated Point page during configuration; stopped browser mutations to avoid interfering with the active session. Treat the iCloud change as an unconfirmed form edit, not provisioned capability.

Container registration, profile refresh, signed archive, CloudKit development schema inspection/production deployment, Mac signing, and same-account physical-device sync remain unverified. Resume with exclusive access to the Apple Developer Chrome page; preserve multicast. No certificates, releases, UI source, HomeStore, or user-home records changed in this attempt.

## Portal verification — 2026-10-30

Verified in local Chrome: `iCloud.com.designxdevelop.luma` is registered, and App ID `com.designxdevelop.luma` (team `2CKK5ZNTJG`) has iCloud checked with CloudKit support and one enabled container. Reopened Edit: exact Luma container is selected. Save disabled confirms no pending changes. Multicast Networking remains checked.

Stable Xcode Settings → Apple Accounts explicitly shows **Sign in to your Apple Account** and **Sign In…**, with no account configured. Signed build `/private/tmp/luma-cloud-provisioned-build.log` fails No Accounts and stale profile lacks CloudKit. Portal configuration is complete; Xcode account authentication is the remaining signing blocker. CloudKit schema deployment and two-device verification remain outstanding.

### Account/profile recheck

Xcode account is now recognized. Actual signed LumaiOS build advanced past provisioning. Decoded generated `Debug-iphoneos/Luma.app/embedded.mobileprovision`: team `2CKK5ZNTJG`, container `iCloud.com.designxdevelop.luma`, iCloud services `*`, multicast `true`. Signing setup blocker resolved. Full build currently hits in-progress UI redesign references (`FloorPlanView` / `NameRoomSheet`); UI owner notified. Schema production deployment and two-device sync remain unverified.

## Schedule failover (same Apple Account) — 2026-10-30

Implemented in `Sources/LumaCore/ScheduleFailover.swift`, `Sources/LumaUI/ScheduleCoordinator.swift`, HomeStore and an Automations row menu.

- **Opt-in per schedule.** Existing schedules keep the legacy single-installation owner until someone picks a primary in Automations. Coordination (`primary`, optional `fallback`, IANA `timeZone`, `graceSeconds` = 600) syncs as its own `schedule:<id>/coordination` field so older builds re-encoding the definition can't drop it. The synced owner becomes the sentinel `coordinated`, which stops older builds once they sync; an older build that stays offline cannot be stopped.
- **Devices** advertise `scheduler:<installationID>/name` through config sync, so each device can choose the other.
- **Occurrence = schedule ID + UTC instant**, computed in the synced zone (not the device's). DST: a skipped local time runs at the next existing time; a repeated time runs once at its first instance.
- **Lease per occurrence** (`LumaScheduleLease` records in a separate private zone `LumaSchedule`, read by record ID, no queries/indexes). State machine `claimed → running(step) → completed | failed | uncertain | cancelled | skipped`, all writes CAS (`.ifServerRecordUnchanged`, `serverRecordChanged` = conflict). A per-attempt nonce resolves ambiguous acks by re-read.
  - Primary may claim from the fire time; fallback only after 90 s with no lease. Only an expired **`claimed`** lease (nothing sent) changes hands. An expired `running` lease is marked `uncertain`, never resumed.
  - Nothing is sent before the holder's own `running` write is confirmed. The holder renews (60 s TTL, 15 s skew margin) and stops before its lease could lapse, so a partitioned holder stops sending; exclusion itself rests on the CAS transitions, not clocks.
  - No cloud = no run: a coordinated schedule never takes the legacy path, including offline and on builds without the entitlement (status "Paused").
- **Delivery is not exactly-once.** Govee has no idempotency keys. Only steps that provably never left the device (validation failure, no route yet after wake) retry, the single step, ≤4 attempts with 2/4/8 s backoff, never past the deadline. Any possibly-delivered failure ends the run `uncertain` without replay. A partially executed scene is never rerun. Runs started before a crash/quit are never resumed (`schedule-runs.json`).
- Editing/deleting/disabling the schedule or its scene, Stop, account change, and lost lease cancel at the next step. Runs more than 10 minutes late are skipped.
- Scheduled runs share `runningSceneID`, so manual/Watch runs see "busy" and Watch Stop cancels them.
- Mac: while it holds a schedule role, Luma holds a `userInitiatedAllowingIdleSystemSleep` activity against App Nap. It does not prevent sleep. Neither device is woken: the Mac must be awake, online, with Luma running; iOS runs only while Luma is open.

### Entitlement gate

CloudKit objects are created only when `CloudAvailability.isEntitled` is true. On macOS it reads the signed entitlements (`SecTaskCopyValueForEntitlement`) and requires the exact container plus CloudKit. Ad-hoc `scripts/build-app.sh` (`app.luma.govee`) and `swift test` stay local. The iOS simulator stays local; iOS device builds are provisioned.

### Mac signing (verified locally, not run)

`macos/Luma.entitlements` now adds `iCloud.com.designxdevelop.luma` / CloudKit beside the sandbox keys. Bundle ID stays `com.designxdevelop.luma` (same App ID as iOS; no bundle/keychain changes). `xcodebuild -project macos/Luma.xcodeproj -scheme LumaMac -allowProvisioningUpdates DEVELOPMENT_TEAM=2CKK5ZNTJG build` succeeded. The signature and embedded profile both carry the container, CloudKit services (`*` in the profile) and team `2CKK5ZNTJG`. The signed build was not launched, so it touched no real account data.

**Only the signed, sandboxed LumaMac build can be a primary or fallback.** The ad-hoc `scripts/build-app.sh` app (`app.luma.govee`, unsandboxed `~/Library/Application Support/Luma`) has no entitlement and stays local. LumaMac is sandboxed, so its home lives in `~/Library/Containers/com.designxdevelop.luma/Data/Library/Application Support/Luma` and its keychain access differs. The dist app's local home, Mac-only legacy schedules and device-local Keychain items **do not move** to LumaMac. LumaMac receives only what is in iCloud (synced config and the synchronizable Govee key). Nothing is migrated or deleted automatically.

### Verified

All 150 package tests pass (`swift test --build-system native`). They include 12 new failover tests with a fake clock and a fake CAS lease server: a forced concurrent claim runs once, a healthy primary blocks the fallback, expired-claim takeover works, an expired run is never resumed, a partitioned primary can't execute, a lost lease stops mid-run, an ambiguous send isn't retried even after restart, unsent-step retries stay bounded by attempts and deadline, late and deleted schedules don't run, an account switch stops a run, another Apple Account never claims, the unsigned gate returns false, DST is handled, and Watch busy/stop/snapshot behavior is unchanged. LumaiOS simulator (unsigned) and signed device builds (with Watch) and the signed LumaMac build pass.

### Not verified / rollout blockers

- Schema deployment is complete: `LumaScheduleLease` and `LumaMutation` were deployed to production through CloudKit Console on October 30, 2026. The app creates each account’s private zones at runtime. Live production writes still need device validation.
- No live CloudKit or two-device failover has been exercised. Validate on a signed Mac + iPhone with the same Apple Account, using a test schedule and a non-critical light.
- Leases are claimed only in the Apple Account that the synced configuration belongs to; another account means "Paused".
- Enable failover while both devices are online and syncing. A legacy owner that hasn't received the change yet (config sync runs every 30 s) can still run its local copy once, beside a fallback.
- No CloudKit push. Ticks run every 15 s while Luma is active. Old lease records are not pruned (one small record per run).
