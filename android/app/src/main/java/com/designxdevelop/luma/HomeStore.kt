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
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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

    companion object {
        /** The running app's store, so a schedule alarm runs through it instead of a second copy of the home. */
        @Volatile var live: HomeStore? = null
    }

    var home by mutableStateOf(SavedHome()); private set
    var demo by mutableStateOf(false); private set
    var hasKey by mutableStateOf(false); private set
    /** Chose "local network only" during onboarding. */
    var lanOnly by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var runningSceneID by mutableStateOf<String?>(null); private set
    /** Lights as they were before the last scene, one level deep (as on iOS). */
    var restorePoint by mutableStateOf<LightScene?>(null)
    var exactAlarms by mutableStateOf(ScheduleAlarms.canExact(app)); private set
    var message by mutableStateOf<String?>(null)
    var lastScan by mutableStateOf<Long?>(null); private set
    val readings = mutableStateMapOf<String, List<Readings.Reading>>()
    var homeGroups by mutableStateOf<List<com.designxdevelop.luma.core.GoveeHomeImport.HomeGroup>>(emptyList()); private set
    var homeAutomations by mutableStateOf<List<com.designxdevelop.luma.core.GoveeHomeImport.Automation>>(emptyList()); private set
    /** A Govee Home import waiting for the person to pick which room changes to apply. */
    var homePlan by mutableStateOf<com.designxdevelop.luma.core.GoveeHomeImport.Plan?>(null)
    var floorPlans by mutableStateOf<List<com.designxdevelop.luma.core.FloorPlan>>(emptyList()); private set
    /** Bumped when a floor image changes so the view reloads it. */
    var floorPlanVersion by mutableStateOf(0); private set
    val log = mutableStateListOf<LogEntry>()

    val onboarded: Boolean get() = demo || hasKey || lanOnly || home.devices.isNotEmpty()
    val devices: List<LightDevice> get() = home.devices
    val rooms: List<Pair<String, List<LightDevice>>> get() = home.devices.groupBy { it.room }.toList().sortedBy { if (it.first == "Unassigned") "￿" else it.first.lowercase() }

    val sync = ScheduleSync(app)
    /** Snapshot of [sync]'s saved state for the UI. */
    var syncStatus by mutableStateOf(sync.saved); private set
    private var cloud: GoveeCloud? = null
    @Volatile private var lan: GoveeLan? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val scanMutex = Mutex()
    private var sceneJob: Job? = null
    /** Latest home waiting to be written; one writer on IO, so saves coalesce and never block Main. */
    private val saves = Channel<SavedHome>(Channel.CONFLATED)
    /** Set when an unreadable home.json couldn't be moved aside, so it's never overwritten. */
    private var saveBlocked = false
    /** Local edits not yet staged with the runner; a sync that lands meanwhile mustn't revert them. */
    private var reconciling = 0

    init {
        demo = prefs.getBoolean("demo", false)
        lanOnly = prefs.getBoolean("lanOnly", false)
        // Not viewModelScope: onCleared closes the channel and this drains the last write after the scope is gone.
        LightControl.scope.launch {
            for (h in saves) runCatching { HomeFile.save(app, h) }.onFailure { e -> withContext(Dispatchers.Main) { log("Couldn't save: ${e.message}", error = true) } }
        }
        HomeFile.takeNotes(app).forEach { (time, text) -> log.add(0, LogEntry(time, text, true)) }
        if (demo) loadDemo() else {
            home = loadHome()
            floorPlans = FloorPlans.load(app)
            loadGoveeHome()
            KeyStore.read(context)?.let { connectCloud(it) }
            if (onboarded) scan() // LAN scan on every launch.
        }
        live = this
        ScheduleAlarms.reschedule(app, home, demo)
        viewModelScope.launch { while (isActive) { if (!demo && sync.paired) syncNow(); delay(30_000) } }
        viewModelScope.launch { demoTicker() }
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
        ScheduleAlarms.reschedule(context, home, demo = true)
    }

    fun leaveDemo() {
        stopScene(); readings.clear()
        demo = false; prefs.edit().putBoolean("demo", false).apply()
        home = loadHome()
        floorPlans = FloorPlans.load(context)
        loadGoveeHome()
        ScheduleAlarms.reschedule(context, home, demo = false)
        KeyStore.read(context)?.let { connectCloud(it) }
        log("Left the demo home.")
        if (onboarded) scan()
    }

    /** An unreadable home.json is kept as home.json.corrupt rather than replaced by the empty home on the next save. */
    private fun loadHome(): SavedHome = HomeFile.load(context) ?: SavedHome().also {
        if (!file.exists()) return@also
        message = if (HomeFile.moveAside(context)) "Your saved home couldn't be read, so Luma started empty. The unreadable file was kept as home.json.corrupt."
        else { saveBlocked = true; "Your saved home couldn't be read or moved aside. Nothing will be saved until Luma restarts, so the file isn't overwritten." }
        log(message!!, error = true)
    }

    private fun loadDemo() {
        home = Demo.home()
        floorPlans = FloorPlans.demo(context, home)
        homeGroups = listOf(com.designxdevelop.luma.core.GoveeHomeImport.HomeGroup(1, "Living Room Dream View", true, 3, "demo-tv", "Demo TV backlight", true))
        homeAutomations = listOf(com.designxdevelop.luma.core.GoveeHomeImport.Automation(1, "Good Morning", true, listOf(com.designxdevelop.luma.core.GoveeHomeImport.Automation.Time(7, 0)), (1..7).toList(),
            listOf(com.designxdevelop.luma.core.GoveeHomeImport.Automation.Target("Demo light bars", "Desk lights", false))))
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
            scanMutex.withLock { try {
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
            } }
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

    override fun onCleared() { stopLan(); sceneJob?.cancel(); saves.close(); if (live === this) live = null }

    // ---- Control ----

    fun perform(command: CapabilityCommand, ids: Collection<String>) {
        for (id in ids) {
            val device = home.devices.firstOrNull { it.id == id } ?: continue
            try { CommandValidation.validate(command, device) } catch (e: Exception) { message = e.message; continue }
            replace(id) { apply(it, command) }
            if (command.instance == "powerSwitch") LightControl.changed(context)
            if (demo || device.isDemo) continue
            viewModelScope.launch { send(device, command) }
        }
    }

    private suspend fun send(device: LightDevice, command: CapabilityCommand) {
        try {
            val l = lan
            // start() is a no-op on a live socket and reopens one dropped after a receive failure.
            if (device.ip != null && l != null && command.instance in LightDevice.LAN_INSTANCES) withContext(Dispatchers.IO) { l.start(); l.control(device, command) }
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

    /** Several commands to one light, sent in order (segment painting). */
    fun perform(commands: List<CapabilityCommand>, device: LightDevice) {
        try { commands.forEach { CommandValidation.validate(it, device) } } catch (e: Exception) { message = e.message; return }
        if (demo || device.isDemo) { log("Painted ${commands.size} segment groups on ${device.displayName}."); return }
        viewModelScope.launch { for (c in commands) send(device, c) }
    }

    fun saveScene(scene: LightScene): Boolean = try {
        CommandValidation.validateScene(scene, home.devices)
        update { it.copy(scenes = it.scenes + scene) }
        log("Saved scene ${scene.name}."); message = "Saved ${scene.name}."; true
    } catch (e: Exception) { message = e.message; false }

    /** Screen/audio sync preview: shows the streamed color without saving it (5–20 updates a second). */
    fun previewStream(id: String, target: com.designxdevelop.luma.core.LightTarget) {
        home = home.copy(devices = home.devices.map { if (it.id == id) it.copy(rgb = target.rgb, colorTemperature = null, brightness = target.brightness) else it })
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
    fun runScene(scene: LightScene, saveRestorePoint: Boolean = true) {
        if (runningSceneID != null) { message = "A scene is already running. Stop it before starting another."; return }
        try { CommandValidation.validateScene(scene, home.devices) } catch (e: Exception) { message = e.message; return }
        if (saveRestorePoint) {
            // Taken before any step is sent. Effects and DreamView aren't undone.
            val steps = snapshotSteps(scene.steps.map { it.deviceID }.toSet())
            restorePoint = if (steps.isEmpty()) null else LightScene(name = "Before ${scene.name}", symbol = "arrow.uturn.backward", steps = steps)
        }
        runningSceneID = scene.id
        log("Running ${scene.name}.")
        sceneJob = viewModelScope.launch {
            try { for (step in scene.steps) { delay(step.delayMilliseconds.toLong()); perform(step.command, listOf(step.deviceID)) } }
            finally { runningSceneID = null }
        }
    }

    fun stopScene() { sceneJob?.cancel(); sceneJob = null; runningSceneID = null }

    fun restoreBeforeScene() { restorePoint?.let { runScene(it, saveRestorePoint = false) }; restorePoint = null }

    // ---- Schedules ----

    fun saveSchedule(schedule: SceneSchedule) = update { s ->
        s.copy(schedules = if (s.schedules.any { it.id == schedule.id }) s.schedules.map { if (it.id == schedule.id) schedule else it } else s.schedules + schedule)
    }

    fun deleteSchedule(schedule: SceneSchedule) = update { s -> s.copy(schedules = s.schedules.filter { it.id != schedule.id }) }

    /** The demo home schedules nothing with AlarmManager; its schedules tick in-app instead. */
    private suspend fun demoTicker() {
        while (viewModelScope.isActive) {
            if (demo) {
                val now = ZonedDateTime.now()
                for (s in home.schedules.filter { it.shouldRun(now) }) {
                    saveSchedule(s.copy(lastRunMinute = SceneSchedule.minuteKey(now)))
                    home.scenes.firstOrNull { it.id == s.sceneID }?.let { log("Schedule: ${it.name} at %02d:%02d.".format(s.hour, s.minute)); runScene(it) }
                }
            }
            delay(15_000)
        }
    }

    /** Called by the schedule alarm while the app is alive. */
    fun runDueSchedules(millis: Long) {
        if (demo) return
        val at = java.time.Instant.ofEpochMilli(millis).atZone(java.time.ZoneId.systemDefault())
        val due = ScheduleAlarms.due(home, at)
        val late = ScheduleAlarms.late(System.currentTimeMillis(), millis)
        for (s in due) {
            saveSchedule(s.copy(lastRunMinute = SceneSchedule.minuteKey(at)))
            val scene = home.scenes.firstOrNull { it.id == s.sceneID } ?: continue
            when {
                late -> log("Missed ${scene.name} at %02d:%02d: Android delivered the alarm late. Allow exact alarms in Automations.".format(s.hour, s.minute), error = true)
                runningSceneID != null -> log("Skipped ${scene.name}: another scene was running.", error = true)
                else -> { log("Schedule: ${scene.name} at %02d:%02d.".format(s.hour, s.minute)); runScene(scene) }
            }
        }
        ScheduleAlarms.reschedule(context, home, demo)
    }

    fun refreshAlarmAccess() { exactAlarms = ScheduleAlarms.canExact(context); ScheduleAlarms.reschedule(context, home, demo) }

    // ---- Floor plans (placing a pin never sends a lighting command) ----

    private fun setPlans(plans: List<com.designxdevelop.luma.core.FloorPlan>) {
        floorPlans = plans
        if (!demo) runCatching { FloorPlans.save(context, plans) }.onFailure { message = "Couldn't save the floor plan: ${it.message}" }
    }

    /** Decodes and re-encodes off Main; returns at once (the dialog closes) and reports a failure through [message]. */
    fun importFloorPlan(name: String, uri: Uri): Boolean {
        val plan = com.designxdevelop.luma.core.FloorPlan(name = name.trim().take(64))
        viewModelScope.launch {
            try { withContext(Dispatchers.IO) { FloorPlans.importImage(context, uri, plan.id) }; setPlans(floorPlans + plan) }
            catch (e: Exception) { message = e.message ?: "That image couldn't be imported." }
        }
        return true
    }

    fun replaceFloorPlanImage(id: String, uri: Uri) {
        viewModelScope.launch {
            try { withContext(Dispatchers.IO) { FloorPlans.importImage(context, uri, id) }; floorPlanVersion++ } catch (e: Exception) { message = e.message }
        }
    }
    fun renameFloorPlan(id: String, name: String) = setPlans(floorPlans.map { if (it.id == id) it.copy(name = name.trim().take(64)) else it })
    fun deleteFloorPlan(id: String) { FloorPlans.image(context, id).delete(); setPlans(floorPlans.filter { it.id != id }) }
    fun placeLight(deviceID: String, planID: String, x: Double, y: Double) = setPlans(com.designxdevelop.luma.core.FloorPlan.place(floorPlans, deviceID, planID, x, y))
    fun removeFloorPlanPin(deviceID: String) = setPlans(floorPlans.map { p -> p.copy(pins = p.pins.filter { it.deviceID != deviceID }) })

    // ---- Govee Home account (read-only: rooms, DreamView groups, automations) ----

    private val homeJson get() = File(context.filesDir, "govee-home.json")
    @kotlinx.serialization.Serializable private data class HomeImport(val groups: List<com.designxdevelop.luma.core.GoveeHomeImport.HomeGroup>, val automations: List<com.designxdevelop.luma.core.GoveeHomeImport.Automation>)

    private fun loadGoveeHome() {
        val saved = runCatching { LumaJson.decodeFromString(HomeImport.serializer(), homeJson.readText()) }.getOrNull()
        homeGroups = saved?.groups.orEmpty(); homeAutomations = saved?.automations.orEmpty()
    }

    private val account get() = com.designxdevelop.luma.core.GoveeAccount(prefs.getString("goveeClientId", null) ?: newClientId())
    private fun newClientId() = java.util.UUID.randomUUID().toString().replace("-", "").also { prefs.edit().putString("goveeClientId", it).apply() }

    /** Returns true when Govee emailed a code and wants it on the next attempt. The password is never stored. */
    suspend fun signInGoveeHome(email: String, password: String, code: String?): Boolean {
        if (demo) { message = "Leave the demo to sign in to Govee Home."; return false }
        return try {
            when (val r = account.login(email.trim(), password, code)) {
                com.designxdevelop.luma.core.GoveeAccount.LoginResult.NeedsCode -> { message = "Govee emailed you a code. Enter it to finish signing in."; true }
                is com.designxdevelop.luma.core.GoveeAccount.LoginResult.SignedIn -> { KeyStore.save(context, r.token, "govee-home-token"); importGoveeHome(); false }
            }
        } catch (e: Exception) { message = e.message; false }
    }

    val goveeHomeSignedIn: Boolean get() = KeyStore.read(context, "govee-home-token") != null
    fun signOutGoveeHome() { KeyStore.delete(context, "govee-home-token"); log("Signed out of Govee Home.") }

    /** Reads rooms, groups and automations; a failed group or automation read doesn't fail the room import. */
    suspend fun importGoveeHome() {
        val token = KeyStore.read(context, "govee-home-token") ?: return
        try {
            val a = account
            val entries = com.designxdevelop.luma.core.GoveeHomeImport.parse(a.deviceList(token))
            val unavailable = mutableListOf<String>()
            val groups = runCatching { com.designxdevelop.luma.core.GoveeHomeImport.parseGroups(a.groups(token)) }.getOrElse { unavailable += "groups"; homeGroups }
            val autos = runCatching { com.designxdevelop.luma.core.GoveeHomeImport.parseAutomations(a.automations(token)) }.getOrElse { unavailable += "automations"; homeAutomations }
            homeGroups = groups; homeAutomations = autos
            homeJson.writeText(LumaJson.encodeToString(HomeImport.serializer(), HomeImport(groups, autos)))
            homePlan = com.designxdevelop.luma.core.GoveeHomeImport.plan(entries, home.devices).copy(groups = groups, automations = autos, unavailable = unavailable)
        } catch (e: com.designxdevelop.luma.core.GoveeAccount.SessionExpired) { signOutGoveeHome(); message = e.message }
        catch (e: Exception) { message = e.message }
    }

    /** A saved device-list file (no groups or automations). */
    fun importGoveeHomeFile(uri: Uri) = runCatching {
        val entries = com.designxdevelop.luma.core.GoveeHomeImport.parse(context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
        homePlan = com.designxdevelop.luma.core.GoveeHomeImport.plan(entries, home.devices)
    }.onFailure { message = it.message }

    fun applyRooms(changes: List<com.designxdevelop.luma.core.GoveeHomeImport.RoomChange>) {
        update { s -> s.copy(devices = s.devices.map { d -> changes.firstOrNull { it.deviceID == d.id }?.let { d.copy(room = it.goveeRoom) } ?: d }) }
        homePlan = null
        log("Applied ${changes.size} rooms from Govee Home.")
    }

    val homeConflicts get() = com.designxdevelop.luma.core.GoveeHomeImport.conflicts(homeAutomations, home.schedules, home.scenes, home.devices)

    // ---- Backup ----

    fun exportBackup(uri: Uri) = runCatching {
        context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(HomeBackup.of(home).encode().toByteArray()) }
        message = "Backup saved."
    }.onFailure { message = "Couldn't save the backup: ${it.message}" }

    fun importBackup(uri: Uri) {
        if (runningSceneID != null) { message = "Stop the running scene before restoring."; return }
        if (!demo && sync.paired) { message = "Turn schedule sync off before restoring a backup, so restored schedules can't undo changes made on other devices."; return }
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

    private fun update(fromRunner: Boolean = false, change: (SavedHome) -> SavedHome) {
        val before = home
        home = change(home)
        if (!demo && !saveBlocked) saves.trySend(home)
        if (before.schedules != home.schedules || before.scenes != home.scenes) {
            ScheduleAlarms.reschedule(context, home, demo)
            // Edits made here become shared changes; ignore lastRunMinute marks, which the runner doesn't keep.
            if (!fromRunner && !demo && sync.paired && (before.scenes != home.scenes || before.schedules.map { it.copy(lastRunMinute = null) } != home.schedules.map { it.copy(lastRunMinute = null) })) {
                val scenes = home.scenes
                val schedules = home.schedules
                reconciling++
                viewModelScope.launch {
                    try { sync.reconcile(scenes, schedules).forEach { log(it, error = true) } } catch (e: java.io.IOException) { log("Schedule sync: ${e.message}", error = true) }
                    finally { reconciling-- }
                    syncNow()
                }
            }
        }
    }

    // ---- Schedule sync (paired with a computer that runs schedules) ----

    fun pair(code: String) {
        if (demo) { message = "Leave the demo to pair with a computer."; return }
        viewModelScope.launch {
            try {
                sync.pair(code, home.scenes, home.schedules).forEach { log(it, error = true) }
                log("Paired with ${sync.saved.runnerName ?: "the runner"}. It runs your schedules; this phone won't.")
                ScheduleAlarms.reschedule(context, home, demo)
                syncNow()
            } catch (e: Exception) { message = e.message }
            syncStatus = sync.saved
        }
    }

    fun unpair() {
        viewModelScope.launch {
            // Unpaired before the update, so the disabled schedules aren't pushed to the runner.
            val disabled = try { sync.unpair(home.schedules) } catch (e: java.io.IOException) { message = e.message; home.schedules.map { it.copy(enabled = false) } }
            update { it.copy(schedules = disabled) }
            syncStatus = sync.saved
            ScheduleAlarms.reschedule(context, home, demo)
            log("Schedule sync is off. Schedules here were turned off so they don't also run on the computer; turn on the ones this phone should run.")
        }
    }

    suspend fun syncNow() {
        val scenes0 = home.scenes
        val schedules0 = home.schedules
        val notices = try { sync.sync() } catch (e: java.io.IOException) { log("Schedule sync: ${e.message}", error = true); return }
        // Skip when scenes or schedules changed during the request: that edit's own reconcile and sync apply the runner's view.
        val untouched = reconciling == 0 && home.scenes === scenes0 && home.schedules === schedules0
        val (scenes, schedules) = sync.shared(home.scenes, home.schedules)
        if (untouched && (scenes != home.scenes || schedules != home.schedules)) update(fromRunner = true) { it.copy(scenes = scenes, schedules = schedules) }
        syncStatus = sync.saved
        notices.forEach { log(it, error = true) }
        notices.firstOrNull()?.let { message = it }
    }

    fun log(text: String, error: Boolean = false) {
        log.add(0, LogEntry(System.currentTimeMillis(), text, error))
        if (log.size > 100) log.removeRange(100, log.size)
    }
}
