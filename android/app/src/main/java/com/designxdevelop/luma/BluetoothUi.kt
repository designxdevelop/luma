package com.designxdevelop.luma

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.designxdevelop.luma.core.BleProfile
import com.designxdevelop.luma.core.BleSession
import com.designxdevelop.luma.core.GoveeBle
import java.util.UUID

/**
 * Govee TV backlights over Bluetooth LE (BluetoothLights.swift): scan, connect, read the encryption
 * marker, negotiate, then control. Order follows the source: connect → MTU → services → marker →
 * notifications → handshake. GATT allows one operation at a time, so operations are queued.
 */
@SuppressLint("MissingPermission") // The screen requests scan/connect permissions before calling in.
class BleLights(private val context: Context) {
    data class Found(val device: BluetoothDevice, val name: String, val model: String, val ad: GoveeBle.Advertisement?, val profile: BleProfile?)

    val found = mutableStateListOf<Found>()
    var scanning by mutableStateOf(false); private set
    var connected by mutableStateOf<Found?>(null); private set
    var ready by mutableStateOf(false); private set
    var status by mutableStateOf<String?>(null); private set
    var power by mutableStateOf<Boolean?>(null); private set
    var brightness by mutableStateOf<Int?>(null); private set
    var firmware by mutableStateOf<String?>(null); private set
    var dreamView by mutableStateOf<Boolean?>(null); private set
    val encryptionLabel: String get() = when { !ready -> "Not connected"; session.version == 0 -> "Not encrypted"; else -> "Encrypted (V${session.version})" }

