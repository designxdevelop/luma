package com.designxdevelop.luma.core

import kotlinx.serialization.Serializable
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

// Screen Sync and Audio Sync math: ports of ScreenSync.swift and AudioReactive.swift (themselves
// ports of the desktop's TypeScript), same constants and rounding, so every client reacts alike.

enum class ScreenRegion(val title: String) {
    Full("Whole picture"), Left("Left third"), Right("Right third"), Top("Top third"), Bottom("Bottom third"),
    EdgeLeft("Left edge"), EdgeRight("Right edge"), EdgeTop("Top edge"), EdgeBottom("Bottom edge"),
    CornerTopLeft("Top-left corner"), CornerTopRight("Top-right corner"), CornerBottomLeft("Bottom-left corner"), CornerBottomRight("Bottom-right corner");

    /** x0, x1, y0 (top), y1 as fractions of the cropped picture; edges and corners are [d] deep. */
    fun rect(d: Double): DoubleArray {
        val t = 1.0 / 3
        val n = 1 - d
        return when (this) {
            Full -> doubleArrayOf(0.0, 1.0, 0.0, 1.0)
            Left -> doubleArrayOf(0.0, t, 0.0, 1.0); Right -> doubleArrayOf(1 - t, 1.0, 0.0, 1.0)
            Top -> doubleArrayOf(0.0, 1.0, 0.0, t); Bottom -> doubleArrayOf(0.0, 1.0, 1 - t, 1.0)
            EdgeLeft -> doubleArrayOf(0.0, d, 0.0, 1.0); EdgeRight -> doubleArrayOf(n, 1.0, 0.0, 1.0)
            EdgeTop -> doubleArrayOf(0.0, 1.0, 0.0, d); EdgeBottom -> doubleArrayOf(0.0, 1.0, n, 1.0)
            CornerTopLeft -> doubleArrayOf(0.0, d, 0.0, d); CornerTopRight -> doubleArrayOf(n, 1.0, 0.0, d)
            CornerBottomLeft -> doubleArrayOf(0.0, d, n, 1.0); CornerBottomRight -> doubleArrayOf(n, 1.0, n, 1.0)
        }
    }
}

data class LinearColor(val r: Double, val g: Double, val b: Double) { companion object { val BLACK = LinearColor(0.0, 0.0, 0.0) } }

/** A frame reduced to a coarse grid; each cell holds count, linear r g b, vivid weight, weight × r g b. */
class ScreenGrid(val columns: Int, val rows: Int, val cells: DoubleArray) {
    fun color(region: ScreenRegion, depth: Double, vivid: Boolean): LinearColor {
        val r = region.rect(depth)
        val s = DoubleArray(8)
        for (y in span(r[2], r[3], rows)) for (x in span(r[0], r[1], columns)) {
            val o = (y * columns + x) * 8
            for (i in 0 until 8) s[i] += cells[o + i]
        }
        val n = if (vivid) s[4] else s[0]
        val base = if (vivid) 5 else 1
        return if (n > 0) LinearColor(s[base] / n, s[base + 1] / n, s[base + 2] / n) else LinearColor.BLACK
    }

    fun colors(depth: Double, vivid: Boolean) = ScreenRegion.entries.associateWith { color(it, depth, vivid) }

    companion object {
        const val MAX_COLUMNS = 30
        const val MAX_ROWS = 18
        fun uniform(c: LinearColor, weight: Double = 1.0) = ScreenGrid(1, 1, doubleArrayOf(1.0, c.r, c.g, c.b, weight, weight * c.r, weight * c.g, weight * c.b))
        fun span(a: Double, b: Double, n: Int): IntRange {
            val lo = min((a * n).roundToInt(), n - 1)
            return lo until max(lo + 1, min((b * n).roundToInt(), n))
        }
    }
}

@Serializable
data class StreamSettings(
    val smoothing: Double = 0.4,
    val threshold: Double = 0.02,
    val brightnessCap: Double = 80.0,
    val updateHz: Double = 5.0,
    val edgeDepth: Double = 0.15,
    val vivid: Boolean = false,
) {
    fun clamped(): StreamSettings {
        val d = StreamSettings()
        fun fit(v: Double, lo: Double, hi: Double, fallback: Double) = if (v.isFinite()) v.coerceIn(lo, hi) else fallback
        return copy(smoothing = fit(smoothing, 0.0, 0.95, d.smoothing), threshold = fit(threshold, 0.005, 0.2, d.threshold),
            brightnessCap = fit(brightnessCap, 1.0, 100.0, d.brightnessCap), updateHz = fit(updateHz, 0.5, 10.0, d.updateHz), edgeDepth = fit(edgeDepth, 0.05, 0.33, d.edgeDepth))
    }
}

