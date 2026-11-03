# Apple Watch redesign (Paper handoff)

## Implementation status (2026-10-30, after the 0.1.0 build 5 upload)

**Implemented** in `ios/LumaWatch/LumaWatchApp.swift`, with the state model in the new
`Sources/LumaCore/WatchState.swift` (no existing core file changed; `WatchSnapshot`,
`WatchRequest`, `WatchRelay` and the phone are unchanged).

Changes from this design:
- **All on is kept** as a secondary button at the bottom of Home (parent decision). All off stays the toolbar button.
- Pending is tracked per request nonce. The UI draws the phone's last report with pending requests overlaid. When a request fails, only its own overlay is removed, so a late failure cannot undo a newer action. A failure that a newer request for the same lights has replaced is not shown. A late reply to an older request does not replace a newer report. An application context that arrives during a request keeps the overlay.
- A reply with no home in it counts as a failure ("Didn’t change"). A failed refresh is not shown as a failure.
- The watch asks for a fresh home (`.refresh`) **every** time the phone becomes reachable, not only when there is no home.
- Copy never claims the lights confirmed a change. The footer says "Last iPhone report <time>". The relay builds that report and may include its own optimistic state.
- Crown: `digitalCrownRotation(detent:from:through:by:sensitivity:isContinuous:isHapticFeedbackEnabled:onChange:onIdle:)`, checked in the Xcode 27.1 watchOS SDK swiftinterface. The view goes back to the `@available(watchOS 9.0, *)` extension, which is below the 10.0 target. It uses detents 0…100 by 5. It sends one `.brightness` when the crown rests, clamped to 1…100. It shows only for lights with `canDim` that are online.
- VoiceOver: disc labels read "Turn off Living room". The ring is adjustable (±5) with the value "55 percent". Offline rows are disabled and read "Offline". Text uses system styles, so Dynamic Type applies. Names wrap to 2 lines.
- Copy follows W06/W07/W11: "Reconnecting…", the "Last known:" prefix while the phone is out of reach, "Turning on…/off…" while a request is pending, and "Running · Stop". On the Light screen, the ring takes crown focus when it appears (`@FocusState` + `.focused(_:)`, watchOS 8+ in the SDK).
- A real room named "Other" shares the bucket with lights that have no room, so room ids stay unique.
- Demo flags: `--demo`, plus `--demo-fail`, `--demo-pending` and `--demo-unreachable`. The sample includes an offline light, a long name, a light that can't dim, and a light with no room.

**Tested:**
- `swift test` (Xcode 27.1): all pass. XCTest ran 17 tests. Swift Testing reported "74 tests in 2 suites" and "76 tests in 8 suites". This includes the 11 new `WatchStateTests` (grouping, overlay, supersede, late reply, empty reply, context during a request, offline, refresh on every reconnect, clamp) and the existing `WatchRelayTests`.
- `LumaWatch` build for watchOS Simulator, Xcode 27.1: no warnings.
- Signed `LumaiOS` Release archive, team 2CKK5ZNTJG: the embedded watch app is signed `com.designxdevelop.luma.watchkitapp`.

**Not tested:**
- Rendering on a watch. T3 `device_list` (hub 0.19.0-canary, agent 0.21.31) lists only iPhone, iPad and Android targets, with no watchOS. Raw simctl and argent were not used to get around that.
- A watch XCUITest target was not added. It needs an edit to the shared `ios/Luma.xcodeproj/project.pbxproj`, which the parent owns. A unit test can't render these screens either: `ImageRenderer` doesn't render `List` or `NavigationStack`. This is a follow-up for the parent to decide.
- **Highest-risk behavior that hasn't run:** in `RoomRow` and `LightRow`, a `.plain` disc Button sits next to a `NavigationLink` inside a `List` row. On watchOS the link may take the whole row's tap, so a disc tap could navigate instead of toggling, or do both.
- Whether the crown actually drives the ring on a device after the `onAppear` focus. We did not check 40/41/46mm layouts, the longest names, Dynamic Type sizes, offline or pending visuals, or the feel of the crown and its haptics.
- A paired iPhone ↔ watch relay on simulators or on hardware.

