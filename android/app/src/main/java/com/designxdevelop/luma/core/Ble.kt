package com.designxdevelop.luma.core

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Govee's Bluetooth LE light protocol (port of GoveeBLE.swift). Every frame, profile rule and
 * vector comes from teh-hippo/ha-govee-led-ble @ b845c59, as on iOS: nothing is guessed.
 */
object GoveeBle {
    const val WRITE_CHAR = "00010203-0405-0607-0809-0a0b0c0d2b11"
    const val NOTIFY_CHAR = "00010203-0405-0607-0809-0a0b0c0d2b10"
    const val ENCRYPTION_CHAR = "00010203-0405-0607-0809-0a0b0c0d2b12"

    fun checksum(bytes: ByteArray, count: Int = bytes.size): Byte { var x = 0; for (i in 0 until count) x = x xor bytes[i].toInt(); return x.toByte() }

    /** 19 content bytes, zero-padded, then their XOR. */
    fun frame(vararg prefix: Int): ByteArray {
        require(prefix.size <= 19)
        val f = ByteArray(20)
        prefix.forEachIndexed { i, b -> f[i] = b.toByte() }
        f[19] = checksum(f, 19)
        return f
    }

    fun isValidFrame(f: ByteArray) = f.size == 20 && checksum(f, 19) == f[19]

    data class Pact(val type: Int, val code: Int)

    data class Advertisement(val flags: Int, val pactType: Int, val pactCode: Int) {
        /** Flag bit 0x40. Its absence is not proof the link is plaintext. */
        val supportsEncryption: Boolean get() = flags and 0x40 != 0
        val pact: Pact get() = Pact(pactType, pactCode)

        companion object {
            /** Company ID little-endian, then the payload (CoreBluetooth's layout): flags, 0x88, 0xEC, pact type (BE16), pact code. */
            fun parse(data: ByteArray): Advertisement? {
                if (data.size < 6 || data[1] != 0x88.toByte() || data[2] != 0xEC.toByte()) return null
                return Advertisement(data[0].toInt() and 255, ((data[3].toInt() and 255) shl 8) or (data[4].toInt() and 255), data[5].toInt() and 255)
            }
            /** Android's ScanRecord splits the company ID off; put it back in front. */
            fun fromScan(companyId: Int, payload: ByteArray) = parse(byteArrayOf((companyId and 255).toByte(), (companyId shr 8).toByte()) + payload)
        }
    }

    private val namePattern = Regex("(?:(?:ihoment|Govee|Minger|GBK|GVH)_(H[0-9A-Z]{4})(?:_|$)|^GVH?([0-9A-Z]{4})(?:_[0-9A-Z]+|[0-9A-Z]{4}|$)$|^(H[0-9A-Z]{4})_[0-9A-Z]+$)", RegexOption.IGNORE_CASE)

    fun model(localName: String): String? {
        val m = namePattern.find(localName) ?: return null
        val raw = (1..3).firstNotNullOfOrNull { m.groups[it]?.value }?.uppercase() ?: return null
        return if (raw.length == 5) raw else "H$raw"
    }

    // ---- Commands (H6099 grammar, shared by H6097 and H66A0) ----

    fun power(on: Boolean) = frame(0x33, 0x01, if (on) 1 else 0)
    fun brightness(percent: Int): ByteArray { if (percent !in 0..100) throw LumaException("Brightness must be 0–100."); return frame(0x33, 0x04, percent) }
    fun color(r: Int, g: Int, b: Int, mask: Int) = frame(0x33, 0x05, 0x15, 0x01, r, g, b, 0, 0, 0, 0, 0, mask and 255, (mask shr 8) and 255)

    enum class VideoSource(val raw: Int) { Movie(0), Game(1) }

    fun videoMode(source: VideoSource, wholeScreen: Boolean, saturation: Int, soundEffects: Boolean, softness: Int): ByteArray {
        if (saturation !in 1..100) throw LumaException("Saturation must be 1–100.")
        if (softness !in 0..100) throw LumaException("Softness must be 0–100.")
        return frame(0x33, 0x05, 0x00, source.raw, if (wholeScreen) 0x09 else 0x08, saturation, if (soundEffects) 1 else 0, 0x02, softness)
    }

    enum class Query(val frame: ByteArray) { Power(frame(0xAA, 0x01)), Brightness(frame(0xAA, 0x04)), ColorMode(frame(0xAA, 0x05, 0x01)), Firmware(frame(0xAA, 0x06)), Hardware(frame(0xAA, 0x07, 0x03)) }