data class LightTarget(val rgb: Int, val brightness: Int)
data class StreamUpdate(val deviceID: String, val target: LightTarget, val sendsColor: Boolean, val sendsBrightness: Boolean)

object ScreenColorMath {
    private val linearTable = DoubleArray(256) { i -> val c = i / 255.0; if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4) }
    fun linear(c8: Int) = linearTable[c8]
    fun srgb(l: Double): Double { val c = l.coerceIn(0.0, 1.0); return 255 * (if (c <= 0.0031308) c * 12.92 else 1.055 * c.pow(1 / 2.4) - 0.055) }

    private const val DARK = 24
    private const val BAR_TOLERANCE = 0.02
    private const val MAX_BAR = 0.25
    const val MAX_PIXELS = 1 shl 20
    private const val VIVID_FLOOR = 0.05
    const val SMOOTHING_STEP = 0.1
    const val JUMP_RELEASE = 0.25

    /** Reduces ARGB pixels (Android's Bitmap.getPixels order) to a grid of linear sums with letterbox bars cropped. */
    fun analyze(px: IntArray, width: Int, height: Int): ScreenGrid? {
        if (width <= 0 || height <= 0 || width > MAX_PIXELS / height || px.size < width * height) return null
        val (top, left) = letterbox(px, width, height)
        val iw = width - 2 * left
        val ih = height - 2 * top
        val columns = min(ScreenGrid.MAX_COLUMNS, iw)
        val rows = min(ScreenGrid.MAX_ROWS, ih)
        val cellX = IntArray(iw) { it * columns / iw * 8 }
        val c = DoubleArray(columns * rows * 8)
        for (y in 0 until ih) {
            val row = (top + y) * width + left
            val cellRow = y * rows / ih * columns * 8
            for (x in 0 until iw) {
                val p = px[row + x]
                val r8 = (p shr 16) and 255
                val g8 = (p shr 8) and 255
                val b8 = p and 255
                val r = linearTable[r8]; val g = linearTable[g8]; val b = linearTable[b8]
                val chroma = (maxOf(r8, g8, b8) - minOf(r8, g8, b8)) / 255.0
                val w = VIVID_FLOOR + chroma * chroma
                val i = cellRow + cellX[x]
                c[i] += 1.0; c[i + 1] += r; c[i + 2] += g; c[i + 3] += b
                c[i + 4] += w; c[i + 5] += w * r; c[i + 6] += w * g; c[i + 7] += w * b
            }
        }
        return ScreenGrid(columns, rows, c)
    }

    /** Symmetric black bars (the smaller side wins); an all-dark frame is a dark scene, not bars. Returns (rows, columns). */
    fun letterbox(px: IntArray, width: Int, height: Int): Pair<Int, Int> {
        fun bright(p: Int) = ((p shr 16) and 255) > DARK || ((p shr 8) and 255) > DARK || (p and 255) > DARK
        fun lineDark(start: Int, step: Int, count: Int): Boolean {
            val allowed = (count * BAR_TOLERANCE).toInt()
            var n = 0
            var o = start
            repeat(count) { if (bright(px[o]) && ++n > allowed) return false; o += step }
            return true
        }
        fun rowDark(y: Int) = lineDark(y * width, 1, width)
        fun colDark(x: Int) = lineDark(x, width, height)
        fun scan(dark: (Int) -> Boolean, from: Int, dir: Int, limit: Int): Int { var n = 0; while (n < limit && dark(from + dir * n)) n++; return n }
        if ((0 until height).all(::rowDark)) return 0 to 0
        val maxRows = (height * MAX_BAR).toInt()
        val maxCols = (width * MAX_BAR).toInt()
        val v = min(scan(::rowDark, 0, 1, maxRows), scan(::rowDark, height - 1, -1, maxRows))
        val h = min(scan(::colDark, 0, 1, maxCols), scan(::colDark, width - 1, -1, maxCols))
        return v to h
    }

    fun smooth(previous: LinearColor?, next: LinearColor, smoothing: Double, dt: Double = SMOOTHING_STEP): LinearColor {
        val p = previous ?: return next
        val jump = maxOf(abs(srgb(next.r) - srgb(p.r)), abs(srgb(next.g) - srgb(p.g)), abs(srgb(next.b) - srgb(p.b))) / 255
        val s = smoothing.coerceIn(0.0, 1.0) * max(0.0, 1 - jump / JUMP_RELEASE)
        val a = 1 - s.pow((if (dt.isFinite()) dt else SMOOTHING_STEP).coerceIn(0.001, 1.0) / SMOOTHING_STEP)
        return LinearColor(p.r + a * (next.r - p.r), p.g + a * (next.g - p.g), p.b + a * (next.b - p.b))
    }

    /** Full-saturation hue plus brightness from the brightest channel, scaled by the cap; never below 1%. */
    fun target(color: LinearColor, brightnessCap: Double): LightTarget {
        val cap = (if (brightnessCap.isFinite()) brightnessCap else 80.0).coerceIn(1.0, 100.0).roundToInt()
        val m = maxOf(color.r, color.g, color.b)
        if (!color.r.isFinite() || !color.g.isFinite() || !color.b.isFinite() || m <= 1.0 / 4096) return LightTarget(0xFFFFFF, 1)
        fun c(v: Double) = srgb(v / m).roundToInt()
        val brightness = (cap * srgb(m) / 255).roundToInt().coerceIn(1, cap)
        return LightTarget((c(color.r) shl 16) or (c(color.g) shl 8) or c(color.b), brightness)
    }

    fun exceedsThreshold(previous: LightTarget?, next: LightTarget, threshold: Double): Boolean {
        previous ?: return true
        val dc = listOf(16, 8, 0).maxOf { abs(((previous.rgb shr it) and 255) - ((next.rgb shr it) and 255)) }
        return dc >= max(1.0, threshold * 255) || abs(previous.brightness - next.brightness) >= max(1.0, threshold * 100)
    }
}

