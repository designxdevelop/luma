# iPhone redesign (Paper handoff)

Design only: no app code was changed. Paper file **Luma — iPhone Redesign**
(`01M672SJ6PPEPK53F9WV8KVAB2`), page **Luma iPhone redesign** (`p-1-0`):
https://app.paper.design/file/01M672SJ6PPEPK53F9WV8KVAB2

| Artboard | ID |
| --- | --- |
| 00 Read me — rationale | `144-0` |
| 01 Home — Lights | `1-0` |
| 01b Home — Long-press menu (Rename…) | `HA-0` |
| 02 Light — Controls sheet (Color) | `6M-0` |
| 03 Light — Controls sheet (White) | `AE-0` |
| 04 Light — Name & room (rename) | `EO-0` |
| 06 Scenes — One running | `MY-0` |
| 07 Scene — Save current lighting | `PN-0` |
| 08 First run — Connect (empty) | `SJ-0` |
| 09 Loading — Looking for lights | `TX-0` |
| 10 States — Offline, updating, problem | `X3-0` |
| 11 Settings — Connections & diagnostics | `10S-0` |

The colors are the `Theme.swift` values, kept as Paper tokens (`--color-*`).
In Paper, Inter stands in for SF Pro. The app keeps the system font.

## Decisions

- **Home in one glance.** Lights are grouped by room, and each room has a room switch. Each light is a tile tinted with its current color.
  - Tap a tile to turn the light on or off.
  - The chevron (44 pt) opens the light's controls.
  - Long-press opens a menu.
  - "All off" is in the header.
- **Brightness comes first** in the light sheet as a 64 pt bar. Color and White are one segmented choice.
  - Presets are unchanged: 8 colors, plus Warm 2700 K, Neutral 4000 K and Daylight 6500 K.
  - Effects and details move to rows below.
- **Rename has three entry points:**
  - the name with a pencil in the sheet header;
  - long-press → Rename…;
  - a "Name it" chip on lights whose name looks like a SKU (for example `H6199_6C77`).

  The copy says that only Luma uses the name (`HomeStore.rename`, local `customName`, maximum 64 characters). "Use original name" resets it.
- **Scenes:** one scene runs at a time.
  - The running scene shows a prominent Stop button. The other scenes show Run as disabled.
  - Scenes can be saved from the light sheet ("Save this look as a scene", through `captureScene`) or from New scene.
- **Four tabs:** Home, Scenes, Automations, Settings.
  - Activity, Screen Sync and connection details move into Settings.
  - Badges count only problems.

## New code required (small)

- Tap-to-toggle tiles.
- Rename… and Move to room… in the long-press menu.
- The "Name it" chip.
- Friendly color names on the New scene sheet (for example "Amber · 65%").
- The 4-tab structure.
- A hit area of at least 44 pt for the small text controls: "Name it", "Select all", and the name in the sheet header.

Room power already exists: `perform(.power, ids:)`. Rooms are only the `room` string on each light, so there is no step to create, rename or add an icon to a room. "New room" only types a new name.

## Problems found in the current app

These were seen on the iPhone 18 Pro simulator, running the installed build in the demo home.

- **Onboarding:** it shows three crushed columns, and "Connect Account…" is truncated. The compact layout is not chosen.
- **White presets:** the "Neutral" label and "2,700 K" wrap inside the preset capsules.
- **Tab badges:** they use red for ordinary counts ("3/4", "2").
- **Build gap:** the installed build has no Name field in Details, although the source has one. Rename was designed from the source.

The Govee Home app was not inspected live, because it is not installed on any simulator or on this Mac. The comparison uses the official App Store screenshots and reviews for version 7.7.10. Those show:

- grid layouts with many icons;
- raw SKU device names;
- reviewer complaints about small on/off targets and menus that move between updates.

## Floor plan (boards 12–19)

Designed against `docs/FLOOR-PLAN-BACKEND.md`.

| Artboard | ID | Backend |
| --- | --- | --- |
| 00b Read me — Floor plan & iCloud sync | `21I-0` | — |
| 12 Plan — Control mode (tap pin = power) | `14Z-0` | `floorPlans`, pins resolved against `store.devices`, `perform(.power, ids:)` |
| 13 Plan — Pin detail (long-press) | `184-0` | existing brightness and controls; "Move pin" enters edit mode |
| 14 Plan — Edit mode | `1BY-0` | `placeLight(_:onFloorPlan:x:y:)` when the drag ends; drag back to the tray calls `removeFloorPlanPin` |
| 15 Plan — Empty | `1EL-0` | photo, camera and Files pickers |
| 16 Plan — Import: name the floor | `1GV-0` | `importFloorPlan(name:image:)` |
| 17 Plan — Offline & missing lights | `1IU-0` | missing devices keep their pins and are labeled "not found" |
| 18 / 18b Plan — Delete floor / Replace image (confirm) | `1M7-0` / `1OZ-0` | `deleteFloorPlan`, `replaceFloorPlanImage` (pins kept) |
| 19 Plan — List view + image unavailable | `1RQ-0` | the accessible list alternative; also used when `floorPlanImageURL` can't load |

**Placement:** Plan is a Rooms / Plan toggle on Home, not a new tab. Floors are chips, plus an add chip.

**Control mode:**
- Tap a pin to toggle power.
- Long-press a pin to open the detail card.
- Pins are 44 pt and show the light's live color, off state, offline state (dashed red) or missing state (dashed "?").

**Edit mode:**
- Tap Edit, then drag pins.
- The tray shows lights **not on any floor**, because a light has only one pin.
- Changes save when the drag ends.
- The ··· menu contains Rename floor, Replace image and Delete floor.

**Coordinates:** pin x and y are measured in the displayed image rectangle, so the map can pan and zoom (per the backend).

**VoiceOver:** reads pins top to bottom, as on board 19. Its adjustable action changes brightness, which needs new code.

## iCloud sync (boards 20–22, plus updates to 08 and 11)

| Artboard | ID |
| --- | --- |
| 11 Settings (now has a "Your devices → iCloud sync" row) | `10S-0` |
| 08 First run (now has a line about returning users) | `SJ-0` |
| 20 Settings — iCloud sync (up to date) | `1VQ-0` |
| 21 Settings — Sync states | `1Y0-0` |
| 22 First run — Found your home in iCloud | `1ZP-0` |

Aligned with `docs/ICLOUD-SYNC.md`: status card plus **Sync Now** (no on/off switch); sync runs while Luma is open; demo mode stays local; Mac sync is not yet enabled.

**What syncs:**
- The Govee key, through iCloud Keychain.
- Names, rooms, scenes, schedule definitions, floor plans and pins, through the private iCloud database.

**What doesn't sync:**
- Live light state. Each device reads it from Govee or the local network.
- Data across different Apple Accounts. There is no sharing between people.
- Running schedules and webhooks. They run only on the device that created them.

**Status states:**
- Syncing…
- Up to date (with the last check time)
- Waiting for a connection (offline; changes stay on the device)
- iCloud unavailable (signed out)
- Govee account not synced (Keychain off)
- Apple Account changed (sync paused, home kept)

**Copy rules:**
- Never promise instant sync ("can take a few minutes").
- No API keys appear in any design.

**Later:** LiDAR scanning, PDF floor plans, and sharing between people.
