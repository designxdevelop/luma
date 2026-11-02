# Govee Home parity and roadmap

What Govee Home does, what Luma does today, and what blocks the rest. "Native" is the Mac/iPhone/iPad/Watch SwiftUI app; "Electron" is the Windows/Linux app in `desktop/`. Evidence levels: **live** = checked against a real account or light; **tests** = automated tests with synthetic fixtures; **source** = public client source only.

Live account evidence (2026-11-02): one read-only sign-in using Luma's exact contract and header set (see [Evidence ledger](#evidence-ledger)). No light, group, or automation was changed.

## Matrix

| Govee Home area | Native | Electron | Blocker / dependency | Value |
| --- | --- | --- | --- | --- |
| Account sign-in (email + emailed code) | Implemented, read-only. Contract **live**-verified (454 → code → token) | Missing | No token refresh: `refreshToken` exists in the live session but the refresh call isn't verified | Medium |
| Add / pair a new light (Bluetooth + Wi-Fi provisioning, Matter) | Missing | Missing | Needs Govee's BLE provisioning; Govee Home stays required for setup | Low (one-time) |
| Light list, names, online state | Implemented (official API + LAN), **live** | Implemented | — | High |
| Rooms | Implemented locally; import from Govee Home (**live** shape) | Implemented locally | — | High |
| Room / group control | Power, brightness, white for a whole room | All on/off | Govee's own control groups use a private POST, not used | High |
| Power, brightness, color, white | Implemented, cloud + LAN, **live** | Implemented | — | High |
| Segments (RGBIC) | Partial: generic form for `segmentedColorRgb` / `segmentedBrightness` | Partial (generic) | A painter UI is roadmap | Medium |
| Light scenes, DIY scenes, snapshots | Implemented: searchable browser by room or light (Scenes › Govee scenes › Browse, and each light's Effects tab); one tap applies the light's own option, or the same name to every light in a room that lists it (others skipped and named); optional Save as Luma Scene. Lists load in one step or on first Effects visit. A DIY reload replaces the DIY list, so deleted DIY scenes disappear and saved Luma scenes using them fail with a clear message | Per light | Shows only what Govee's public API lists per model; Govee Home's own catalog can be larger (app-only scenes). Creating DIY animations isn't in any API | High |
| Music mode | Partial: the light's own mic mode via generic `musicMode` | Partial | Computer-audio-reactive mode is roadmap | Medium |
| DreamView TV sync start/stop | Implemented: cloud `dreamViewToggle` + Movie scene | Missing | — | High |
| DreamView group readback | Implemented: name, enabled, reported light count, main light (**live**) | Missing | Member identities and areas: endpoint unknown (see below) | High |
| DreamView membership / area editing | Local draft only, Apply disabled | Missing | Member read endpoint unknown; BLE `0x50` needs `cmd_ver`; these controllers report `supportEnc` (encryption support; handshake unevidenced) | High |
| PC screen sync (Govee Desktop DreamView) | Implemented locally (ScreenCaptureKit / camera on iPhone) | Implemented (Windows/Linux capture) | Real capture-to-light response unverified | High |
| Schedules | Luma schedules (run while the app runs) | Implemented | Govee's on-device timers are BLE/private | High |
| Govee Home automations | Read-only list in the import preview, with conflicts against Luma schedules | Missing | Editing would need private POSTs; not attempted | Medium |
| Tap-to-Run / triggers | Luma scenes + authenticated local webhooks | Implemented | Sensor triggers need MQTT events | Medium |
| Device settings (firmware, auto-off, LAN toggle, camera calibration) | Missing (only what the official API advertises) | Missing | BLE or private endpoints | Low–medium |
| Non-light devices (appliances, sensors) | Controls through the generic capability form; readings not shown | Same | Property readout is roadmap; this account has lights only | Medium |
| Sharing devices with family | Missing | Missing | Private account API; `share` field seen, nothing more | Low |
| Siri / Shortcuts | Implemented (iOS; Mac in the Xcode build, not the SwiftPM package): room on/off, brightness, color/white, run a Luma scene, apply a Govee scene, with App Shortcuts phrases. Rooms resolve to their current lights each run | — | Voice Siri and real-device runs not yet tested (see VERIFICATION.md) | High |
| Alexa / Google / IFTTT / SmartThings / Matter | Not replicated; Luma offers local webhooks and Shortcuts actions | Webhooks | — | Medium |
| Widgets / watch | Apple Watch relay | — | iOS widgets roadmap | Medium |
| Community feed, DIY sharing, shop, rewards, AI bot | **Excluded**: not device control. Scene file export/import covers sharing between Luma users | Excluded | — | — |

## Where Luma goes further

| Feature | Native | Electron |
| --- | --- | --- |
| Local LAN control without the cloud | Yes | Yes |
| Local screen sync with region mapping and brightness caps | Yes | Yes |
| Authenticated local webhooks (TLS, pinned) | Yes | Yes |
| Scene editor with ordered steps and waits, JSON, file import/export | Yes | Yes |
| Whole-home backup and restore (scenes, schedules, names, rooms, DreamView drafts) | Yes | Missing |
| Restore lights to how they were before a scene ran | Yes | Missing |
| Schedule conflict check against Govee Home automations | Yes | Missing |
| Redacted compatibility report for issue filing (no IDs, IPs, MACs) | Yes | Missing |
| Activity log and per-control confirmation | Yes | Yes |

## DreamView membership: current boundary

- `GET bff-app/v1/device/list`: **no** group fields on the TV backlight rows (live, H6097 and H66A0). The earlier key-name scan was removed.
- `GET bff-app/v1/general-control/list?filterEmpty=false`: returns the DreamView group (observed `type` 10, a `sceneFeastId`, `mainDevice`, `deviceCount`, `enable`). One sample, so "type 10 = DreamView" is an observation.
- `GET bff-app/v1/general-control/group-devices?groupId=…`: empty for that group.
- Govee's internal name for DreamView is "feast" (`sceneFeastId`, `feastLastUpdateTime`, `movie_feast` resources in the 7.7.10 APK). The 7.7.10 dex is Virbox-encrypted, so the feast detail endpoint isn't readable statically.
- **Minimum user step to finish member readback:** a HAR or mitmproxy capture of Govee Home opening the DreamView group's page (REA `inspect_web_network_capture` reads it). With that, member identities and areas can be read; writing still needs `cmd_ver` and probably the BLE encryption these controllers report supporting.

## Staged roadmap

1. **Done this pass:** bulk Govee scene loading, DreamView group readback, Govee Home automations readback with conflict check, room brightness/white, whole-home backup/restore, restore-after-scene, compatibility report. Remove the speculative key-name scan.
   **Done next pass:** searchable one-tap Govee scene browser; Siri / Shortcuts room and scene actions (App Intents).
2. **Next (no new evidence needed):** sensor/appliance property readout from the official state endpoint; segment painter for `segmentedColorRgb`; port backup/restore and restore-after-scene to Electron; per-light Siri entities if room-level control proves too coarse.
3. **Needs a capture from the user:** DreamView member/area readback (feast endpoint), token refresh check.
4. **Needs hardware evidence and explicit consent:** DreamView membership writes (`0x50`), Movie/Game/All/Part settings (`0x60`), Bluetooth encryption handshake. Never on the working Lite group without a backup and readback.
5. **Not planned:** pairing, firmware updates, community/shop.

## Evidence ledger

- Sign-in: `POST account/rest/account/v2/login` → 454; `POST …/v1/verification {type 8}` → 200; login with code → 200. Session fields (names only): `A`, `B`, `accountId`, `client`, `clientType`, `isSavvyUser`, `refreshToken`, `token`, `tokenExpireCycle`, `topic`. There is no `tokenExpireTime`.
- Headers: `appVersion 7.4.10`, `clientType 1`, `iotVersion 0`, `clientId`, `timestamp`, iOS `User-Agent` (Luma's set) returned 200 for device list, `general-control/list`, and `ecology/resource/automations`.
- Device list: 16 rows, 3 rooms; `data` keys `accountSetting`, `devices`, `feastLastUpdateTime`, `groups`, `sort`, `sortTime`. TV backlight rows carry `supportEnc: true`, `supportBleBroadV3`, `secretCode` (never shown by Luma).
- Automations: `data.autoExecs[]` with `name`, `enable`, `cmdType`, `groupId`, `schedule.{times[].hour/minute, repeat[], skus[].{sku, deviceName, isFeast, feastId, feastType}}`. `repeat` uses 1–7; the weekday mapping is not verified against Govee Home, so Luma shows it as-is only when it covers every day.
- Raw responses and the probe token were kept only in `/tmp/luma-govee-state` (mode 0700) during this pass and deleted at the end, along with the one-use secret files.

## Integrated follow-up

The isolated remaining-parity patches have now been applied to the main working tree alongside scenes and Siri. Combined verification: 166 Swift tests and 221 desktop tests pass. Native now includes the segment painter, non-light device listing and property readings, with bulk light actions excluding non-lights. Electron now includes account sign-in/import, DreamView start/stop, backup/restore, scene-state restoration, room brightness/white, compatibility reports, property readings and segment painting. See [remaining coverage and limitations](PARITY-REMAINING.md). The earlier matrix records the prior pass; these integration results supersede its missing/partial labels for those features. Real hardware validation remains separate.

## Native audio integration

Native Audio Sync is wired into the shared session UI and lifecycle: ScreenCaptureKit system audio on Mac, microphone input on iOS, Pulse/Spectrum mapping, live meter, sensitivity and restore controls. Menu-bar actions reflect Audio Sync. The implementation has automated synthetic coverage; live OS capture, permission interaction and physical-light response remain unverified. See [native Audio Sync](AUDIO-SYNC-NATIVE.md).

## Cross-device schedule integration

Native and Electron schedule sharing is integrated: one desktop runner, authenticated certificate-pinned LAN pairing, shared scenes/schedules, queued offline pause/disable/delete and revision conflict handling. iOS need not remain open once changes reach the runner. No cloud relay or live-light-state synchronization is provided. Runner uptime and network reachability remain necessary. See [schedule sync behavior and limitations](SCHEDULE-SYNC.md).
