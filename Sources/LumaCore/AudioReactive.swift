import Foundation
import Accelerate

// Audio Sync math, a port of desktop/src/shared/audio-math.ts with the same constants,
// rounding and test vectors, so Mac and Windows/Linux react to the same music the same way.
//
// Captured audio is reduced to one loudness value and 8 log-spaced band levels (0…1). Those
// map to per-light color and brightness through a noise gate, slow automatic gain, a floor
// under the brightness cap, and a fast-attack / slow-release envelope that keeps full-depth
// swings well under 3 per second. No samples are kept.

public struct AudioLevels: Equatable, Sendable {
    public static let bandCount = 8
    public let level: Double
    public let bands: [Double]
    /// Nil unless there are exactly 8 bands and every value is finite in 0…1.
    public init?(level: Double, bands: [Double]) {
        let ok = { (v: Double) in v.isFinite && v >= 0 && v <= 1 }
        guard ok(level), bands.count == Self.bandCount, bands.allSatisfy(ok) else { return nil }
        self.level = level; self.bands = bands
    }
}

public struct AudioSyncOptions: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable { case pulse, spectrum }
    public static let sensitivityRange = 0.5...2.0
    public var style: Style = .pulse
    /// Gain after automatic level adjustment, 0.5…2.
    public var sensitivity: Double = 1
    public init(style: Style = .pulse, sensitivity: Double = 1) { self.style = style; self.sensitivity = sensitivity }
}

public enum AudioReactive {
    /// Band edges in Hz: 40 Hz … 16 kHz, log spaced (bass → treble).
    public static let edgesHz: [Double] = (0...AudioLevels.bandCount).map { 40 * pow(400, Double($0) / Double(AudioLevels.bandCount)) }
    public static let gate = 0.08, floorShare = 0.2, attackS = 0.05, releaseMinS = 0.25, releaseMaxS = 1.2
    public static let agcHalfLifeS = 4.0, agcMinPeak = 0.35, hueS = 0.4, hueSpan = 260.0
    public static let bandDB = (-90.0, -20.0), levelDB = (-60.0, 0.0)

    static func clamp01(_ v: Double) -> Double { v > 0 ? (v < 1 ? v : 1) : 0 }

    /// RMS of samples (−1…1) as 0…1 over −60…0 dBFS. Silence and non-finite input give 0.
    public static func rmsLevel(_ samples: [Float]) -> Double {
        var sum = 0.0, n = 0
        for s in samples where s.isFinite { sum += Double(s) * Double(s); n += 1 }
        guard n > 0, sum > 0 else { return 0 }
        return clamp01((10 * log10(sum / Double(n)) - levelDB.0) / (levelDB.1 - levelDB.0))
    }

    /// Per-bin dBFS (bin k at k·sampleRate/(2·bins)) to 8 band levels, the same as the desktop's
    /// AnalyserNode path: mean power of the bins in each band, in dB, mapped over −90…−20.
    public static func bandLevels(db: [Float], sampleRate: Double) -> [Double] {
        let bins = db.count, hzPerBin = sampleRate / Double(2 * bins)
        guard bins > 1 else { return Array(repeating: 0, count: AudioLevels.bandCount) }
        func power(_ v: Float) -> Double { v.isFinite ? pow(10, Double(v) / 10) : 0 }
        return (0..<AudioLevels.bandCount).map { b in
            let lo = max(1, Int((edgesHz[b] / hzPerBin).rounded(.up))), hi = min(bins - 1, Int((edgesHz[b + 1] / hzPerBin).rounded(.up)) - 1)
            var p = 0.0, n = 0
            if lo <= hi { for k in lo...hi { p += power(db[k]); n += 1 } }
            if n == 0 { p = power(db[min(bins - 1, max(1, Int((edgesHz[b] / hzPerBin).rounded())))]); n = 1 }
            guard p > 0 else { return 0 }
            return clamp01((10 * log10(p / Double(n)) - bandDB.0) / (bandDB.1 - bandDB.0))
        }
    }

    /// Full-saturation hue (degrees) as 0xRRGGBB.
    public static func hueToRGB(_ hue: Double) -> Int {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = Int((255 * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))).rounded())
        let (r, g, b) = h < 1 ? (255, x, 0) : h < 2 ? (x, 255, 0) : h < 3 ? (0, 255, x) : h < 4 ? (0, x, 255) : h < 5 ? (x, 0, 255) : (255, 0, x)
        return (r << 16) | (g << 8) | b
    }

    /// floor…cap in whole percents, both ≥ 1.
    public static func brightnessRange(cap brightnessCap: Double) -> ClosedRange<Int> {
        let cap = max(1, min(100, Int((brightnessCap.isFinite ? brightnessCap : 1).rounded())))
        return max(1, Int((Double(cap) * floorShare).rounded()))...cap
    }
}

