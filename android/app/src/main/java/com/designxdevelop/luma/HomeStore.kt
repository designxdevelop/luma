package com.designxdevelop.luma

import android.app.Application
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.designxdevelop.luma.core.CapabilityCommand
import com.designxdevelop.luma.core.CommandValidation
import com.designxdevelop.luma.core.Demo
import com.designxdevelop.luma.core.DreamView
import com.designxdevelop.luma.core.GoveeCloud
import com.designxdevelop.luma.core.GoveeLan
import com.designxdevelop.luma.core.HomeBackup
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.LightScene
import com.designxdevelop.luma.core.LumaJson
import com.designxdevelop.luma.core.Readings
import com.designxdevelop.luma.core.SavedHome
import com.designxdevelop.luma.core.SceneKind
import com.designxdevelop.luma.core.SceneSchedule
import com.designxdevelop.luma.core.SceneStep
import com.designxdevelop.luma.core.arr
import com.designxdevelop.luma.core.get
import com.designxdevelop.luma.core.jsonEquals
import com.designxdevelop.luma.core.num
import com.designxdevelop.luma.core.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.ZonedDateTime

/**
 * The app's single source of truth (Android counterpart of HomeStore.swift).
 * Demo mode never starts LAN discovery or cloud requests: commands only change the preview.
 */
class HomeStore(app: Application) : AndroidViewModel(app) {
    data class LogEntry(val time: Long, val text: String, val error: Boolean)

    private val context: Context get() = getApplication()
    private val prefs = app.getSharedPreferences("luma", Context.MODE_PRIVATE)
    private val file = File(app.filesDir, "home.json")

    var home by mutableStateOf(SavedHome()); private set
    var demo by mutableStateOf(false); private set
    var hasKey by mutableStateOf(false); private set
    /** Chose "local network only" during onboarding. */
    var lanOnly by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var runningSceneID by mutableStateOf<String?>(null); private set
    var message by mutableStateOf<String?>(null)
    var lastScan by mutableStateOf<Long?>(null); private set
    val readings = mutableStateMapOf<String, List<Readings.Reading>>()
    val log = mutableStateListOf<LogEntry>()

    val onboarded: Boolean get() = demo || hasKey || lanOnly || home.devices.isNotEmpty()
    val devices: List<LightDevice> get() = home.devices
    val rooms: List<Pair<String, List<LightDevice>>> get() = home.devices.groupBy { it.room }.toList().sortedBy { if (it.first == "Unassigned") "￿" else it.first.lowercase() }

    private var cloud: GoveeCloud? = null
    private var lan: GoveeLan? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var sceneJob: Job? = null

    init {
        demo = prefs.getBoolean("demo", false)
        lanOnly = prefs.getBoolean("lanOnly", false)
        if (demo) loadDemo() else {
            home = runCatching { LumaJson.decodeFromString(SavedHome.serializer(), file.readText()) }.getOrDefault(SavedHome())
            KeyStore.read(context)?.let { connectCloud(it) }
            if (onboarded) scan() // LAN scan on every launch.
        }
        viewModelScope.launch { scheduleTicker() }
    }

    // ---- Account and modes ----

    fun connect(apiKey: String) {
        val key = apiKey.trim()
        if (key.isEmpty()) { message = "Paste your Govee API key."; return }
        if (demo) leaveDemo()
        KeyStore.save(context, key)
        connectCloud(key)
        scan()
    }

    fun removeKey() { KeyStore.delete(context); cloud = null; hasKey = false; log("Removed the Govee API key from this phone.") }

    fun useLanOnly() { lanOnly = true; prefs.edit().putBoolean("lanOnly", true).apply(); scan() }

    fun enterDemo() {
        stopScene(); stopLan(); cloud = null
        demo = true; prefs.edit().putBoolean("demo", true).apply()
        loadDemo()
    }

    fun leaveDemo() {
        stopScene(); readings.clear()
        demo = false; prefs.edit().putBoolean("demo", false).apply()
        home = runCatching { LumaJson.decodeFromString(SavedHome.serializer(), file.readText()) }.getOrDefault(SavedHome())
        KeyStore.read(context)?.let { connectCloud(it) }
        log("Left the demo home.")
        if (onboarded) scan()
    }

