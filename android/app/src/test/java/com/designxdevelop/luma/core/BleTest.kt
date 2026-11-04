package com.designxdevelop.luma.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vectors from Tests/LumaCoreTests/GoveeBLETests.swift (ha-govee-led-ble @ b845c59 and independent Python crypto). */
class BleTest {
    private fun h(s: String) = BleCrypto.hex(s)
    private fun f(s: String) = GoveeBle.frame(*h(s).map { it.toInt() and 255 }.toIntArray())
    private fun failure(r: BleSession.Failure, block: () -> Unit) = assertEquals(r, assertThrows(BleSession.BleFailure::class.java, block).reason)

    @Test fun commandsAndStatus() {
        assertArrayEquals(f("330101"), GoveeBle.power(true))
        assertArrayEquals(f("33042a"), GoveeBle.brightness(42))
        assertArrayEquals(f("330515010102030000000000ff3f"), GoveeBle.color(1, 2, 3, 0x3FFF))
        assertArrayEquals(f("33050001082a010237"), GoveeBle.videoMode(GoveeBle.VideoSource.Game, false, 42, true, 55))
        assertArrayEquals(f("aa0703"), GoveeBle.Query.Hardware.frame)
        assertThrows(LumaException::class.java) { GoveeBle.brightness(101) }
        assertEquals(GoveeBle.Status.Power(true), GoveeBle.parseStatus(f("aa0101")))
        assertEquals(GoveeBle.Status.ModeStatus(GoveeBle.Mode.Video(GoveeBle.VideoSource.Game, false, 42, true, 55)), GoveeBle.parseStatus(f("aa050001082a010237")))
        assertEquals(GoveeBle.Status.ModeStatus(GoveeBle.Mode.StaticColor(4500)), GoveeBle.parseStatus(f("aa0515011194")))
        assertEquals(GoveeBle.Status.Firmware("1.02.03"), GoveeBle.parseStatus(f("aa06312e30322e3033")))
        assertNull(GoveeBle.parseStatus(f("aa04ff")))
        assertNull(GoveeBle.parseStatus(f("aa0101").copyOf(19) + 0))
        assertArrayEquals(f("3360010101"), GoveeBle.DreamView.setEnabled(true))
        assertEquals(GoveeBle.DreamView.Reading.Sound(true, 79), GoveeBle.DreamView.parse(f("aa600b014f")))
        assertNull(GoveeBle.DreamView.parse(f("aa600c")))
    }

    @Test fun advertisementNameAndProfile() {
        val enc = GoveeBle.Advertisement.parse(byteArrayOf(0x43, 0x88.toByte()) + h("ec00010100"))!!
        assertTrue(enc.supportsEncryption); assertEquals(GoveeBle.Pact(1, 1), enc.pact)
        assertEquals(enc, GoveeBle.Advertisement.fromScan(0x8843, h("ec00010100")))
        assertNull(GoveeBle.Advertisement.parse(byteArrayOf(0x43, 0x88.toByte(), 0xEC.toByte())))
        assertEquals("H6097", GoveeBle.model("Govee_H6097_1A2B")); assertEquals("H66A0", GoveeBle.model("ihoment_h66a0_ABCD"))
        assertEquals("H5075", GoveeBle.model("GVH5075_1234")); assertEquals("H6099", GoveeBle.model("H6099_12AB")); assertNull(GoveeBle.model("Living Room Speaker"))
        assertTrue(BleProfile.resolve("H6097", GoveeBle.Pact(2, 1))!!.supports(BleProfile.Feature.DreamView))
        assertEquals(setOf(BleProfile.Feature.Power, BleProfile.Feature.Brightness), BleProfile.resolve("H6097", null)!!.features)
        assertFalse(BleProfile.resolve("h66a0", null)!!.supports(BleProfile.Feature.VideoMode))
        assertNull(BleProfile.resolve("H6127", null))
    }

    @Test fun selectionTable() {
        val rows = listOf(false to BleSession.Marker.Absent to 0, true to BleSession.Marker.Absent to 1, false to BleSession.Marker.Value(byteArrayOf(1, 0)) to 0,
            true to BleSession.Marker.Value(byteArrayOf(1, 0)) to 1, false to BleSession.Marker.Value(byteArrayOf(1, 1)) to 1, true to BleSession.Marker.Value(byteArrayOf(1, 2)) to 2,
            false to BleSession.Marker.Value(byteArrayOf(2, 2, 0, 1, 2, 3)) to 2, false to BleSession.Marker.Value(byteArrayOf(2, 1, 0, 1, 2, 3)) to 1)
        for ((pair, version) in rows) {
            val s = BleSession()
            s.select(pair.second, pair.first)
            assertEquals(version, s.version)
            if (version == 0) assertArrayEquals(GoveeBle.power(true), s.encode(GoveeBle.power(true))) else failure(BleSession.Failure.NotReady) { s.encode(GoveeBle.power(true)) }
        }
        // Evidence never falls back to plaintext.
        val earlier = BleSession()
        earlier.select(BleSession.Marker.Value(byteArrayOf(1, 2)), false)
        earlier.select(BleSession.Marker.Value(byteArrayOf(1, 0)), false)
        assertEquals(2, earlier.version); assertFalse(earlier.ready)
        val bad = BleSession()
        failure(BleSession.Failure.SelectionFailed) { bad.select(BleSession.Marker.Value(byteArrayOf(3, 1)), false) }
        failure(BleSession.Failure.PreviousSelectionFailed) { bad.select(BleSession.Marker.Absent, false) }
        failure(BleSession.Failure.SelectionFailed) { BleSession().select(BleSession.Marker.ReadFailed, false) }
    }

