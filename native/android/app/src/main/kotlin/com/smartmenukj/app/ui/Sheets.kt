@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.smartmenukj.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.StoreState

/** A room: its devices, an all-off switch, rename and remove. */
@Composable
fun RoomSheet(state: StoreState, id: String, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val room = state.data.room(id)
    if (room == null) {
        LaunchedEffect(Unit) { onDismiss() }
        return
    }
    val devices = state.data.devicesIn(id)
    var renaming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf(room.name) }
    var confirm by remember { mutableStateOf(false) }
    NSheet(onDismiss) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                DotText(room.name, 28)
                val on = devices.count { it.countsAsOn }
                Text(if (on == 0) "${devices.size} devices, all off" else "$on of ${devices.size} on", style = NType.body(14.sp, p.textDim))
            }
            val anyOn = devices.any { it.countsAsOn }
            PowerOrb(anyOn, {
                for (d in devices) SceneAction.turn(d, !anyOn)?.let { store.command(d.id, it.command) }
            }, size = 56.dp)
        }
        Spacer(Modifier.height(16.dp))
        if (devices.isEmpty()) {
            Text("No devices here yet. Open a device and pick this room, or drag it into the room on the map.",
                style = NType.body(14.sp, p.textDim))
        }
        FlowRow(maxItemsInEachRow = 2, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            for (d in devices) {
                DeviceTile(d, Describe.state(d), { store.toggle(d.id) }, { nav.device = d.id },
                    { v -> Describe.levelCommand(d, v)?.let { store.command(d.id, it) } }, Modifier.weight(1f))
            }
            if (devices.size % 2 == 1) Spacer(Modifier.weight(1f))
        }
        Spacer(Modifier.height(18.dp))
        if (renaming) {
            NTextField(name, { name = it }, "Room name")
            Spacer(Modifier.height(10.dp))
            PrimaryButton("Save", { store.renameRoom(id, name); renaming = false })
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                NChip("Rename", icon = Icons.Outlined.Edit) { renaming = true }
                NChip("Show on map", icon = Icons.Outlined.GridView) { onDismiss(); nav.openMap(floorId = room.floorId) }
                NChip(if (confirm) "Tap again" else "Remove", icon = Icons.Outlined.Delete) {
                    if (confirm) { store.removeRoom(id); onDismiss() } else confirm = true
                }
            }
        }
    }
}

/** The list of homes: switch, add, rename, remove. */
@Composable
fun HomesSheet(state: StoreState, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val p = palette
    var adding by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var renaming by remember { mutableStateOf<String?>(null) }
    NSheet(onDismiss) {
        DotText("Homes", 28)
        Spacer(Modifier.height(12.dp))
        for (h in state.homes) {
            SettingRow(
                h.name,
                if (h.id == state.homeId) "Open now" else null,
                Icons.Outlined.Home,
                onClick = { store.switchHome(h.id); onDismiss() },
            ) {
                if (h.id == state.homeId) Box(Modifier.size(8.dp).background(Palette.Red, CircleShape))
                androidx.compose.material3.IconButton(onClick = { renaming = h.id; name = h.name }) {
                    Icon(Icons.Outlined.Edit, "Rename", tint = p.textDim)
                }
                if (state.homes.size > 1) androidx.compose.material3.IconButton(onClick = { store.removeHome(h.id) }) {
                    Icon(Icons.Outlined.Delete, "Remove", tint = p.textDim)
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        val target = renaming
        if (adding || target != null) {
            NTextField(name, { name = it }, if (target != null) "New name" else "Name of the home")
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PrimaryButton(if (target != null) "Rename" else "Add home", {
                    if (target != null) store.renameHome(target, name) else { store.addHome(name); onDismiss() }
                    adding = false; renaming = null; name = ""
                })
                SecondaryButton("Cancel", { adding = false; renaming = null })
            }
        } else {
            SecondaryButton("Add a home", { adding = true; name = "" })
        }
    }
}