/** Latest-only streaming state: at most one update per light per rate interval; nothing is queued. */
class StreamMixer(settings: StreamSettings = StreamSettings()) {
    var settings: StreamSettings = settings.clamped(); set(value) { field = value.clamped() }
    private var smoothed: Map<ScreenRegion, LinearColor>? = null
    private var target: Map<ScreenRegion, LinearColor>? = null
    private class Lane(val sent: LightTarget, val nextAt: Double, var pending: LightTarget?)
    private val lanes = HashMap<String, Lane>()
    var superseded = 0; private set
    private var lastTick: Double? = null

    fun ingest(colors: Map<ScreenRegion, LinearColor>) { target = colors }

    fun tick(now: Double, lights: Map<String, ScreenRegion>): List<StreamUpdate> {
        val t = target ?: return emptyList()
        val dt = lastTick?.let { now - it } ?: ScreenColorMath.SMOOTHING_STEP
        lastTick = now
        val next = ScreenRegion.entries.associateWith { ScreenColorMath.smooth(smoothed?.get(it), t[it] ?: LinearColor.BLACK, settings.smoothing, dt) }
        smoothed = next
        return lights.toSortedMap().mapNotNull { (id, region) -> route(id, ScreenColorMath.target(next.getValue(region), settings.brightnessCap), now) }
    }

    /** Audio Sync: ready-made targets through the same lanes. */
    fun tickTargets(now: Double, targets: Map<String, LightTarget>): List<StreamUpdate> {
        lastTick = now
        val cap = max(1, settings.brightnessCap.roundToInt())
        return targets.toSortedMap().mapNotNull { (id, t) -> route(id, t.copy(brightness = t.brightness.coerceIn(1, cap)), now) }
    }

    private fun route(id: String, wanted: LightTarget, now: Double): StreamUpdate? {
        val lane = lanes[id]
        if (lane != null && now < lane.nextAt) {
            if (ScreenColorMath.exceedsThreshold(lane.sent, wanted, settings.threshold)) {
                if (lane.pending != null && lane.pending != wanted) superseded++
                lane.pending = wanted
            }
            return null
        }
        // A lowered cap is a hard limit, even within the dead band.
        val exceedsCap = lane != null && lane.sent.brightness > settings.brightnessCap.roundToInt()
        if (!exceedsCap && !ScreenColorMath.exceedsThreshold(lane?.sent, wanted, settings.threshold)) return null
        lanes[id] = Lane(wanted, now + 1 / settings.updateHz, null)
        return StreamUpdate(id, wanted, lane?.sent?.rgb != wanted.rgb, lane?.sent?.brightness != wanted.brightness)
    }

    fun forget(id: String) { lanes.remove(id) }
    fun reset() { smoothed = null; target = null; lastTick = null; lanes.clear() }
}

