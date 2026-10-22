import Foundation

// Screen Sync math. Pure and platform neutral, matching the Windows/Linux port:
// colors are averaged in linear light from 8-bit sRGB, letterbox bars are
// cropped symmetrically, and lights get a full-saturation hue plus a capped
// brightness. Nothing here touches capture, networking, or the UI.

/// What part of the picture a light follows. Raw values are persisted and match
/// the Windows/Linux port; never rename them.
public enum ScreenRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case full, left, right, top, bottom
    case edgeLeft, edgeRight, edgeTop, edgeBottom
    case cornerTopLeft, cornerTopRight, cornerBottomLeft, cornerBottomRight
    case edgeLeftUpper, edgeLeftLower, edgeRightUpper, edgeRightLower
    case edgeTopLeft, edgeTopRight, edgeBottomLeft, edgeBottomRight

    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case thirds = "Whole picture and thirds", edges = "Edges", corners = "Corners", halves = "Half edges"
        public var id: Self { self }
        public var regions: [ScreenRegion] { ScreenRegion.allCases.filter { $0.group == self } }
    }

    public var id: Self { self }
    public var group: Group {
        switch self {
        case .full, .left, .right, .top, .bottom: .thirds
        case .edgeLeft, .edgeRight, .edgeTop, .edgeBottom: .edges
        case .cornerTopLeft, .cornerTopRight, .cornerBottomLeft, .cornerBottomRight: .corners
        default: .halves
        }
    }
    public var title: String {
        switch self {
        case .full: "Whole picture"; case .left: "Left third"; case .right: "Right third"; case .top: "Top third"; case .bottom: "Bottom third"
        case .edgeLeft: "Left edge"; case .edgeRight: "Right edge"; case .edgeTop: "Top edge"; case .edgeBottom: "Bottom edge"
        case .cornerTopLeft: "Top-left corner"; case .cornerTopRight: "Top-right corner"
        case .cornerBottomLeft: "Bottom-left corner"; case .cornerBottomRight: "Bottom-right corner"
        case .edgeLeftUpper: "Left edge, upper half"; case .edgeLeftLower: "Left edge, lower half"
        case .edgeRightUpper: "Right edge, upper half"; case .edgeRightLower: "Right edge, lower half"
        case .edgeTopLeft: "Top edge, left half"; case .edgeTopRight: "Top edge, right half"
        case .edgeBottomLeft: "Bottom edge, left half"; case .edgeBottomRight: "Bottom edge, right half"
        }
    }

    /// Area as fractions of the cropped picture: x from `x0` to `x1`, y from `y0` (top) to `y1`.
    /// Edges, corners and half edges are `depth` deep.
    public func rect(depth d: Double) -> (x0: Double, x1: Double, y0: Double, y1: Double) {
        let t = 1.0 / 3, n = 1 - d
        switch self {
        case .full: return (0, 1, 0, 1)
        case .left: return (0, t, 0, 1); case .right: return (1 - t, 1, 0, 1)
        case .top: return (0, 1, 0, t); case .bottom: return (0, 1, 1 - t, 1)
        case .edgeLeft: return (0, d, 0, 1); case .edgeRight: return (n, 1, 0, 1)
        case .edgeTop: return (0, 1, 0, d); case .edgeBottom: return (0, 1, n, 1)
        case .cornerTopLeft: return (0, d, 0, d); case .cornerTopRight: return (n, 1, 0, d)
        case .cornerBottomLeft: return (0, d, n, 1); case .cornerBottomRight: return (n, 1, n, 1)
        case .edgeLeftUpper: return (0, d, 0, 0.5); case .edgeLeftLower: return (0, d, 0.5, 1)
        case .edgeRightUpper: return (n, 1, 0, 0.5); case .edgeRightLower: return (n, 1, 0.5, 1)
        case .edgeTopLeft: return (0, 0.5, 0, d); case .edgeTopRight: return (0.5, 1, 0, d)
        case .edgeBottomLeft: return (0, 0.5, n, 1); case .edgeBottomRight: return (0.5, 1, n, 1)
        }
    }
}

/// Linear-light color, each channel 0…1.
public struct LinearColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public static let black = LinearColor(0, 0, 0)
}

