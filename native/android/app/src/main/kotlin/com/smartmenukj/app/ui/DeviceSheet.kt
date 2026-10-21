@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.smartmenukj.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.VolumeOff
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.StoreState
import com.smartmenukj.core.util.ColorMath
import kotlin.math.atan2
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NSheet(onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val p = palette
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = p.surface,
        contentColor = p.text,
        dragHandle = { BottomSheetDefaults.DragHandle(color = p.border) },
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 28.dp)
            .navigationBarsPadding(), content = content)
    }
}

@Composable
fun DeviceSheet(state: StoreState, id: String, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val d = state.data.device(id)
    if (d == null) {
        LaunchedEffect(Unit) { onDismiss() }
        return
    }
    val p = palette
    var editing by remember { mutableStateOf(false) }
    val send = { c: DeviceCommand -> store.command(d.id, c); Unit }
    NSheet(onDismiss) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(d.name, style = NType.dot(28.sp, p.text))
                Text(listOfNotNull(state.roomName(d.roomId), Describe.state(d)).joinToString(" · "),
                    style = NType.body(14.sp, p.textDim))
            }
            IconButton(onClick = { store.setFavorite(d.id, !d.favorite) }) {
                Icon(if (d.favorite) Icons.Filled.Star else Icons.Outlined.StarBorder, "Favourite",
                    tint = if (d.favorite) Palette.Accent else p.text)
            }
            IconButton(onClick = { editing = !editing }) { Icon(Icons.Outlined.Edit, "Edit", tint = p.text) }
        }
        if (!store.canControl(d)) {
            Spacer(Modifier.height(12.dp))
            NCard(padding = PaddingValues(14.dp)) {
                Text("This device comes from a connection the native app cannot drive yet. It is kept as it was, and works again when that connection arrives here.",
                    style = NType.body(13.sp, p.textDim))
            }
        }
        Spacer(Modifier.height(18.dp))
        if (editing) DeviceEditor(state, d) { editing = false } else DeviceControls(d, send)
    }
}

