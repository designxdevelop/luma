package com.designxdevelop.luma

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.designxdevelop.luma.core.CapabilityCommand
import com.designxdevelop.luma.core.DreamView
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.SceneKind
import com.designxdevelop.luma.core.SceneLibrary

val ColorPresets = listOf("Red" to 0xFF3B30, "Orange" to 0xFF9500, "Yellow" to 0xFFD60A, "Green" to 0x34C759, "Teal" to 0x00C7BE, "Blue" to 0x0A84FF, "Purple" to 0xAF52DE, "Pink" to 0xFF2D95)
val WhitePresets = listOf("Warm" to 2700, "Neutral" to 4000, "Daylight" to 6500)

fun rgbColor(rgb: Int) = Color(0xFF000000 or rgb.toLong())

/** Approximate white-point color for a kelvin value, for tile tint only. */
fun kelvinColor(k: Int): Color { val t = ((k - 2000) / 7000f).coerceIn(0f, 1f); return Color(1f, 0.72f + 0.25f * t, 0.45f + 0.55f * t) }

fun lightColor(d: LightDevice): Color = d.colorTemperature?.takeIf { it > 0 }?.let(::kelvinColor) ?: rgbColor(d.rgb ?: 0xFFAA66)

/** Friendly name for a color: nearest preset ("Amber"-style names come from the preset list). */
fun colorName(d: LightDevice): String {
    d.colorTemperature?.takeIf { it > 0 }?.let { return "%,d K".format(it) }
    val rgb = d.rgb ?: return ""
    fun dist(a: Int, b: Int) = listOf(16, 8, 0).sumOf { s -> val x = (a shr s and 255) - (b shr s and 255); x * x }
    return (ColorPresets + listOf("Warm" to 0xFFB66A, "Lavender" to 0xCA8BFF, "Aqua" to 0x89CBD2, "Periwinkle" to 0x7FA8FF, "Amber" to 0xFFAE64)).minBy { dist(it.second, rgb) }.first
}

fun statusLine(d: LightDevice): String = when {
    d.online == false -> "Offline"
    d.power != true -> "Off"
    else -> listOfNotNull(d.brightness?.let { "$it%" }, colorName(d).ifEmpty { null }).joinToString(" · ").ifEmpty { "On" }
}

private val skuLike = Regex("^(Govee )?H[0-9A-Z]{4}(_[0-9A-F]{2,4})?$")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(store: HomeStore, modifier: Modifier) {
    var sheetFor by remember { mutableStateOf<String?>(null) }
    var adjustRoom by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<LightDevice?>(null) }
    var moving by remember { mutableStateOf<LightDevice?>(null) }
    val on = store.devices.count { it.isLight && it.power == true }
    LazyColumn(modifier.fillMaxSize()) {
        item {
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 20.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Home", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                    Text(if (store.devices.isEmpty()) "No lights yet" else "$on of ${store.devices.count { it.isLight }} on", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(store::allOff, enabled = on > 0) { Text("All off") }
            }
        }
        if (store.demo) item { Banner("Demo home: sample lights. Nothing real is controlled.") }
        if (store.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) }
        if (store.devices.isEmpty()) item {
            Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Looking for lights…", style = MaterialTheme.typography.titleMedium)
                Text("Luma checks Govee cloud and this Wi-Fi network. Lights need LAN Control turned on in Govee Home to be found locally.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                OutlinedButton(store::refresh) { Text("Scan again") }
            }
        }
        items(store.rooms, key = { it.first }) { (room, lights) ->
            val roomLights = lights.filter { it.isLight }
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(room, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    TextButton({ adjustRoom = room }) { Text("Adjust") }
                    Switch(roomLights.any { it.power == true }, { v -> store.perform(CapabilityCommand.power(v), roomLights.map { it.id }) },
                        Modifier.semantics { contentDescription = "$room power" })
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp), maxItemsInEachRow = 2) {
                    lights.forEach { d ->
                        LightTile(d, Modifier.weight(1f), onToggle = { store.togglePower(d) }, onOpen = { sheetFor = d.id },
                            onRename = { renaming = d }, onMove = { moving = d })
                    }
                    if (lights.size % 2 == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        item { Spacer(Modifier.height(16.dp)) }
    }
    sheetFor?.let { id -> store.devices.firstOrNull { it.id == id }?.let { LightSheet(store, it, onRename = { renaming = it }, onDismiss = { sheetFor = null }) } }
    adjustRoom?.let { room -> RoomAdjustSheet(store, room) { adjustRoom = null } }
    renaming?.let { d -> RenameDialog(d, onSave = { store.rename(d.id, it) }, onDismiss = { renaming = null }) }
    moving?.let { d -> MoveDialog(d, store.rooms.map { it.first }, onMove = { store.moveToRoom(d.id, it) }, onDismiss = { moving = null }) }
}