/// One color per region. Missing regions read as black.
public struct RegionColors: Equatable, Sendable {
    private var colors: [ScreenRegion: LinearColor]
    public init(all color: LinearColor) { colors = Dictionary(uniqueKeysWithValues: ScreenRegion.allCases.map { ($0, color) }) }
    public subscript(region: ScreenRegion) -> LinearColor {
        get { colors[region] ?? .black }
        set { colors[region] = newValue }
    }
}

/// A frame reduced to a coarse grid over the picture (bars cropped). Each cell
/// holds its pixel count and sums: linear r, g, b, then the vivid weight and
/// weight × linear r, g, b. Region colors are computed from it with the
/// current edge depth and vivid setting. Only these sums leave capture.
public struct ScreenGrid: Equatable, Sendable {
    public static let maxColumns = 30, maxRows = 18, valuesPerCell = 8
    public let columns: Int, rows: Int
    public let cells: [Double]
    public init?(columns: Int, rows: Int, cells: [Double]) {
        guard (1...Self.maxColumns).contains(columns), (1...Self.maxRows).contains(rows),
              cells.count == columns * rows * Self.valuesPerCell else { return nil }
        self.columns = columns; self.rows = rows; self.cells = cells
    }
    /// A single-color grid, for synthetic sources and tests.
    public init(uniform c: LinearColor, weight: Double = 1) {
        columns = 1; rows = 1; cells = [1, c.r, c.g, c.b, weight, weight * c.r, weight * c.g, weight * c.b]
    }

    /// Cell index range covering the fraction `a..<b` of `n` cells; never empty.
    static func span(_ a: Double, _ b: Double, _ n: Int) -> Range<Int> {
        let lo = min(Int((a * Double(n)).rounded()), n - 1)
        return lo..<max(lo + 1, min(Int((b * Double(n)).rounded()), n))
    }

    public func color(_ region: ScreenRegion, depth: Double, vivid: Bool) -> LinearColor {
        let r = region.rect(depth: depth)
        var s = [Double](repeating: 0, count: Self.valuesPerCell)
        for y in Self.span(r.y0, r.y1, rows) {
            for x in Self.span(r.x0, r.x1, columns) {
                let o = (y * columns + x) * Self.valuesPerCell
                for i in 0..<Self.valuesPerCell { s[i] += cells[o + i] }
            }
        }
        let (n, base) = vivid ? (s[4], 5) : (s[0], 1)
        return n > 0 ? LinearColor(s[base] / n, s[base + 1] / n, s[base + 2] / n) : .black
    }

    public func colors(depth: Double = ScreenSyncSettings().edgeDepth, vivid: Bool = false) -> RegionColors {
        var out = RegionColors(all: .black)
        for region in ScreenRegion.allCases { out[region] = color(region, depth: depth, vivid: vivid) }
        return out
    }
}

public struct ScreenSyncSettings: Codable, Equatable, Sendable {
    /// Share of the old color kept per 100 ms (`ScreenColorMath.smoothingStep`).
    /// 0 follows instantly; 0.95 is very slow. Large jumps ease off automatically.
    public var smoothing: Double = 0.4
    /// Dead band as a fraction of the channel/brightness range.
    public var threshold: Double = 0.02
    /// Highest brightness Screen Sync sends, 1–100%.
    public var brightnessCap: Double = 80
    /// Per-light LAN update cap. Govee LAN is unacknowledged UDP: sends are
    /// latest-only with no retries, so a dropped datagram is replaced by the next
    /// one rather than queued. 10 Hz bounds a light at ≤20 small datagrams/s.
    public var updateHz: Double = 5
    /// How deep edges, corners and half edges reach into the picture, as a share of its width or height.
    public var edgeDepth: Double = 0.15
    /// Weights colorful pixels over gray and white ones, so color isn't washed out by UI or text.
    public var vivid = false
    public static let smoothingRange = 0.0...0.95
    public static let thresholdRange = 0.005...0.2
    public static let brightnessCapRange = 1.0...100
    public static let updateHzRange = 0.5...10.0
    public static let edgeDepthRange = 0.05...0.33
    public init() {}
    /// Settings saved before a field existed keep their other values.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        brightnessCap = try c.decodeIfPresent(Double.self, forKey: .brightnessCap) ?? d.brightnessCap
        updateHz = try c.decodeIfPresent(Double.self, forKey: .updateHz) ?? d.updateHz
        edgeDepth = try c.decodeIfPresent(Double.self, forKey: .edgeDepth) ?? d.edgeDepth
        vivid = try c.decodeIfPresent(Bool.self, forKey: .vivid) ?? d.vivid
    }
    /// Clamps every field; non-finite values fall back to defaults.
    public func clamped() -> Self {
        let d = Self()
        func fit(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double { v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback }
        var s = self
        s.smoothing = fit(smoothing, Self.smoothingRange, d.smoothing)
        s.threshold = fit(threshold, Self.thresholdRange, d.threshold)
        s.brightnessCap = fit(brightnessCap, Self.brightnessCapRange, d.brightnessCap)
        s.updateHz = fit(updateHz, Self.updateHzRange, d.updateHz)
        s.edgeDepth = fit(edgeDepth, Self.edgeDepthRange, d.edgeDepth)
        return s
    }
}

