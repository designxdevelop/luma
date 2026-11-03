import Foundation

/// Govee's documented cloud `dreamViewToggle` starts or stops the DreamView group
/// a person set up in Govee Home. Group members and Movie/Game video settings are
/// not part of the cloud API, so nothing here reads or changes them.
public enum DreamView {
    public static let instance = "dreamViewToggle"

    public static func capability(of device: LightDevice) -> Capability? {
        device.capabilities.first { $0.instance == instance }
    }

    /// The advertised option named on/off, or the documented 1/0 when the light
    /// lists no options. Validation still checks the value against the schema.
    public static func command(on: Bool, for device: LightDevice) throws -> CapabilityCommand {
        guard let cap = capability(of: device) else { throw LumaError.message("\(device.name) does not advertise DreamView.") }
        let named = cap.parameters?["options"]?.array?.first { $0["name"]?.string?.lowercased() == (on ? "on" : "off") }?["value"]
        let command = CapabilityCommand(type: cap.type, instance: instance, value: named ?? .number(on ? 1 : 0))
        try CommandValidation.validate(command, for: device)
        return command
    }

    /// Power on, then DreamView on. The toggle is last so no later step can
    /// replace the running sync with another effect.
    public static func movieScene(for device: LightDevice) throws -> LightScene {
        var steps: [SceneStep] = []
        if device.supports("powerSwitch") { steps.append(.init(deviceID: device.id, command: .power(true))) }
        steps.append(.init(deviceID: device.id, command: try command(on: true, for: device)))
        return LightScene(name: "Movie · \(device.name)", symbol: "film", steps: steps)
    }
}

/// A partner-light layout a person designs in Luma. It is never sent to lights:
/// writing membership needs the BLE `0x50` group upload with each member's
/// `cmd_ver`, and these controllers report Bluetooth encryption support (`supportEnc`).
/// Govee Home's group name and light count can be read (`GoveeHomeImport.parseGroups`);
/// member identities can't yet (see docs/PARITY.md).
public struct DreamViewDraft: Codable, Sendable, Equatable {
    public struct Member: Codable, Sendable, Equatable, Identifiable {
        public var deviceID: String
        /// Screen areas as ha-govee-led-ble's wire values 1…10. Their on-screen positions aren't verified.
        public var areas: [Int]
        public var id: String { deviceID }
        public init(deviceID: String, areas: [Int]) { self.deviceID = deviceID; self.areas = areas }
    }
    public var members: [Member] = []
    public init(members: [Member] = []) { self.members = members }

    public static let areas = 1...10

    /// Member capacity per ha-govee-led-ble @ b845c59 `services.yaml`; nil for models it doesn't list.
    public static func memberLimit(sku: String) -> Int? {
        ["H6199": 5, "H6097": 7, "H6099": 7, "H66A0": 10][sku.uppercased()]
    }

    public static let applyBlocker = "Luma can't send this to your lights yet: it can't read which lights are in the group or their command versions, and a Bluetooth writer would also have to handle the encryption these TV backlights report supporting. Set members in Govee Home."
}
