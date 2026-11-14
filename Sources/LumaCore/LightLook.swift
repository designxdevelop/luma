import Foundation

// Govee's API reports one color per light, never segment or scene colors. Luma
// remembers what it last sent so the UI can draw the gradient the light is
// probably showing. Same rules as Android (`core/Model.kt`).
// ponytail: only Luma's own writes update it; a change made in Govee Home leaves
// the old palette until Luma next sets a color. Clear on telemetry if that bites.

extension LightDevice {
    /// Updates `palette` for a command Luma is sending to this light.
    public mutating func noteLook(_ command: CapabilityCommand) {
        switch command.instance {
        case "colorRgb", "colorTemperatureK": palette = nil
        case "segmentedColorRgb":
            guard let schema = SegmentPaint(capabilities.first { $0.instance == command.instance }), !schema.indexes.isEmpty,
                  let color = command.value[schema.valueField]?.number, let segments = command.value["segment"]?.array else { return }
            let painted = Set(segments.compactMap { $0.number.map { Int($0) } })
            var colors = palette?.count == schema.indexes.count ? palette! : Array(repeating: rgb ?? 0xFFC98F, count: schema.indexes.count)
            for (slot, index) in schema.indexes.enumerated() where painted.contains(index) { colors[slot] = Int(color) }
            palette = colors
        case "lightScene", "diyScene", "snapshot":
            let name = GoveeSceneLibrary.options(for: self).first { $0.kind.rawValue == command.instance && $0.value == command.value }?.name
            palette = name.flatMap(ScenePalette.colors)
        default: break
        }
    }
}

/// Best-guess colors for a Govee scene from its name; nil when the name says nothing.
public enum ScenePalette {
    static let table: [(words: [String], colors: [Int])] = [
        (["sunrise", "dawn", "morning"], [0xFF7A3D, 0xFFB36B, 0xFFE2A8]),
        (["sunset", "dusk", "twilight"], [0xFF5E62, 0xFF9966, 0xB24592]),
        (["aurora", "northern"], [0x00E5A0, 0x3FA9F5, 0x8A5CF6]),
        (["candle", "fire", "flame", "warm", "cozy"], [0xFF4E1F, 0xFF8A1F, 0xFFC46B]),
        (["ocean", "sea", "wave", "water", "rain", "lake"], [0x0077FF, 0x00C6D7, 0x6FE3E1]),
        (["forest", "jungle", "leaf", "spring", "grass", "nature"], [0x0B6E4F, 0x1FA34A, 0x9BE15D]),
        (["rainbow", "party", "disco", "colorful", "carnival", "pulse"], [0xFF3B30, 0xFFD60A, 0x34C759, 0x0A84FF, 0xAF52DE]),
        (["star", "night", "galaxy", "space", "universe", "moon"], [0x1B2A6B, 0x6A5ACD, 0xC6B5FF]),
        (["romantic", "love", "rose", "valentine", "sakura", "cherry"], [0xFF2D75, 0xFF7EB3, 0xB5179E]),
        (["movie", "cinema", "film", "fade"], [0x3A1C71, 0xD76D77, 0xFFAF7B]),
        (["snow", "ice", "winter", "frost"], [0x5AA9E6, 0xA8E0FF, 0xEAF6FF]),
        (["christmas", "xmas"], [0xD62828, 0xF6F1D1, 0x2A9D3F]),
        (["halloween", "pumpkin"], [0xFF7A00, 0x6A0DAD, 0x2B1055]),
        (["reading", "work", "study", "focus"], [0xFFE9C4, 0xFFF6E5]),
    ]
    public static func colors(named name: String) -> [Int]? {
        let name = name.lowercased()
        return table.first { $0.words.contains { name.contains($0) } }?.colors
    }
}