/// What one light should show: a 24-bit RGB hue and a 1–100% brightness.
public struct LightTarget: Equatable, Sendable {
    public var rgb: Int
    public var brightness: Int
    public init(rgb: Int, brightness: Int) { self.rgb = rgb; self.brightness = brightness }
}

/// One latest-only update for one light. Unchanged fields are not resent.
public struct StreamUpdate: Equatable, Sendable {
    public let deviceID: String
    public let target: LightTarget
    public let sendsColor: Bool
    public let sendsBrightness: Bool
    public init(deviceID: String, target: LightTarget, sendsColor: Bool, sendsBrightness: Bool) {
        self.deviceID = deviceID; self.target = target; self.sendsColor = sendsColor; self.sendsBrightness = sendsBrightness
    }
}

public enum ScreenColorMath {
    static let linearTable: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    public static func linear(_ c8: UInt8) -> Double { linearTable[Int(c8)] }
    /// Linear 0…1 to sRGB 0…255, unrounded.
    public static func srgb(_ l: Double) -> Double {
        let c = min(max(l, 0), 1)
        return 255 * (c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    /// Near-black: no channel above this 8-bit value (tolerates encoder noise).
    static let dark: UInt8 = 24
    /// A row or column is a bar when at most 2% of its pixels are brighter than `dark`.
    static let barTolerance = 0.02
    /// Bars never take more than this share of a side.
    static let maxBar = 0.25
    /// Bounds per-frame work. Capture is configured far smaller than this.
    public static let maxPixels = 1 << 20

    public struct Bands: Equatable, Sendable { public var top = 0, bottom = 0, left = 0, right = 0 }

    /// Every pixel counts at least this much in vivid mode, so gray scenes still have a color.
    static let vividFloor = 0.05

    /// Reduces a 32BGRA frame (bytes B, G, R, A) to a grid of linear-light sums,
    /// with letterbox bars cropped. Returns nil for an empty, oversized, or
    /// truncated buffer. Rows may be padded (`bytesPerRow`).
    public static func analyze(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> ScreenGrid? {
        guard width > 0, height > 0, width <= maxPixels / height, bytesPerRow >= width * 4,
              bytes.count >= (height - 1) * bytesPerRow + width * 4 else { return nil }
        let px = bytes.bindMemory(to: UInt8.self)
        let bands = letterbox(px, width: width, height: height, bytesPerRow: bytesPerRow)
        let x0 = bands.left, iw = width - bands.right - x0, y0 = bands.top, ih = height - bands.bottom - y0
        let columns = min(ScreenGrid.maxColumns, iw), rows = min(ScreenGrid.maxRows, ih), k = ScreenGrid.valuesPerCell
        // Pixel p falls in cell floor(p * cells / size), so cell i starts at ceil(i * size / cells):
        // with 30 × 18 cells the thirds land exactly on the old pixel boundaries.
        let cellX = (0..<iw).map { $0 * columns / iw * k }
        var cells = [Double](repeating: 0, count: columns * rows * k)
        linearTable.withUnsafeBufferPointer { lin in
            cells.withUnsafeMutableBufferPointer { c in
                for y in 0..<ih {
                    let row = (y0 + y) * bytesPerRow + x0 * 4, cellRow = y * rows / ih * columns * k
                    for x in 0..<iw {
                        let o = row + x * 4, b8 = px[o], g8 = px[o + 1], r8 = px[o + 2]
                        let r = lin[Int(r8)], g = lin[Int(g8)], b = lin[Int(b8)]
                        let chroma = Double(max(r8, g8, b8) - min(r8, g8, b8)) / 255, w = vividFloor + chroma * chroma
                        let i = cellRow + cellX[x]
                        c[i] += 1; c[i + 1] += r; c[i + 2] += g; c[i + 3] += b
                        c[i + 4] += w; c[i + 5] += w * r; c[i + 6] += w * g; c[i + 7] += w * b
                    }
                }
            }
        }
        return ScreenGrid(columns: columns, rows: rows, cells: cells)
    }

    /// Contiguous black bars at the edges. Bars must be symmetric (the smaller
    /// side wins), so a dark sky is not cropped; an entirely dark frame is a dark
    /// scene, not all bars.
    static func letterbox(_ px: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Bands {
        func lineIsDark(start: Int, step: Int, count: Int) -> Bool {
            let allowed = Int(Double(count) * barTolerance)
            var bright = 0, o = start
            for _ in 0..<count {
                if px[o] > dark || px[o + 1] > dark || px[o + 2] > dark { bright += 1; if bright > allowed { return false } }
                o += step
            }
            return true
        }
        func rowDark(_ y: Int) -> Bool { lineIsDark(start: y * bytesPerRow, step: 4, count: width) }
        func colDark(_ x: Int) -> Bool { lineIsDark(start: x * 4, step: bytesPerRow, count: height) }
        func scan(_ dark: (Int) -> Bool, from: Int, dir: Int, limit: Int) -> Int {
            var n = 0
            while n < limit && dark(from + dir * n) { n += 1 }
            return n
        }
        guard (0..<height).contains(where: { !rowDark($0) }) else { return Bands() }
        let maxRows = Int(Double(height) * maxBar), maxCols = Int(Double(width) * maxBar)
        let v = min(scan(rowDark, from: 0, dir: 1, limit: maxRows), scan(rowDark, from: height - 1, dir: -1, limit: maxRows))
        let h = min(scan(colDark, from: 0, dir: 1, limit: maxCols), scan(colDark, from: width - 1, dir: -1, limit: maxCols))
        return Bands(top: v, bottom: v, left: h, right: h)
    }

    /// `smoothing` is the share kept per this many seconds, so feel doesn't depend on frame rate.
    public static let smoothingStep = 0.1
    /// A jump of this share of the sRGB range (any channel) bypasses smoothing entirely.
    public static let jumpRelease = 0.25

    /// Exponential smoothing in linear light, normalized to elapsed time `dt`.
    /// Smoothing eases off in proportion to the jump (measured in sRGB, so dark
    /// scenes count), so scene cuts land at once while small noise stays filtered.
    public static func smooth(_ previous: LinearColor?, _ next: LinearColor, smoothing: Double, dt: Double = smoothingStep) -> LinearColor {
        guard let p = previous else { return next }
        let jump = max(abs(srgb(next.r) - srgb(p.r)), abs(srgb(next.g) - srgb(p.g)), abs(srgb(next.b) - srgb(p.b))) / 255
        let s = min(max(smoothing, 0), 1) * max(0, 1 - jump / jumpRelease)
        let a = 1 - pow(s, min(max(dt.isFinite ? dt : smoothingStep, 0.001), 1) / smoothingStep)
        return LinearColor(p.r + a * (next.r - p.r), p.g + a * (next.g - p.g), p.b + a * (next.b - p.b))
    }

    /// Full-saturation hue (brightest channel at 255) plus brightness from the
    /// brightest channel, scaled by the cap and never below 1%. Black keeps a
    /// neutral color at 1% so Screen Sync never turns a light off.
    public static func target(_ color: LinearColor, brightnessCap: Double) -> LightTarget {
        let cap = Int(min(max(brightnessCap.isFinite ? brightnessCap : 80, 1), 100).rounded())
        let m = max(color.r, color.g, color.b)
        guard color.r.isFinite, color.g.isFinite, color.b.isFinite, m > 1.0 / 4096 else { return LightTarget(rgb: 0xFFFFFF, brightness: 1) }
        func c(_ v: Double) -> Int { Int(srgb(v / m).rounded()) }
        let brightness = max(1, min(cap, Int((Double(cap) * srgb(m) / 255).rounded())))
        return LightTarget(rgb: c(color.r) << 16 | c(color.g) << 8 | c(color.b), brightness: brightness)
    }

    /// Dead band: only changes of at least `threshold` of the range are sent.
    public static func exceedsThreshold(_ previous: LightTarget?, _ next: LightTarget, threshold: Double) -> Bool {
        guard let previous else { return true }
        let dc = [16, 8, 0].map { abs(((previous.rgb >> $0) & 255) - ((next.rgb >> $0) & 255)) }.max() ?? 0
        return Double(dc) >= max(1, threshold * 255) || Double(abs(previous.brightness - next.brightness)) >= max(1, threshold * 100)
    }
}

/// Latest-only state for one Screen Sync session. Frames overwrite the target;
/// `tick` smooths at a fixed cadence and returns at most one update per light
/// per rate interval. Nothing is ever queued, so old frames cannot be replayed.
public struct ScreenSyncMixer: Sendable {
    public var settings: ScreenSyncSettings { didSet { settings = settings.clamped() } }
    public private(set) var smoothed: RegionColors?
    private var target: RegionColors?
    private var lanes: [String: (sent: LightTarget, nextAt: Double)] = [:]
    private var lastTick: Double?

    public init(settings: ScreenSyncSettings = .init()) { self.settings = settings.clamped() }

    public mutating func ingest(_ colors: RegionColors) { target = colors }

    /// `now` is seconds on any monotonic clock. `lights` maps eligible light IDs to regions.
    public mutating func tick(now: Double, lights: [String: ScreenRegion]) -> [StreamUpdate] {
        guard let target else { return [] }
        let dt = lastTick.map { now - $0 } ?? ScreenColorMath.smoothingStep
        lastTick = now
        var next = target
        for region in ScreenRegion.allCases { next[region] = ScreenColorMath.smooth(smoothed?[region], target[region], smoothing: settings.smoothing, dt: dt) }
        smoothed = next
        var updates: [StreamUpdate] = []
        for (id, region) in lights.sorted(by: { $0.key < $1.key }) {
            let wanted = ScreenColorMath.target(next[region], brightnessCap: settings.brightnessCap)
            let lane = lanes[id]
            if let lane, now < lane.nextAt { continue }
            // A lowered cap is a hard limit, even when the adjustment is
            // smaller than the color-change dead band. Keep the rate limit.
            let exceedsCap = lane.map { $0.sent.brightness > Int(settings.brightnessCap.rounded()) } ?? false
            guard exceedsCap || ScreenColorMath.exceedsThreshold(lane?.sent, wanted, threshold: settings.threshold) else { continue }
            updates.append(.init(deviceID: id, target: wanted, sendsColor: lane?.sent.rgb != wanted.rgb, sendsBrightness: lane?.sent.brightness != wanted.brightness))
            lanes[id] = (wanted, now + 1 / settings.updateHz)
        }
        return updates
    }

    /// Drop a light's lane so nothing further is computed for it until it returns.
    public mutating func forget(_ id: String) { lanes.removeValue(forKey: id) }
    public mutating func reset() { smoothed = nil; target = nil; lastTick = nil; lanes.removeAll() }
}

extension LightDevice {
    /// Why this light can't join Screen Sync right now, or nil when it can.
    /// Only lights with local (LAN) control that are online and on qualify;
    /// Screen Sync never powers a light on or off.
    public var screenSyncIssue: String? {
        if isDemo { return nil }
        if ip == nil { return "Not found on Wi-Fi. Screen Sync needs local (LAN) control." }
        if online == false { return "Offline" }
        guard let power else { return "Waiting for status" }
        return power ? nil : "Off. Turn it on to include it."
    }
}
