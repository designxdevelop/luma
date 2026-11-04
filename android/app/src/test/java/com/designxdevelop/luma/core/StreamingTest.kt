package com.designxdevelop.luma.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/** Vectors from Tests/LumaCoreTests/AudioReactiveTests.swift and ScreenSyncMathTests.swift ("desktop" ones come from the TS). */
class StreamingTest {
    private fun lv(level: Double, bands: List<Double> = List(8) { 0.0 }) = AudioLevels.of(level, bands.toDoubleArray())!!

    @Test fun audioMapperMatchesDesktopVectors() {
        val seq = listOf(0.9 to listOf(0.9, 0.6, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0), 0.9 to listOf(0.9, 0.6, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0),
            0.3 to listOf(0.0, 0.0, 0.0, 0.0, 0.2, 0.5, 0.7, 0.4), 0.05 to List(8) { 0.0 }, 0.7 to listOf(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8))
        fun run(style: AudioStyle, count: Int, cap: Double, smoothing: Double): List<List<List<Int>>> {
            val m = AudioMapper()
            return seq.map { (l, b) -> m.step(lv(l, b), count, StreamSettings(brightnessCap = cap, smoothing = smoothing), style, 1.2, 0.05).map { listOf(it.rgb, it.brightness) } }
        }
        assertEquals(listOf(listOf(listOf(16744704, 56), listOf(16744704, 56)), listOf(listOf(16744704, 71), listOf(16744704, 71)), listOf(listOf(16767744, 69), listOf(16767744, 69)),
            listOf(listOf(16767744, 65), listOf(16767744, 65)), listOf(listOf(15531776, 72), listOf(15531776, 72))), run(AudioStyle.Pulse, 2, 80.0, 0.4))
        assertEquals(listOf(listOf(listOf(16711680, 42), listOf(65322, 12), listOf(5570815, 12)), listOf(listOf(16711680, 54), listOf(65322, 12), listOf(5570815, 12)),
            listOf(listOf(16711680, 46), listOf(65322, 20), listOf(5570815, 42)), listOf(listOf(16711680, 40), listOf(65322, 19), listOf(5570815, 37)),
            listOf(listOf(16711680, 35), listOf(65322, 45), listOf(5570815, 51))), run(AudioStyle.Spectrum, 3, 60.0, 0.0))
    }

    @Test fun bandsLoudnessAndSpectrumMatchDesktop() {
        val db = FloatArray(1024) { Float.NEGATIVE_INFINITY }
        db[3] = -20f; db[200] = -35f
        val desktop = listOf(0.9569957149051456, 0.0, 0.0, 0.0, 0.0, 0.0, 0.4670787255173894, 0.0)
        AudioReactive.bandLevels(db, 48_000.0).zip(desktop).forEach { (a, b) -> assertTrue("$a vs $b", abs(a - b) < 1e-9) }
        val sine = FloatArray(2048) { (0.5 * sin(2 * PI * 440 * it / 48_000)).toFloat() }
        assertTrue(abs(AudioReactive.rmsLevel(sine) - 0.8495389755675116) < 1e-6)
        assertNull(AudioLevels.of(1.1, DoubleArray(8)))
        for ((hz, band) in listOf(60.0 to 0, 1500.0 to 4, 5000.0 to 6)) {
            val levels = AudioSpectrum.levels(FloatArray(AudioSpectrum.SIZE) { (0.8 * sin(2 * PI * hz * it / 48_000)).toFloat() }, 48_000.0)!!
            assertEquals("$hz Hz", band, levels.bands.indices.maxBy { levels.bands[it] })
            assertTrue(levels.bands[band] > 0.6); assertTrue(levels.level > 0.9)
        }
        assertEquals(0.0, AudioSpectrum.levels(FloatArray(AudioSpectrum.SIZE), 48_000.0)!!.level, 0.0)
        assertEquals(0x5500FF, AudioReactive.hueToRGB(260.0)); assertEquals(0xFF0000, AudioReactive.hueToRGB(0.0))
    }

    @Test fun mixerTargetsKeepRateCapDeadBandAndCap() {
        val m = StreamMixer(StreamSettings(brightnessCap = 60.0, updateHz = 2.0))
        val red = LightTarget(0xFF0000, 50)
        assertEquals(listOf(StreamUpdate("a", red, true, true)), m.tickTargets(0.0, mapOf("a" to red)))
        assertTrue(m.tickTargets(0.1, mapOf("a" to LightTarget(0x00FF00, 50))).isEmpty())
        assertTrue(m.tickTargets(0.2, mapOf("a" to LightTarget(0x0000FF, 50))).isEmpty())
        assertEquals(1, m.superseded)
        assertTrue(m.tickTargets(0.6, mapOf("a" to LightTarget(0xFF0000, 51))).isEmpty()) // dead band
        assertEquals(listOf(StreamUpdate("a", LightTarget(0xFF0000, 30), false, true)), m.tickTargets(0.7, mapOf("a" to LightTarget(0xFF0000, 30))))
        assertEquals(60, m.tickTargets(2.0, mapOf("b" to LightTarget(0xFF0000, 99))).first().target.brightness)
    }

    @Test fun loweredCapOverridesDeadBand() {
        val m = StreamMixer()
        m.ingest(ScreenRegion.entries.associateWith { LinearColor(1.0, 1.0, 1.0) })
        assertEquals(80, m.tick(0.0, mapOf("lamp" to ScreenRegion.Full)).single().target.brightness)
        m.settings = m.settings.copy(brightnessCap = 79.0)
        assertTrue(m.tick(0.1, mapOf("lamp" to ScreenRegion.Full)).isEmpty())
        val u = m.tick(0.5, mapOf("lamp" to ScreenRegion.Full)).single()
        assertEquals(79, u.target.brightness); assertTrue(u.sendsBrightness && !u.sendsColor)
    }

    @Test fun letterboxBarsAreCropped() {
        val red = 0xFFFF0000.toInt(); val blue = 0xFF0000FF.toInt(); val gray = 0xFF808080.toInt(); val black = 0xFF000000.toInt()
        fun content(x: Int) = if (x < 54) red else if (x >= 107) blue else gray
        val boxed = ScreenColorMath.analyze(IntArray(160 * 90) { i -> val x = i % 160; val y = i / 160; if (y < 10 || y >= 80) black else content(x) }, 160, 90)!!.colors(0.15, false)
        val bare = ScreenColorMath.analyze(IntArray(160 * 70) { content(it % 160) }, 160, 70)!!.colors(0.15, false)
        for (r in ScreenRegion.entries) { val a = boxed.getValue(r); val b = bare.getValue(r); assertTrue("$r", abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9) }
        assertEquals(LinearColor(1.0, 0.0, 0.0), boxed[ScreenRegion.Left])
        assertEquals(LightTarget(0xFFFFFF, 1), ScreenColorMath.target(LinearColor.BLACK, 80.0))
        assertNull(ScreenColorMath.analyze(IntArray(4), 0, 1))
    }
}
