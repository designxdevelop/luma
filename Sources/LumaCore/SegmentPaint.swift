import Foundation

/// The segment painter's model for `segmentedColorRgb` / `segmentedBrightness`
/// (Govee's documented segment capabilities). Pure: it reads the advertised STRUCT
/// schema and turns a painting into the fewest validated commands. The same rules
/// as Luma for Windows/Linux (`desktop/src/shared/devices.ts`).
public struct SegmentPaint: Sendable, Equatable {
    public static let instances = ["segmentedColorRgb", "segmentedBrightness"]
    static let maxSegments = 256

    public var type: String
    public var instance: String
    /// Advertised segment indexes, ascending.
    public var indexes: [Int]
    /// `rgb` or `brightness`: the struct's integer value field.
    public var valueField: String
    public var valueRange: ClosedRange<Int>
    /// Most segments one command may carry (the array's `size.max`), when advertised.
    public var perCommand: Int?

    public var isColor: Bool { valueField == "rgb" }

    /// Nil when the capability isn't a paintable segment schema (including one with a
    /// required field the painter can't fill, so nothing is ever half-sent).
    public init?(_ capability: Capability?) {
        guard let capability, Self.instances.contains(capability.instance), let p = capability.parameters,
              p["dataType"]?.string?.uppercased() == "STRUCT", let fields = p["fields"]?.array else { return nil }
        guard let segment = fields.first(where: { $0["fieldName"]?.string == "segment" }),
              let value = fields.first(where: { $0["fieldName"]?.string != "segment" && $0["dataType"]?.string?.uppercased() == "INTEGER" && $0["fieldName"]?.string != nil }),
              !fields.contains(where: { $0["required"] == .bool(true) && $0 != segment && $0 != value }) else { return nil }
        var indexes: [Int] = []
        if let lo = Self.int(segment["elementRange"]?["min"]), let hi = Self.int(segment["elementRange"]?["max"]), lo >= 0, hi >= lo, hi - lo < Self.maxSegments {
            indexes = Array(lo...hi)
        } else if let options = segment["options"]?.array {
            indexes = Array(Set(options.compactMap { Self.int($0["value"]) })).sorted().prefix(Self.maxSegments).map { $0 }
        }
        guard !indexes.isEmpty, let field = value["fieldName"]?.string else { return nil }
        let fallback = field == "rgb" ? 0...0xFFFFFF : 0...100
        let lo = Self.int(value["range"]?["min"]) ?? fallback.lowerBound, hi = Self.int(value["range"]?["max"]) ?? fallback.upperBound
        self.type = capability.type; self.instance = capability.instance; self.indexes = indexes; self.valueField = field
        self.valueRange = lo <= hi ? lo...hi : fallback
        self.perCommand = Self.int(segment["size"]?["max"]).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Paintable segment capabilities of a device, color first.
    public static func all(for device: LightDevice) -> [SegmentPaint] {
        instances.compactMap { instance in SegmentPaint(device.capabilities.first { $0.instance == instance }) }
    }

    /// One command per distinct value, segments ascending, split at the per-command
    /// limit, ordered by first segment so the same painting always gives the same commands.
    public func commands(for paint: [Int: Int]) throws -> [CapabilityCommand] {
        let allowed = Set(indexes)
        var groups: [Int: [Int]] = [:]
        for (index, value) in paint {
            guard allowed.contains(index) else { throw LumaError.message("Segment \(index) isn't on this light.") }
            guard valueRange.contains(value) else { throw LumaError.message("\(valueField) must be \(valueRange.lowerBound)…\(valueRange.upperBound).") }
            groups[value, default: []].append(index)
        }
        var commands: [(first: Int, command: CapabilityCommand)] = []
        for (value, members) in groups {
            let sorted = members.sorted(), chunk = perCommand ?? sorted.count
            for start in stride(from: 0, to: sorted.count, by: chunk) {
                let part = Array(sorted[start..<min(start + chunk, sorted.count)])
                commands.append((part[0], CapabilityCommand(type: type, instance: instance, value: .object([
                    "segment": .array(part.map { .number(Double($0)) }), valueField: .number(Double(value)),
                ]))))
            }
        }
        return commands.sorted { $0.first < $1.first }.map(\.command)
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard let n = value?.number, n.isFinite, n.rounded() == n, abs(n) <= Double(Int32.max) else { return nil }
        return Int(n)
    }
}
