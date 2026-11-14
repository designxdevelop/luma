package com.designxdevelop.luma

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.LightScene
import com.designxdevelop.luma.core.get
import com.designxdevelop.luma.core.num

// Luma's glow language, matching Theme.swift: lights are drawn with their own colors,
// as gradients when Luma knows more than one (painted segments, a known scene).

val LightDevice.isLit: Boolean get() = power == true && online != false
val LightDevice.hasPalette: Boolean get() = (palette?.size ?: 0) > 1

fun Color.hueShifted(degrees: Float): Color {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(toArgb(), hsv)
    hsv[0] = (hsv[0] + degrees + 360f) % 360f
    return Color(android.graphics.Color.HSVToColor(hsv))
}

/** The palette Luma last sent, else the one color fanned into neighbors so it reads as light. */
fun lookColors(d: LightDevice): List<Color> =
    d.palette?.takeIf { it.size > 1 }?.map(::rgbColor) ?: lightColor(d).let { listOf(it.hueShifted(-22f), it, it.hueShifted(22f)) }

/** Distinct colors and whites a scene sets, in step order. */
fun sceneColors(scene: LightScene): List<Color> = scene.steps.mapNotNull { s ->
    when (s.command.instance) {
        "colorRgb" -> s.command.value.num?.toInt()?.let(::rgbColor)
        "colorTemperatureK" -> s.command.value.num?.toInt()?.let(::kelvinColor)
        "segmentedColorRgb" -> s.command.value["rgb"].num?.toInt()?.let(::rgbColor)
        else -> null
    }
}.distinct().take(8)

private fun gradientStops(colors: List<Color>) = if (colors.size > 1) colors else colors + colors

/** A glowing bar of a light's colors; [fraction] is how much of it is lit (brightness). */
@Composable
fun LookStrip(colors: List<Color>, fraction: Float, modifier: Modifier = Modifier, height: Dp = 5.dp) {
    val f by animateFloatAsState(fraction.coerceIn(0f, 1f), spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessLow), label = "strip")
    val track = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    Canvas(modifier.height(height)) {
        val h = size.height
        drawRoundRect(track, cornerRadius = CornerRadius(h / 2))
        if (f > 0f && colors.isNotEmpty()) {
            val w = maxOf(h, size.width * f)
            val brush = Brush.horizontalGradient(gradientStops(colors), endX = w)
            drawRoundRect(brush, Offset(-h, -h), Size(w + 2 * h, h * 3), CornerRadius(h * 1.5f), alpha = 0.28f) // halo
            drawRoundRect(brush, size = Size(w, h), cornerRadius = CornerRadius(h / 2))
        }
    }
}

/** A glowing disc of a light's colors. A light with a palette turns slowly, the way those effects move. */
@Composable
fun LightOrb(d: LightDevice, size: Dp = 44.dp) {
    val lit = d.isLit
    val colors = lookColors(d)
    val angle = if (lit && d.hasPalette) rememberInfiniteTransition(label = "orb").animateFloat(0f, 360f, infiniteRepeatable(tween(18_000, easing = LinearEasing)), label = "spin").value else 0f
    val off = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    Box(Modifier.size(size).drawBehind {
        val r = this.size.minDimension * 0.36f
        if (!lit) { drawCircle(off, r); return@drawBehind }
        val halo = this.size.minDimension * 0.8f
        drawCircle(Brush.radialGradient(listOf(colors[colors.size / 2].copy(alpha = 0.55f), Color.Transparent), radius = halo), halo)
        rotate(angle) { drawCircle(Brush.sweepGradient(colors + colors.first()), r) }
        val shine = Offset(this.size.width * 0.38f, this.size.height * 0.32f)
        drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.6f), Color.Transparent), shine, r), r)
    }.semantics { }, contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Lightbulb, null, Modifier.size(size * 0.36f), tint = if (lit) Color.White else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Soft light from the given colors, fading downward: the room's glow behind a page. */
