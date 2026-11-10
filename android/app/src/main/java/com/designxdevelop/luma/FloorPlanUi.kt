package com.designxdevelop.luma

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.designxdevelop.luma.core.FloorPlan
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.LumaException
import com.designxdevelop.luma.core.LumaJson
import com.designxdevelop.luma.core.SavedHome
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import kotlin.math.roundToInt

/** Floor plan images (PNG, ≤ 4096 px, metadata stripped) and pins, beside home.json (FloorPlanStorage.swift). */
object FloorPlans {
    private const val MAX_PX = 4096
    private fun folder(context: Context) = File(context.filesDir, "floor-plans").apply { mkdirs() }
    fun image(context: Context, id: String) = File(folder(context), "$id.png")
    fun load(context: Context): List<FloorPlan> = runCatching {
        LumaJson.decodeFromString(ListSerializer(FloorPlan.serializer()), File(folder(context), "plans.json").readText())
    }.getOrDefault(emptyList())
    fun save(context: Context, plans: List<FloorPlan>) = File(folder(context), "plans.json").writeText(LumaJson.encodeToString(ListSerializer(FloorPlan.serializer()), plans))

    /** Re-encodes the picked image so the stored copy carries no location or camera metadata. */
    fun importImage(context: Context, uri: Uri, id: String) {
        val bitmap = if (Build.VERSION.SDK_INT >= 28) ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { d, info, _ ->
            val scale = minOf(1.0, MAX_PX.toDouble() / maxOf(info.size.width, info.size.height))
            d.setTargetSize((info.size.width * scale).roundToInt().coerceAtLeast(1), (info.size.height * scale).roundToInt().coerceAtLeast(1))
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        } else {
            // ponytail: API 26–27 ignores EXIF rotation; add androidx.exifinterface if those phones matter.
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_PX) sample *= 2
            context.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
                ?: throw LumaException("That file isn't an image Luma can read.")
        }
        image(context, id).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    /** A drawn sample plan with pins for the demo lights. */
    fun demo(context: Context, home: SavedHome): List<FloorPlan> {
        val id = "D3D3D3D3-0000-4000-8000-0000000000F1"
        val file = image(context, id)
        if (!file.exists()) {
            val b = Bitmap.createBitmap(1200, 800, Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            c.drawColor(0xFFFAF8F5.toInt())
            val wall = Paint().apply { color = 0xFF55504A.toInt(); strokeWidth = 10f; style = Paint.Style.STROKE }
            val label = Paint().apply { color = 0xFF8A8580.toInt(); textSize = 40f; isAntiAlias = true }
            c.drawRect(40f, 40f, 1160f, 760f, wall)
            c.drawLine(700f, 40f, 700f, 760f, wall); c.drawLine(700f, 420f, 1160f, 420f, wall)
            c.drawText("Living room", 80f, 110f, label); c.drawText("Office", 740f, 110f, label); c.drawText("Bedroom", 740f, 490f, label)
            file.outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        var plan = listOf(FloorPlan(id = id, name = "Ground floor"))
        listOf("demo-floor" to (0.12 to 0.25), "demo-strip" to (0.35 to 0.8), "demo-tv" to (0.45 to 0.12), "demo-desk" to (0.78 to 0.3), "demo-bed" to (0.85 to 0.8))
            .filter { (dev, _) -> home.devices.any { it.id == dev } }
            .forEach { (dev, xy) -> plan = FloorPlan.place(plan, dev, id, xy.first, xy.second) }
        return plan
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FloorPlanView(store: HomeStore, onOpenLight: (String) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var selected by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf<Uri?>(null) }
    var replacing by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val plans = store.floorPlans
    val plan = plans.firstOrNull { it.id == selected } ?: plans.firstOrNull()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        if (replacing && plan != null) store.replaceFloorPlanImage(plan.id, uri) else naming = uri
        replacing = false
    }
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            plans.forEach { p -> FilterChip(p.id == plan?.id, { selected = p.id }, { Text(p.name) }) }
            AssistChip({ picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, { Text("+ Floor") })
        }
        if (plan == null) {
            Banner("Add a floor plan: a photo or screenshot of your layout. Then place your lights on it. Tap a light on the plan to turn it on or off.")
            return@Column
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (editing) "Drag lights to place them. Changes save when you let go." else "Tap a light to turn it on or off. Long-press for controls.",
                Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton({ editing = !editing }) { Text(if (editing) "Done" else "Edit") }
            Box {
                TextButton({ menu = true }) { Text("···") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Rename floor") }, { menu = false; renaming = true })
                    DropdownMenuItem({ Text("Replace image") }, { menu = false; replacing = true; picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                    DropdownMenuItem({ Text("Delete floor", color = MaterialTheme.colorScheme.error) }, { menu = false; deleting = true })
                }
            }
        }
        // Decoded off the UI thread; null while loading, so the "can't be loaded" banner doesn't flash.
        val image by produceState<Result<androidx.compose.ui.graphics.ImageBitmap>?>(null, plan.id, store.floorPlanVersion) {
            value = null
            value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { BitmapFactory.decodeFile(FloorPlans.image(context, plan.id).path)!!.asImageBitmap() } }
        }
        val bitmap = image?.getOrNull()
        if (image == null) Box(Modifier.fillMaxWidth().aspectRatio(1.5f))
        else if (bitmap == null) Banner("This floor's image can't be loaded. Replace it from the ··· menu; pins are kept.")
        else BoxWithConstraints(Modifier.fillMaxWidth().aspectRatio(bitmap.width.toFloat() / bitmap.height).clipToBounds()
            .background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(12.dp))) {
            val w = constraints.maxWidth.toFloat()
            val h = constraints.maxHeight.toFloat()
            val pinPx = with(LocalDensity.current) { 44.dp.toPx() }
            Image(bitmap, "Floor plan ${plan.name}", Modifier.fillMaxWidth().aspectRatio(bitmap.width.toFloat() / bitmap.height))
            plan.pins.forEach { pin ->
                val d = store.devices.firstOrNull { it.id == pin.deviceID }
                var drag by remember(pin) { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
                val x = (pin.x * w + drag.x).toFloat()
                val y = (pin.y * h + drag.y).toFloat()
                Box(Modifier.offset { IntOffset((x - pinPx / 2).roundToInt(), (y - pinPx / 2).roundToInt()) }.size(44.dp)
                    .then(if (editing) Modifier.pointerInput(pin) {
                        detectDragGestures(onDragEnd = { store.placeLight(pin.deviceID, plan.id, ((pin.x * w + drag.x) / w).toDouble(), ((pin.y * h + drag.y) / h).toDouble()); drag = androidx.compose.ui.geometry.Offset.Zero }) { change, amount -> change.consume(); drag += amount }
                    } else Modifier.combinedClickable(onClick = { d?.let(store::togglePower) }, onLongClick = { d?.let { onOpenLight(it.id) } }))
                    .semantics { contentDescription = d?.let { "${it.displayName}, ${statusLine(it)}" } ?: "Light not found" }) { Pin(d) }
            }
        }
        if (editing) {
            val placed = plans.flatMap { p -> p.pins.map { it.deviceID } }.toSet()
            val tray = store.devices.filter { it.isLight && it.id !in placed }
            Text(if (tray.isEmpty()) "Every light has a pin. Use Remove to take one off the plan." else "Not on any floor: tap to add to the middle, then drag.", style = MaterialTheme.typography.labelLarge)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                tray.forEach { d -> AssistChip({ store.placeLight(d.id, plan.id, 0.5, 0.5) }, { Text(d.displayName) }) }
                plan.pins.forEach { pin ->
                    val name = store.devices.firstOrNull { it.id == pin.deviceID }?.displayName ?: "Missing light"
                    OutlinedButton({ store.removeFloorPlanPin(pin.deviceID) }) { Text("Remove $name") }
                }
            }
        }
    }
    naming?.let { uri -> NameDialog("Name this floor", "Floor name", "Floor ${plans.size + 1}", onSave = { store.importFloorPlan(it, uri) }) { naming = null } }
    if (renaming && plan != null) NameDialog("Rename floor", "Floor name", plan.name, onSave = { store.renameFloorPlan(plan.id, it); true }) { renaming = false }
    if (deleting && plan != null) AlertDialog(onDismissRequest = { deleting = false }, title = { Text("Delete ${plan.name}?") },
        text = { Text("Its image and pins are removed. Lights aren't affected.") },
        confirmButton = { TextButton({ store.deleteFloorPlan(plan.id); deleting = false }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton({ deleting = false }) { Text("Cancel") } })
}

@Composable
private fun Pin(d: LightDevice?) {
    val stroke = MaterialTheme.colorScheme.surface
    when {
        d == null -> Box(Modifier.size(44.dp).border(2.dp, MaterialTheme.colorScheme.onSurfaceVariant, CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape), Alignment.Center) { Text("?") }
        d.online == false -> Box(Modifier.size(44.dp).border(2.dp, MaterialTheme.colorScheme.error, CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape))
        d.power == true -> Box(Modifier.size(44.dp).background(lightColor(d), CircleShape).border(3.dp, stroke, CircleShape))
        else -> Box(Modifier.size(44.dp).background(Color(0xFF5A5A5E), CircleShape).border(3.dp, stroke, CircleShape))
    }
}
