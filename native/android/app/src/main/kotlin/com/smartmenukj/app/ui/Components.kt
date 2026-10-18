package com.smartmenukj.app.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.core.model.*

val palette: Palette @Composable get() = LocalPalette.current

/** The dot grid that sits behind Nothing OS screens. */
fun Modifier.dotGrid(color: Color, spacing: Dp = 16.dp, radius: Float = 1.6f, origin: Offset = Offset.Zero) = drawBehind {
    val step = spacing.toPx()
    if (step < 4) return@drawBehind
    var y = origin.y.mod(step)
    while (y <= size.height) {
        var x = origin.x.mod(step)
        while (x <= size.width) {
            drawCircle(color, radius, Offset(x, y))
            x += step
        }
        y += step
    }
}

/** A rounded card with a hairline border. Inverted cards are white on black, like Nothing widgets that are on. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NCard(
    modifier: Modifier = Modifier,
    inverted: Boolean = false,
    radius: Dp = 24.dp,
    padding: PaddingValues = PaddingValues(18.dp),
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val p = palette
    val bg by animateColorAsState(if (inverted) p.text else p.surface, label = "card")
    val shape = RoundedCornerShape(radius)
    Column(
        modifier
            .clip(shape)
            .background(bg)
            .border(1.dp, if (inverted) p.text else p.border, shape)
            .then(if (onClick != null || onLongClick != null) {
                Modifier.combinedClickable(onClick = { onClick?.invoke() }, onLongClick = onLongClick)
            } else Modifier)
            .padding(padding),
        content = content,
    )
}

/** "● LABEL" section header. */
@Composable
fun SectionLabel(text: String, accent: Boolean = false, trailing: (@Composable () -> Unit)? = null) {
    val p = palette
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 22.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(6.dp).background(if (accent) Palette.Red else p.textDim, CircleShape))
        Spacer(Modifier.width(8.dp))
        Text(text.uppercase(), style = NType.label(p.textDim), modifier = Modifier.weight(1f))
        trailing?.invoke()
    }
}

@Composable
fun HeaderAction(label: String, onClick: () -> Unit) {
    Text(label, style = NType.body(13.sp, palette.textDim, 500),
        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(horizontal = 6.dp, vertical = 2.dp))
}

/** A round, selectable chip. */
@Composable
fun NChip(label: String, selected: Boolean = false, icon: ImageVector? = null, onClick: () -> Unit) {
    val p = palette
    val bg = if (selected) p.text else p.surfaceHigh
    val fg = if (selected) p.background else p.text
    Row(
        Modifier.clip(CircleShape).background(bg).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = fg, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, style = NType.body(13.sp, fg, 500), maxLines = 1)
    }
}

/** Dot-matrix text, for big numbers and titles. */
@Composable
fun DotText(text: String, size: Int = 32, color: Color = palette.text, modifier: Modifier = Modifier) {
    Text(text, style = NType.dot(size.sp, color), modifier = modifier, maxLines = 1, overflow = TextOverflow.Clip)
}

fun deviceIcon(kind: DeviceKind, active: Boolean = false): ImageVector = when (kind) {
    DeviceKind.light -> if (active) Icons.Filled.Lightbulb else Icons.Outlined.Lightbulb
    DeviceKind.outlet -> if (active) Icons.Filled.Power else Icons.Outlined.Power
    DeviceKind.toggle -> if (active) Icons.Filled.ToggleOn else Icons.Outlined.ToggleOff
    DeviceKind.sensor -> Icons.Outlined.Sensors
    DeviceKind.climate -> Icons.Outlined.DeviceThermostat
    DeviceKind.cover -> if (active) Icons.Outlined.Blinds else Icons.Outlined.BlindsClosed
    DeviceKind.fan -> Icons.Outlined.Air
    DeviceKind.lock -> if (active) Icons.Outlined.LockOpen else Icons.Outlined.Lock
    DeviceKind.media -> if (active) Icons.Filled.Tv else Icons.Outlined.TvOff
    DeviceKind.camera -> Icons.Outlined.Videocam
    DeviceKind.vacuum -> Icons.Outlined.CleaningServices
    DeviceKind.mower -> Icons.Outlined.Grass
    DeviceKind.purifier -> Icons.Outlined.Cyclone
    DeviceKind.humidifier -> if (active) Icons.Filled.WaterDrop else Icons.Outlined.WaterDrop
    DeviceKind.appliance -> Icons.Outlined.LocalLaundryService
    DeviceKind.alarm -> if (active) Icons.Filled.Shield else Icons.Outlined.Shield
    DeviceKind.valve -> Icons.Outlined.Plumbing
    DeviceKind.siren -> if (active) Icons.Filled.Campaign else Icons.Outlined.Campaign
    DeviceKind.garage -> if (active) Icons.Filled.Garage else Icons.Outlined.Garage
    DeviceKind.button -> if (active) Icons.Filled.TouchApp else Icons.Outlined.TouchApp
    DeviceKind.other -> Icons.Outlined.DevicesOther
}