    private val main = Handler(Looper.getMainLooper())
    private val adapter get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val sessions = HashMap<String, BleSession>() // Per light: one light's encryption requirement never applies to another.
    private var session = BleSession()
    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var mtu = 23
    private val queue = ArrayDeque<() -> Boolean>()
    private var busy = false

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val record = result.scanRecord ?: return
            val name = record.deviceName ?: result.device.name ?: return
            val model = GoveeBle.model(name) ?: return
            val data = record.manufacturerSpecificData
            val ad = (0 until (data?.size() ?: 0)).firstNotNullOfOrNull { GoveeBle.Advertisement.fromScan(data!!.keyAt(it), data.valueAt(it)) }
            val entry = Found(result.device, name, model, ad, BleProfile.resolve(model, ad?.pact))
            main.post { found.removeAll { it.device.address == entry.device.address }; found += entry }
        }
        override fun onScanFailed(errorCode: Int) { main.post { scanning = false; status = "Bluetooth scan failed ($errorCode)." } }
    }

    fun scan() {
        val scanner = adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner ?: run { status = "Turn on Bluetooth to look for lights."; return }
        found.clear(); scanning = true; status = null
        scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
        main.postDelayed({ stopScan() }, 10_000)
    }

    fun stopScan() { if (scanning) runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }; scanning = false }

    fun connect(f: Found) {
        stopScan(); disconnect()
        connected = f; status = "Connecting…"
        session = sessions.getOrPut(f.device.address) { BleSession() }.also { it.reset() }
        gatt = f.device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        main.postDelayed({ if (connected == f && !ready) fail("The light didn't finish connecting.") }, 15_000)
    }

    fun disconnect() {
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null; writeChar = null; notifyChar = null; queue.clear(); busy = false
        connected?.let { sessions[it.device.address] = session }
        connected = null; ready = false; power = null; brightness = null; firmware = null; dreamView = null
        session.reset()
    }

    /** Sends a logical frame through the session, then re-reads what it changes. */
    fun send(frame: ByteArray, reread: GoveeBle.Query? = null) {
        if (!ready) return
        val bytes = runCatching { session.encode(frame) }.getOrElse { fail("Luma couldn't encrypt that command, so it wasn't sent."); return }
        write(bytes)
        reread?.let { q -> write(session.encode(q.frame)) }
    }

    private fun fail(message: String) { main.post { status = message; disconnect() } }

    private fun enqueue(op: () -> Boolean) { main.post { queue.addLast(op); pump() } }
    private fun pump() { if (busy) return; while (queue.isNotEmpty()) { if (queue.removeFirst().invoke()) { busy = true; return } } }
    private fun done() { main.post { busy = false; pump() } }

    private fun write(bytes: ByteArray) = enqueue {
        val c = writeChar ?: return@enqueue false
        val g = gatt ?: return@enqueue false
        if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, bytes, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == 0
        else @Suppress("DEPRECATION") run { c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE; c.value = bytes; g.writeCharacteristic(c) }
    }

    private fun handle(event: BleSession.Event) {
        when (event) {
            is BleSession.Event.Write -> write(event.bytes)
            BleSession.Event.Ready -> main.post {
                ready = true; status = null
                val queries = listOf(GoveeBle.Query.Power, GoveeBle.Query.Brightness, GoveeBle.Query.Firmware).map { it.frame } +
                    (if (connected?.profile?.supports(BleProfile.Feature.DreamView) == true) listOf(GoveeBle.DreamView.query(GoveeBle.DreamView.Setting.SwitchGroup)) else emptyList())
                queries.forEach { write(session.encode(it)) }
            }
            is BleSession.Event.Packet -> main.post {
                when (val s = GoveeBle.parseStatus(event.bytes)) {
                    is GoveeBle.Status.Power -> power = s.on
                    is GoveeBle.Status.Brightness -> brightness = s.percent
                    is GoveeBle.Status.Firmware -> firmware = s.version
                    is GoveeBle.Status.DreamViewStatus -> (s.reading as? GoveeBle.DreamView.Reading.Enabled)?.let { dreamView = it.on }
                    else -> Unit
                }
            }
            BleSession.Event.Ignored -> Unit
        }
    }

    private fun startSession(marker: BleSession.Marker) {
        val f = connected ?: return
        try { session.select(marker, f.ad?.supportsEncryption ?: false) }
        catch (e: Exception) { return fail("Luma couldn't tell how this light encrypts its connection, so it didn't send anything.") }
        val n = notifyChar ?: return fail("This light doesn't offer Govee's notification channel.")
        val g = gatt ?: return
        g.setCharacteristicNotification(n, true)
        enqueue {
            val cccd = n.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")) ?: return@enqueue false
            if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == 0
            else @Suppress("DEPRECATION") run { cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(cccd) }
        }
    }

    private fun negotiate() {
        try { session.startNegotiation(mtu - 3)?.let { write(it); main.postDelayed({ if (!ready && connected != null) fail("The light didn't answer the encryption handshake.") }, 6_000) } ?: handle(BleSession.Event.Ready) }
        catch (e: Exception) { fail("This connection can't carry the light's encryption (the Bluetooth packet size is too small).") }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, statusCode: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) g.requestMtu(185)
            else if (newState == BluetoothProfile.STATE_DISCONNECTED && connected != null) fail(if (ready) "The light disconnected." else "Couldn't connect to the light.")
        }
        override fun onMtuChanged(g: BluetoothGatt, value: Int, statusCode: Int) { mtu = value; g.discoverServices() }
        override fun onServicesDiscovered(g: BluetoothGatt, statusCode: Int) {
            val chars = g.services.flatMap { it.characteristics }
            fun find(id: String) = chars.firstOrNull { it.uuid.toString().equals(id, ignoreCase = true) }
            writeChar = find(GoveeBle.WRITE_CHAR); notifyChar = find(GoveeBle.NOTIFY_CHAR)
            if (writeChar == null) return fail("This light doesn't offer Govee's control channel.")
            val marker = find(GoveeBle.ENCRYPTION_CHAR)
            if (marker == null) main.post { startSession(BleSession.Marker.Absent) } else if (!g.readCharacteristic(marker)) main.post { startSession(BleSession.Marker.ReadFailed) }
        }
        @Deprecated("API < 33") override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, statusCode: Int) {
            @Suppress("DEPRECATION") val v = c.value
            main.post { startSession(if (statusCode == BluetoothGatt.GATT_SUCCESS && v != null) BleSession.Marker.Value(v) else BleSession.Marker.ReadFailed) }
        }
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, statusCode: Int) {
            main.post { startSession(if (statusCode == BluetoothGatt.GATT_SUCCESS) BleSession.Marker.Value(value) else BleSession.Marker.ReadFailed) }
        }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, statusCode: Int) { done(); main.post { negotiate() } }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, statusCode: Int) = done()
        @Deprecated("API < 33") override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) { @Suppress("DEPRECATION") receive(c.value) }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) = receive(value)
    }

    private fun receive(bytes: ByteArray) {
        main.post {
            try { handle(session.receive(bytes)) } catch (e: Exception) { fail("The light rejected the encryption handshake.") }
        }
    }

    companion object {
        val permissions: Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        fun granted(context: Context) = permissions.all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
    }
}

