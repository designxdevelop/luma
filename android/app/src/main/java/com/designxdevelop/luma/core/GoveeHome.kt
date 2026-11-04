package com.designxdevelop.luma.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sign-in to the private Govee Home account API (GoveeAccount.swift), only to read the device list
 * (rooms), control groups (DreamView) and automations. Contract per homebridge-govee @ c7b3037 and
 * goveetl @ 3890402; Govee publishes none, so it can change. Nothing here controls lights.
 */
class GoveeAccount(private val clientID: String, private val host: String = "https://app2.govee.com", private val transport: Transport = Http) {
    fun interface Transport { fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Pair<Int, ByteArray> }
    sealed interface LoginResult { data class SignedIn(val token: String) : LoginResult; data object NeedsCode : LoginResult }
    class SessionExpired : Exception("Your Govee Home sign-in expired. Sign in again.")

    /** When Govee wants a code (status 454) this also asks it to email one. The password is never stored. */
    suspend fun login(email: String, password: String, code: String? = null): LoginResult {
        val root = post("account/rest/account/v2/login", buildJsonObject {
            put("email", email); put("password", password); put("client", clientID); code?.takeIf { it.isNotBlank() }?.let { put("code", it.trim()) }
        })
        return when (val status = root["status"].num) {
            454.0 -> {
                if (!code.isNullOrBlank()) throw LumaException("Govee didn't accept that code. Request a new one and try again.")
                val sent = post("account/rest/account/v1/verification", buildJsonObject { put("email", email); put("type", 8) })
                if (sent["status"].num != 200.0) throw LumaException("Govee couldn't send a sign-in code. Try again later.")
                LoginResult.NeedsCode
            }
            200.0 -> LoginResult.SignedIn(root["client"]["token"].str?.trim()?.takeIf { it.isNotEmpty() } ?: throw LumaException("Govee returned an incomplete session."))
            null -> throw LumaException("Govee returned an unexpected sign-in response.")
            // The server's message is never shown: it can echo account details.
            else -> throw LumaException("Govee didn't accept the email or password (status ${status.toInt()}).")
        }
    }

    suspend fun deviceList(token: String) = get("bff-app/v1/device/list", token)
    suspend fun groups(token: String) = get("bff-app/v1/general-control/list?filterEmpty=false", token)
    suspend fun automations(token: String) = get("bff-app/v1/ecology/resource/automations", token)

    private fun headers() = mapOf("appVersion" to "7.4.10", "clientId" to clientID, "clientType" to "1", "iotVersion" to "0",
        "timestamp" to System.currentTimeMillis().toString(), "User-Agent" to "GoveeHome/7.4.10 (com.ihoment.GoVeeSensor; build:8; iOS 26.5.0) Alamofire/5.11.0")

    private suspend fun get(path: String, token: String): ByteArray {
        val (status, data) = withContext(Dispatchers.IO) { transport.send("GET", "$host/$path", headers() + ("Authorization" to "Bearer $token"), null) }
        if (status == 401 || status == 403) throw SessionExpired()
        if (status !in 200..299) throw LumaException("Govee Home request failed (HTTP $status).")
        if (runCatching { LumaJson.parseToJsonElement(data.decodeToString())["status"].num }.getOrNull() == 401.0) throw SessionExpired()
        return data
    }

    private suspend fun post(path: String, body: JsonElement): JsonElement {
        val (status, data) = withContext(Dispatchers.IO) { transport.send("POST", "$host/$path", headers() + ("Content-Type" to "application/json"), body.toString().toByteArray()) }
        if (status !in 200..299) throw LumaException("Govee sign-in failed (HTTP $status).")
        return runCatching { LumaJson.parseToJsonElement(data.decodeToString()) }.getOrElse { throw LumaException("Govee sign-in failed (HTTP $status).") }
    }

    object Http : Transport {
        override fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Pair<Int, ByteArray> {
            if (!url.startsWith("https://")) throw LumaException("Govee sign-in requires HTTPS.")
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.instanceFollowRedirects = false // A redirect would resend the password elsewhere.
                c.requestMethod = method; c.connectTimeout = 30_000; c.readTimeout = 30_000
                headers.forEach(c::setRequestProperty)
                if (body != null) { c.doOutput = true; c.outputStream.use { it.write(body) } }
                val status = c.responseCode
                if (status in 300..399) throw LumaException("Govee redirected the request; Luma stopped it.")
                val data = (if (status >= 400) c.errorStream else c.inputStream)?.use { it.readBytes() } ?: ByteArray(0)
                if (data.size > 8 * 1024 * 1024) throw LumaException("Govee response is too large.")
                return status to data
            } finally { c.disconnect() }
        }
    }
}

/** Rooms, groups and automations from a Govee Home account (GoveeHomeImport.swift). */
object GoveeHomeImport {
    data class Entry(val device: String, val sku: String, val name: String, val room: String?, val bleName: String? = null, val bleAddress: String? = null, val firmware: String? = null)
    data class RoomChange(val deviceID: String, val name: String, val currentRoom: String, val goveeRoom: String) { val selectedByDefault: Boolean get() = currentRoom == "Unassigned" }
    data class Plan(val changes: List<RoomChange>, val unchanged: Int, val withoutRoom: Int, val notInLuma: List<Entry>, val groups: List<HomeGroup> = emptyList(), val automations: List<Automation> = emptyList(), val unavailable: List<String> = emptyList())

    @Serializable data class HomeGroup(val id: Int, val name: String, val enabled: Boolean, val reportedLightCount: Int? = null, val mainDevice: String? = null, val mainSKU: String? = null, val isDreamView: Boolean)
    @Serializable data class Automation(val id: Int, val name: String, val enabled: Boolean, val times: List<Time>, val repeatDays: List<Int>, val targets: List<Target>) {
        @Serializable data class Time(val hour: Int, val minute: Int)
        @Serializable data class Target(val sku: String, val name: String, val isDreamView: Boolean)
    }
    data class Conflict(val automation: String, val scheduleID: String, val light: String)

