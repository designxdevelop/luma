# Next release — user authorized

After synced schedule failover/retry implementation is integrated and verified:

1. Finish iOS/iPad UI acceptance checks and validate private CloudKit production schema and same-account sync. Preserve multicast and floor-plan changes.
2. Build native Mac app for direct local use and archive/upload macOS to TestFlight with team 2CKK5ZNTJG, app ID com.designxdevelop.luma. macOS target currently version1.0 build1; inspect App Store Connect app platform/version/build requirements and set coherent versions before upload. Enable and verify Mac CloudKit entitlements safely. Existing scripts/build-app.sh produces local dist/Luma.app.
3. Archive/upload updated iOS TestFlight with embedded Watch companion, matching versions/build numbers and verified entitlements. Latest confirmed server-received iOS build is4 (auto-incremented during export), despite prior report calling it3. Use a new build number and inspect export metadata.
4. Watch code is a basic phone-dependent companion: all lights on/off, per-light toggle/dim, scene run/stop, cached snapshot through WatchConnectivity. It has not received the iPhone/Mac redesign or real paired-device validation. Smoke-check companion build and relay regression tests; don't claim fully validated Watch behavior.

User authorized these uploads on 2026-10-30 after schedule addition. Parent coordinates release once dependency task completes. No extra routine confirmation is required; actual login/2FA blockers must be presented. Do not upload before integration/required checks. Current working tree is intentionally shared and includes uncommitted authorized backend/UI work.

Watch redesign is a separate non-blocking track (user request). Opus is designing a new Watch page in Paper and docs/REDESIGN-WATCH.md only. Do not wait for it to archive/upload Mac or iOS. Preserve existing companion for this release; implement the new Watch UI after the iOS release snapshot/upload so late Watch edits cannot change the archive unexpectedly.

## Authorized follow-up: Watch implementation and second upload

After the new Mac and iOS TestFlight release has been successfully uploaded:

1. Implement the Paper Watch redesign from docs/REDESIGN-WATCH.md in ios/LumaWatch/LumaWatchApp.swift. Preserve All on as a secondary action, room power, All off, scene run/stop, pending/failure/reconnect states, Crown brightness and accessibility.
2. Build and validate small/large Watch layouts and paired iPhone relay with demo data. Verify real SDK signatures and current Apple Watch guidance. Preserve phone app and sync compatibility; no real light commands during automated QA.
3. Increment the iPhone and embedded Watch build numbers coherently, archive and upload another iOS TestFlight build carrying the redesigned Watch companion. This second upload is explicitly authorized by the user and needs no repeated routine approval.

Watch work must start after the preceding release upload, and must not hold up the initial Mac/iOS release. Parent coordinates both releases and verification.

## Initial release uploaded — 2026-10-30

Both stable-Xcode version 0.1.0/build 5 (superseded: all releases now ship as 1.0) archives exported with destination upload and internal-only TestFlight. `manageAppVersionAndBuildNumber=false`.
- Mac: `/private/tmp/luma-mac-5-upload.log` — Uploaded LumaMac / EXPORT SUCCEEDED.
- iOS: `/private/tmp/luma-ios-5-upload.log` — 16:11:52 Upload succeeded / Uploaded LumaiOS / EXPORT SUCCEEDED.
- Signed local Mac app: dist/Luma-iCloud.app, signature verified.
- CloudKit production schema still not deployed; management token private prompt pending. Builds fail sync/coordinated schedules safely until schema ready; no two-device live validation claimed.

Watch implementation may now start; next iOS+embedded Watch build must increment to6 or higher after checking latest server versions.