/** Why a light can't stream right now, or null. Streaming needs LAN control and never powers a light on or off. */
fun LightDevice.streamIssue(): String? = when {
    !isLight -> "Not a light"
    isDemo -> null
    ip == null -> "Not found on Wi-Fi. Sync needs local (LAN) control."
    online == false -> "Offline"
    power == null -> "Waiting for status"
    power == false -> "Off. Turn it on to include it."
    else -> null
}

// ---- Audio ----

class AudioLevels private constructor(val level: Double, val bands: DoubleArray) {
    companion object {
        const val BANDS = 8
        fun of(level: Double, bands: DoubleArray): AudioLevels? {
            fun ok(v: Double) = v.isFinite() && v in 0.0..1.0
            return if (ok(level) && bands.size == BANDS && bands.all(::ok)) AudioLevels(level, bands) else null
        }
    }
}

enum class AudioStyle { Pulse, Spectrum }

object AudioReactive {
    val edgesHz = DoubleArray(AudioLevels.BANDS + 1) { 40 * 400.0.pow(it.toDouble() / AudioLevels.BANDS) }
    const val GATE = 0.08
    const val FLOOR_SHARE = 0.2
    const val ATTACK_S = 0.05
    const val RELEASE_MIN_S = 0.25
    const val RELEASE_MAX_S = 1.2
    const val AGC_HALF_LIFE_S = 4.0
    const val AGC_MIN_PEAK = 0.35
    const val HUE_S = 0.4
    const val HUE_SPAN = 260.0

    fun clamp01(v: Double) = if (v > 0) (if (v < 1) v else 1.0) else 0.0

    /** RMS as 0…1 over −60…0 dBFS. */
    fun rmsLevel(samples: FloatArray): Double {
        var sum = 0.0
        var n = 0
        for (s in samples) if (s.isFinite()) { sum += s.toDouble() * s; n++ }
        if (n == 0 || sum <= 0) return 0.0
        return clamp01((10 * log10(sum / n) + 60) / 60)
    }

    /** Per-bin dBFS to 8 band levels over −90…−20 dB (mean power per band). */
    fun bandLevels(db: FloatArray, sampleRate: Double): DoubleArray {
        val bins = db.size
        val hzPerBin = sampleRate / (2 * bins)
        if (bins <= 1) return DoubleArray(AudioLevels.BANDS)
        fun power(v: Float) = if (v.isFinite()) 10.0.pow(v / 10.0) else 0.0
        return DoubleArray(AudioLevels.BANDS) { b ->
            val lo = max(1, kotlin.math.ceil(edgesHz[b] / hzPerBin).toInt())
            val hi = min(bins - 1, kotlin.math.ceil(edgesHz[b + 1] / hzPerBin).toInt() - 1)
            var p = 0.0
            var n = 0
            if (lo <= hi) for (k in lo..hi) { p += power(db[k]); n++ }
            if (n == 0) { p = power(db[min(bins - 1, max(1, Math.round(edgesHz[b] / hzPerBin).toInt()))]); n = 1 }
            if (p <= 0) 0.0 else clamp01((10 * log10(p / n) + 90) / 70)
        }
    }

    fun hueToRGB(hue: Double): Int {
        val h = ((hue % 360) + 360) % 360 / 60
        val x = (255 * (1 - abs(h % 2 - 1))).roundToInt()
        val (r, g, b) = when { h < 1 -> Triple(255, x, 0); h < 2 -> Triple(x, 255, 0); h < 3 -> Triple(0, 255, x); h < 4 -> Triple(0, x, 255); h < 5 -> Triple(x, 0, 255); else -> Triple(255, 0, x) }
        return (r shl 16) or (g shl 8) or b
    }

    fun brightnessRange(cap: Double): IntRange {
        val c = (if (cap.isFinite()) cap else 1.0).roundToInt().coerceIn(1, 100)
        return max(1, (c * FLOOR_SHARE).roundToInt())..c
    }
}

/** Stateful mapping from analysis frames to light targets (pulse or spectrum). */
class AudioMapper {
    private var peak = AudioReactive.AGC_MIN_PEAK
    private val bandPeaks = DoubleArray(AudioLevels.BANDS) { AudioReactive.AGC_MIN_PEAK }
    private var env = DoubleArray(0)
    private var hue = arrayOfNulls<Double>(0)

