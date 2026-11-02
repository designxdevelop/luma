import Foundation

/// A plain-text summary of what Luma can do with each light model, for issue
/// reports. Only models, capability names and data types, and connection paths:
/// never device IDs, names, rooms, IP addresses, or Bluetooth identities.
public enum CompatibilityReport {
    /// Capabilities with their own controls in Luma; anything else uses the generic feature form.
    public static let dedicated: Set<String> = ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK", DreamView.instance, "lightScene", "diyScene", "snapshot"]

    public static func text(for devices: [LightDevice], app: String) -> String {
        var lines = ["Luma compatibility report", app, ""]
        var seen = Set<String>()
        for device in devices.sorted(by: { $0.sku < $1.sku }) where !device.isDemo {
            let caps = device.capabilities.sorted { $0.instance < $1.instance }
            let paths = [device.capabilities.isEmpty ? nil : "cloud", device.ip == nil ? nil : "LAN"].compactMap { $0 }
            let entry = describe(device.sku, caps: caps, paths: paths)
            // Identical models with identical features are listed once.
            guard seen.insert(entry.joined(separator: "\n")).inserted else { continue }
            lines += entry + [""]
        }
        if seen.isEmpty { lines.append("No lights.") }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ sku: String, caps: [Capability], paths: [String]) -> [String] {
        var lines = ["\(sku) · \(paths.isEmpty ? "no connection" : paths.joined(separator: " + "))"]
        let own = caps.filter { dedicated.contains($0.instance) }.map(\.instance)
        let generic = caps.filter { !dedicated.contains($0.instance) }.map { "\($0.instance) (\($0.type.replacingOccurrences(of: "devices.capabilities.", with: "")), \($0.parameters?["dataType"]?.string ?? "?"))" }
        if !own.isEmpty { lines.append("  Luma controls: " + own.joined(separator: ", ")) }
        if !generic.isEmpty { lines.append("  Generic form: " + generic.joined(separator: ", ")) }
        if paths.contains("LAN") { lines.append("  LAN: power, brightness, color, white (Govee LAN API)") }
        if let limit = DreamViewDraft.memberLimit(sku: sku) { lines.append("  DreamView controller: up to \(limit) members (ha-govee-led-ble); membership isn't editable in Luma") }
        return lines
    }
}
