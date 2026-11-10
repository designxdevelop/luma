package com.designxdevelop.luma

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.designxdevelop.luma.core.AudioLevels
import com.designxdevelop.luma.core.AudioMapper
import com.designxdevelop.luma.core.AudioSpectrum
import com.designxdevelop.luma.core.AudioStyle
import com.designxdevelop.luma.core.CapabilityCommand
import com.designxdevelop.luma.core.LanPacket
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.LinearColor
import com.designxdevelop.luma.core.ScreenColorMath
import com.designxdevelop.luma.core.ScreenGrid
import com.designxdevelop.luma.core.ScreenRegion
import com.designxdevelop.luma.core.StreamMixer
import com.designxdevelop.luma.core.StreamSettings
import com.designxdevelop.luma.core.StreamUpdate
import com.designxdevelop.luma.core.streamIssue
import kotlinx.coroutines.delay
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.math.sin

enum class SyncSource(val title: String) { Camera("Camera"), Microphone("Microphone"), Sample("Sample") }

/**
 * Sends latest-only LAN updates (unacknowledged UDP; a dropped datagram is replaced by the next).
 * Demo lights only change the preview.
 */
class LanStreamer(private val store: HomeStore) {
    private val io = Executors.newSingleThreadExecutor()
    private val socket = lazy { DatagramSocket() }

    fun send(updates: List<StreamUpdate>) {
        for (u in updates) {
            val d = store.devices.firstOrNull { it.id == u.deviceID } ?: continue
            store.previewStream(d.id, u.target)
            if (d.isDemo || store.demo) continue
            val ip = d.ip ?: continue
            val packets = buildList {
                if (u.sendsColor) add(LanPacket.control(CapabilityCommand.rgb(u.target.rgb)))
                if (u.sendsBrightness) add(LanPacket.control(CapabilityCommand.brightness(u.target.brightness)))
            }
            io.execute { packets.forEach { p -> runCatching { socket.value.send(DatagramPacket(p, p.size, InetAddress.getByName(ip), LanPacket.CONTROL_PORT)) } } }
        }
    }

    fun close() { io.execute { if (socket.isInitialized()) socket.value.close() }; io.shutdown() }
}

