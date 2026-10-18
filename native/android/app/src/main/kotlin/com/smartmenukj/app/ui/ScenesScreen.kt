@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.smartmenukj.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.StoreState

@Composable
fun ScenesScreen(state: StoreState) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    Column(Modifier.fillMaxSize()) {
        ScreenTitle("Scenes") { NChip("New", icon = Icons.Outlined.Add) { nav.scene = NEW_SCENE } }
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (state.data.scenes.isEmpty()) item {
                Text("A scene puts many devices in their place with one tap: lights down for a film, everything off when you leave.",
                    style = NType.body(14.sp, p.textDim), modifier = Modifier.padding(vertical = 8.dp))
            }
            items(state.data.scenes, key = { it.id }) { s ->
                NCard(padding = PaddingValues(16.dp), onClick = { store.runScene(s.id) }, onLongClick = { nav.scene = s.id }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(sceneIcon(s.icon), null, tint = p.text)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(s.name, style = NType.body(16.sp, p.text, 500))
                            Text(listOfNotNull("${s.actions.size} devices", s.schedule?.let { "${it.time} · ${it.daysLabel}" }).joinToString(" · "),
                                style = NType.body(13.sp, p.textDim))
                        }
                        IconButton(onClick = { nav.scene = s.id }) { Icon(Icons.Outlined.Edit, "Edit", tint = p.textDim) }
                    }
                }
            }
            item {
                Text("Tap a scene to run it. Timed scenes run while the app is open in this version.",
                    style = NType.body(12.sp, p.textDim), modifier = Modifier.padding(top = 8.dp))
            }
        }
    }
}

/** Makes or changes a scene: its name, icon, time, and what each device does. */
@Composable
fun SceneEditor(state: StoreState, id: String, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val p = palette
    val d = state.data
    val existing = d.scenes.firstOrNull { it.id == id }
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var icon by remember { mutableStateOf(existing?.icon ?: "auto") }
    var actions by remember { mutableStateOf<Map<String, SceneAction>>(existing?.actions?.associateBy { it.deviceId } ?: emptyMap()) }
    var timed by remember { mutableStateOf(existing?.schedule != null) }
    var hour by remember { mutableIntStateOf(existing?.schedule?.hour ?: 7) }
    var minute by remember { mutableIntStateOf(existing?.schedule?.minute ?: 0) }
    var days by remember { mutableStateOf(existing?.schedule?.days ?: (1..7).toSet()) }
    var confirm by remember { mutableStateOf(false) }
    NSheet(onDismiss) {
        DotText(if (existing == null) "New scene" else "Scene", 26)
        Spacer(Modifier.height(12.dp))
        if (existing == null && name.isEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((n, i) in Scene.templates) NChip(n, icon = sceneIcon(i)) {
                    name = n; icon = i
                    actions = if (i == "off" || i == "away" || i == "night") {
                        d.devices.mapNotNull { SceneAction.turn(it, false) }.associateBy { it.deviceId }
                    } else d.devices.filter { it.countsAsOn }.map { SceneAction.capture(it) }.associateBy { it.deviceId }
                }
            }
            Spacer(Modifier.height(12.dp))
        }
        NTextField(name, { name = it }, "Name")
        Spacer(Modifier.height(12.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (k in sceneIconKeys) {
                IconButton(onClick = { icon = k }) { Icon(sceneIcon(k), k, tint = if (icon == k) Palette.Red else p.textDim) }
            }
        }
        SectionLabel("Devices · ${actions.size}", trailing = {
            HeaderAction("Use how they are now") {
                actions = d.devices.filter { it.id in actions || it.countsAsOn }.map { SceneAction.capture(it) }.associateBy { it.deviceId }
            }
        })
        Text("For each device pick On (as it is now), Off, or leave it out.", style = NType.body(13.sp, p.textDim))
        Spacer(Modifier.height(8.dp))
        for (dev in d.devices) {
            val a = actions[dev.id]
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(deviceIcon(dev.kind), null, tint = p.text, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(dev.name, style = NType.body(14.sp, p.text, 500))
                    Text(state.roomName(dev.roomId) ?: "No room", style = NType.body(12.sp, p.textDim))
                }
                NChip("On", selected = a != null && !a.isOff) {
                    actions = actions + (dev.id to (if (dev.state.isActive) SceneAction.capture(dev) else SceneAction.turn(dev, true) ?: SceneAction.capture(dev)))
                }
                Spacer(Modifier.width(6.dp))
                val off = SceneAction.turn(dev, false)
                if (off != null) {
                    NChip("Off", selected = a != null && a.isOff) { actions = actions + (dev.id to off) }
                    Spacer(Modifier.width(6.dp))
                }
                NChip("—", selected = a == null) { actions = actions - dev.id }
            }
        }
        SectionLabel("Time")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Run by itself", style = NType.body(15.sp, p.text, 500), modifier = Modifier.weight(1f))
            NSwitch(timed) { timed = it }
        }
        if (timed) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconButton(onClick = { hour = (hour + 23) % 24 }) { Icon(Icons.Outlined.Remove, "Earlier hour", tint = p.text) }
                DotText("%02d".format(hour), 44)
                IconButton(onClick = { hour = (hour + 1) % 24 }) { Icon(Icons.Outlined.Add, "Later hour", tint = p.text) }
                DotText(":", 44)
                IconButton(onClick = { minute = (minute + 55) % 60 }) { Icon(Icons.Outlined.Remove, "Earlier", tint = p.text) }
                DotText("%02d".format(minute), 44)
                IconButton(onClick = { minute = (minute + 5) % 60 }) { Icon(Icons.Outlined.Add, "Later", tint = p.text) }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun").forEachIndexed { i, n ->
                    val day = i + 1
                    NChip(n, selected = day in days) { days = if (day in days) days - day else days + day }
                }
            }
        }
        Spacer(Modifier.height(18.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PrimaryButton("Save", {
                store.saveScene(Scene(
                    id = existing?.id ?: store.newSceneId(),
                    name = name.ifBlank { "Scene" },
                    icon = icon,
                    actions = d.devices.mapNotNull { actions[it.id] },
                    schedule = if (timed && days.isNotEmpty()) SceneSchedule(hour, minute, days) else null,
                ))
                onDismiss()
            }, enabled = actions.isNotEmpty())
            if (existing != null) {
                SecondaryButton("Run", { store.runScene(existing.id) })
                SecondaryButton(if (confirm) "Tap again" else "Remove", { if (confirm) { store.removeScene(existing.id); onDismiss() } else confirm = true })
            }
        }
    }
}
