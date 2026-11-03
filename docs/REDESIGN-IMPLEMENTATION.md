# iOS redesign — implementation QA (2026-10-30)

Build under test: current working tree, `LumaiOS` scheme, `/Applications/Xcode.app`,
`CODE_SIGNING_ALLOWED=NO`, installed fresh on each simulator (not a stale build).
All checks ran in the **demo home**; no real lights or user home were touched.
Paper reference: file `01M672SJ6PPEPK53F9WV8KVAB2`, exports in `docs/qa/paper/`.
Simulator evidence: `docs/qa/sim/`. Test image: `docs/qa/sim/luma-test-floorplan.png`
(added with `simctl addmedia` to the iPad and iPhone 17 simulators).

## Fixed in this pass

| Problem | Fix |
| --- | --- |
| VoiceOver could not change brightness on a floor-plan pin | Adjustable action (±10, clamped to the light's advertised `brightness` range within 1–100). Not offered while editing, or when the light is missing, offline or has no brightness. The tap action is also disabled while editing or offline. Test: `pinBrightnessClampsToAdvertisedRange`. |
| VoiceOver/XCUITest frame of every pin covered the whole plan (680×985 on iPad) | Cause: `dropDestination` on an ancestor of the pins. Pins are now a sibling layer of the image/gesture/drop layer, with the same zoom transform. The pin frame is now 77×62. |
| iPad Home header: "Find Lights" wrapped one letter per line, with a tall empty power capsule | `PageHeader` actions are `.fixedSize()` (`ipad-light-sheet.png` shows the bug, `ipad-home-fixed.png` the fix). |
| iPhone at AX Extra Large: "Connect Acc…" was truncated and the step icons overlapped "Step 1" | The button label can wrap, and the step icon has a fixed size (`iphone-ax-xl-welcome*.png`). |

## Fixed in the second pass (2026-10-30)

| Problem | Cause and fix | Evidence |
| --- | --- | --- |
| A dragged pin moved only about 55% of the finger travel | This was an app bug, not slop from the synthetic pan. The pin's `DragGesture` used the pin's own `.local` space, and that space moves with the pin's `.offset`. The pin chased the finger, so it settled at about half the travel. The fix: the pin layer declares the named coordinate space `floorPlanPins` before `.scaleEffect`, and the drag reads its translation there. That space is stable and unzoomed. The transform math is now in testable functions: `unzoomPoint`, `zoomPoint` and `draggedPinPoint`. | On the iPhone 18 Pro with `gesture pan`: at 1x, a finger move of (−100, −80) moved the pin (−99, −79.4). At 2x pinch zoom, a finger move of (+80, +60) moved the pin's on-screen frame (+79, +59). Tests: `zoomTransformRoundTripsAndDropsLandUnderFinger` (1x, 2x and 3.5x, with offsets) and `draggedPinFollowsFullTranslation`. Screenshot: `iphone-pin-drag-2x.png`. |
| Light sheet (02): the "Color #hex" header and "Custom color / Apply Color" | The header is removed. There is now a "Custom" row with the current-color swatch and a trailing color well. Paper has the same layout. The status next to "Custom" says "Now showing" only when the light has confirmed the color. While a change is pending, it shows `controlStatus` ("Updating…" or "Waiting for light…") instead. A color pick is sent once the picker settles (250 ms) and is not sent when the sheet opens. | `iphone-light-sheet-custom.png` |
| Light sheet: Done button | On iOS there is a grabber (`presentationDragIndicator(.visible)`) and swipe-to-dismiss, with no Done button. macOS keeps Done (⏎). | `iphone-light-sheet-custom.png` |
| Name & room (04): Save at the bottom | On iOS, Save is in the navigation bar (`confirmationAction`). macOS keeps the bottom button. | `iphone-name-room-navsave.png` |
| Scenes (06): no banner, Run under the title | Each card has a gradient banner of the scene's colors, the icon tile overlaps the banner edge, and there is a "…" menu on a material circle. The card shows the title with "Running…" or a summary, and a trailing Run or Stop capsule. The running card has an accent border. The type is Dynamic Type (`.headline`/`.subheadline`). `ViewThatFits` drops Run/Stop below the title at large sizes. | `iphone-scenes-cards.png`, `iphone-scenes-ax-xl.png` |

## Verified on the simulators (second pass)

The iPhone 17 (`A2B918AE…`) returned `DEVICE_IN_USE` (owner `t3-7b28d9f14137e81e82a06469`), so this pass used the free **iPhone 18 Pro** (`267FF4EC…`, iOS 27.2). The iPad (`50F474C5…`) also returned `DEVICE_IN_USE` (owner `t3-9fbb1a90855a76aeefa860c7`), and no other iPad exists. **No iPad screenshots were taken in this pass.**

- **Full Files import.** The fixture `docs/qa/sim/luma-test-floorplan.png` was copied to the simulator's "On My iPhone" storage (the `group.com.apple.FileProvider.LocalStorage` folder, as `luma-files-fixture.png`). No user data was involved. The path was Plan → Add floor → Files… → Browse → On My iPhone → the fixture → Name this floor → Add. The plan opened in edit mode (`iphone-files-import-done.png`).
- **Running, Stop and disabled Run.** In the scene editor, "Wait before step 1" of the demo scene "Evening unwind" was set to 7.5 s and saved. Running it showed the banner "Running Evening unwind", a "Stop Evening unwind" button with the text "Running…", and **"Run Focus time" disabled**. Recent runs showed "Running" (`iphone-scene-running-stop.png`). The scene finished before Stop was pressed. Stop/cancel is covered by the tests `savedSceneWebhookAndCancellation` and `delayedDemoSceneStaysRunningAndBlocksOtherRunsUntilStopped` (the second one is new).
- **Tests.** `swift test`: 138 Swift Testing tests (74 + 64) and 6 XCTest tests pass. The macOS app (`swift build --product Luma`) and the `LumaiOS` simulator build both succeed.

## Verified on the simulators (first pass)

The iPad was the iPad Pro 13 (M5). The iPhone was an **iPhone 17** (iOS 27.2). The iPhone 18 Pro Max (`358230FB…`) was owned by another agent-device session (`DEVICE_IN_USE`, owner `t3-0467245fa9a3676f2a6cc9b8`), so it was not used.

- **Photos import → name the floor → plan.** Verified on iPad and iPhone.
- **Files picker.** It opens on iPad. A full import from Files was **not** completed, because there is no file in Files.
- **Tray placement.**
  - Tapping a tray item places the light: verified on iPad and iPhone.
  - Dragging a tray item onto the plan (`agent-device gesture drag`) places the light: verified on iPad.
- **Dragging a pin in edit mode saves its new position.** Verified on iPad and iPhone (`gesture pan`). This pass saw the pin move about 55% of the finger travel; the second pass found the cause and fixed it.
- **Tapping a pin toggles power.** Verified on iPhone (value On → Off).
- **Long-pressing a pin opens the light sheet.** Verified on iPad.
- **List view.** It shows the placed lights with their state.
- **Floor menu.** It has Rename, Replace Image (Photos/Files) and Delete.
- **Replace image.** The confirmation says "Pins keep their positions", and the pin was kept after the replace.
- **Rename and move room.** Renaming to "Reading lamp" and moving the light to Office worked from the sheet's Name & room page.
- **Scenes.** Run → "Completed" appears in Recent runs. Demo scenes finish instantly, so the running/Stop state was **not** observed.
- **iPad orientation.** Landscape and portrait look correct: the floor bar, the tray and the sheet are not clipped, and the pin keeps its relative position.
- **Dynamic Type.**
  - iPad at AX Large: the Home screen and the empty plan look correct.
  - iPhone at AX Extra Large: the onboarding looks correct after the fix.
  - The other screens were checked at the default size only.
- **Tests.** `swift test`, final run: 135 Swift Testing tests (74 + 61) and 6 XCTest tests pass, with 0 failures. This includes the new pin brightness test.

## Remaining differences from Paper (not fixed)

- "confirmed by the light" appears only for local lights, which is by design: cloud lights are confirmed by Govee's report.
- "Use original name" appears only when a custom name is set.
- The scene editor on iPhone is cramped. The name field and the symbol grid sit side by side, and the step rows are clipped on the right. During QA, a ref shift deleted a step; Cancel discarded the deletion. This is not in Paper scope, but it should be fixed.

## Not verified

- VoiceOver with the screen reader on. The adjustable action was checked by unit test and by the AX tree only.
- iPad screenshots of the second-pass fixes (iPad `DEVICE_IN_USE`). The iPhone 18 Pro Max, and iPhone landscape (agent-device has no rotate command; the iPad was rotated with argent `rotate`).
- **iCloud sync.** CloudSyncCoordinator does not start on the simulator (`os(iOS) && !targetEnvironment(simulator)`). It must be validated on a signed device (team `2CKK5ZNTJG`): first sync, a second device, signed-out and Keychain-off states, and the Apple Account change.
- **Mac UI.** The code builds through `swift test`. The UI QA on Mac is for the parent's native handoff; it was not done here.