    @Test fun v1TransformAndHandshake() {
        val key = ByteArray(16) { it.toByte() }
        assertArrayEquals(h("71a5d00cbe4136cf6d8a60dec77d07d8e99c40ca"), BleCrypto.v1(f("330101"), key, true))
        val odd = ByteArray(23) { it.toByte() }
        assertArrayEquals(h("0a940bb5416ef045f1c39458c653ea5af98d52ea53f70f"), BleCrypto.v1(odd, key, true))
        assertArrayEquals(odd, BleCrypto.v1(h("0a940bb5416ef045f1c39458c653ea5af98d52ea53f70f"), key, false))
        val queue = ArrayDeque(listOf(ByteArray(17) { (0x20 + it).toByte() }, ByteArray(17) { 7 }))
        val s = BleSession { n -> queue.removeFirst().also { assertEquals(n, it.size) } }
        s.select(BleSession.Marker.Value(byteArrayOf(1, 1)), false)
        assertArrayEquals(h("a3774dcd1ecce7f1765b45e310b7938e46c17089"), s.startNegotiation(20))
        val second = s.receive(h("4d59159c56527d09941c0344c948c99166e140b9")) as BleSession.Event.Write
        assertEquals(2, BleCrypto.parseV1Handshake(second.bytes)!!.first)
        assertEquals(BleSession.Event.Ignored, s.receive(h("4d59159c56527d09941c0344c948c99166e140b9")))
        assertEquals(BleSession.Event.Ready, s.receive(h("42a3f946a5b02ec277402b74ca634efe66e140ba")))
        assertArrayEquals(h("71a5d00cbe4136cf6d8a60dec77d07d8e99c40ca"), s.encode(GoveeBle.power(true)))
        assertArrayEquals(f("aa0101"), (s.receive(BleCrypto.v1(f("aa0101"), key, true)) as BleSession.Event.Packet).bytes)
        assertEquals(BleSession.Event.Ignored, s.receive(ByteArray(20) { 0x55 }))
    }

    @Test fun v2HandshakeSealAndReplay() {
        val small = BleSession()
        small.select(BleSession.Marker.Value(byteArrayOf(1, 2)), false)
        failure(BleSession.Failure.V2NeedsLargerWrites) { small.startNegotiation(49) }
        val queue = ArrayDeque(listOf(ByteArray(8) { it.toByte() }, ByteArray(12) { it.toByte() }))
        val s = BleSession { queue.removeFirst() }
        s.select(BleSession.Marker.Value(byteArrayOf(1, 2)), false)
        assertArrayEquals(h("e71101000102030405060708090a0b10565850822a740b5ad5601139e0e749919dd22435e3d3643e"), s.startNegotiation(182))
        assertEquals(BleSession.Event.Ready, s.receive(h("e71100000102030405060708090a0b161810c26a344b1a8cdf4c31936cc20b4a34ae46de183aa540ff1ea4205daeac827c80")))
        assertEquals("H6097", s.deviceSKU); assertArrayEquals(h("112233445566"), s.deviceMAC)
        assertArrayEquals(h("000000022703aecf1ecadcfdbfb6ccf9bcbeb3c9fc8b197427a1fac650fa64ae36cb1944f36a8afb"), s.encode(GoveeBle.power(true)))
        val reply = h("000000056146a75887c99b728e89ba890486e4f39373393fa62e1af5d93d75b37b5b0e157988052e")
        assertArrayEquals(f("aa0101"), (s.receive(reply) as BleSession.Event.Packet).bytes)
        assertEquals(BleSession.Event.Ignored, s.receive(reply)); assertEquals(1, s.rejectedFrames)
    }

    @Test fun badHandshakeFailsClosed() {
        val s = BleSession()
        s.select(BleSession.Marker.Absent, true)
        s.startNegotiation(20)
        failure(BleSession.Failure.HandshakeRejected) { s.receive(f("aa0101")) }
        assertFalse(s.ready); assertEquals(1, s.requiredVersion)
        failure(BleSession.Failure.NotReady) { s.encode(GoveeBle.power(true)) }
    }
}