@Composable
fun Banner(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.secondary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .background(MaterialTheme.colorScheme.secondary.copy(alpha = 0.12f), RoundedCornerShape(12.dp)).padding(12.dp))
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LightTile(d: LightDevice, modifier: Modifier, onToggle: () -> Unit, onOpen: () -> Unit, onRename: () -> Unit, onMove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val lit = d.power == true && d.online != false
    val tint = lightColor(d)
    val bg = if (lit) tint else MaterialTheme.colorScheme.surfaceContainer
    val fg = if (lit) (if (tint.luminance() > 0.45f) Color(0xFF1C1C1E) else Color.White) else MaterialTheme.colorScheme.onSurface
    Box(modifier) {
        Card(
            Modifier.fillMaxWidth().height(104.dp).combinedClickable(onClick = onToggle, onLongClick = { menu = true }, onClickLabel = "Toggle power")
                .semantics { contentDescription = "${d.displayName}, ${statusLine(d)}" },
            colors = CardDefaults.cardColors(bg),
        ) {
            Row(Modifier.fillMaxSize().padding(start = 14.dp, top = 12.dp, bottom = 12.dp)) {
                Column(Modifier.weight(1f).fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
                    Text(d.displayName, color = fg, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Column {
                        if (d.customName == null && skuLike.matches(d.name)) Text("Name it", color = fg, style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.clickable(onClick = onRename).border(1.dp, fg.copy(alpha = 0.5f), CircleShape).padding(horizontal = 10.dp, vertical = 4.dp))
                        Text(statusLine(d), color = fg.copy(alpha = 0.8f), style = MaterialTheme.typography.bodySmall,
                            fontWeight = if (d.online == false) FontWeight.SemiBold else null)
                    }
                }
                IconButton(onOpen, Modifier.align(Alignment.CenterVertically)) {
                    Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, "Open ${d.displayName} controls", tint = fg)
                }
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem({ Text("Controls…") }, { menu = false; onOpen() })
            DropdownMenuItem({ Text("Rename…") }, { menu = false; onRename() })
            DropdownMenuItem({ Text("Move to room…") }, { menu = false; onMove() })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LightSheet(store: HomeStore, d: LightDevice, onRename: (LightDevice) -> Unit, onDismiss: () -> Unit) {
    var effects by remember { mutableStateOf(false) }
    var saveLook by remember { mutableStateOf(false) }
    var mode by remember(d.id) { mutableStateOf(if ((d.colorTemperature ?: 0) > 0) 1 else 0) }
    ModalBottomSheet(onDismiss) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f).height(48.dp).clickable { onRename(d) }, verticalAlignment = Alignment.CenterVertically) {
                    Text(d.displayName, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Icon(Icons.Outlined.Edit, "Rename", Modifier.padding(start = 8.dp).size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (d.supports("powerSwitch")) Switch(d.power == true, { store.perform(CapabilityCommand.power(it), listOf(d.id)) }, Modifier.semantics { contentDescription = "Power" })
            }
            Text("${d.room} · ${statusLine(d)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (d.supports("brightness")) {
                var b by remember(d.id, d.brightness) { mutableFloatStateOf((d.brightness ?: 50).toFloat()) }
                Text("Brightness ${b.toInt()}%", style = MaterialTheme.typography.labelLarge)
                Slider(b, { b = it }, valueRange = 1f..100f, onValueChangeFinished = { store.perform(CapabilityCommand.brightness(b.toInt()), listOf(d.id)) },
                    modifier = Modifier.height(64.dp).semantics { contentDescription = "Brightness" })
            }
            val color = d.supports("colorRgb")
            val white = d.supports("colorTemperatureK")
            if (color && white) SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("Color", "White").forEachIndexed { i, label -> SegmentedButton(mode == i, { mode = i }, SegmentedButtonDefaults.itemShape(i, 2)) { Text(label) } }
            }
            if (color && (mode == 0 || !white)) ColorPicker(d) { store.perform(CapabilityCommand.rgb(it), listOf(d.id)) }
            if (white && (mode == 1 || !color)) WhitePicker(d.colorTemperature, store.kelvinRange(d)) { store.setKelvin(it, listOf(d.id)) }
            HorizontalDivider()
            if (SceneLibrary.advertisesScenes(d)) SettingRowCompact("Effects", "${SceneLibrary.options(d).size} Govee scenes") { TextButton({ effects = true; if (SceneLibrary.options(d).isEmpty()) store.loadEffects(d) }) { Text("Browse") } }
            DreamView.capability(d)?.let {
                SettingRowCompact("DreamView", "Starts the sync group set up in Govee Home") { Switch(d.dreamView == true, { v -> store.setDreamView(d, v) }) }
            }
            store.readings[d.id]?.takeIf { it.isNotEmpty() }?.let { values ->
                Text("Readings", style = MaterialTheme.typography.labelLarge)
                values.forEach { r -> Row { Text(r.label, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant); Text(r.text) } }
            }
            Text("Details", style = MaterialTheme.typography.labelLarge)
            listOf("Model" to d.sku, "Connection" to (if (d.isDemo) "Demo" else listOfNotNull(d.ip?.let { "Local network ($it)" }, d.capabilities.isNotEmpty().takeIf { it }?.let { "Govee cloud" }).joinToString(" + ").ifEmpty { "Unknown" })).forEach { (k, v) ->
                Row { Text(k, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant); Text(v) }
            }
            OutlinedButton({ saveLook = true }, Modifier.fillMaxWidth().height(48.dp)) { Text("Save this look as a scene") }
        }
    }
    if (effects) EffectsDialog(store, d) { effects = false }
    if (saveLook) NameDialog("Save this look", "Scene name", "${d.displayName} look", onSave = { store.saveLook(it, listOf(d.id)) }) { saveLook = false }
}

@Composable
fun SettingRowCompact(title: String, detail: String, trailing: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title); Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        trailing()
    }
}