@Composable
fun AmbientGlow(colors: List<Color>, modifier: Modifier = Modifier) {
    val alpha = if (isSystemInDarkTheme()) 0.36f else 0.3f
    Canvas(modifier) {
        val cs = colors.take(6)
        cs.forEachIndexed { i, c ->
            val center = Offset(size.width * (i + 0.5f) / cs.size, if (i % 2 == 0) 0f else size.height * 0.22f)
            val r = maxOf(size.width / cs.size, size.width * 0.5f)
            drawCircle(Brush.radialGradient(listOf(c.copy(alpha = alpha), Color.Transparent), center, r), r, center)
        }
    }
}

/** A scene's icon on a gradient of the colors it sets. */
@Composable
fun SceneSwatch(scene: LightScene, size: Dp = 44.dp, glowing: Boolean = false) {
    val found = sceneColors(scene)
    val colors = when (found.size) { 0 -> listOf(Color(0xFFFFB347), Color(0xFFB95500)); 1 -> listOf(found[0].hueShifted(-25f), found[0], found[0].hueShifted(25f)); else -> found }
    val glow by animateFloatAsState(if (glowing) 0.6f else 0.25f, label = "swatch")
    Box(Modifier.size(size).drawBehind {
        val r = this.size.minDimension
        drawCircle(Brush.radialGradient(listOf(colors[colors.size / 2].copy(alpha = glow), Color.Transparent), radius = r), r)
    }.background(Brush.linearGradient(colors), RoundedCornerShape(size * 0.27f)), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.AutoAwesome, null, Modifier.size(size * 0.45f), tint = Color.White)
    }
}

/**
 * A wide bar you drag anywhere on (Theme.swift's BrightnessBar). With [fill] the gradient
 * grows with the value (brightness); without it the whole track shows and a thumb marks
 * the value (hue, white temperature). [onDone] fires on release or tap.
 */
@Composable
fun GlowBar(
    value: Float, range: ClosedFloatingPointRange<Float>, colors: List<Color>, label: String,
    onChange: (Float) -> Unit, onDone: () -> Unit, modifier: Modifier = Modifier, fill: Boolean = true,
    content: @Composable RowScope.() -> Unit = {},
) {
    val span = range.endInclusive - range.start
    val frac = ((value - range.start) / span).coerceIn(0f, 1f)
    val change by rememberUpdatedState(onChange)
    val done by rememberUpdatedState(onDone)
    val track = MaterialTheme.colorScheme.surfaceContainerHigh
    fun at(x: Float, width: Int) = range.start + (x / width).coerceIn(0f, 1f) * span
    Box(
        modifier.fillMaxWidth().height(if (fill) 64.dp else 44.dp).clip(RoundedCornerShape(if (fill) 18.dp else 22.dp)).background(track)
            .pointerInput(range) { detectTapGestures { change(at(it.x, size.width)); done() } }
            .pointerInput(range) { detectHorizontalDragGestures(onDragEnd = { done() }) { c, _ -> change(at(c.position.x, size.width)) } }
            .drawBehind {
                val w = if (fill) size.width * frac else size.width
                if (w > 0f) drawRect(Brush.horizontalGradient(gradientStops(colors), endX = w), size = Size(w, size.height), alpha = if (fill) 0.85f else 1f)
                val x = (size.width * frac).coerceIn(8.dp.toPx(), size.width - 8.dp.toPx()) - if (fill) 6.dp.toPx() else 0f
                if (!fill || w > 20.dp.toPx()) {
                    drawRoundRect(Color.Black.copy(alpha = 0.18f), Offset(x - 3.dp.toPx(), size.height * 0.2f), Size(6.dp.toPx(), size.height * 0.6f), CornerRadius(3.dp.toPx()))
                    drawRoundRect(Color.White, Offset(x - 2.dp.toPx(), size.height * 0.22f), Size(4.dp.toPx(), size.height * 0.56f), CornerRadius(2.dp.toPx()))
                }
            }
            .semantics {
                contentDescription = label
                progressBarRangeInfo = ProgressBarRangeInfo(value, range)
                setProgress { change(it.coerceIn(range)); done(); true }
            },
    ) { Row(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically, content = content) }
}