    sealed interface Mode {
        data class Video(val source: VideoSource?, val wholeScreen: Boolean?, val saturation: Int, val soundEffects: Boolean, val softness: Int) : Mode
        data class StaticColor(val kelvin: Int) : Mode
        data class Scene(val id: Int) : Mode
        data class Other(val raw: Int) : Mode
    }

    sealed interface Status {
        data class Power(val on: Boolean) : Status
        data class Brightness(val percent: Int) : Status
        data class ModeStatus(val mode: Mode) : Status
        data class Firmware(val version: String) : Status
        data class Hardware(val version: String) : Status
        data class DreamViewStatus(val reading: DreamView.Reading) : Status
    }

    fun parseStatus(f: ByteArray): Status? {
        if (!isValidFrame(f) || f[0] != 0xAA.toByte()) return null
        val d = IntArray(17) { f[it + 2].toInt() and 255 }
        return when (f[1].toInt() and 255) {
            0x01 -> Status.Power(d[0] != 0)
            0x04 -> if (d[0] <= 100) Status.Brightness(d[0]) else null
            0x06 -> Status.Firmware(ascii(d.toList()))
            0x07 -> if (d[0] == 3) Status.Hardware(ascii(d.drop(1))) else null
            0x05 -> Status.ModeStatus(when (d[0]) {
                0x00 -> Mode.Video(VideoSource.entries.firstOrNull { it.raw == d[1] }, when (d[2]) { 9 -> true; 8 -> false; else -> null }, d[3], d[4] != 0, d[6])
                0x15 -> Mode.StaticColor((d[2] shl 8) or d[3])
                0x04 -> Mode.Scene(d[1] or (d[2] shl 8))
                else -> Mode.Other(d[0])
            })
            0x60 -> DreamView.parse(f)?.let(Status::DreamViewStatus)
            else -> null
        }
    }

    private fun ascii(bytes: List<Int>) = bytes.takeWhile { it != 0 }.filter { it in 0x20 until 0x7F }.map { it.toChar() }.joinToString("")

    /** The controller's DreamView module 0x60. Group membership is never read or written. */
    object DreamView {
        enum class Setting(val raw: Int) { SwitchGroup(0x01), MemberBrightness(0x03), SameBrightness(0x04), MemberConnect(0x05), Saturation(0x09), VideoSettings(0x0A), Sound(0x0B) }

        sealed interface Reading {
            data class Enabled(val on: Boolean) : Reading
            data class MemberBrightness(val raw: List<Int>) : Reading
            data class SameBrightness(val on: Boolean) : Reading
            data class MemberConnect(val raw: List<Int>) : Reading
            data class Saturation(val value: Int) : Reading
            data class VideoSettings(val applyArea: Int, val contentMode: Int) : Reading
            data class Sound(val enabled: Boolean, val softness: Int) : Reading
        }

        fun query(s: Setting) = if (s == Setting.SwitchGroup) frame(0xAA, 0x60, s.raw, 1) else frame(0xAA, 0x60, s.raw)

        fun parse(f: ByteArray): Reading? {
            if (!isValidFrame(f) || f[0] != 0xAA.toByte() || f[1] != 0x60.toByte()) return null
            val s = Setting.entries.firstOrNull { it.raw == (f[2].toInt() and 255) } ?: return null
            val b = List(16) { f[it + 3].toInt() and 255 }
            return when (s) {
                Setting.SwitchGroup -> Reading.Enabled(b[0] != 0)
                Setting.MemberBrightness -> Reading.MemberBrightness(b)
                Setting.SameBrightness -> Reading.SameBrightness(b[0] != 0)
                Setting.MemberConnect -> Reading.MemberConnect(b.take(10))
                Setting.Saturation -> Reading.Saturation(b[0])
                Setting.VideoSettings -> Reading.VideoSettings(b[0], b[1])
                Setting.Sound -> Reading.Sound(b[0] != 0, b[1])
            }
        }

        fun setEnabled(on: Boolean) = frame(0x33, 0x60, 0x01, if (on) 1 else 0, 1)
        fun setSaturation(v: Int): ByteArray { if (v !in 0..100) throw LumaException("Saturation must be 0–100."); return frame(0x33, 0x60, 0x09, v) }
        fun setVideo(wholeScreen: Boolean, movie: Boolean) = frame(0x33, 0x60, 0x0A, if (wholeScreen) 0 else 1, if (movie) 1 else 0)
    }
}