/** Screen and audio sync (ScreenSyncView.swift). Runs while this screen is open; closing it stops syncing. */
@Composable
fun SyncScreen(store: HomeStore, onClose: () -> Unit) {
    val context = LocalContext.current
    var source by remember { mutableStateOf(if (store.demo) SyncSource.Sample else SyncSource.Camera) }
    var running by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(StreamSettings()) }
    var style by remember { mutableStateOf(AudioStyle.Pulse) }
    var sensitivity by remember { mutableStateOf(1.0) }
    val chosen = remember { mutableStateMapOf<String, ScreenRegion>() }
    val eligible = store.devices.filter { it.streamIssue() == null }
    LaunchedEffect(Unit) {
        // Default layout: left/right thirds for the first two lights, whole picture for the rest.
        eligible.forEachIndexed { i, d -> chosen[d.id] = when (i) { 0 -> ScreenRegion.Left; 1 -> ScreenRegion.Right; else -> ScreenRegion.Full } }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) running = true else store.message = "Luma needs that permission for ${source.title} sync." }
    fun start() {
        val needed = when (source) { SyncSource.Camera -> Manifest.permission.CAMERA; SyncSource.Microphone -> Manifest.permission.RECORD_AUDIO; SyncSource.Sample -> null }
        if (needed == null || ContextCompat.checkSelfPermission(context, needed) == PackageManager.PERMISSION_GRANTED) running = true else permission.launch(needed)
    }

    val mixer = remember { StreamMixer() }
    val streamer = remember { LanStreamer(store) }
    val grid = remember { AtomicReference<ScreenGrid?>(null) }
    val levels = remember { AtomicReference<AudioLevels?>(null) }
    DisposableEffect(Unit) { onDispose { streamer.close() } }
    LaunchedEffect(settings) { mixer.settings = settings }

    // Tick loop: 10 Hz for pictures, 20 Hz for audio; the mixer's per-light rate cap bounds sends.
    LaunchedEffect(running, source, style, sensitivity) {
        if (!running) { mixer.reset(); return@LaunchedEffect }
        val audio = AudioMapper()
        val start = System.nanoTime()
        while (true) {
            val now = (System.nanoTime() - start) / 1e9
            val lights = chosen.filterKeys { id -> store.devices.any { it.id == id && it.streamIssue() == null } }
            when (source) {
                SyncSource.Camera, SyncSource.Sample -> {
                    val g = if (source == SyncSource.Sample) sampleGrid(now) else grid.get()
                    g?.let { mixer.ingest(it.colors(settings.edgeDepth, settings.vivid)) }
                    streamer.send(mixer.tick(now, lights))
                    delay(100)
                }
                SyncSource.Microphone -> {
                    levels.getAndSet(null)?.let { l ->
                        val ids = lights.keys.sorted()
                        val targets = audio.step(l, ids.size, settings, style, sensitivity, 0.05)
                        streamer.send(mixer.tickTargets(now, ids.zip(targets).toMap()))
                    }
                    delay(50)
                }
            }
        }
    }
    if (running && source == SyncSource.Microphone) MicrophoneCapture { levels.set(it) }

    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Screen & audio sync", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    TextButton(onClose) { Text("Done") }
                }
                Text(when (source) {
                    SyncSource.Camera -> "Point the back camera at your TV or monitor. Lights follow the colors in their part of the picture. Frames are reduced on the phone and never saved or uploaded."
                    SyncSource.Microphone -> "Lights pulse with the music the microphone hears. Only loudness and 8 frequency levels are used; no audio is recorded."
                    SyncSource.Sample -> "A built-in color sample, so you can try sync without a camera or music."
                }, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SyncSource.entries.filter { it != SyncSource.Sample || store.demo }.forEach { s -> FilterChip(source == s, { running = false; source = s }, { Text(s.title) }, enabled = true) }
                }
                if (source == SyncSource.Camera) {
                    if (running) CameraCapture(Modifier.fillMaxWidth().aspectRatio(16f / 9), onError = { store.message = it }) { grid.set(it) }
                    else Box(Modifier.fillMaxWidth().aspectRatio(16f / 9).background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(12.dp)), Alignment.Center) { Text("Camera preview appears when sync starts") }
                }
                Text("Lights", style = MaterialTheme.typography.labelLarge)
                if (store.devices.none { it.isLight }) Text("No lights yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                store.devices.filter { it.isLight }.forEach { d -> SyncLightRow(d, chosen, source) }
                if (source == SyncSource.Microphone) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        AudioStyle.entries.forEach { s -> FilterChip(style == s, { style = s }, { Text(if (s == AudioStyle.Pulse) "Pulse" else "Spectrum") }) }
                    }
                    Text("Sensitivity ${"%.1f".format(sensitivity)}×", style = MaterialTheme.typography.labelLarge)
                    Slider(sensitivity.toFloat(), { sensitivity = it.toDouble() }, valueRange = 0.5f..2f)
                }
                Text("Brightness up to ${settings.brightnessCap.toInt()}%", style = MaterialTheme.typography.labelLarge)
                Slider(settings.brightnessCap.toFloat(), { settings = settings.copy(brightnessCap = it.toDouble()) }, valueRange = 1f..100f)
                Text("Smoothing ${(settings.smoothing * 100).toInt()}%", style = MaterialTheme.typography.labelLarge)
                Slider(settings.smoothing.toFloat(), { settings = settings.copy(smoothing = it.toDouble()) }, valueRange = 0f..0.95f)
                if (source != SyncSource.Microphone) Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(settings.vivid, { settings = settings.copy(vivid = it) }); Text("Vivid: favor colorful pixels over gray and white")
                }
                val count = chosen.keys.count { id -> eligible.any { it.id == id } }
                if (running) Button({ running = false }, Modifier.fillMaxWidth().height(48.dp)) { Text("Stop") }
                else Button(::start, Modifier.fillMaxWidth().height(48.dp), enabled = count > 0) { Text("Start with $count ${if (count == 1) "light" else "lights"}") }
                Text("Sync uses local (LAN) control, up to ${settings.updateHz.toInt()} updates a second per light. It never turns lights on or off.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun SyncLightRow(d: LightDevice, chosen: MutableMap<String, ScreenRegion>, source: SyncSource) {
    val issue = d.streamIssue()
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Checkbox(d.id in chosen && issue == null, { on -> if (on) chosen[d.id] = ScreenRegion.Full else chosen.remove(d.id) }, enabled = issue == null)
        Box(Modifier.size(14.dp).background(lightColor(d), CircleShape))
        Column(Modifier.weight(1f).padding(start = 8.dp)) {
            Text(d.displayName)
            Text(issue ?: statusLine(d), style = MaterialTheme.typography.bodySmall, color = if (issue != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (source != SyncSource.Microphone && d.id in chosen && issue == null) Box {
            OutlinedButton({ menu = true }) { Text(chosen[d.id]?.title ?: "Region") }
            DropdownMenu(menu, { menu = false }) { ScreenRegion.entries.forEach { r -> DropdownMenuItem({ Text(r.title) }, { chosen[d.id] = r; menu = false }) } }
        }
    }
}

/** A slowly cycling two-color picture (left and right differ) for the demo. */
private fun sampleGrid(t: Double): ScreenGrid {
    fun c(phase: Double) = LinearColor(0.5 + 0.5 * sin(t * 0.8 + phase), 0.5 + 0.5 * sin(t * 0.8 + phase + 2.1), 0.5 + 0.5 * sin(t * 0.8 + phase + 4.2))
    val left = c(0.0)
    val right = c(3.0)
    val cells = DoubleArray(2 * 8)
    listOf(left, right).forEachIndexed { i, col -> doubleArrayOf(1.0, col.r, col.g, col.b, 1.0, col.r, col.g, col.b).copyInto(cells, i * 8) }
    return ScreenGrid(2, 1, cells)
}

/** Back camera at ~320×180, reduced to a grid on a background thread; only the grid leaves. */
@Composable
private fun CameraCapture(modifier: Modifier, onError: (String) -> Unit, onGrid: (ScreenGrid) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    // TextureView mode so the preview clips to its frame inside the scrolling dialog.
    val preview = remember { PreviewView(context).apply { implementationMode = PreviewView.ImplementationMode.COMPATIBLE; scaleType = PreviewView.ScaleType.FILL_CENTER } }
    DisposableEffect(owner) {
        val executor = Executors.newSingleThreadExecutor()
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val provider = runCatching { future.get() }.getOrElse { onError("The camera couldn't start: ${it.message}"); return@addListener }
            val analysis = ImageAnalysis.Builder()
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setResolutionSelector(androidx.camera.core.resolutionselector.ResolutionSelector.Builder()
                    .setResolutionStrategy(androidx.camera.core.resolutionselector.ResolutionStrategy(android.util.Size(320, 240), androidx.camera.core.resolutionselector.ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)).build())
                .build()
            analysis.setAnalyzer(executor) { image ->
                image.use {
                    val plane = it.planes[0]
                    val w = it.width
                    val h = it.height
                    val buf = plane.buffer
                    val px = IntArray(w * h)
                    for (y in 0 until h) for (x in 0 until w) {
                        val o = y * plane.rowStride + x * plane.pixelStride
                        px[y * w + x] = ((buf.get(o).toInt() and 255) shl 16) or ((buf.get(o + 1).toInt() and 255) shl 8) or (buf.get(o + 2).toInt() and 255)
                    }
                    ScreenColorMath.analyze(px, w, h)?.let(onGrid)
                }
            }
            val p = Preview.Builder().build().also { it.surfaceProvider = preview.surfaceProvider }
            runCatching { provider.unbindAll(); provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, p, analysis) }.onFailure { onError("The camera couldn't start: ${it.message}") }
        }, ContextCompat.getMainExecutor(context))
        onDispose { runCatching { future.get().unbindAll() }; executor.shutdown() }
    }
    AndroidView({ preview }, modifier.clipToBounds())
}


