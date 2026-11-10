package com.designxdevelop.luma.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import kotlin.concurrent.thread
import kotlin.math.round

/** Pure wire helpers for Govee's documented LAN API (port of `LANPacket` in GoveeLAN.swift). */
object LanPacket {
    const val MULTICAST = "239.255.255.250"
    const val SCAN_PORT = 4001
    const val LISTEN_PORT = 4002
    const val CONTROL_PORT = 4003

    data class Status(val power: Boolean, val brightness: Int, val rgb: Int, val kelvin: Int)
    sealed interface Received {
        data class Discovery(val device: LightDevice) : Received
        data class DevStatus(val status: Status) : Received
    }

    fun envelope(command: String, data: JsonObject = JsonObject(emptyMap())): ByteArray =
        buildJsonObject { putJsonObject("msg") { put("cmd", command); put("data", data) } }.toString().toByteArray()

    fun scan() = envelope("scan", buildJsonObject { put("account_topic", "reserve") })
    fun devStatus() = envelope("devStatus")

    fun isUnicastIPv4(ip: String): Boolean {
        val parts = ip.split(".")
        if (parts.size != 4 || parts.any { it.isEmpty() || it.length > 3 || !it.all(Char::isDigit) || it.toInt() > 255 }) return false
        val first = parts[0].toInt()
        return first in 1..223 && first != 127
    }

    fun control(command: CapabilityCommand): ByteArray {
        val n = command.value.num
        if (n == null || !n.isFinite() || round(n) != n || n < 0 || n > 0xFFFFFF) throw LumaException("LAN commands require a valid integer value.")
        val v = n.toInt()
        return when {
            command.type == "devices.capabilities.on_off" && command.instance == "powerSwitch" && v in 0..1 ->
                envelope("turn", buildJsonObject { put("value", v) })
            command.type == "devices.capabilities.range" && command.instance == "brightness" && v in 1..100 ->
                envelope("brightness", buildJsonObject { put("value", v) })
            command.type == "devices.capabilities.color_setting" && command.instance == "colorRgb" ->
                colorwc((v shr 16) and 255, (v shr 8) and 255, v and 255, 0)
            command.type == "devices.capabilities.color_setting" && command.instance == "colorTemperatureK" && v in 2000..9000 ->
                colorwc(0, 0, 0, v)
            else -> throw LumaException("This command or value is not supported by Govee's LAN API. Use cloud control for scenes and advanced capabilities.")
        }
    }

    private fun colorwc(r: Int, g: Int, b: Int, kelvin: Int) = envelope("colorwc", buildJsonObject {
        putJsonObject("color") { put("r", r); put("g", g); put("b", b) }
        put("colorTemInKelvin", kelvin)
    })

    fun parse(data: ByteArray, sourceIP: String): Received {
        if (data.size > 8192 || !isUnicastIPv4(sourceIP)) throw LumaException("Invalid LAN datagram.")
        val root = runCatching { LumaJson.parseToJsonElement(data.decodeToString()) }.getOrNull() ?: throw LumaException("Invalid LAN envelope.")
        val msg = root["msg"]
        val cmd = msg["cmd"].str
        val body = msg["data"]
        if (cmd == null || body == null) throw LumaException("Invalid LAN envelope.")
        return when (cmd) {
            "scan" -> {
                val ip = body["ip"].str
                val id = body["device"].str
                val sku = body["sku"].str
                if (ip != sourceIP || id.isNullOrEmpty() || id.length > 128 || sku.isNullOrEmpty() || sku.length > 32) throw LumaException("Invalid Govee discovery response.")
                Received.Discovery(LightDevice(id = id, sku = sku, name = "Govee $sku", ip = ip))
            }
            "devStatus" -> {
                val power = int(body["onOff"], 0..1)
                val brightness = int(body["brightness"], 0..100)
                val r = int(body["color"]["r"], 0..255)
                val g = int(body["color"]["g"], 0..255)
                val b = int(body["color"]["b"], 0..255)
                val k = int(body["colorTemInKelvin"], 0..9000)
                if (power == null || brightness == null || r == null || g == null || b == null || k == null || (k != 0 && k < 2000)) throw LumaException("Invalid Govee status response.")
                Received.DevStatus(Status(power == 1, brightness, (r shl 16) or (g shl 8) or b, k))
            }
            else -> throw LumaException("Unsupported LAN response.")
        }
    }