    fun parse(data: ByteArray): List<Entry> {
        if (data.size > 8 * 1024 * 1024) throw LumaException("The Govee Home file is too large.")
        val root = runCatching { LumaJson.parseToJsonElement(data.decodeToString()) }.getOrElse { throw LumaException("That file isn't JSON.") }
        root["status"].num?.let { if (it != 200.0) throw LumaException("That file is a failed Govee response (status ${it.toInt()}).") }
        val body = root["data"] ?: root
        val devices = body["devices"].arr ?: throw LumaException("No device list found. Save the response of GET /bff-app/v1/device/list.")
        val rooms = body["groups"].arr.orEmpty().mapNotNull { g -> g["groupId"].num?.let { id -> clean(g["groupName"].str)?.let { id to it } } }.toMap()
        return devices.mapNotNull { row ->
            val device = clean(row["device"].str) ?: return@mapNotNull null
            val sku = clean(row["sku"].str) ?: return@mapNotNull null
            val settings = nested(row["deviceExt"]["deviceSettings"])
            Entry(device, sku, clean(row["deviceName"].str) ?: sku, row["groupId"].num?.let(rooms::get),
                clean(settings["bleName"].str), clean(settings["address"].str), clean(row["versionSoft"].str ?: settings["wifiSoftVersion"].str))
        }
    }

    /** `deviceExt` fields arrive as JSON-encoded strings; accept objects too. */
    private fun nested(v: JsonElement?): JsonElement? = if (v is JsonPrimitive && v.isString) runCatching { LumaJson.parseToJsonElement(v.content) }.getOrNull() else v

    /** Matches on device ID (case-insensitive) and model. Never creates lights. */
    fun plan(entries: List<Entry>, devices: List<LightDevice>): Plan {
        val changes = mutableListOf<RoomChange>()
        var unchanged = 0; var withoutRoom = 0
        val notInLuma = mutableListOf<Entry>()
        for (e in entries) {
            val d = devices.firstOrNull { it.id.equals(e.device, true) && it.sku.equals(e.sku, true) } ?: run { notInLuma += e; null } ?: continue
            when (e.room) { null -> withoutRoom++; d.room -> unchanged++; else -> changes += RoomChange(d.id, d.displayName, d.room, e.room) }
        }
        return Plan(changes, unchanged, withoutRoom, notInLuma)
    }

    fun parseGroups(data: ByteArray): List<HomeGroup> = envelope(data)["list"].arr.orEmpty().mapNotNull { row ->
        val id = row["groupId"].num ?: return@mapNotNull null
        val name = clean(row["name"].str) ?: return@mapNotNull null
        HomeGroup(id.toInt(), name, row["enable"].num == 1.0, row["deviceCount"].num?.toInt(), clean(row["mainDevice"]["device"].str), clean(row["mainDevice"]["sku"].str),
            row["type"].num == 10.0 && (row["sceneFeastId"].num ?: 0.0) > 0)
    }

    fun parseAutomations(data: ByteArray): List<Automation> = envelope(data)["autoExecs"].arr.orEmpty().mapNotNull { row ->
        val id = row["groupId"].num ?: return@mapNotNull null
        val name = clean(row["name"].str) ?: return@mapNotNull null
        val s = row["schedule"]
        Automation(id.toInt(), name, row["enable"].num == 1.0,
            s["times"].arr.orEmpty().mapNotNull { t -> val h = t["hour"].num; val m = t["minute"].num; if (h != null && m != null && h in 0.0..23.0 && m in 0.0..59.0) Automation.Time(h.toInt(), m.toInt()) else null },
            s["repeat"].arr.orEmpty().mapNotNull { it.num?.toInt() },
            s["skus"].arr.orEmpty().mapNotNull { t ->
                val sku = clean(t["sku"].str) ?: return@mapNotNull null
                val dv = t["isFeast"].num == 1.0
                Automation.Target(sku, clean(if (dv) t["feastName"].str else t["deviceName"].str) ?: sku, dv)
            })
    }

    /** Enabled Govee automations at the same minute as an enabled Luma schedule on the same light (model + Govee name). Days aren't compared. */
    fun conflicts(automations: List<Automation>, schedules: List<SceneSchedule>, scenes: List<LightScene>, devices: List<LightDevice>): List<Conflict> = buildList {
        for (a in automations.filter { it.enabled }) for (s in schedules.filter { it.enabled && Automation.Time(it.hour, it.minute) in a.times }) {
            val ids = scenes.firstOrNull { it.id == s.sceneID }?.steps?.map { it.deviceID }?.toSet().orEmpty()
            for (d in devices.filter { it.id in ids }) {
                val t = a.targets.firstOrNull { !it.isDreamView && it.sku.equals(d.sku, true) && it.name == d.name } ?: continue
                add(Conflict(a.name, s.id, d.customName ?: t.name))
            }
        }
    }

    private fun envelope(data: ByteArray): JsonElement {
        val root = runCatching { LumaJson.parseToJsonElement(data.decodeToString()) }.getOrNull()?.takeIf { data.size <= 8 * 1024 * 1024 } ?: throw LumaException("Govee Home returned an unreadable response.")
        root["status"].num?.let { if (it != 200.0) throw LumaException("Govee Home request failed (status ${it.toInt()}).") }
        return root["data"] ?: root
    }

    private fun clean(text: String?) = text?.trim()?.takeIf { it.isNotEmpty() }?.take(64)
}