@Composable
private fun ColorPicker(d: LightDevice, onPick: (Int) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ColorPresets.forEach { (name, rgb) ->
            Box(Modifier.size(48.dp).background(rgbColor(rgb), CircleShape)
                .border(if (d.rgb == rgb && (d.colorTemperature ?: 0) == 0) 3.dp else 0.dp, MaterialTheme.colorScheme.onSurface, CircleShape)
                .clickable(onClickLabel = name) { onPick(rgb) }.semantics { contentDescription = name })
        }
    }
    var hue by remember(d.id) { mutableFloatStateOf(0f) }
    Text("Custom hue", style = MaterialTheme.typography.labelLarge)
    Slider(hue, { hue = it }, valueRange = 0f..359f, onValueChangeFinished = { onPick(android.graphics.Color.HSVToColor(floatArrayOf(hue, 1f, 1f)) and 0xFFFFFF) },
        modifier = Modifier.semantics { contentDescription = "Hue" })
}

@Composable
fun WhitePicker(current: Int?, range: IntRange, onPick: (Int) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        WhitePresets.forEach { (name, k) ->
            FilterChip(current == k, { onPick(k) }, { Text(name, maxLines = 1) }, Modifier.height(48.dp))
        }
    }
    var k by remember(current) { mutableFloatStateOf((current?.takeIf { it > 0 } ?: 4000).coerceIn(range).toFloat()) }
    Row { Text("Warm", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium); Text("%,d K".format(k.toInt()), style = MaterialTheme.typography.labelMedium); Text("Cool", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, textAlign = androidx.compose.ui.text.style.TextAlign.End) }
    Slider(k, { k = it }, valueRange = range.first.toFloat()..range.last.toFloat(), onValueChangeFinished = { onPick((k / 100).toInt() * 100) },
        modifier = Modifier.semantics { contentDescription = "Color temperature" })
}