    fun step(levels: AudioLevels, count: Int, settings: StreamSettings, style: AudioStyle, sensitivity: Double, dt0: Double = 0.05): List<LightTarget> {
        val a = AudioReactive
        val dt = (if (dt0.isFinite()) dt0 else 0.05).coerceIn(0.001, 1.0)
        val decay = 0.5.pow(dt / a.AGC_HALF_LIFE_S)
        val gain = sensitivity.coerceIn(0.5, 2.0)
        fun norm(v: Double, peak: Double) = if (v < a.GATE) 0.0 else a.clamp01((v - a.GATE) / max(1e-3, peak - a.GATE) * gain)
        peak = maxOf(a.AGC_MIN_PEAK, levels.level, peak * decay)
        val loud = norm(levels.level, peak)
        val bands = DoubleArray(AudioLevels.BANDS) { i -> bandPeaks[i] = maxOf(a.AGC_MIN_PEAK, levels.bands[i], bandPeaks[i] * decay); norm(levels.bands[i], bandPeaks[i]) }
        val total = bands.sum()
        val weighted = bands.withIndex().sumOf { it.value * it.index }
        val balanceHue = if (total > 1e-3) weighted / total / (AudioLevels.BANDS - 1) * a.HUE_SPAN else null
        val smoothing = settings.smoothing.coerceIn(0.0, 0.95) / 0.95
        val release = 1 - exp(-dt / (a.RELEASE_MIN_S + smoothing * (a.RELEASE_MAX_S - a.RELEASE_MIN_S)))
        val attack = 1 - exp(-dt / a.ATTACK_S)
        val hueStep = 1 - exp(-dt / a.HUE_S)
        val range = a.brightnessRange(settings.brightnessCap)
        val n = max(0, count)
        if (env.size != n) env = DoubleArray(n) { env.getOrElse(it) { 0.0 } }
        if (hue.size != n) hue = Array(n) { hue.getOrNull(it) }
        return (0 until n).map { i ->
            var energy = loud
            var hueTarget = balanceHue
            if (style == AudioStyle.Spectrum && n > 1) {
                val p = i.toDouble() / (n - 1) * (AudioLevels.BANDS - 1)
                val lo = p.toInt()
                val hi = min(AudioLevels.BANDS - 1, lo + 1)
                val f = p - lo
                energy = bands[lo] * (1 - f) + bands[hi] * f
                hueTarget = p / (AudioLevels.BANDS - 1) * a.HUE_SPAN
            }
            env[i] += (if (energy > env[i]) attack else release) * (energy - env[i])
            if (hueTarget != null) hue[i] = hue[i]?.let { it + hueStep * (hueTarget - it) } ?: hueTarget
            val b = (range.first + (range.last - range.first) * env[i]).roundToInt()
            LightTarget(a.hueToRGB(hue[i] ?: 0.0), b.coerceIn(range.first, range.last))
        }
    }

    fun reset() { env = DoubleArray(0); hue = arrayOfNulls(0) }
}

/** Mono PCM → AudioLevels with a Blackman-windowed 2048-point FFT scaled like Web Audio's AnalyserNode. */
object AudioSpectrum {
    const val SIZE = 2048
    private val window = DoubleArray(SIZE) { val x = 2 * PI * it / (SIZE - 1); 0.42 - 0.5 * cos(x) + 0.08 * cos(2 * x) }

    fun levels(samples: FloatArray, sampleRate: Double): AudioLevels? {
        if (samples.size != SIZE || sampleRate <= 0) return null
        val re = DoubleArray(SIZE) { samples[it] * window[it] }
        val im = DoubleArray(SIZE)
        fft(re, im)
        val half = SIZE / 2
        val db = FloatArray(half) { Float.NEGATIVE_INFINITY }
        for (k in 1 until half) {
            val mag = sqrt(re[k] * re[k] + im[k] * im[k]) / SIZE
            db[k] = if (mag > 0) (20 * log10(mag)).toFloat() else Float.NEGATIVE_INFINITY
        }
        return AudioLevels.of(AudioReactive.rmsLevel(samples), AudioReactive.bandLevels(db, sampleRate))
    }

    /** In-place iterative radix-2 FFT. */
    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) { var t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t }
        }
        var len = 2
        while (len <= n) {
            val ang = -2 * PI / len
            for (i in 0 until n step len) for (k in 0 until len / 2) {
                val wr = cos(ang * k)
                val wi = kotlin.math.sin(ang * k)
                val ur = re[i + k]; val ui = im[i + k]
                val vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi
                val vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr
                re[i + k] = ur + vr; im[i + k] = ui + vi
                re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
            }
            len = len shl 1
        }
    }

}
