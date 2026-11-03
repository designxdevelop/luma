package com.designxdevelop.luma.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException

/**
 * Govee's capability API (port of GoveeCloud.swift). Requests are serialized and paced:
 * 84 ms per account, 1 s per device, 2 s per repeated read, and Retry-After on 429.
 * Commands are never retried; reads get one retry after a transient transport failure.
 */
class GoveeCloud(apiKey: String, private val transport: Transport = HttpTransport) {
    data class Response(val status: Int, val body: ByteArray, val retryAfter: String? = null)
    fun interface Transport { fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Response }

    private val apiKey = apiKey.trim()
    private val mutex = Mutex()
    private var nextAccount = 0L
    private val nextDevice = HashMap<String, Long>()
    private val nextRead = HashMap<String, Long>()

    suspend fun devices(): List<LightDevice> {
        val rows = request("user/devices")["data"].arr ?: throw LumaException("Govee returned an invalid device list.")
        return rows.map { row ->
            val id = row["device"].str
            val sku = row["sku"].str
            if (id == null || sku == null) throw LumaException("Govee returned a device without an ID or model.")
            val type = row["type"].str?.takeUnless { Readings.isLight(it) || it.length > 128 }
            LightDevice(id = id, sku = sku, name = row["deviceName"].str ?: sku, capabilities = row["capabilities"]?.let(::decodeCapabilities).orEmpty(), deviceType = type)
        }
    }

    /** State plus readable values with no dedicated control. None for offline devices. */
    suspend fun stateAndReadings(device: LightDevice): Pair<LightDevice, List<Readings.Reading>> {
        val payload = request("device/state", device)["payload"]
        val caps = payload["capabilities"].arr
        if (payload == null || caps == null) throw LumaException("Govee returned invalid device state.")
        validateIdentity(payload, device)
        var updated = device
        caps.firstOrNull { it["instance"].str == "online" }?.get("state")?.get("value")?.bool?.let { updated = updated.copy(online = it) }
        // Govee marks offline state as historical; don't present it as fresh.
        if (updated.online == false) return updated to emptyList()
        for (cap in caps) {
            val instance = cap["instance"].str ?: continue
            val v = cap["state"]["value"].num ?: continue
            if (!v.isFinite() || kotlin.math.round(v) != v || v < 0 || v > Int.MAX_VALUE) continue
            updated = when {
                instance == "powerSwitch" && v <= 1 -> updated.copy(power = v == 1.0)
                instance == "brightness" && v <= 100 -> updated.copy(brightness = v.toInt())
                instance == "colorRgb" && v <= 0xFFFFFF -> updated.copy(rgb = v.toInt())
                instance == "colorTemperatureK" -> updated.copy(colorTemperature = v.toInt())
                instance == DreamView.INSTANCE && v <= 1 -> updated.copy(dreamView = v == 1.0)
                else -> updated
            }
        }
        if (updated.online == true) updated = updated.copy(lastSeen = System.currentTimeMillis())
        return updated to Readings.parse(payload, device.capabilities)
    }

    suspend fun control(device: LightDevice, command: CapabilityCommand) { request("device/control", device, command) }

    suspend fun scenes(device: LightDevice, diy: Boolean): List<Capability> {
        val payload = request(if (diy) "device/diy-scenes" else "device/scenes", device)["payload"] ?: throw LumaException("Govee returned invalid scene data.")
        validateIdentity(payload, device)
        payload["capabilities"]?.let { return decodeCapabilities(it) }
        val type = payload["type"].str
        val instance = payload["instance"].str
        val value = payload["value"]
        if (type != null && instance != null && value != null) {
            return listOf(Capability(type, instance, buildJsonObject {
                put("dataType", "ENUM")
                put("options", JsonArray(listOf(buildJsonObject { put("name", instance); put("value", value) })))
            }))
        }
        throw LumaException("Govee returned invalid scene capabilities.")
    }

    private fun decodeCapabilities(value: JsonElement): List<Capability> =
        (value.arr ?: throw LumaException("Govee returned invalid capabilities.")).map { row ->
            val type = row["type"].str
            val instance = row["instance"].str
            if (type == null || instance == null) throw LumaException("Govee returned an incomplete capability.")
            Capability(type, instance, row["parameters"])
        }

    private fun validateIdentity(payload: JsonElement, device: LightDevice) {
        payload["device"].str?.let { if (it != device.id) throw LumaException("Govee returned state for a different device.") }
        payload["sku"].str?.let { if (it != device.sku) throw LumaException("Govee returned a different device model.") }
    }

