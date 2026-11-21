package com.smartmenukj.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.StoreState

/** Every device, by room, with a search and a kind filter. */
@Composable
fun DevicesScreen(state: StoreState) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    var kind by remember { mutableStateOf<DeviceKind?>(null) }
    var query by remember { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    val d = state.data
    val shown = d.devices.filter { (kind == null || it.kind == kind) && (query.isBlank() || it.name.contains(query, true)) }
    val groups = (d.rooms.map { it.id to it.name } + (null to "No room")).map { (id, name) ->
        name to shown.filter { if (id == null) d.room(it.roomId) == null else it.roomId == id }
    }.filter { it.second.isNotEmpty() }
    val kinds = d.devices.map { it.kind }.distinct()
    val span: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }

    Column(Modifier.fillMaxSize()) {
        ScreenTitle("Devices") { NChip("Add", icon = Icons.Outlined.Add) { adding = true } }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(160.dp),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 28.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(span = span) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    NTextField(query, { query = it }, "Search")
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        NChip("All ${d.devices.size}", selected = kind == null) { kind = null }
                        for (k in kinds) NChip(k.label, selected = kind == k, icon = deviceIcon(k)) { kind = if (kind == k) null else k }
                    }
                }
            }
            if (d.devices.isEmpty()) item(span = span) {
                Text("No devices yet. Connect them in Connect, or add a virtual one to plan.", style = NType.body(14.sp, p.textDim))
            }
            for ((name, list) in groups) {
                item(span = span) { SectionLabel("$name · ${list.size}") }
                items(list, key = { it.id }) { dev ->
                    DeviceTile(dev, Describe.state(dev), { store.toggle(dev.id) }, { nav.device = dev.id },
                        { v -> Describe.levelCommand(dev, v)?.let { store.command(dev.id, it) } })
                }
            }
        }
    }
    if (adding) AddVirtualDevice(state) { adding = false }
}

/** Adds a device that lives only in the app, to try things or plan a room. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun AddVirtualDevice(state: StoreState, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    var name by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf(DeviceKind.light) }
    var room by remember { mutableStateOf(state.data.rooms.firstOrNull()?.id) }
    NSheet(onDismiss) {
        DotText("Virtual device", 26)
        Text("Real devices come in through Connect. A virtual one lives only here, for trying the app or planning.",
            style = NType.body(14.sp, p.textDim))
        Spacer(Modifier.height(14.dp))
        NTextField(name, { name = it }, "Name", hint = kind.label)
        Spacer(Modifier.height(12.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (k in listOf(DeviceKind.light, DeviceKind.outlet, DeviceKind.cover, DeviceKind.climate, DeviceKind.lock,
                DeviceKind.media, DeviceKind.vacuum, DeviceKind.sensor, DeviceKind.fan, DeviceKind.alarm)) {
                NChip(k.label, selected = kind == k, icon = deviceIcon(k)) { kind = k }
            }
        }
        Spacer(Modifier.height(12.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (r in state.data.rooms) NChip(r.name, selected = room == r.id) { room = r.id }
        }
        Spacer(Modifier.height(16.dp))
        PrimaryButton("Add", { val dev = store.addVirtualDevice(name, kind, room); onDismiss(); nav.device = dev.id })
    }
}