    private fun loadDemo() {
        home = Demo.home()
        readings["demo-bed"] = listOf(Readings.Reading("sensorTemperature", "Temperature", "21.5 °C"), Readings.Reading("sensorHumidity", "Humidity", "44%"))
        log("Demo home loaded. These are sample lights; no real devices are controlled.")
    }

    private fun connectCloud(key: String) {
        cloud = GoveeCloud(key); hasKey = true
        refreshCloud()
    }

    // ---- Discovery ----

    /** Cloud device list and state, then LAN discovery. Never runs in demo mode. */
    fun refresh() { if (demo) { message = "Demo mode: sample lights only."; return }; refreshCloud(); scan() }

    private fun refreshCloud() {
        val cloud = cloud ?: return
        viewModelScope.launch {
            loading = true
            try {
                val listed = cloud.devices()
                update { saved -> saved.copy(devices = mergeCloud(saved.devices, listed)) }
                log("Govee cloud listed ${listed.size} devices.")
                for (device in home.devices.filter { d -> listed.any { it.id == d.id } }) {
                    try {
                        val (state, values) = cloud.stateAndReadings(device)
                        replace(device.id) { it.copy(power = state.power, brightness = state.brightness, rgb = state.rgb, colorTemperature = state.colorTemperature, dreamView = state.dreamView, online = state.online, lastSeen = state.lastSeen) }
                        readings[device.id] = values
                    } catch (e: Exception) { log("${device.displayName}: ${e.message}", error = true) }
                }
            } catch (e: Exception) { log(e.message ?: "Govee cloud failed.", error = true); message = e.message }
            finally { loading = false }
        }
    }

    private fun mergeCloud(current: List<LightDevice>, listed: List<LightDevice>): List<LightDevice> {
        val out = current.toMutableList()
        for (d in listed) {
            val i = out.indexOfFirst { it.id.equals(d.id, ignoreCase = true) }
            if (i < 0) { out += d; continue }
            val old = out[i]
            // Keep scene lists downloaded earlier when the device list carries fewer options.
            val caps = d.capabilities.map { cap ->
                val prior = old.capabilities.firstOrNull { it.instance == cap.instance }
                if (SceneKind.from(cap.instance) != null && prior != null && (prior.parameters["options"].arr?.size ?: 0) > (cap.parameters["options"].arr?.size ?: 0)) prior else cap
            } + old.capabilities.filter { o -> SceneKind.from(o.instance) != null && d.capabilities.none { it.instance == o.instance } }
            out[i] = old.copy(name = d.name, sku = d.sku, capabilities = caps, deviceType = d.deviceType)
        }
        return out
    }