fun integrationIcon(key: String): ImageVector = when (key) {
    "hub" -> Icons.Outlined.Hub
    "bulb" -> Icons.Outlined.Lightbulb
    "plug" -> Icons.Outlined.ElectricalServices
    "power" -> Icons.Outlined.Power
    "strip" -> Icons.Outlined.LinearScale
    "chip" -> Icons.Outlined.Memory
    "virtual" -> Icons.Outlined.BlurOn
    else -> Icons.Outlined.DeviceHub
}

fun sceneIcon(key: String): ImageVector = when (key) {
    "off" -> Icons.Outlined.PowerSettingsNew
    "morning" -> Icons.Outlined.WbSunny
    "movie" -> Icons.Outlined.Movie
    "night" -> Icons.Outlined.Bedtime
    "away" -> Icons.Outlined.DirectionsWalk
    "dinner" -> Icons.Outlined.Restaurant
    "focus" -> Icons.Outlined.CenterFocusStrong
    "party" -> Icons.Outlined.Celebration
    "relax" -> Icons.Outlined.Spa
    else -> Icons.Outlined.AutoAwesome
}

val sceneIconKeys = listOf("auto", "off", "morning", "movie", "night", "away", "dinner", "focus", "party", "relax")

fun Int.asColor() = Color(0xFF000000.toInt() or this)

/**
 * Square device tile. Active devices invert to white, like Nothing widgets. Tap switches it (or opens its controls),
 * hold opens its controls, and a sideways drag sets its level (brightness, blind, fan speed, volume).
 */
@Composable
fun DeviceTile(
    device: Device,
    subtitle: String,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    onLevel: (Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = palette
    val active = device.state.isActive && device.state.reachable
    val haptic = LocalHapticFeedback.current
    val level = Describe.level(device)
    var dragging by remember { mutableStateOf<Double?>(null) }
    val shown = dragging ?: level
    val fg = if (active) p.background else p.text
    val dim = if (active) p.background.copy(alpha = 0.6f) else p.textDim
    val glow = Describe.lightColor(device)?.asColor()
    val shape = RoundedCornerShape(24.dp)
    var width by remember { mutableIntStateOf(1) }
    Box(
        modifier
            .aspectRatio(1.05f)
            .clip(shape)
            .background(if (active) p.text else p.surface)
            .border(1.dp, if (active) p.text else p.border, shape)
            .onSizeChanged { width = it.width }
            .pointerInput(device.id) {
                detectTapGestures(
                    onTap = { if (Describe.tapToggles(device)) { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); onToggle() } else onOpen() },
                    onLongPress = { haptic.performHapticFeedback(HapticFeedbackType.LongPress); onOpen() },
                )
            }
            .then(if (level != null) Modifier.pointerInput(device.id, level) {
                var v = level
                detectHorizontalDragGestures(
                    onDragStart = { v = Describe.level(device) ?: 0.0; dragging = v },
                    onDragEnd = { dragging?.let(onLevel); dragging = null },
                    onDragCancel = { dragging = null },
                ) { _, dx ->
                    v = (v + dx / width.coerceAtLeast(1)).coerceIn(0.0, 1.0)
                    dragging = v
                }
            } else Modifier),
    ) {
        if (shown != null && (dragging != null || (active && level != null))) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(shown.toFloat().coerceIn(0f, 1f))
                .background((if (active) p.background else p.text).copy(alpha = 0.08f)))
        }
        Column(Modifier.fillMaxSize().padding(16.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Box(Modifier.size(40.dp).clip(CircleShape).background(if (active) p.background.copy(alpha = 0.08f) else p.surfaceHigh),
                    contentAlignment = Alignment.Center) {
                    Icon(deviceIcon(device.kind, active), null, tint = glow ?: fg, modifier = Modifier.size(22.dp))
                }
                Spacer(Modifier.weight(1f))
                if (!device.state.reachable) Box(Modifier.size(8.dp).background(Palette.Red, CircleShape))
                else if (shown != null && (dragging != null || active)) {
                    Text("${(shown * 100).toInt()}", style = NType.dot(22.sp, fg))
                }
            }
            Spacer(Modifier.weight(1f))
            Text(device.name, style = NType.body(15.sp, fg, 500), maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(2.dp))
            Text(subtitle, style = NType.body(12.sp, dim), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** A wide bar that fills as its value goes up. Drag or tap to set it; [onDone] is called when the finger lifts. */
@Composable
fun LevelBar(
    value: Double,
    onDone: (Double) -> Unit,
    modifier: Modifier = Modifier,
    label: (Double) -> String = { "${(it * 100).toInt()}%" },
    color: Color? = null,
    height: Dp = 64.dp,
) {
    val p = palette
    var local by remember { mutableStateOf<Double?>(null) }
    val v = (local ?: value).coerceIn(0.0, 1.0)
    var width by remember { mutableIntStateOf(1) }
    val shape = RoundedCornerShape(20.dp)
    Box(
        modifier.fillMaxWidth().height(height).clip(shape).background(p.surfaceHigh)
            .onSizeChanged { width = it.width }
            .pointerInput(Unit) {
                detectTapGestures { o -> val n = (o.x / width).toDouble().coerceIn(0.0, 1.0); onDone(n) }
            }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { o -> local = (o.x / width).toDouble().coerceIn(0.0, 1.0) },
                    onDragEnd = { local?.let(onDone); local = null },
                    onDragCancel = { local = null },
                ) { change, _ -> local = (change.position.x / width).toDouble().coerceIn(0.0, 1.0) }
            },
    ) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(v.toFloat()).background(color ?: p.text))
        Text(label(v), style = NType.dot(22.sp, if (v > 0.25) (if (color != null) Color.Black else p.background) else p.text),
            modifier = Modifier.align(Alignment.CenterStart).padding(start = 18.dp))
    }
}