/// Stateful mapping from analysis frames to light targets (pulse or spectrum).
public struct AudioMapper: Sendable {
    private var peak = AudioReactive.agcMinPeak
    private var bandPeaks = Array(repeating: AudioReactive.agcMinPeak, count: AudioLevels.bandCount)
    private var env: [Double] = []
    private var hue: [Double?] = []

    public init() {}

    public mutating func step(_ levels: AudioLevels, count: Int, settings: ScreenSyncSettings, options: AudioSyncOptions, dt: Double = 0.05) -> [LightTarget] {
        typealias A = AudioReactive
        let dt = max(0.001, min(1, dt.isFinite ? dt : 0.05))
        let decay = pow(0.5, dt / A.agcHalfLifeS)
        let gain = max(AudioSyncOptions.sensitivityRange.lowerBound, min(AudioSyncOptions.sensitivityRange.upperBound, options.sensitivity))
        func norm(_ v: Double, _ peak: Double) -> Double { v < A.gate ? 0 : A.clamp01((v - A.gate) / max(1e-3, peak - A.gate) * gain) }
        peak = max(A.agcMinPeak, levels.level, peak * decay)
        let loud = norm(levels.level, peak)
        var bands = [Double]()
        for (i, v) in levels.bands.enumerated() { bandPeaks[i] = max(A.agcMinPeak, v, bandPeaks[i] * decay); bands.append(norm(v, bandPeaks[i])) }
        let total = bands.reduce(0, +)
        let weighted = bands.enumerated().reduce(0.0) { $0 + $1.element * Double($1.offset) }
        let balanceHue: Double? = total > 1e-3 ? weighted / total / Double(AudioLevels.bandCount - 1) * A.hueSpan : nil

        let smoothing = max(0, min(0.95, settings.smoothing)) / 0.95
        let release = 1 - exp(-dt / (A.releaseMinS + smoothing * (A.releaseMaxS - A.releaseMinS)))
        let attack = 1 - exp(-dt / A.attackS), hueStep = 1 - exp(-dt / A.hueS)
        let range = A.brightnessRange(cap: settings.brightnessCap), floor = range.lowerBound, cap = range.upperBound
        let n = max(0, count)
        if env.count != n { env = Array(env.prefix(n)) + Array(repeating: 0, count: max(0, n - env.count)) }
        if hue.count != n { hue = Array(hue.prefix(n)) + Array(repeating: nil, count: max(0, n - hue.count)) }

        var out: [LightTarget] = []
        for i in 0..<n {
            var energy = loud, hueTarget = balanceHue
            if options.style == .spectrum && n > 1 {
                let p = Double(i) / Double(n - 1) * Double(AudioLevels.bandCount - 1)
                let lo = Int(p), hi = min(AudioLevels.bandCount - 1, lo + 1), f = p - Double(lo)
                energy = bands[lo] * (1 - f) + bands[hi] * f
                hueTarget = p / Double(AudioLevels.bandCount - 1) * A.hueSpan
            }
            env[i] += (energy > env[i] ? attack : release) * (energy - env[i])
            if let target = hueTarget { hue[i] = hue[i].map { $0 + hueStep * (target - $0) } ?? target }
            let b = Int((Double(floor) + Double(cap - floor) * env[i]).rounded())
            out.append(LightTarget(rgb: A.hueToRGB(hue[i] ?? 0), brightness: max(floor, min(cap, b))))
        }
        return out
    }

    /// Forgets envelopes and color (pause); gain memory is kept.
    public mutating func reset() { env = []; hue = [] }
}

/// Mono PCM → AudioLevels with a Blackman-windowed 2048-point FFT, scaled like Web Audio's
/// AnalyserNode (|X[k]| / N in dBFS), so band levels match the desktop analysis.
public final class AudioSpectrum: @unchecked Sendable {
    public static let size = 2048
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    public init?() {
        guard let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .blackman, count: Self.size, isHalfWindow: false)
    }

    /// `samples` must hold exactly `size` mono samples.
    public func levels(_ samples: [Float], sampleRate: Double) -> AudioLevels? {
        guard samples.count == Self.size, sampleRate > 0 else { return nil }
        let windowed = vDSP.multiply(samples, window)
        let half = Self.size / 2
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var db = [Float](repeating: -.infinity, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                // zrip output is 2× the DFT; bin 0 packs DC and Nyquist and is skipped by bandLevels.
                for k in 1..<half {
                    let mag = (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot() / 2 / Float(Self.size)
                    db[k] = mag > 0 ? 20 * log10(mag) : -.infinity
                }
            }
        }
        return AudioLevels(level: AudioReactive.rmsLevel(samples), bands: AudioReactive.bandLevels(db: db, sampleRate: sampleRate))
    }
}