/** What Luma may do over Bluetooth for one model and revision (GoveeBLEProfile in Swift). */
data class BleProfile(val model: String, val name: String, val features: Set<Feature>, val wholeMask: Int, val dreamViewMemberLimit: Int, val limitation: String? = null) {
    enum class Feature { Power, Brightness, Color, VideoMode, HardwareQuery, DreamView }
    fun supports(f: Feature) = f in features

    companion object {
        private val full = Feature.entries.toSet()
        fun resolve(model: String, pact: GoveeBle.Pact?): BleProfile? = when (model.uppercase()) {
            "H6097" -> if (pact in listOf(GoveeBle.Pact(1, 1), GoveeBle.Pact(2, 1))) BleProfile("H6097", "TV Backlight 3 Lite", full, 0x3FFF, 7)
                else BleProfile("H6097", "TV Backlight 3 Lite", setOf(Feature.Power, Feature.Brightness), 0x3FFF, 7,
                    if (pact == null) "Revision not advertised yet: power and brightness only." else "Unrecognised revision: power and brightness only.")
            "H6099" -> BleProfile("H6099", "TV Backlight 3 Lite", full, 0x3FFF, 7)
            "H66A0" -> BleProfile("H66A0", "TV Backlight 3 Pro", setOf(Feature.Power, Feature.Brightness, Feature.Color, Feature.DreamView), 0x3FFF, 10)
            else -> null
        }
    }
}

/** Govee's link encryption (GoveeBLECrypto.swift): V1 AES-ECB with an RC4 tail, V2 AES-GCM with a per-device key. */
object BleCrypto {
    // Vendor-global constants shipped in every Govee Home install, not per-device secrets.
    val communicationKey = hex("4d616b696e674c696665536d61727465")
    private val handshakeKey = hex("fc03783c7c42cb83e202a1643648aff6")
    private val deviceKey = hex("ae028b630bae6ecc4bff1b249e22f955")
    const val TAG = 16
    const val MIN_V2_WRITE = 50

    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    fun v1(data: ByteArray, key: ByteArray, encrypt: Boolean): ByteArray {
        val boundary = data.size / 16 * 16
        val head = if (boundary == 0) ByteArray(0) else Cipher.getInstance("AES/ECB/NoPadding").run {
            init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES")); doFinal(data, 0, boundary)
        }
        val tail = if (boundary == data.size) ByteArray(0) else rc4(data.copyOfRange(boundary, data.size), key)
        return head + tail
    }

    /** RC4 is symmetric; implemented here because not every Android provider ships ARCFOUR. */
    private fun rc4(data: ByteArray, key: ByteArray): ByteArray {
        val s = IntArray(256) { it }
        var j = 0
        for (i in 0 until 256) { j = (j + s[i] + (key[i % key.size].toInt() and 255)) and 255; val t = s[i]; s[i] = s[j]; s[j] = t }
        var i = 0; j = 0
        return ByteArray(data.size) { n ->
            i = (i + 1) and 255; j = (j + s[i]) and 255
            val t = s[i]; s[i] = s[j]; s[j] = t
            (data[n].toInt() xor s[(s[i] + s[j]) and 255]).toByte()
        }
    }