    private fun int(value: JsonElement?, range: IntRange): Int? {
        val n = value.num ?: return null
        if (!n.isFinite() || round(n) != n || n < range.first || n > range.last) return null
        return n.toInt()
    }
}

/**
 * UDP transport. A successful send is not a device acknowledgment. The caller holds the
 * Wi-Fi multicast lock; Android drops multicast replies without it.
 */
class GoveeLan(private val onDevice: (LightDevice) -> Unit, private val onError: (String) -> Unit) {
    private var socket: MulticastSocket? = null
    private val knownByIP = java.util.concurrent.ConcurrentHashMap<String, LightDevice>()

    @Synchronized fun start() {
        if (socket != null) return
        val s = MulticastSocket(null as java.net.SocketAddress?).apply {
            reuseAddress = true
            bind(InetSocketAddress(LanPacket.LISTEN_PORT))
            @Suppress("DEPRECATION") joinGroup(InetAddress.getByName(LanPacket.MULTICAST))
            timeToLive = 1
        }
        socket = s
        thread(name = "luma-lan", isDaemon = true) { receive(s) }
    }

    fun discover() = send(LanPacket.scan(), LanPacket.MULTICAST, LanPacket.SCAN_PORT)

    fun requestStatus(device: LightDevice) {
        val ip = device.ip?.takeIf(LanPacket::isUnicastIPv4) ?: throw LumaException("This light has no valid LAN address.")
        knownByIP[ip] = device
        send(LanPacket.devStatus(), ip, LanPacket.CONTROL_PORT)
    }

    fun control(device: LightDevice, command: CapabilityCommand) {
        val ip = device.ip?.takeIf(LanPacket::isUnicastIPv4) ?: throw LumaException("This light has no discovered LAN address.")
        val packet = LanPacket.control(command)
        knownByIP[ip] = device
        send(packet, ip, LanPacket.CONTROL_PORT)
    }

    @Synchronized fun stop() { socket?.close(); socket = null; knownByIP.clear() }

    companion object {
        /** One control datagram from a throwaway socket, for runs with no discovery listener (scheduled alarms). */
        fun sendOnce(device: LightDevice, command: CapabilityCommand) {
            val ip = device.ip?.takeIf(LanPacket::isUnicastIPv4) ?: throw LumaException("This light has no discovered LAN address.")
            val packet = LanPacket.control(command)
            java.net.DatagramSocket().use { it.send(DatagramPacket(packet, packet.size, InetAddress.getByName(ip), LanPacket.CONTROL_PORT)) }
        }
    }

    private fun send(data: ByteArray, ip: String, port: Int) {
        val s = socket ?: throw LumaException("Start LAN discovery first.")
        s.send(DatagramPacket(data, data.size, InetAddress.getByName(ip), port))
    }

    private fun receive(s: MulticastSocket) {
        val buffer = ByteArray(8193)
        while (!s.isClosed) {
            val packet = DatagramPacket(buffer, buffer.size)
            try { s.receive(packet) } catch (e: Exception) {
                if (!s.isClosed) onError("Could not receive Govee UDP packet: ${e.message}")
                // Drop the dead socket (unless stop/start already replaced it) so the next start() opens a new one.
                synchronized(this) { if (socket === s) { s.close(); socket = null } }
                return
            }
            if (packet.length !in 1..8192) continue
            val ip = packet.address.hostAddress ?: continue
            val received = runCatching { LanPacket.parse(packet.data.copyOf(packet.length), ip) }.getOrNull() ?: continue
            when (received) {
                is LanPacket.Received.Discovery -> {
                    val known = knownByIP[ip]?.takeIf { it.id.equals(received.device.id, ignoreCase = true) }
                    val light = (known ?: received.device).copy(ip = ip, online = true, lastSeen = System.currentTimeMillis())
                    knownByIP[ip] = light
                    onDevice(light)
                    // Discovery alone carries no state; ask for it separately.
                    runCatching { send(LanPacket.devStatus(), ip, LanPacket.CONTROL_PORT) }.onFailure { onError(it.message ?: "LAN error") }
                }
                is LanPacket.Received.DevStatus -> {
                    val st = received.status
                    val light = knownByIP[ip]?.copy(power = st.power, brightness = st.brightness, rgb = st.rgb, colorTemperature = st.kelvin,
                        online = true, lastSeen = System.currentTimeMillis()) ?: continue
                    knownByIP[ip] = light
                    onDevice(light)
                }
            }
        }
    }
}