    /** Multicast scan to 239.255.255.250:4001; replies arrive on 4002. Needs the Wi-Fi multicast lock. */
    fun scan() {
        if (demo) { log("Demo mode: LAN discovery is disabled. Leave demo to discover real lights."); return }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                if (multicastLock == null) {
                    val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                    multicastLock = wifi.createMulticastLock("luma-lan").apply { setReferenceCounted(false); acquire() }
                }
                val l = lan ?: GoveeLan(onDevice = { d -> viewModelScope.launch { mergeLan(d) } }, onError = { e -> viewModelScope.launch { log(e, error = true) } }).also { lan = it }
                l.start()
                l.discover()
                home.devices.filter { it.ip != null }.forEach { runCatching { l.requestStatus(it) } }
                withContext(Dispatchers.Main) { lastScan = System.currentTimeMillis(); log("Looking for lights on the local network…") }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { log("LAN scan failed: ${e.message}", error = true) }
            }
        }
    }

    private fun mergeLan(found: LightDevice) {
        if (demo) return
        val i = home.devices.indexOfFirst { it.id.equals(found.id, ignoreCase = true) }
        update { saved ->
            val list = saved.devices.toMutableList()
            if (i < 0) { list += found.copy(room = "Unassigned"); log("Found ${found.name} at ${found.ip}.") }
            else list[i] = list[i].copy(ip = found.ip, online = true, lastSeen = found.lastSeen,
                power = found.power ?: list[i].power, brightness = found.brightness ?: list[i].brightness,
                rgb = found.rgb ?: list[i].rgb, colorTemperature = found.colorTemperature?.takeIf { it > 0 } ?: if (found.rgb != null) null else list[i].colorTemperature)
            saved.copy(devices = list)
        }
    }

    private fun stopLan() { lan?.stop(); lan = null; multicastLock?.release(); multicastLock = null }

    override fun onCleared() { stopLan(); sceneJob?.cancel() }

    // ---- Control ----

    fun perform(command: CapabilityCommand, ids: Collection<String>) {
        for (id in ids) {
            val device = home.devices.firstOrNull { it.id == id } ?: continue
            try { CommandValidation.validate(command, device) } catch (e: Exception) { message = e.message; continue }
            replace(id) { apply(it, command) }
            if (demo || device.isDemo) continue
            viewModelScope.launch { send(device, command) }
        }
    }

    private suspend fun send(device: LightDevice, command: CapabilityCommand) {
        try {
            val l = lan
            if (device.ip != null && l != null && command.instance in LightDevice.LAN_INSTANCES) withContext(Dispatchers.IO) { l.control(device, command) }
            else (cloud ?: throw IllegalStateException("${device.displayName} needs Govee cloud for this. Add your API key in Settings.")).control(device, command)
        } catch (e: Exception) { log(e.message ?: "Command failed.", error = true); message = e.message }
    }

    private fun apply(d: LightDevice, c: CapabilityCommand): LightDevice {
        val n = c.value.num?.toInt()
        return when (c.instance) {
            "powerSwitch" -> d.copy(power = n == 1)
            "brightness" -> d.copy(brightness = n)
            "colorRgb" -> d.copy(rgb = n, colorTemperature = null)
            "colorTemperatureK" -> d.copy(colorTemperature = n)
            DreamView.INSTANCE -> d.copy(dreamView = DreamView.capability(d)?.parameters["options"].arr
                ?.firstOrNull { jsonEquals(it["value"], c.value) }?.get("name").str?.equals("on", ignoreCase = true) ?: (n == 1))
            else -> d
        }
    }

    fun togglePower(device: LightDevice) = perform(CapabilityCommand.power(device.power != true), listOf(device.id))

    fun allOff() = perform(CapabilityCommand.power(false), home.devices.filter { it.isLight && it.power == true }.map { it.id })

    fun kelvinRange(d: LightDevice): IntRange {
        val range = d.capabilities.firstOrNull { it.instance == "colorTemperatureK" }?.parameters["range"]
        return (range["min"].num?.toInt() ?: 2000)..(range["max"].num?.toInt() ?: 9000)
    }

    fun setKelvin(kelvin: Int, ids: Collection<String>) {
        for (d in home.devices.filter { it.id in ids && it.supports("colorTemperatureK") }) perform(CapabilityCommand.kelvin(kelvin.coerceIn(kelvinRange(d))), listOf(d.id))
    }

    fun setDreamView(device: LightDevice, on: Boolean) =
        runCatching { perform(DreamView.command(on, device), listOf(device.id)) }.onFailure { message = it.message }

    fun loadEffects(device: LightDevice) {
        if (demo || device.isDemo) return
        val cloud = cloud ?: run { message = "Connect Govee cloud to load device effects."; return }
        viewModelScope.launch {
            try {
                val caps = cloud.scenes(device, false) + cloud.scenes(device, true)
                replace(device.id) { d -> d.copy(capabilities = d.capabilities.filter { c -> caps.none { it.instance == c.instance } } + caps) }
                log("Loaded effects for ${device.displayName}.")
            } catch (e: Exception) { log(e.message ?: "Could not load effects.", error = true); message = e.message }
        }
    }

    fun rename(id: String, name: String?) = replace(id) { it.copy(customName = name?.trim()?.take(64)?.ifEmpty { null }) }

    fun moveToRoom(id: String, room: String) { if (room.isNotBlank()) replace(id) { it.copy(room = room.trim().take(64)) } }

    // ---- Scenes ----

    fun snapshotSteps(ids: Collection<String>): List<SceneStep> = buildList {
        for (d in home.devices.filter { it.id in ids }) {
            d.power?.let { add(SceneStep(deviceID = d.id, command = CapabilityCommand.power(it))) }
            if (d.power == false) continue
            d.brightness?.takeIf { it > 0 && d.supports("brightness") }?.let { add(SceneStep(deviceID = d.id, command = CapabilityCommand.brightness(it))) }
            val k = d.colorTemperature
            if (k != null && k > 0 && d.supports("colorTemperatureK")) add(SceneStep(deviceID = d.id, command = CapabilityCommand.kelvin(k)))
            else d.rgb?.takeIf { d.supports("colorRgb") }?.let { add(SceneStep(deviceID = d.id, command = CapabilityCommand.rgb(it))) }
        }
    }

    fun saveLook(name: String, ids: Collection<String>): Boolean = try {
        val scene = LightScene(name = name.trim(), steps = snapshotSteps(ids))
        CommandValidation.validateScene(scene, home.devices)
        update { it.copy(scenes = it.scenes + scene) }
        log("Saved scene ${scene.name}."); true
    } catch (e: Exception) { message = e.message; false }

    fun deleteScene(scene: LightScene) = update { s -> s.copy(scenes = s.scenes - scene, schedules = s.schedules.filter { it.sceneID != scene.id }) }

    /** One scene runs at a time; steps go out in order with their delays. */
    fun runScene(scene: LightScene) {
        if (runningSceneID != null) { message = "A scene is already running. Stop it before starting another."; return }
        try { CommandValidation.validateScene(scene, home.devices) } catch (e: Exception) { message = e.message; return }
        runningSceneID = scene.id
        log("Running ${scene.name}.")
        sceneJob = viewModelScope.launch {
            try { for (step in scene.steps) { delay(step.delayMilliseconds.toLong()); perform(step.command, listOf(step.deviceID)) } }
            finally { runningSceneID = null }
        }
    }

    fun stopScene() { sceneJob?.cancel(); sceneJob = null; runningSceneID = null }

    // ---- Schedules ----

    fun saveSchedule(schedule: SceneSchedule) = update { s ->
        s.copy(schedules = if (s.schedules.any { it.id == schedule.id }) s.schedules.map { if (it.id == schedule.id) schedule else it } else s.schedules + schedule)
    }

    fun deleteSchedule(schedule: SceneSchedule) = update { s -> s.copy(schedules = s.schedules.filter { it.id != schedule.id }) }

    /**
     * ponytail: in-process ticker; it only fires while Luma's process is alive (open, or recently
     * backgrounded). Upgrade path: exact alarms (SCHEDULE_EXACT_ALARM) + a foreground service.
     */
    private suspend fun scheduleTicker() {
        while (viewModelScope.isActive) {
            val now = ZonedDateTime.now()
            for (s in home.schedules.filter { it.shouldRun(now) }) {
                saveSchedule(s.copy(lastRunMinute = SceneSchedule.minuteKey(now)))
                home.scenes.firstOrNull { it.id == s.sceneID }?.let { log("Schedule: ${it.name} at %02d:%02d.".format(s.hour, s.minute)); runScene(it) }
            }
            delay(15_000)
        }
    }

    // ---- Backup ----

    fun exportBackup(uri: Uri) = runCatching {
        context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(HomeBackup.of(home).encode().toByteArray()) }
        message = "Backup saved."
    }.onFailure { message = "Couldn't save the backup: ${it.message}" }

    fun importBackup(uri: Uri) {
        if (runningSceneID != null) { message = "Stop the running scene before restoring."; return }
        try {
            val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            val backup = HomeBackup.decode(bytes)
            if (!demo && file.exists()) file.copyTo(File(context.filesDir, "home-before-restore.json"), overwrite = true)
            val (restored, r) = HomeBackup.restore(backup, home)
            update { restored }
            message = "Restored ${r.scenes} scenes, ${r.schedules} schedules, ${r.lightsUpdated} lights." +
                (if (r.lightsNotFound > 0) " ${r.lightsNotFound} lights weren't found." else "") +
                (if (r.scenesWithMissingLights > 0) " ${r.scenesWithMissingLights} scenes use missing lights." else "")
            log(message!!)
        } catch (e: Exception) { message = e.message ?: "That file isn't a Luma home backup." }
    }

    // ---- State plumbing ----

    private fun replace(id: String, change: (LightDevice) -> LightDevice) = update { s -> s.copy(devices = s.devices.map { if (it.id == id) change(it) else it }) }

    private fun update(change: (SavedHome) -> SavedHome) {
        home = change(home)
        if (!demo) runCatching {
            val tmp = File(file.parentFile, "home.json.tmp")
            tmp.writeText(LumaJson.encodeToString(SavedHome.serializer(), home))
            tmp.renameTo(file)
        }.onFailure { log("Couldn't save: ${it.message}", error = true) }
    }

    fun log(text: String, error: Boolean = false) {
        log.add(0, LogEntry(System.currentTimeMillis(), text, error))
        if (log.size > 100) log.removeRange(100, log.size)
    }
}
