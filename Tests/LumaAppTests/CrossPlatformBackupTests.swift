import Foundation
import Testing
import LumaCore
@testable import LumaUI

/// Luma for Windows/Linux writes the same `luma-home-backup` format (desktop/src/main/backup.ts).
/// The fixture below is that encoder's real output (legacy Electron IDs remapped to UUIDs,
/// `symbol` added, whole-second date), so a cross-platform restore is checked from this side too.
@MainActor struct CrossPlatformBackupTests {
    static let electronBackup = #"""
{
  "format": "luma-home-backup",
  "version": 1,
  "exportedAt": "2026-11-02T18:30:12Z",
  "scenes": [
    {
      "id": "f22dfd35-c116-4420-8cfe-9e79163e2054",
      "name": "Movie night",
      "symbol": "film",
      "icon": "film",
      "steps": [
        {
          "id": "95569698-a3fb-4b02-a6a3-d05819b12718",
          "deviceID": "demo-floor",
          "command": {
            "type": "devices.capabilities.on_off",
            "instance": "powerSwitch",
            "value": 1
          },
          "delayMilliseconds": 0
        },
        {
          "id": "80d54812-554a-4ae6-a779-d2d6e2989cac",
          "deviceID": "demo-floor",
          "command": {
            "type": "devices.capabilities.range",
            "instance": "brightness",
            "value": 30
          },
          "delayMilliseconds": 500
        }
      ]
    }
  ],
  "schedules": [
    {
      "id": "9440dee9-6711-41dd-9ac8-11a2a22244cf",
      "sceneID": "f22dfd35-c116-4420-8cfe-9e79163e2054",
      "hour": 20,
      "minute": 15,
      "weekdays": [
        6,
        7
      ],
      "enabled": true
    }
  ],
  "lights": [
    {
      "id": "demo-floor",
      "sku": "Demo lamp",
      "customName": "Reading corner",
      "room": "Den"
    },
    {
      "id": "AA:BB:CC:DD:EE:01",
      "sku": "H6008",
      "room": "Office"
    }
  ]
}
"""#

    @Test func electronBackupDecodesAndRestoresOntoKnownLights() throws {
        let backup = try HomeBackup.decode(Data(Self.electronBackup.utf8))
        #expect(backup.scenes.first?.symbol == "film" && backup.scenes.first?.steps.count == 2)
        #expect(backup.schedules.first?.sceneID == backup.scenes.first?.id && backup.schedules.first?.weekdays == [6, 7])
        #expect(backup.scenes.first?.steps.last?.delayMilliseconds == 500)

        let store = HomeStore(demo: true); defer { store.shutdown() }
        store.home.devices = store.home.devices.map { var d = $0; d.isDemo = false; return d }
        let result = try store.restore(backup)
        #expect(result.scenes == 1 && result.schedules == 1 && result.lightsUpdated == 1 && result.lightsNotFound == 1)
        #expect(store.devices.first { $0.id == "demo-floor" }?.customName == "Reading corner")
        #expect(store.devices.first { $0.id == "demo-floor" }?.room == "Den")
        try CommandValidation.validateScene(store.home.scenes[0], devices: store.devices)
    }
}