@Composable
private fun EffectsDialog(store: HomeStore, d: LightDevice, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf<SceneKind?>(null) }
    var sent by remember { mutableStateOf<String?>(null) }
    val all = SceneLibrary.options(d)
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Effects · ${d.displayName}") }, confirmButton = { TextButton(onDismiss) { Text("Done") } },
        dismissButton = { if (!d.isDemo) TextButton({ store.loadEffects(d) }) { Text("Reload") } },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(query, { query = it }, singleLine = true, label = { Text("Search") }, modifier = Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilterChip(kind == null, { kind = null }, { Text("All") })
                    SceneKind.entries.filter { k -> all.any { it.kind == k } }.forEach { k -> FilterChip(kind == k, { kind = k }, { Text(k.title) }) }
                }
                val shown = SceneLibrary.filter(all, query, kind)
                if (shown.isEmpty()) Text(if (all.isEmpty()) "No effects loaded yet." else "No matches.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(Modifier.height(320.dp)) {
                    items(shown, key = { it.id }) { o ->
                        Row(Modifier.fillMaxWidth().height(48.dp).clickable { store.perform(o.command, listOf(d.id)); sent = o.id }, verticalAlignment = Alignment.CenterVertically) {
                            Text(o.name, Modifier.weight(1f)); if (sent == o.id) Text("Sent ✓ ", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary); Text(o.kind.title, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RoomAdjustSheet(store: HomeStore, room: String, onDismiss: () -> Unit) {
    val lights = store.devices.filter { it.room == room && it.isLight }
    val ids = lights.map { it.id }
    ModalBottomSheet(onDismiss) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Adjust $room", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text("${lights.size} lights", color = MaterialTheme.colorScheme.onSurfaceVariant)
            var b by remember { mutableFloatStateOf(lights.mapNotNull { it.brightness }.average().takeIf { !it.isNaN() }?.toFloat() ?: 50f) }
            Text("Brightness ${b.toInt()}%", style = MaterialTheme.typography.labelLarge)
            Slider(b, { b = it }, valueRange = 1f..100f, onValueChangeFinished = { store.perform(CapabilityCommand.brightness(b.toInt()), lights.filter { it.supports("brightness") }.map { it.id }) },
                modifier = Modifier.height(64.dp).semantics { contentDescription = "Room brightness" })
            if (lights.any { it.supports("colorTemperatureK") }) {
                Text("White", style = MaterialTheme.typography.labelLarge)
                WhitePicker(lights.mapNotNull { it.colorTemperature }.distinct().singleOrNull(), 2000..9000) { store.setKelvin(it, ids) }
            }
        }
    }
}

@Composable
fun NameDialog(title: String, label: String, initial: String, note: String? = null, onSave: (String) -> Boolean, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(title) },
        text = { Column { OutlinedTextField(text, { text = it.take(64) }, singleLine = true, label = { Text(label) }); note?.let { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp)) } } },
        confirmButton = { TextButton({ if (onSave(text)) onDismiss() }, enabled = text.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } })
}

@Composable
private fun RenameDialog(d: LightDevice, onSave: (String?) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(d.displayName) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Name") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(text, { text = it.take(64) }, singleLine = true, label = { Text("Light name") })
                Text("Only Luma uses this name. Govee Home keeps “${d.name}”.", style = MaterialTheme.typography.bodySmall)
                if (d.customName != null) AssistChip({ onSave(null); onDismiss() }, { Text("Use original name") })
            }
        },
        confirmButton = { TextButton({ onSave(text); onDismiss() }, enabled = text.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } })
}

@Composable
private fun MoveDialog(d: LightDevice, rooms: List<String>, onMove: (String) -> Unit, onDismiss: () -> Unit) {
    var newRoom by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Move ${d.displayName}") },
        text = {
            Column {
                rooms.filter { it != d.room }.forEach { r -> Text(r, Modifier.fillMaxWidth().height(48.dp).clickable { onMove(r); onDismiss() }.padding(vertical = 12.dp)) }
                Spacer(Modifier.width(8.dp))
                OutlinedTextField(newRoom, { newRoom = it.take(64) }, singleLine = true, label = { Text("New room") })
            }
        },
        confirmButton = { TextButton({ onMove(newRoom); onDismiss() }, enabled = newRoom.isNotBlank()) { Text("Move") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } })
}
