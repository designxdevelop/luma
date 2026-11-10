# App Store media status

## 2026-10-30 capture (current redesign, demo mode)

Captured from `/tmp/luma-shots-dd/.../Luma.app` launched with `--demo` on two
fresh, dedicated simulators (iOS 27.0), via T3 agent-device. No real lights.
Every image was inspected; all are JPEG, no alpha.

| Folder | Files | Size |
| --- | --- | --- |
| `screenshots/iphone-6.9/` | `1-home`, `2-scenes`, `3-floorplan`, `4-controls`, `5-automations` (.jpg) | 1320 × 2868 |
| `screenshots/ipad-13/` | same five | 2064 × 2752 |

Floor plan uses `docs/qa/sim/luma-test-floorplan.png` (upscaled) with the four
demo lights pinned. The previous set was removed from the working tree; it
remains in git history (last commit containing it: `99046ae`, under
`docs/app-store/screenshots-backup-2026-10-30/`).

Not done: App Store Connect upload, live-media backup, Header / Search Results
tab inspection (5244 × 2950 or 3840 × 1646), Mac capture. These need native
computer use, which this agent lacks. Watch: not exposed by T3; not captured.

## Earlier notes

Inventory attempted 2026-10-30. No App Store Connect media was changed. The live
slots, localizations, preview videos, poster frames, counts, and processing
states could not be inspected: the native Chrome accessibility connection
timed out twice. Consequently no live media backup exists yet. Back up the
actual uploaded files before replacing anything.

## Existing repository assets

These are prior assets, not verified matches for the uploaded builds or for
the media currently in App Store Connect. Do not treat them as new captures.

| Folder | Files | Size |
| --- | --- | --- |
| `screenshots/iphone-6.9/` | `1-lights.png`, `2-scenes.png`, `3-screen-sync.png`, `4-automations.png` | 1320 × 2868 |
| `screenshots/ipad-13/` | `1-lights.png`, `2-scenes.png`, `3-screen-sync.png` | 2064 × 2752 |
| `screenshots/watch/` | `1-lights.png` | 422 × 514 |

No new screenshots were captured or uploaded. The T3 device list did not
expose a Watch simulator. The iPhone 18 Pro Max was held by another session;
waiting five seconds still returned `DEVICE_IN_USE`. The working tree also has
uncommitted UI changes, so a fresh build must be checked against the uploaded
builds before it is represented as build 6 or Mac build 5.

## Requirements and remaining work

Apple allows 1–10 PNG or JPEG screenshots per size, without alpha. Accepted
sizes include 1320 × 2868 for a large iPhone, 2064 × 2752 for 13-inch iPad,
422 × 514 for Apple Watch, and 1280 × 800, 1440 × 900, 2560 × 1600 or
2880 × 1800 for Mac. Check the actual ASC slots and requirements for each
localization; Apple's current specification also lists medium iPhone sizes.
See [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

App previews are optional, up to three per device size and language; their
poster frames are selected from the video and are not app icons. See [Apple's
app preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications).

1. Restore Chrome accessibility, inventory every live platform and localization,
   and download the existing media to `screenshots/backup-2026-10-30/` before
   replacement.
2. Free a suitable device session and establish build provenance; capture real
   demo-mode iPhone, iPad, Watch and Mac screens without controlling real lights.
3. Upload the appropriate assets, check saved counts and processing states,
   and update this file. Do not submit for review.

## App Store Connect upload verified — October 30, 2026

Parent uploaded and verified 5 JPEG screenshots each for iPhone Dynamic Island large display (6.9-inch) and iPad 13-inch, English (U.S.). Removed the 4 old iPhone and 3 old iPad images from this version; Apple explicitly retains them in Asset Library. New order: Home, Scenes, Floor plan, Controls, Automations. Apple confirmed iPad inheritance to other sizes. No submission or build selection change. Header remains 0/1 (5244×2950 or 3840×1646). Search Results remains 0/1 (5244×2950, 3840×2560, or 1920×1280); Apple uses screenshots when this is empty. Mac and Watch captures remain pending.

Creative assets: Search Results JPEG uploaded and slot verified 1/1. Header JPEG rejected by Apple with “File has an invalid extension”; PNG accepted and header slot verified 1/1.