@Composable
fun DeviceControls(d: Device, send: (DeviceCommand) -> Unit) {
    val p = palette
    val s = d.state
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (d.has(Capability.onOff) || d.has(Capability.lock)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (d.has(Capability.onOff)) {
                    PowerOrb(s.on == true, { send(DeviceCommand(on = s.on != true)) })
                    Spacer(Modifier.width(16.dp))
                }
                if (d.has(Capability.lock)) {
                    PowerOrb(s.locked == false, { send(DeviceCommand(locked = s.locked != true)) },
                        icon = if (s.locked == false) Icons.Outlined.LockOpen else Icons.Outlined.Lock)
                    Spacer(Modifier.width(16.dp))
                    Text(if (s.locked == false) "Unlocked. Tap to lock." else "Locked. Tap to unlock.", style = NType.body(14.sp, p.textDim))
                }
            }
        }
        if (d.has(Capability.brightness)) {
            Labeled("Brightness") {
                LevelBar(if (s.on == false) 0.0 else s.brightness ?: 1.0, { v ->
                    send(if (v < 0.01) DeviceCommand(on = false) else DeviceCommand(brightness = v))
                })
                Presets(listOf(0.1, 0.25, 0.5, 0.75, 1.0)) { send(DeviceCommand(brightness = it)) }
            }
        }
        if (d.has(Capability.colorTemp)) {
            Labeled("White") {
                val k = s.colorTempK ?: 3000
                LevelBar(((k - 2200) / 4300.0), { v -> send(DeviceCommand(colorTempK = (2200 + v * 4300).roundToInt())) },
                    label = { "${(2200 + it * 4300).roundToInt()} K" },
                    color = ColorMath.kelvinToRgb((2200 + ((k - 2200) / 4300.0).coerceIn(0.0, 1.0) * 4300).roundToInt()).asColor())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((name, kk) in listOf("Warm" to 2700, "Neutral" to 4000, "Cool" to 5500, "Daylight" to 6500)) {
                        NChip(name, selected = s.color == null && s.colorTempK == kk) { send(DeviceCommand(colorTempK = kk)) }
                    }
                }
            }
        }
        if (d.has(Capability.color)) {
            Labeled("Colour") { ColorRing(s.color) { send(DeviceCommand(color = it)) } }
        }
        if (d.has(Capability.position)) {
            Labeled(if (d.kind == DeviceKind.garage) "Door" else "Open") {
                LevelBar(s.position ?: 0.0, { send(DeviceCommand(position = it)) })
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    NChip("Close") { send(DeviceCommand(position = 0.0)) }
                    NChip("Half") { send(DeviceCommand(position = 0.5)) }
                    NChip("Open") { send(DeviceCommand(position = 1.0)) }
                }
            }
        }
        if (d.has(Capability.targetTemp)) {
            Labeled("Temperature") { TempControl(s) { send(DeviceCommand(targetTemp = it)) } }
        }
        if (d.has(Capability.speed)) {
            Labeled("Speed") {
                LevelBar(if (s.on == false) 0.0 else s.speed ?: 0.5, { v ->
                    send(if (v < 0.01) DeviceCommand(on = false) else DeviceCommand(speed = v))
                })
            }
        }
        if (d.has(Capability.humidity)) {
            val lo = d.props["minHumidity"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull() } ?: 30.0
            val hi = d.props["maxHumidity"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull() } ?: 80.0
            Labeled("Humidity") {
                LevelBar(((s.targetHumidity ?: 50.0) - lo) / (hi - lo), { v -> send(DeviceCommand(targetHumidity = (lo + v * (hi - lo)).roundToInt().toDouble())) },
                    label = { "${(lo + it * (hi - lo)).roundToInt()}%" })
            }
        }
        if (d.has(Capability.volume)) {
            Labeled("Volume") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { send(DeviceCommand(muted = s.muted != true)) }) {
                        Icon(if (s.muted == true) Icons.AutoMirrored.Outlined.VolumeOff else Icons.AutoMirrored.Outlined.VolumeUp,
                            "Mute", tint = if (s.muted == true) Palette.Accent else p.text)
                    }
                    LevelBar(s.volume ?: 0.0, { send(DeviceCommand(volume = it)) }, modifier = Modifier.weight(1f))
                }
            }
        }
        if (d.has(Capability.remote)) Labeled("Remote") { RemotePad(d, send) }
        if (d.has(Capability.run) || d.has(Capability.dock) || d.has(Capability.locate)) {
            Labeled(Describe.activity(d.kind, s.activity) + (s.battery?.let { " · ${(it * 100).roundToInt()}%" } ?: "")) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (d.has(Capability.run)) {
                        val running = s.activity == Activity.RUNNING
                        ActionButton(if (running) Icons.Outlined.Pause else Icons.Outlined.PlayArrow, if (running) "Pause" else "Start", running) {
                            send(DeviceCommand(action = if (running) DeviceAction.pause else DeviceAction.start))
                        }
                        if (d.props["noStop"] == null) ActionButton(Icons.Outlined.Stop, "Stop") { send(DeviceCommand(action = DeviceAction.stop)) }
                    }
                    if (d.has(Capability.dock)) ActionButton(Icons.Outlined.Home, "Go home", s.activity == Activity.RETURNING) {
                        send(DeviceCommand(action = DeviceAction.dock))
                    }
                    if (d.has(Capability.locate)) ActionButton(Icons.Outlined.NotificationsActive, "Find") { send(DeviceCommand(action = DeviceAction.locate)) }
                }
            }
        }
        if (d.has(Capability.alarm)) Labeled("Alarm") { AlarmControls(d, send) }
        if (d.has(Capability.press)) {
            PrimaryButton(if (d.kind == DeviceKind.button) "Run" else "Press", { send(DeviceCommand(action = DeviceAction.press)) },
                modifier = Modifier.fillMaxWidth())
        }
        if (d.has(Capability.mode) && d.modes.isNotEmpty()) {
            Labeled(when (d.kind) { DeviceKind.vacuum -> "Suction"; DeviceKind.media -> "Input"; else -> "Mode" }) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (m in d.modes) NChip(Describe.mode(m), selected = s.mode == m) { send(DeviceCommand(mode = m)) }
                }
            }
        }
        if (s.readings.isNotEmpty()) {
            Labeled("Readings") {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    for ((k, v) in s.readings) {
                        NCard(padding = PaddingValues(14.dp), radius = 18.dp) {
                            Text(k, style = NType.label(p.textDim))
                            Spacer(Modifier.height(4.dp))
                            Text(v, style = NType.dot(22.sp, p.text))
                        }
                    }
                }
            }
        }
        if (d.capabilities.isEmpty() && s.readings.isEmpty()) {
            Text("Nothing to control on this one yet.", style = NType.body(14.sp, p.textDim))
        }
    }
}

