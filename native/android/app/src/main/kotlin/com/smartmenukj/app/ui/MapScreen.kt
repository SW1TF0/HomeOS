package com.smartmenukj.app.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.HomeStore
import com.smartmenukj.core.store.StoreState
import kotlin.math.roundToInt

/**
 * The floor plan. Rooms are drawn on a dot grid; devices sit in them as dots that light up when on. Tap a device to
 * switch it, hold it for its controls. In edit mode rooms and devices can be dragged, rooms resized from their corner.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MapScreen(state: StoreState) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val d = state.data
    val floor = d.floors.firstOrNull { it.id == nav.mapFloor } ?: d.floors.firstOrNull()
    var addingRoom by remember { mutableStateOf(false) }
    var floorMenu by remember { mutableStateOf<Floor?>(null) }
    var addingFloor by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        ScreenTitle("Map") {
            if (nav.mapEdit && state.canUndo) {
                IconButton(onClick = { store.undoLayout() }) { Icon(Icons.AutoMirrored.Outlined.Undo, "Undo", tint = p.text) }
            }
            NChip(if (nav.mapEdit) "Done" else "Edit", selected = nav.mapEdit,
                icon = if (nav.mapEdit) Icons.Outlined.Check else Icons.Outlined.Edit) { nav.mapEdit = !nav.mapEdit }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (f in d.floors) {
                Box(Modifier.clip(CircleShape).combinedClickable(onClick = { nav.mapFloor = f.id }, onLongClick = { floorMenu = f })) {
                    NChip(f.name, selected = f.id == floor?.id) { nav.mapFloor = f.id }
                }
            }
            NChip("Floor", icon = Icons.Outlined.Add) { addingFloor = true }
        }
        if (floor == null) return@Column
        val rooms = d.roomsOn(floor.id)
        val placed = d.devices.filter { it.floorId == floor.id && it.mapPos != null }
        val unplaced = d.devices.filter { it.mapPos == null || it.floorId == null || d.floors.none { f -> f.id == it.floorId } }
        if (nav.mapEdit) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                NChip("Room", icon = Icons.Outlined.AddBox) { addingRoom = true }
                if (unplaced.isNotEmpty()) Text("Tap to place:", style = NType.body(12.sp, p.textDim))
                for (dev in unplaced.take(40)) {
                    NChip(dev.name, icon = deviceIcon(dev.kind)) {
                        val room = d.room(dev.roomId)?.takeIf { it.floorId == floor.id } ?: rooms.firstOrNull()
                        val pos = room?.let { HomeStore.freeSpot(d, it) } ?: MapPos(2.0, 2.0)
                        store.moveDevice(dev.id, floor.id, pos)
                    }
                }
            }
        }
        FloorPlan(floor, rooms, placed)
    }

    if (addingRoom && floor != null) {
        NameDialog("New room", "Room name", "", onDismiss = { addingRoom = false }) { store.addRoom(floor.id, it); addingRoom = false }
    }
    if (addingFloor) {
        NameDialog("New floor", "Floor name", "Floor ${d.floors.size + 1}", onDismiss = { addingFloor = false }) {
            nav.mapFloor = store.addFloor(it).id; addingFloor = false
        }
    }
    floorMenu?.let { f ->
        NameDialog("Floor", "Name", f.name, onDismiss = { floorMenu = null },
            extra = if (d.floors.size > 1) ({ TextButton(onClick = { store.removeFloor(f.id); floorMenu = null; nav.mapFloor = null }) {
                Text("Remove floor", color = Palette.Red)
            } }) else null) { store.renameFloor(f.id, it); floorMenu = null }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FloorPlan(floor: Floor, rooms: List<Room>, devices: List<Device>) {
    val nav = LocalNav.current
    val p = palette
    val density = LocalDensity.current
    val editing = nav.mapEdit
    BoxWithConstraints(Modifier.fillMaxSize().clip(RoundedCornerShape(0.dp))) {
        val widthPx = constraints.maxWidth.toFloat()
        // Fit the floor to the screen width the first time it is shown.
        val right = (rooms.maxOfOrNull { it.right } ?: 20.0).coerceAtLeast(10.0)
        var cell by remember(floor.id) { mutableFloatStateOf(((widthPx - with(density) { 32.dp.toPx() }) / (right + 1).toFloat()).coerceIn(12f, 120f)) }
        var pan by remember(floor.id) { mutableStateOf(Offset(with(density) { 8.dp.toPx() }, with(density) { 8.dp.toPx() })) }
        Box(
            Modifier.fillMaxSize()
                .dotGrid(p.dot, with(density) { cell.toDp() }, 1.4f, pan)
                .pointerInput(floor.id) {
                    detectTransformGestures { centroid, move, zoom, _ ->
                        val next = (cell * zoom).coerceIn(10f, 160f)
                        val f = next / cell
                        pan = (pan - centroid) * f + centroid + move
                        cell = next
                    }
                },
        ) {
            for (r in rooms) RoomBox(r, cell, pan, editing, devices.count { it.roomId == r.id && it.countsAsOn })
            for (dev in devices) DeviceDot(dev, floor.id, cell, pan, editing)
            if (rooms.isEmpty() && !editing) {
                Column(Modifier.align(Alignment.Center).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No rooms on this floor yet.", style = NType.body(15.sp, p.textDim))
                    Spacer(Modifier.height(10.dp))
                    PrimaryButton("Draw rooms", { nav.mapEdit = true })
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RoomBox(r: Room, cell: Float, pan: Offset, editing: Boolean, on: Int) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val density = LocalDensity.current
    // While dragging, the room follows the finger exactly; the store snaps it to the grid.
    var drag by remember(r.id) { mutableStateOf<Offset?>(null) }
    var grow by remember(r.id) { mutableStateOf<Offset?>(null) }
    val x = r.x * cell + pan.x + (drag?.x ?: 0f)
    val y = r.y * cell + pan.y + (drag?.y ?: 0f)
    val w = r.width * cell + (grow?.x ?: 0f)
    val h = r.height * cell + (grow?.y ?: 0f)
    val shape = RoundedCornerShape(10.dp)
    Box(
        Modifier.offset { IntOffset(x.roundToInt(), y.roundToInt()) }
            .size(with(density) { w.toFloat().coerceAtLeast(cell * 2).toDp() }, with(density) { h.toFloat().coerceAtLeast(cell * 2).toDp() })
            .clip(shape)
            .background(if (on > 0) p.surfaceHigh else p.surface.copy(alpha = 0.85f))
            .border(if (editing) 1.5.dp else 1.dp, if (editing) p.text else p.border, shape)
            .combinedClickable(onClick = { if (!editing) nav.room = r.id }, onLongClick = { nav.room = r.id })
            .then(if (editing) Modifier.pointerInput(r.id, cell) {
                detectDragGestures(
                    onDragStart = { store.beginLayoutChange(); drag = Offset.Zero },
                    onDragEnd = {
                        drag?.let { o -> store.setRoomRect(r.id, r.x + o.x / cell, r.y + o.y / cell, r.width, r.height, record = false) }
                        drag = null
                    },
                    onDragCancel = { drag = null },
                ) { ch, amount -> ch.consume(); drag = (drag ?: Offset.Zero) + amount }
            } else Modifier),
    ) {
        Text(r.name, style = NType.label(if (on > 0) p.text else p.textDim), maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(8.dp))
        if (on > 0) Box(Modifier.align(Alignment.TopEnd).padding(9.dp).size(6.dp).background(Palette.Accent, CircleShape))
        if (editing) {
            Box(
                Modifier.align(Alignment.BottomEnd).size(28.dp)
                    .pointerInput(r.id, cell) {
                        detectDragGestures(
                            onDragStart = { store.beginLayoutChange(); grow = Offset.Zero },
                            onDragEnd = {
                                grow?.let { g -> store.setRoomRect(r.id, r.x, r.y, r.width + g.x / cell, r.height + g.y / cell, record = false) }
                                grow = null
                            },
                            onDragCancel = { grow = null },
                        ) { ch, amount -> ch.consume(); grow = (grow ?: Offset.Zero) + amount }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.OpenInFull, "Resize", tint = p.text, modifier = Modifier.size(14.dp))
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DeviceDot(dev: Device, floorId: String, cell: Float, pan: Offset, editing: Boolean) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val density = LocalDensity.current
    val pos = dev.mapPos ?: return
    var drag by remember(dev.id) { mutableStateOf<Offset?>(null) }
    val active = dev.state.isActive && dev.state.reachable
    val size = with(density) { 34.dp.toPx() }
    val cx = (pos.x * cell + pan.x).toFloat() + (drag?.x ?: 0f)
    val cy = (pos.y * cell + pan.y).toFloat() + (drag?.y ?: 0f)
    val glow = Describe.lightColor(dev)?.asColor()
    Box(
        Modifier.offset { IntOffset((cx - size / 2).roundToInt(), (cy - size / 2).roundToInt()) }
            .size(34.dp)
            .clip(CircleShape)
            .background(if (active) (glow ?: p.text) else p.surfaceHigh)
            .border(1.dp, if (!dev.state.reachable) Palette.Red else if (active) Color.Transparent else p.border, CircleShape)
            .combinedClickable(
                onClick = { if (!editing && Describe.tapToggles(dev)) store.toggle(dev.id) else nav.device = dev.id },
                onLongClick = { nav.device = dev.id },
            )
            .then(if (editing) Modifier.pointerInput(dev.id, cell) {
                detectDragGestures(
                    onDragStart = { drag = Offset.Zero },
                    onDragEnd = {
                        drag?.let { o -> store.moveDevice(dev.id, floorId, MapPos(HomeStore.snap(pos.x + o.x / cell), HomeStore.snap(pos.y + o.y / cell))) }
                        drag = null
                    },
                    onDragCancel = { drag = null },
                ) { ch, amount -> ch.consume(); drag = (drag ?: Offset.Zero) + amount }
            } else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Icon(deviceIcon(dev.kind, active), dev.name, tint = if (active) Color.Black else p.text, modifier = Modifier.size(18.dp))
    }
}

/** A small dialog that asks for a name. */
@Composable
fun NameDialog(
    title: String,
    label: String,
    initial: String,
    onDismiss: () -> Unit,
    extra: (@Composable () -> Unit)? = null,
    onSave: (String) -> Unit,
) {
    val p = palette
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = p.surface,
        shape = RoundedCornerShape(28.dp),
        title = { Text(title, style = NType.dot(24.sp, p.text)) },
        text = {
            Column {
                NTextField(text, { text = it }, label)
                extra?.let { Spacer(Modifier.height(8.dp)); it() }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(text.trim()) }) { Text("Save", color = p.text) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = p.textDim) } },
    )
}
