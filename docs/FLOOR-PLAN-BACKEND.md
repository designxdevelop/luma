# Floor-plan implementation handoff

Native shared Swift backend, ready for the Paper UI. No server or account needed.

- `HomeStore.floorPlans`: ordered plans with UUID, name and light pins.
- `importFloorPlan(name:image:)`: image data from a photo/file picker; returns UUID.
- `floorPlanImageURL`, `renameFloorPlan`, `replaceFloorPlanImage`, `deleteFloorPlan`.
- `placeLight(_:onFloorPlan:x:y:)`, `removeFloorPlanPin(_:from:)`: saves only when drag ends. Coordinates are 0...1 in the displayed **image rectangle**, excluding letterboxing and accounting for zoom/pan. Moving a light to another floor removes its previous pin.
- Resolve pin `deviceID` against `store.devices` for live state and existing power/control APIs. Placement never sends a lighting command. Hide or label missing devices; keep their saved pins so a temporary discovery gap does not erase the layout.

Images stay in Application Support/Luma/floor-plans (Luma-Demo in demo mode), with private file permissions and iOS data protection. ImageIO converts imports up to 20 MB into orientation-correct PNGs of at most 4096 px, without source metadata. Plan metadata saves atomically, separately from existing home.json, so existing homes need no migration. An unreadable metadata file disables modifications to preserve it. Replacement keeps pins; confirm before replacing or deleting.

UI still to implement after design: picker/import, floors list/selector, pan/zoom map, edit mode drag and unplaced lights, control mode power/detail actions, accessible list alternative, errors/offline states. LiDAR, cloud sync, PDF parsing and Electron parity are outside this initial backend.