@Composable
fun BluetoothScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val ble = remember { BleLights(context.applicationContext) }
    DisposableEffect(Unit) { onDispose { ble.stopScan(); ble.disconnect() } }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r -> if (r.values.all { it }) ble.scan() }
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Bluetooth lights", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    TextButton(onClose) { Text("Done") }
                }
                Text("Control Govee TV backlights (H6097, H6099, H66A0) directly over Bluetooth, with no Wi-Fi or account. Other Govee lights are listed but not controlled: their Bluetooth commands aren't publicly documented.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                ble.status?.let { Banner(it) }
                val c = ble.connected
                if (c == null) {
                    Button({ if (BleLights.granted(context)) ble.scan() else request.launch(BleLights.permissions) }, Modifier.fillMaxWidth().height(48.dp), enabled = !ble.scanning) {
                        Text(if (ble.scanning) "Looking for lights…" else "Look for Bluetooth lights")
                    }
                    if (!ble.scanning && ble.found.isEmpty()) Text("Keep the phone near the light. The light must not be connected to Govee Home at the same time.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    ble.found.forEach { f ->
                        Card(Modifier.fillMaxWidth().clickable(enabled = f.profile != null) { ble.connect(f) }, colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
                            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(f.profile?.name ?: f.model, style = MaterialTheme.typography.titleMedium)
                                    Text(listOfNotNull(f.model, f.name, f.profile?.limitation ?: if (f.profile == null) "Listed only: not controllable" else null).joinToString(" · "),
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                if (f.profile != null) TextButton({ ble.connect(f) }) { Text("Connect") }
                            }
                        }
                    }
                } else {
                    val p = c.profile
                    Text("${p?.name ?: c.model} · ${ble.encryptionLabel}" + (ble.firmware?.let { " · firmware $it" } ?: ""), style = MaterialTheme.typography.titleMedium)
                    if (!ble.ready) Text("Connecting and checking encryption…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Power", Modifier.weight(1f)); Switch(ble.power == true, { ble.send(GoveeBle.power(it), GoveeBle.Query.Power) })
                        }
                        var b by remember(ble.brightness) { mutableFloatStateOf((ble.brightness ?: 50).toFloat()) }
                        Text("Brightness ${b.toInt()}%", style = MaterialTheme.typography.labelLarge)
                        Slider(b, { b = it }, valueRange = 0f..100f, onValueChangeFinished = { ble.send(GoveeBle.brightness(b.toInt()), GoveeBle.Query.Brightness) })
                        if (p?.supports(BleProfile.Feature.Color) == true) FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            ColorPresets.forEach { (name, rgb) ->
                                Box(Modifier.size(44.dp).background(rgbColor(rgb), CircleShape).clickable(onClickLabel = name) { ble.send(GoveeBle.color(rgb shr 16 and 255, rgb shr 8 and 255, rgb and 255, p.wholeMask)) })
                            }
                        }
                        if (p?.supports(BleProfile.Feature.VideoMode) == true) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            GoveeBle.VideoSource.entries.forEach { s -> FilterChip(false, { ble.send(GoveeBle.videoMode(s, true, 100, false, 50), GoveeBle.Query.ColorMode) }, { Text("${s.name} video mode") }) }
                        }
                        if (p?.supports(BleProfile.Feature.DreamView) == true) Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) { Text("DreamView"); Text("Starts the group set up in Govee Home", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            Switch(ble.dreamView == true, { on -> ble.send(GoveeBle.DreamView.setEnabled(on)); ble.send(GoveeBle.DreamView.query(GoveeBle.DreamView.Setting.SwitchGroup)) })
                        }
                    }
                    OutlinedButton(ble::disconnect, Modifier.fillMaxWidth()) { Text("Disconnect") }
                }
            }
        }
    }
}
