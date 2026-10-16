import Foundation

// Screen Sync math. Pure and platform neutral, matching the Windows/Linux port:
// colors are averaged in linear light from 8-bit sRGB, letterbox bars are
// cropped symmetrically, and lights get a full-saturation hue plus a capped
// brightness. Nothing here touches capture, networking, or the UI.

public enum ScreenRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case full, left, right, top, bottom
    public var id: Self { self }
    public var title: String {
        switch self { case .full: "Whole picture"; case .left: "Left"; case .right: "Right"; case .top: "Top"; case .bottom: "Bottom" }
    }
}

/// Linear-light color, each channel 0…1.
public struct LinearColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public static let black = LinearColor(0, 0, 0)
}

public struct RegionColors: Equatable, Sendable {
    public var full: LinearColor, left: LinearColor, right: LinearColor, top: LinearColor, bottom: LinearColor
    public init(full: LinearColor, left: LinearColor, right: LinearColor, top: LinearColor, bottom: LinearColor) {
        self.full = full; self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
    public init(all color: LinearColor) { self.init(full: color, left: color, right: color, top: color, bottom: color) }
    public subscript(region: ScreenRegion) -> LinearColor {
        get { switch region { case .full: full; case .left: left; case .right: right; case .top: top; case .bottom: bottom } }
        set { switch region { case .full: full = newValue; case .left: left = newValue; case .right: right = newValue; case .top: top = newValue; case .bottom: bottom = newValue } }
    }
}

public struct ScreenSyncSettings: Codable, Equatable, Sendable {
    /// 0 follows instantly; 0.95 is very slow.
    public var smoothing: Double = 0.6
    /// Dead band as a fraction of the channel/brightness range.
    public var threshold: Double = 0.03
    /// Highest brightness Screen Sync sends, 1–100%.
    public var brightnessCap: Double = 80
    /// Per-light LAN update cap. Govee LAN is unacknowledged UDP, so stay conservative.
    public var updateHz: Double = 2
    public static let smoothingRange = 0.0...0.95
    public static let thresholdRange = 0.005...0.2
    public static let brightnessCapRange = 1.0...100
    public static let updateHzRange = 0.5...5.0
    public init() {}
    /// Clamps every field; non-finite values fall back to defaults.
    public func clamped() -> Self {
        let d = Self()
        func fit(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double { v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback }
        var s = self
        s.smoothing = fit(smoothing, Self.smoothingRange, d.smoothing)
        s.threshold = fit(threshold, Self.thresholdRange, d.threshold)
        s.brightnessCap = fit(brightnessCap, Self.brightnessCapRange, d.brightnessCap)
        s.updateHz = fit(updateHz, Self.updateHzRange, d.updateHz)
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

    /// Average colors of a 32BGRA frame (bytes B, G, R, A). Returns nil for an
    /// empty, oversized, or truncated buffer. Rows may be padded (`bytesPerRow`).
    public static func analyze(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> RegionColors? {
        guard width > 0, height > 0, width <= maxPixels / height, bytesPerRow >= width * 4,
              bytes.count >= (height - 1) * bytesPerRow + width * 4 else { return nil }
        let px = bytes.bindMemory(to: UInt8.self)
        let bands = letterbox(px, width: width, height: height, bytesPerRow: bytesPerRow)
        let x0 = bands.left, x1 = width - bands.right, y0 = bands.top, y1 = height - bands.bottom
        let iw = Double(x1 - x0), ih = Double(y1 - y0)
        let lx = Double(x0) + iw / 3, rx = Double(x0) + 2 * iw / 3, ty = Double(y0) + ih / 3, by = Double(y0) + 2 * ih / 3
        var sums = [ScreenRegion: (Double, Double, Double, Int)]()
        for region in ScreenRegion.allCases { sums[region] = (0, 0, 0, 0) }
        func add(_ region: ScreenRegion, _ r: Double, _ g: Double, _ b: Double) {
            let s = sums[region]!; sums[region] = (s.0 + r, s.1 + g, s.2 + b, s.3 + 1)
        }
        for y in y0..<y1 {
            let row = y * bytesPerRow
            for x in x0..<x1 {
                let o = row + x * 4
                let r = linearTable[Int(px[o + 2])], g = linearTable[Int(px[o + 1])], b = linearTable[Int(px[o])]
                add(.full, r, g, b)
                if Double(x) < lx { add(.left, r, g, b) }
                if Double(x) >= rx { add(.right, r, g, b) }
                if Double(y) < ty { add(.top, r, g, b) }
                if Double(y) >= by { add(.bottom, r, g, b) }
            }
        }
        var result = RegionColors(all: .black)
        for (region, s) in sums where s.3 > 0 { result[region] = LinearColor(s.0 / Double(s.3), s.1 / Double(s.3), s.2 / Double(s.3)) }
        return result
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

    /// Exponential smoothing in linear light.
    public static func smooth(_ previous: LinearColor?, _ next: LinearColor, smoothing: Double) -> LinearColor {
        guard let p = previous else { return next }
        let a = 1 - smoothing
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

    public init(settings: ScreenSyncSettings = .init()) { self.settings = settings.clamped() }

    public mutating func ingest(_ colors: RegionColors) { target = colors }

    /// `now` is seconds on any monotonic clock. `lights` maps eligible light IDs to regions.
    public mutating func tick(now: Double, lights: [String: ScreenRegion]) -> [StreamUpdate] {
        guard let target else { return [] }
        var next = target
        for region in ScreenRegion.allCases { next[region] = ScreenColorMath.smooth(smoothed?[region], target[region], smoothing: settings.smoothing) }
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
    public mutating func reset() { smoothed = nil; target = nil; lanes.removeAll() }
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