Paper file **Luma — iPhone Redesign** (`01M672SJ6PPEPK53F9WV8KVAB2`), new page
**Luma Watch redesign** (`p-2-0`):
https://app.paper.design/file/01M672SJ6PPEPK53F9WV8KVAB2/p-2-0
The iPhone/Mac page (`p-1-0`) was not modified.

| Artboard | ID | Size |
| --- | --- | --- |
| W00 Read me — Watch rationale | `38E-0` | — |
| W01 Home — Rooms · connected | `2V0-0` | 46mm |
| W01s Home — Rooms · connected | `2WM-0` | 41mm |
| W01x Home — Rooms (smallest) | `39V-0` | 40mm SE |
| W02 Room — Lights | `2Y8-0` | 46mm |
| W03 Light — Power + Crown brightness | `2ZD-0` | 46mm |
| W03s Light — Power + Crown brightness | `301-0` | 41mm |
| W04 Light — Updating (pending) | `30P-0` | 46mm |
| W05 Light — Didn’t change (failed, reverted) | `31D-0` | 46mm |
| W06 Scenes — One running (Stop) | `321-0` | 46mm |
| W06b Scenes — Quick run | `32R-0` | 41mm |
| W07 Connection — Reconnecting (last known) | `33H-0` | 46mm |
| W08 Connection — iPhone not reachable | `34X-0` | 46mm |
| W09 Lights — Offline (not tappable) | `35G-0` | 46mm |
| W10 First open — Connecting | `36H-0` | 41mm |
| W10b Empty — No lights | `36T-0` | 41mm |
| W11 All off — Sending | `373-0` | 41mm |
| W12 Light — No longer in the iPhone home (missing) | `39E-0` | 46mm |