@Composable
private fun Labeled(label: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(label, style = NType.label(palette.textDim))
        content()
    }
}

@Composable
private fun Presets(values: List<Double>, onPick: (Double) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (v in values) NChip("${(v * 100).roundToInt()}%") { onPick(v) }
    }
}

/** A hue ring: drag around it to pick a colour. */
@Composable
private fun ColorRing(color: Int?, onPick: (Int) -> Unit) {
    val p = palette
    var size by remember { mutableIntStateOf(1) }
    var picked by remember(color) { mutableStateOf(color?.let { ColorMath.rgbToHsv(it)[0] }) }
    fun hueAt(o: Offset): Double {
        val c = size / 2f
        val deg = Math.toDegrees(atan2((o.y - c).toDouble(), (o.x - c).toDouble()))
        return (deg + 450) % 360
    }
    val hues = (0..12).map { Color.hsv((it * 30f) % 360f, 1f, 1f) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(180.dp).onSizeChanged { size = it.width }.clip(CircleShape)
                .background(Brush.sweepGradient(hues.map { it }))
                .pointerInput(Unit) { detectTapGestures { o -> val h = hueAt(o); picked = h; onPick(ColorMath.hsvToRgb(h, 1.0, 1.0)) } }
                .pointerInput(Unit) {
                    detectDragGestures(onDragEnd = { picked?.let { onPick(ColorMath.hsvToRgb(it, 1.0, 1.0)) } }) { ch, _ -> picked = hueAt(ch.position) }
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(Modifier.size(110.dp).clip(CircleShape).background(p.surface), contentAlignment = Alignment.Center) {
                Box(Modifier.size(54.dp).clip(CircleShape)
                    .background(picked?.let { ColorMath.hsvToRgb(it, 1.0, 1.0).asColor() } ?: p.surfaceHigh)
                    .border(1.dp, p.border, CircleShape))
            }
        }
        Spacer(Modifier.width(16.dp))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (c in listOf(0xFF3B30, 0xFF9500, 0xFFD60A, 0x34C759, 0x0A84FF, 0xBF5AF2)) {
                Box(Modifier.size(32.dp).clip(CircleShape).background(c.asColor()).clickable { picked = ColorMath.rgbToHsv(c)[0]; onPick(c) })
            }
        }
    }
}

@Composable
private fun TempControl(s: DeviceState, onSet: (Double) -> Unit) {
    val p = palette
    var target by remember(s.targetTemp) { mutableStateOf(s.targetTemp ?: 21.0) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        RoundButton(Icons.Outlined.Remove) { target = ((target - 0.5) * 2).roundToInt() / 2.0; onSet(target) }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            DotText("%.1f°".format(target), 56)
            s.currentTemp?.let { Text("Now %.1f°".format(it), style = NType.body(13.sp, p.textDim)) }
        }
        RoundButton(Icons.Outlined.Add) { target = ((target + 0.5) * 2).roundToInt() / 2.0; onSet(target) }
    }
}

@Composable
private fun RoundButton(icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    val p = palette
    Box(Modifier.size(56.dp).clip(CircleShape).background(p.surfaceHigh).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = p.text)
    }
}