    private suspend fun request(path: String, device: LightDevice? = null, command: CapabilityCommand? = null): JsonElement = mutex.withLock {
        try { execute(path, device, command) } catch (e: IOException) {
            if (command != null || !transient(e)) throw describe(e, path, 1)
            try { execute(path, device, command) } catch (e2: IOException) { throw describe(e2, path, 2) }
        }
    }

    private fun transient(e: IOException) = e is SocketTimeoutException || e is UnknownHostException || e is java.net.ConnectException || e is java.net.SocketException

    /** Names the step only: never the key, payload, device ID, or device name. */
    private fun describe(e: IOException, path: String, attempts: Int): LumaException {
        val step = when (path) { "user/devices" -> "listing devices"; "device/state" -> "reading light state"; "device/control" -> "sending a command"; else -> "reading scenes" }
        val reason = when (e) {
            is SocketTimeoutException -> "received no response for 20 seconds"
            is UnknownHostException -> "could not resolve openapi.api.govee.com"
            is java.net.ConnectException -> "could not connect to openapi.api.govee.com"
            is javax.net.ssl.SSLException -> "could not establish a trusted TLS connection (check VPN, proxy, or network filters)"
            else -> "failed"
        }
        val tries = if (attempts > 1) " after $attempts attempts" else ""
        val outcome = if (path == "device/control") " Govee may or may not have applied it; it was not retried." else ""
        return LumaException("Govee cloud $reason while $step$tries.$outcome LAN control is unaffected.")
    }

    private suspend fun execute(path: String, device: LightDevice?, command: CapabilityCommand?): JsonElement {
        if (apiKey.isEmpty()) throw LumaException("Add your Govee API key in Settings first.")
        val readKey = path + ":" + (device?.id ?: "account")
        var ready = nextAccount
        device?.let { d -> nextDevice[d.id]?.let { ready = maxOf(ready, it) } }
        if (command == null) nextRead[readKey]?.let { ready = maxOf(ready, it) }
        val wait = ready - now()
        if (wait > 0) delay(wait)
        val t = now()
        nextAccount = t + 84
        device?.let { nextDevice[it.id] = t + 1000 }
        if (command == null) nextRead[readKey] = t + 2000

        val body = device?.let { d ->
            buildJsonObject {
                put("requestId", newId())
                putJsonObject("payload") {
                    put("sku", d.sku); put("device", d.id)
                    command?.let { c -> putJsonObject("capability") { put("type", c.type); put("instance", c.instance); put("value", c.value) } }
                }
            }.toString().toByteArray()
        }
        val headers = mapOf("Govee-API-Key" to apiKey, "Content-Type" to "application/json")
        val (status, data, retryAfter) = withContext(Dispatchers.IO) {
            transport.send(if (device != null) "POST" else "GET", "https://openapi.api.govee.com/router/api/v1/$path", headers, body)
        }
        if (status == 429) nextAccount = now() + retryAfterMillis(retryAfter)
        if (status !in 200..299) throw when (status) {
            401, 403 -> LumaException("Govee rejected the API key (HTTP $status). Check your key in Settings.")
            429 -> LumaException("Govee's rate limit was reached. Requests are paused; try again later.")
            else -> LumaException("Govee request failed (HTTP $status).")
        }
        if (data.size > 8 * 1024 * 1024) throw LumaException("Govee response is too large.")
        val root = runCatching { LumaJson.parseToJsonElement(data.decodeToString()) }.getOrElse { throw LumaException("Govee returned invalid JSON.") }
        val code = root["code"].num
        if (code != 200.0) {
            if (code == 429.0) nextAccount = now() + 60_000
            // Avoid echoing remote response text, which may include account details.
            throw LumaException("Govee rejected the request (${code?.toInt() ?: "missing code"}).")
        }
        return root
    }

    private fun now() = System.nanoTime() / 1_000_000

    companion object {
        /** Retry-After in seconds, clamped to 2…3600 like the Swift client; 60 s when absent or unreadable. */
        fun retryAfterMillis(header: String?): Long = ((header?.trim()?.toDoubleOrNull() ?: 60.0).coerceIn(2.0, 3600.0) * 1000).toLong()
    }

    object HttpTransport : Transport {
        override fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Response {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.requestMethod = method
                c.connectTimeout = 20_000; c.readTimeout = 20_000
                headers.forEach(c::setRequestProperty)
                if (body != null) { c.doOutput = true; c.outputStream.use { it.write(body) } }
                val status = c.responseCode
                val stream = if (status >= 400) c.errorStream else c.inputStream
                return Response(status, stream?.use { it.readBytes() } ?: ByteArray(0), c.getHeaderField("Retry-After"))
            } finally { c.disconnect() }
        }
    }
}