/** A big round on/off button. */
@Composable
fun PowerOrb(on: Boolean, onClick: () -> Unit, size: Dp = 76.dp, icon: ImageVector = Icons.Outlined.PowerSettingsNew) {
    val p = palette
    val bg by animateColorAsState(if (on) Palette.Red else p.surfaceHigh, label = "orb")
    Box(Modifier.size(size).clip(CircleShape).background(bg).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, if (on) "Turn off" else "Turn on", tint = if (on) Color.White else p.text, modifier = Modifier.size(size * 0.42f))
    }
}

/** A round icon button with a label under it. */
@Composable
fun ActionButton(icon: ImageVector, label: String, selected: Boolean = false, onClick: () -> Unit) {
    val p = palette
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(76.dp)) {
        Box(Modifier.size(56.dp).clip(CircleShape).background(if (selected) p.text else p.surfaceHigh).clickable(onClick = onClick),
            contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = if (selected) p.background else p.text)
        }
        Spacer(Modifier.height(6.dp))
        Text(label, style = NType.body(12.sp, p.textDim), maxLines = 1)
    }
}

@Composable
fun NTextField(
    value: String,
    onChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    hint: String = "",
    secret: Boolean = false,
    multiline: Boolean = false,
) {
    val p = palette
    TextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        placeholder = if (hint.isNotEmpty()) ({ Text(hint, color = p.textDim) }) else null,
        singleLine = !multiline,
        minLines = if (multiline) 3 else 1,
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation()
        else androidx.compose.ui.text.input.VisualTransformation.None,
        shape = RoundedCornerShape(16.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = p.surfaceHigh,
            unfocusedContainerColor = p.surfaceHigh,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedLabelColor = p.textDim,
            unfocusedLabelColor = p.textDim,
            cursorColor = Palette.Red,
            focusedTextColor = p.text,
            unfocusedTextColor = p.text,
        ),
        textStyle = NType.body(15.sp, p.text),
        modifier = modifier.fillMaxWidth(),
    )
}

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val p = palette
    Button(onClick = onClick, enabled = enabled, modifier = modifier, shape = CircleShape,
        colors = ButtonDefaults.buttonColors(containerColor = p.text, contentColor = p.background),
        contentPadding = PaddingValues(horizontal = 22.dp, vertical = 14.dp)) {
        Text(text, style = NType.body(14.sp, weight = 500))
    }
}

@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val p = palette
    OutlinedButton(onClick = onClick, enabled = enabled, modifier = modifier, shape = CircleShape,
        border = androidx.compose.foundation.BorderStroke(1.dp, p.border),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = p.text),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 14.dp)) {
        Text(text, style = NType.body(14.sp, weight = 500))
    }
}

@Composable
fun NSwitch(checked: Boolean, onChange: (Boolean) -> Unit) {
    val p = palette
    Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(
        checkedThumbColor = Color.White, checkedTrackColor = Palette.Red, checkedBorderColor = Color.Transparent,
        uncheckedThumbColor = p.textDim, uncheckedTrackColor = p.surfaceHigh, uncheckedBorderColor = Color.Transparent,
    ))
}

/** A row in a settings list. */
@Composable
fun SettingRow(
    title: String,
    subtitle: String? = null,
    icon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val p = palette
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 8.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = p.text)
            Spacer(Modifier.width(16.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = NType.body(15.sp, p.text, 500))
            if (subtitle != null) Text(subtitle, style = NType.body(13.sp, p.textDim))
        }
        trailing?.invoke()
    }
}