Sizes: 46mm = 208×248 pt, 41mm = 176×215 pt, 40mm SE = 162×197 pt (smallest size on watchOS 10, the target's deployment version; W01x shows names wrap to two lines there and the list scrolls). Inter stands in for SF Compact; the
app keeps the system font and Dynamic Type.

## Tokens (Theme.swift dark values; watchOS is always dark)

| Role | Hex | Swift |
| --- | --- | --- |
| Background | `#000000` | system |
| Row platter | `#1C1C1E` | default `List` row |
| Control / off disc | `#2C2C2E` | `.quaternary` fill |
| Accent (title, Running, Updating) | `#FFA347` | `lumaAccent` dark (already the app `.tint`) |
| Accent fill (All off, Run) | `#B95500` | `lumaAccentFill` |
| Warning (Reconnecting, Didn’t change) | `#FFB340` | `warning` dark |
| Danger (offline) | `#FF6961` | `danger` dark |
| Secondary text | `#A1A1A6` | `.secondary` |

Theme.swift isn't in the watch target; copy the 4 hex values as a private `Color`
extension in `LumaWatchApp.swift` (the `Color(rgb:)` helper already exists).

Type: title 18/700 (17/700 small), row title 16/600 (15/600), status 13/500,
brightness 34/700 tabular (28 small). Row min height 56 pt (50 small), radius 18,
power disc 36 pt (32 small). Disc hit area = full row height (≥ 50 pt). The All off
button is the system `topBarTrailing` toolbar button (34 pt visual, system hit area).

## Structure and interactions

- **Home** (`NavigationStack` + `List`): title "Luma"; toolbar `topBarTrailing`
  power button = **All off** (`.power(ids: [], on: false)`, a11y "All off").
  Rows: **Scenes** (→ Scenes list), section **Rooms** (grouped from `Light.room`;
  lights with an empty room go in a last section named "Other").
  - Room disc tap: `.power(ids: roomLightIDs, on: !anyOn)`. Row tap → Room.
  - Room status: "On" if any light on, else "Off". No counts or badges.
  - "All on" is dropped from the toolbar; room discs cover it. (Re-add as a menu
    item only if asked.)
- **Room**: title = room name with back. Light rows: disc tap toggles
  (`.power(ids:[id])`), row tap → Light. Status "On · 55%" / "Off" / "Offline".
- **Light**: large ring shows brightness; **Digital Crown** drives it
  (`.focusable()` + `.digitalCrownRotation(_:from:through:by:sensitivity:isContinuous:isHapticFeedbackEnabled:)`
  on a local `Double` binding, 1…100 by 5; confirm the exact signature in the watchOS 10 SDK).
  Debounce ~250 ms, then send `.brightness`. Bottom capsule = power toggle filled with the light's
  color when on. Lights with `canDim == false` show only the power capsule
  (ring hidden).
- **Scenes**: rows with Run (`.runScene`). When `runningSceneID != nil`, that scene
  is a bordered card with **Stop** (`.stopScene`); others are dimmed with "Stop the
  running one first" (matches the phone's one-at-a-time rule).

## States (what the watch can actually know)

The watch only knows its last `WatchSnapshot`, its own pending requests and
`WCSession` reachability. Copy never claims live state.

| State | Source | UI |
| --- | --- | --- |
| Connecting (first open) | `snapshot == nil`, no problem | W10 spinner |
| Empty | `snapshot.lights.isEmpty` | W10b |
| Connected | `isReachable && snapshot != nil` | W01 |
| Reconnecting | `snapshot != nil && !isReachable` | W07: pill, values prefixed "Last known:", controls disabled (no send is attempted) |
| iPhone not reachable | `snapshot == nil && !isReachable` for > ~5 s | W08 |
| Updating (pending) | request sent, no reply yet | W04/W11: spinner disc, "Updating…" / "Turning off…" |
| Confirmed | reply snapshot arrives | normal values from the reply (no "confirmed" label) |
| Didn’t change (failed) | `errorHandler` fired; snapshot reverted | W05: reverted value + Try again (resends the same request); clears after 4 s or on next snapshot |
| Offline light | `online == false` | W09: dashed red disc, not tappable, a11y "Offline" |
| Missing light | open Light id absent from the newest snapshot | W12: "Light not found" + Back to Home |
| Demo | `snapshot.demo` | unchanged (no extra label needed) |

W07 and W08 are mutually exclusive and clear on their own: `sessionReachabilityDidChange`
must call `send(.refresh)` whenever `isReachable` becomes true (today it only does so when
`snapshot == nil`). W08's Try again re-checks `isReachable` and sends `.refresh` if reachable;
otherwise it stays (it is a re-check, not a send).

`power == nil` (unknown) shows "Unknown" and an off-style disc.

## Code needed (watch target only, after release)

In `LumaWatchApp.swift`:

1. `WatchModel`: add `var reachable: Bool` (set in activation and
   `sessionReachabilityDidChange`), `var pending: Set<String>` (light ids;
   `"*"` for All off; scene id string for scenes) and
   `var failed: (request: WatchRequest, at: Date)?`.
   In `send`: insert pending ids before `sendMessage`; remove in both handlers;
   on error set `failed` instead of the raw `problem` string. Replace the
   `problem` text banner with the enum-driven states above.
2. Split `HomeView` into `HomeView`, `RoomView(room:)`, `LightView`, `ScenesView`.
   Rooms are `Dictionary(grouping: lights, by: \.room)` sorted by name.
3. `LightView`: replace `Toggle` + `Slider` with the ring + crown + capsule.
   Keep the existing "collapse rapid changes" behavior (debounce, send latest).
4. Offline rows: `.disabled(true)` and `.accessibilityValue("Offline")`.
5. Accessibility: disc buttons labeled "Turn off Living room" etc.; the ring is
   `.accessibilityAdjustableAction` (±5) with value "55 percent".

No changes to `WatchSnapshot`, `WatchRequest`, `WatchRelay.swift` or the phone.
Room power reuses `.power(ids:)`, which the relay already accepts.

## Staged plan

1. Release iOS/Mac (no watch changes).
2. Branch; implement 1–5 above; run with `--demo` on 41mm and 46mm watch
   simulators and compare to the artboards.
3. Test with the paired iPhone simulator in demo home: reachable, phone app
   killed (W07/W08), `--relay-check-all-off`. No real lights.
4. Add a unit test for room grouping and the pending/failed bookkeeping.

## Not verified

See "Not tested" above.

## Release update — October 30, 2026

Coordinator replaced row NavigationLinks next to power discs with separate plain navigation buttons and a typed navigation path, reducing the row tap interception risk. Signed iOS archive and embedded Watch both report build 6. Focused Watch checks pass (11 state tests and 3 relay/schedule tests). Build 0.1.0 (6) uploaded successfully as internal-only TestFlight; Apple processing was confirmed by the upload tool. Watch simulator rendering and paired-device behavior remain unverified.
