import Foundation
import LumaCore

struct ControlKey: Hashable {
    let deviceID: String
    let instance: String
}

struct PendingControl {
    enum Phase { case queued, sending, confirming }
    let id: UUID
    let command: CapabilityCommand
    var phase: Phase = .queued
}

struct RecentConfirmation {
    let value: JSONValue
    let until: ContinuousClock.Instant
}

struct QueuedControl {
    let id: UUID
    let deviceID: String
    let command: CapabilityCommand
    let coalescible: Bool
    var completion: CheckedContinuation<Void, any Error>?
    var key: ControlKey { .init(deviceID: deviceID, instance: command.instance) }
}

extension LightDevice {
    func reportedValue(for instance: String) -> JSONValue? {
        switch instance {
        case "powerSwitch": power.map { .number($0 ? 1 : 0) }
        case "brightness": brightness.map { .number(Double($0)) }
        case "colorRgb": rgb.map { .number(Double($0)) }
        case "colorTemperatureK": colorTemperature.map { .number(Double($0)) }
        default: nil
        }
    }
    mutating func display(_ command: CapabilityCommand) {
        guard let n = command.value.number else { return }
        switch command.instance {
        case "powerSwitch": power = n == 1
        case "brightness": brightness = Int(n)
        case "colorRgb": rgb = Int(n); colorTemperature = 0
        case "colorTemperatureK": colorTemperature = Int(n)
        default: break
        }
    }
}