/** 48 kHz mono microphone, one analysis per 50 ms of audio over the last 2048 samples. Nothing is stored. */
@SuppressLint("MissingPermission") // Requested before this composable is shown.
@Composable
private fun MicrophoneCapture(onLevels: (AudioLevels) -> Unit) {
    DisposableEffect(Unit) {
        val rate = 48_000
        val size = maxOf(AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT), AudioSpectrum.SIZE * 4)
        val record = AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT, size)
        val on = java.util.concurrent.atomic.AtomicBoolean(true)
        val worker = thread(name = "luma-audio", isDaemon = true) {
            val window = FloatArray(AudioSpectrum.SIZE)
            val chunk = FloatArray(rate / 20)
            runCatching { record.startRecording() }
            while (on.get()) {
                val n = record.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                if (n < 0) break // An error code (e.g. dead object), not a short read: retrying would spin.
                if (n == 0) continue
                if (n >= window.size) chunk.copyInto(window, 0, n - window.size, n)
                else { window.copyInto(window, 0, n); chunk.copyInto(window, window.size - n, 0, n) }
                AudioSpectrum.levels(window.copyOf(), rate.toDouble())?.let(onLevels)
            }
        }
        onDispose { on.set(false); runCatching { record.stop() }; worker.join(200); record.release() }
    }
}