    fun aesEcb(block: ByteArray, key: ByteArray): ByteArray = Cipher.getInstance("AES/ECB/NoPadding").run { init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES")); doFinal(block) }

    fun v1Handshake(opcode: Int, random: ByteArray): ByteArray {
        val body = byteArrayOf(0xE7.toByte(), opcode.toByte()) + random
        return v1(body + GoveeBle.checksum(body), communicationKey, true)
    }

    fun parseV1Handshake(frame: ByteArray): Pair<Int, ByteArray>? {
        if (frame.size != 20) return null
        val plain = v1(frame, communicationKey, false)
        if (plain[0] != 0xE7.toByte() || (plain[1].toInt() != 1 && plain[1].toInt() != 2) || GoveeBle.checksum(plain) != 0.toByte()) return null
        return plain[1].toInt() to plain.copyOfRange(2, 18)
    }

    fun v2Request(clientIV: ByteArray, nonce: ByteArray): ByteArray {
        val header = byteArrayOf(0xE7.toByte(), 0x11, 0x01) + nonce + TAG.toByte()
        return header + gcmSeal(clientIV, handshakeKey, nonce, header)
    }

    data class V2Identity(val deviceIV: ByteArray, val sku: String, val mac: ByteArray, val key: ByteArray)

    fun parseV2Response(frame: ByteArray): V2Identity? {
        if (frame.size != 50 || frame[0] != 0xE7.toByte() || frame[1] != 0x11.toByte() || frame[2] != 0.toByte()) return null
        val plain = runCatching { gcmOpen(frame.copyOfRange(15, 50), handshakeKey, frame.copyOfRange(3, 15), frame.copyOfRange(0, 15)) }.getOrNull() ?: return null
        if (plain.size != 19) return null
        val info = plain.copyOfRange(8, 19)
        return V2Identity(plain.copyOfRange(0, 8), String(plain, 8, 5, Charsets.UTF_8), plain.copyOfRange(13, 19), aesEcb(info + ByteArray(16 - info.size), deviceKey))
    }

    fun seal(plain: ByteArray, iv: ByteArray, key: ByteArray, counter: Long): ByteArray {
        val ctr = byteArrayOf((counter shr 24).toByte(), (counter shr 16).toByte(), (counter shr 8).toByte(), counter.toByte())
        return ctr + gcmSeal(plain, key, iv + ctr, ctr)
    }

    fun unseal(frame: ByteArray, iv: ByteArray, key: ByteArray): Pair<Long, ByteArray>? {
        if (frame.size < 4 + TAG) return null
        val ctr = frame.copyOfRange(0, 4)
        val plain = runCatching { gcmOpen(frame.copyOfRange(4, frame.size), key, iv + ctr, ctr) }.getOrNull() ?: return null
        return ctr.fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 255) } to plain
    }

    private fun gcmSeal(plain: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG * 8, nonce)); updateAAD(aad); doFinal(plain)
    }

    private fun gcmOpen(sealed: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG * 8, nonce)); updateAAD(aad); doFinal(sealed)
    }
}

/**
 * Encryption for one connection, transport-agnostic and fail-closed (GoveeBLESession in Swift):
 * positive encryption evidence (advertised flag, a marker, or an earlier encrypted connection)
 * never falls back to plaintext.
 */
class BleSession(private val random: (Int) -> ByteArray = { n -> ByteArray(n).also(SecureRandom()::nextBytes) }) {
    sealed interface Marker { data object Absent : Marker; data class Value(val bytes: ByteArray) : Marker; data object ReadFailed : Marker }
    enum class Failure { SelectionFailed, PreviousSelectionFailed, NotSelected, NotReady, V2NeedsLargerWrites, HandshakeRejected, CounterExhausted }
    class BleFailure(val reason: Failure) : Exception(reason.name)
    sealed interface Event { data class Write(val bytes: ByteArray) : Event; data object Ready : Event; data class Packet(val bytes: ByteArray) : Event; data object Ignored : Event }

    var version = 0; private set
    var requiredVersion = 0; private set
    var ready = false; private set
    var markerPact: GoveeBle.Pact? = null; private set
    var deviceSKU: String? = null; private set
    var deviceMAC: ByteArray? = null; private set
    var rejectedFrames = 0; private set
    private var selectionFailed = false
    private var awaiting: Int? = null
    private var key: ByteArray? = null
    private var clientIV: ByteArray? = null
    private var deviceIV: ByteArray? = null
    private var counter = 2L
    private var received = 0L
    private var maxWrite = 0

    val encrypted: Boolean get() = ready && version != 0

    /** Forget this connection; the encryption requirement survives. */
    fun reset() { ready = false; markerPact = null; awaiting = null; key = null; clientIV = null; deviceIV = null; counter = 2; received = 0; maxWrite = 0; deviceSKU = null; deviceMAC = null }