@Composable
private fun RemotePad(d: Device, send: (DeviceCommand) -> Unit) {
    val keys = d.props["keys"]?.let { it as? kotlinx.serialization.json.JsonArray }?.map { (it as kotlinx.serialization.json.JsonPrimitive).content }?.toSet()
    fun has(k: RemoteKey) = keys == null || k.name in keys
    fun key(k: RemoteKey) = send(DeviceCommand(key = k))
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        if (keys == null) {
            RoundButton(Icons.Outlined.KeyboardArrowUp) { key(RemoteKey.up) }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                RoundButton(Icons.Outlined.KeyboardArrowLeft) { key(RemoteKey.left) }
                RoundButton(Icons.Outlined.Circle) { key(RemoteKey.ok) }
                RoundButton(Icons.Outlined.KeyboardArrowRight) { key(RemoteKey.right) }
            }
            RoundButton(Icons.Outlined.KeyboardArrowDown) { key(RemoteKey.down) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (keys == null) {
                ActionButton(Icons.AutoMirrored.Outlined.ArrowBack, "Back") { key(RemoteKey.back) }
                ActionButton(Icons.Outlined.Home, "Home") { key(RemoteKey.home) }
            }
            if (has(RemoteKey.volumeDown)) ActionButton(Icons.Outlined.VolumeDown, "Vol -") { key(RemoteKey.volumeDown) }
            if (has(RemoteKey.volumeUp)) ActionButton(Icons.Outlined.VolumeUp, "Vol +") { key(RemoteKey.volumeUp) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (has(RemoteKey.rewind)) ActionButton(Icons.Outlined.SkipPrevious, "Back") { key(RemoteKey.rewind) }
            if (has(RemoteKey.playPause)) ActionButton(Icons.Outlined.PlayArrow, "Play") { key(RemoteKey.playPause) }
            if (has(RemoteKey.stop)) ActionButton(Icons.Outlined.Stop, "Stop") { key(RemoteKey.stop) }
            if (has(RemoteKey.forward)) ActionButton(Icons.Outlined.SkipNext, "Next") { key(RemoteKey.forward) }
        }
    }
}

@Composable
private fun AlarmControls(d: Device, send: (DeviceCommand) -> Unit) {
    val s = d.state
    val arms = d.props["arms"]?.let { it as? kotlinx.serialization.json.JsonArray }?.map { (it as kotlinx.serialization.json.JsonPrimitive).content }
        ?: listOf("home", "away")
    val needsCode = d.props["codeFormat"] != null
    var code by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        DotText(Describe.activity(d.kind, s.activity), 28, color = if (s.activity in Activity.busy) Palette.Accent else palette.text)
        if (needsCode) NTextField(code, { code = it }, "Code", secret = true)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (a in arms) {
                val action = when (a) {
                    "home" -> DeviceAction.armHome
                    "away" -> DeviceAction.armAway
                    "night" -> DeviceAction.armNight
                    "vacation" -> DeviceAction.armVacation
                    else -> null
                } ?: continue
                NChip("Arm $a", selected = s.activity == action.alarmState) { send(DeviceCommand(action = action, code = code.ifEmpty { null })) }
            }
            NChip("Disarm", selected = s.activity == Activity.DISARMED) { send(DeviceCommand(action = DeviceAction.disarm, code = code.ifEmpty { null })) }
        }
    }
}

/** Rename a device, pick its room and kind, or remove it. */
@Composable
private fun DeviceEditor(state: StoreState, d: Device, onDone: () -> Unit) {
    val store = LocalStore.current
    val p = palette
    var name by remember { mutableStateOf(d.name) }
    var confirm by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        NTextField(name, { name = it }, "Name")
        Text("Room", style = NType.label(p.textDim))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            NChip("No room", selected = d.roomId == null) { store.setRoom(d.id, null) }
            for (r in state.data.rooms) NChip(r.name, selected = d.roomId == r.id) { store.setRoom(d.id, r.id) }
        }
        Text("Show as", style = NType.label(p.textDim))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (k in DeviceKind.entries) NChip(k.label, selected = d.kind == k, icon = deviceIcon(k)) { store.setKind(d.id, k) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PrimaryButton("Save", { store.renameDevice(d.id, name); onDone() })
            SecondaryButton(if (confirm) "Tap again to remove" else "Remove", {
                if (confirm) store.removeDevice(d.id) else confirm = true
            })
        }
    }
}