    fun select(marker: Marker, advertisedEncryption: Boolean, plaintextEvidence: Boolean = false) {
        reset()
        version = 0
        if (advertisedEncryption && requiredVersion == 0) requiredVersion = 1
        fun fail(r: Failure = Failure.SelectionFailed): Nothing { selectionFailed = true; reset(); throw BleFailure(r) }
        when (marker) {
            Marker.Absent -> {
                if (selectionFailed) fail(Failure.PreviousSelectionFailed)
                version = if (requiredVersion != 0) requiredVersion else if (advertisedEncryption) 1 else 0
            }
            is Marker.Value -> {
                val parsed = parseMarker(marker.bytes)
                if (parsed == null) {
                    if (!plaintextEvidence || advertisedEncryption || requiredVersion != 0) fail()
                    selectionFailed = false; ready = true; return
                }
                version = if (parsed.first != 0) parsed.first else requiredVersion
                markerPact = parsed.second
                selectionFailed = false
            }
            Marker.ReadFailed -> {
                if (!plaintextEvidence || advertisedEncryption || requiredVersion != 0) fail()
                selectionFailed = false; ready = true; return
            }
        }
        if (version != 0) requiredVersion = version
        ready = version == 0
    }

    /** First handshake frame, or null when the link is plaintext and ready. */
    fun startNegotiation(maxWriteLength: Int): ByteArray? {
        if (ready && version == 0) return null
        maxWrite = maxWriteLength
        return when (version) {
            1 -> { awaiting = 1; BleCrypto.v1Handshake(1, random(17)) }
            2 -> {
                if (maxWriteLength < BleCrypto.MIN_V2_WRITE) { reset(); throw BleFailure(Failure.V2NeedsLargerWrites) }
                val iv = random(8)
                clientIV = iv; awaiting = 0x11
                BleCrypto.v2Request(iv, random(12))
            }
            else -> throw BleFailure(Failure.NotSelected)
        }
    }

    fun receive(frame: ByteArray): Event {
        if (!ready) {
            val expected = awaiting ?: return Event.Ignored
            if (version == 1) {
                val reply = BleCrypto.parseV1Handshake(frame) ?: run { rejectedFrames++; reset(); throw BleFailure(Failure.HandshakeRejected) }
                if (reply.first != expected) { rejectedFrames++; return Event.Ignored } // a duplicate key reply
                if (expected == 1) { key = reply.second; awaiting = 2; return Event.Write(BleCrypto.v1Handshake(2, random(17))) }
                awaiting = null; ready = true
                return Event.Ready
            }
            val id = BleCrypto.parseV2Response(frame) ?: run { rejectedFrames++; reset(); throw BleFailure(Failure.HandshakeRejected) }
            deviceIV = id.deviceIV; key = id.key; deviceSKU = id.sku; deviceMAC = id.mac
            awaiting = null; ready = true
            return Event.Ready
        }
        return when (version) {
            0 -> Event.Packet(frame)
            1 -> {
                val plain = BleCrypto.v1(frame, key ?: throw BleFailure(Failure.NotReady), false)
                if (plain.size != 20 || GoveeBle.checksum(plain) != 0.toByte()) { rejectedFrames++; Event.Ignored } else Event.Packet(plain)
            }
            else -> {
                val opened = BleCrypto.unseal(frame, deviceIV ?: throw BleFailure(Failure.NotReady), key ?: throw BleFailure(Failure.NotReady))
                if (opened == null || opened.first <= received) { rejectedFrames++; Event.Ignored } else { received = opened.first; Event.Packet(opened.second) }
            }
        }
    }

    fun encode(packet: ByteArray): ByteArray {
        if (!ready) throw BleFailure(Failure.NotReady)
        return when (version) {
            0 -> packet
            1 -> BleCrypto.v1(packet, key ?: throw BleFailure(Failure.NotReady), true)
            else -> {
                val k = key ?: throw BleFailure(Failure.NotReady)
                val iv = clientIV ?: throw BleFailure(Failure.NotReady)
                if (packet.size + 20 > maxWrite) throw BleFailure(Failure.V2NeedsLargerWrites)
                if (counter >= 0xFFFFFFFFL) throw BleFailure(Failure.CounterExhausted)
                BleCrypto.seal(packet, iv, k, counter++)
            }
        }
    }

    companion object {
        /** `format version [flag pactType(be16) pactCode if format 2] tail…` */
        fun parseMarker(b: ByteArray): Pair<Int, GoveeBle.Pact?>? {
            if (b.size < 2 || (b[0].toInt() != 1 && b[0].toInt() != 2) || (b[1].toInt() and 255) > 2) return null
            if (b[0].toInt() == 2) {
                if (b.size < 6) return null
                return b[1].toInt() to GoveeBle.Pact(((b[3].toInt() and 255) shl 8) or (b[4].toInt() and 255), b[5].toInt() and 255)
            }
            return b[1].toInt() to null
        }
    }
}
