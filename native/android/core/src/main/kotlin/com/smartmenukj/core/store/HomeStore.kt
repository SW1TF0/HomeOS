package com.smartmenukj.core.store

import com.smartmenukj.core.integrations.Catalog
import com.smartmenukj.core.integrations.IntegrationDriver
import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import kotlin.math.floor

/** Where homes are kept: small named text files. */
interface HomeStorage {
    fun read(name: String): String?
    fun write(name: String, text: String)
    fun delete(name: String)
}

class MemoryStorage : HomeStorage {
    val files = mutableMapOf<String, String>()
    override fun read(name: String) = files[name]
    override fun write(name: String, text: String) { files[name] = text }
    override fun delete(name: String) { files.remove(name) }
}

/** How a connection did the last time it was used. */
data class IntegrationStatus(val ok: Boolean, val message: String = "", val at: Long = System.currentTimeMillis())

data class StoreState(
    val loaded: Boolean = false,
    val homes: List<HomeEntry> = emptyList(),
    val homeId: String = "",
    val data: HomeData = HomeData(),
    val status: Map<String, IntegrationStatus> = emptyMap(),
    /** Connections being searched or paired right now. */
    val busy: Set<String> = emptySet(),
    val canUndo: Boolean = false,
) {
    val home: HomeEntry? get() = homes.firstOrNull { it.id == homeId }
}

/**
 * Everything the app knows and does with a home. The screens read [state] and call these methods; nothing else
 * changes a home. Saves a moment after each change.
 */
class HomeStore(
    private val storage: HomeStorage,
    private val http: Http,
    private val scope: CoroutineScope,
    private val newId: () -> String = { UUID.randomUUID().toString().take(8) },
    private val saveDelayMs: Long = 400,
) {
    private val _state = MutableStateFlow(StoreState())
    val state: StateFlow<StoreState> = _state.asStateFlow()
    val data: HomeData get() = _state.value.data

    /** Short messages for the user ("Hue: added 3 new devices."). */
    var onMessage: (String) -> Unit = {}

    private val drivers = mutableMapOf<String, IntegrationDriver>()
    private var saveJob: Job? = null
    private var pollJob: Job? = null
    private val undo = ArrayDeque<HomeData>()

    // ---- Loading and saving ------------------------------------------------------------------

    fun load() {
        val list = storage.read(HOMES)?.let { runCatching { parseJson(it).asObj() }.getOrNull() }
        var homes = list?.list("homes")?.mapNotNull { e -> e.asObj()?.let { runCatching { HomeEntry.fromJson(it) }.getOrNull() } }
            ?: emptyList()
        var current = list?.string("current")
        if (homes.isEmpty()) {
            val id = "home"
            homes = listOf(HomeEntry(id, DEFAULT_HOME))
            current = id
            storage.write(homeFile(id), Seed.sampleHome().toJson().toString())
            writeHomes(homes, id)
        }
        val id = homes.firstOrNull { it.id == current }?.id ?: homes.first().id
        val d = readHome(id) ?: Seed.emptyHome()
        _state.value = StoreState(loaded = true, homes = homes, homeId = id, data = d)
        startDrivers()
    }

    private fun readHome(id: String): HomeData? =
        storage.read(homeFile(id))?.let { t -> runCatching { HomeData.fromJson(parseJson(t).asObj()!!) }.getOrNull() }

    private fun writeHomes(homes: List<HomeEntry>, current: String) {
        storage.write(HOMES, jsonObjectOf("current" to current, "homes" to homes.map { it.toJson() }).toString())
    }

    private fun saveSoon() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(saveDelayMs)
            saveNow()
        }
    }

    fun saveNow() {
        val s = _state.value
        if (!s.loaded) return
        storage.write(homeFile(s.homeId), s.data.toJson().toString())
        writeHomes(s.homes, s.homeId)
        onSaved()
    }

    /** Called after every save, so a backup file can follow. */
    var onSaved: () -> Unit = {}

    private fun change(layout: Boolean = false, save: Boolean = true, f: (HomeData) -> HomeData) {
        _state.update { s ->
            if (layout) {
                undo.addLast(s.data)
                while (undo.size > 30) undo.removeFirst()
            }
            s.copy(data = f(s.data), canUndo = undo.isNotEmpty())
        }
        if (save) saveSoon()
    }

    private fun devices(f: (List<Device>) -> List<Device>) = change { it.copy(devices = f(it.devices)) }

    private fun device(id: String, f: (Device) -> Device) = devices { list -> list.map { if (it.id == id) f(it) else it } }

    // ---- Connections ------------------------------------------------------------------------

    private fun startDrivers() {
        drivers.values.forEach { d -> scope.launch { runCatching { d.stop() } } }
        drivers.clear()
        for (cfg in data.integrations) {
            if (!cfg.enabled) continue
            val spec = Catalog.spec(cfg.type) ?: continue
            val driver = spec.create(cfg, http)
            drivers[cfg.id] = driver
            scope.launch { runCatching { driver.start() } }
        }
    }

    fun driverFor(device: Device): IntegrationDriver? = drivers[device.integrationId]

    /** Whether this app can control [device] (its connection is one this app has). */
    fun canControl(device: Device) = drivers.containsKey(device.integrationId)

    fun addIntegration(type: String, name: String? = null, settings: Map<String, String> = emptyMap()): IntegrationConfig {
        val spec = Catalog.spec(type) ?: throw IllegalArgumentException("Unknown connection $type")
        if (type == "demo") data.integrations.firstOrNull { it.type == "demo" }?.let { return it }
        val cfg = IntegrationConfig(id = "$type-${newId()}", type = type, name = name ?: spec.name,
            settings = toJsonElement(settings) as JsonObject)
        change { it.copy(integrations = it.integrations + cfg) }
        startDrivers()
        return cfg
    }

    fun updateIntegration(id: String, name: String, settings: Map<String, String>) {
        change { d ->
            d.copy(integrations = d.integrations.map {
                if (it.id == id) it.copy(name = name, settings = it.settings + (toJsonElement(settings) as JsonObject)) else it
            })
        }
        startDrivers()
    }

    /** Removes a connection and every device that came from it. */
    fun removeIntegration(id: String) {
        change { d ->
            val gone = d.devices.filter { it.integrationId == id }.map { it.id }.toSet()
            d.copy(
                integrations = d.integrations.filter { it.id != id },
                devices = d.devices.filter { it.integrationId != id },
                scenes = d.scenes.map { s -> s.copy(actions = s.actions.filter { it.deviceId !in gone }) },
            )
        }
        startDrivers()
    }

    private fun busy(id: String, on: Boolean) = _state.update { it.copy(busy = if (on) it.busy + id else it.busy - id) }

    private fun status(id: String, st: IntegrationStatus) = _state.update { it.copy(status = it.status + (id to st)) }

    /** Pairs a connection that needs it (Hue's link button) and keeps what it was given. */
    suspend fun pair(id: String): Boolean {
        val driver = drivers[id] ?: return false
        busy(id, true)
        return try {
            val got = driver.pair()
            val cfg = data.integration(id)!!
            updateIntegration(id, cfg.name, got)
            onMessage("${cfg.name}: paired.")
            true
        } catch (e: Exception) {
            status(id, IntegrationStatus(false, e.message ?: "$e"))
            onMessage("${data.integration(id)?.name}: ${e.message}")
            false
        } finally {
            busy(id, false)
        }
    }

    /** Finds the devices of a connection. New ones are added without a room; known ones keep where they are. */
    suspend fun sync(id: String): Int {
        val driver = drivers[id] ?: return 0
        val cfg = data.integration(id) ?: return 0
        busy(id, true)
        try {
            val found = driver.discover()
            var added = 0
            devices { list ->
                val byId = list.associateBy { it.id }.toMutableMap()
                val order = list.map { it.id }.toMutableList()
                for (f in found) {
                    val old = byId[f.id]
                    if (old == null) {
                        byId[f.id] = f
                        order += f.id
                        added++
                    } else {
                        // Keep what was learned later (pairing tokens, keys...).
                        byId[f.id] = old.copy(props = old.props + f.props, capabilities = f.capabilities,
                            state = old.state.merge(f.state))
                    }
                }
                order.map { byId[it]!! }
            }
            status(id, IntegrationStatus(true, "${found.size} devices"))
            onMessage(if (added == 0) "${cfg.name}: ${found.size} devices, nothing new." else "${cfg.name}: added $added new devices.")
            return added
        } catch (e: Exception) {
            status(id, IntegrationStatus(false, e.message ?: "$e"))
            onMessage("${cfg.name}: ${e.message}")
            return 0
        } finally {
            busy(id, false)
        }
    }

    /** Reads the state of every device from its connection. */
    suspend fun refreshAll() = coroutineScope {
        val d = data
        val jobs = mutableListOf<Deferred<Map<String, DeviceState>>>()
        for (cfg in d.integrations) {
            if (!cfg.enabled || Catalog.spec(cfg.type)?.polls != true) continue
            val driver = drivers[cfg.id] ?: continue
            val mine = d.devices.filter { it.integrationId == cfg.id }
            if (mine.isNotEmpty()) jobs += async { runCatching { driver.refreshAll(mine) }.getOrDefault(emptyMap()) }
        }
        val results = jobs.awaitAll()
        val merged = results.fold(emptyMap<String, DeviceState>()) { a, b -> a + b }
        if (merged.isNotEmpty()) {
            change(save = false) { h -> h.copy(devices = h.devices.map { dev -> merged[dev.id]?.let { dev.copy(state = it) } ?: dev }) }
        }
    }

    /** Reads every device now and then every [seconds] while the app is open. */
    fun startPolling(seconds: Int) {
        pollJob?.cancel()
        pollJob = scope.launch {
            while (isActive) {
                runCatching { refreshAll() }
                delay(seconds.coerceAtLeast(3) * 1000L)
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    // ---- Devices ----------------------------------------------------------------------------

    /**
     * Shows the change at once and sends it. If the device refuses, it goes back to how it was and the user is told
     * why.
     */
    fun command(deviceId: String, c: DeviceCommand): Job = scope.launch { send(deviceId, c) }

    suspend fun send(deviceId: String, c: DeviceCommand): Boolean {
        val dev = data.device(deviceId) ?: return false
        val before = dev.state
        if (c.key == null || c.key == RemoteKey.mute || c.key == RemoteKey.power) {
            device(deviceId) { it.copy(state = it.state.applyCommand(c)) }
        }
        val driver = drivers[dev.integrationId]
        if (driver == null) {
            device(deviceId) { it.copy(state = before) }
            onMessage("${dev.name}: this connection does not work in this version yet.")
            return false
        }
        return try {
            val confirmed = driver.send(data.device(deviceId) ?: dev, c)
            if (confirmed != null) device(deviceId) { it.copy(state = it.state.merge(confirmed)) }
            true
        } catch (e: Exception) {
            device(deviceId) { it.copy(state = before.merge(DeviceState(reachable = before.reachable))) }
            onMessage("${dev.name}: ${e.message ?: "did not answer"}")
            false
        }
    }

    /** The main switch of a device: on/off, open/close, lock/unlock, start/go home. */
    fun toggle(deviceId: String) {
        val d = data.device(deviceId) ?: return
        val s = d.state
        val c = when {
            d.has(Capability.onOff) -> DeviceCommand(on = s.on != true)
            d.has(Capability.position) -> DeviceCommand(position = if ((s.position ?: 0.0) > 0.01) 0.0 else 1.0)
            d.has(Capability.lock) -> DeviceCommand(locked = s.locked != true)
            d.has(Capability.run) -> DeviceCommand(action = if (s.activity == Activity.RUNNING) {
                if (d.has(Capability.dock)) DeviceAction.dock else DeviceAction.pause
            } else DeviceAction.start)
            d.has(Capability.press) -> DeviceCommand(action = DeviceAction.press)
            else -> return
        }
        command(deviceId, c)
    }

    fun renameDevice(id: String, name: String) = device(id) { it.copy(name = name.trim().ifEmpty { it.name }) }

    fun setFavorite(id: String, favorite: Boolean) = device(id) { it.copy(favorite = favorite) }

    fun setKind(id: String, kind: DeviceKind) = device(id) { it.copy(kind = kind) }

    /** Puts a device in a room. It is placed on the map inside the room unless it already is. */
    fun setRoom(id: String, roomId: String?) {
        val room = data.room(roomId)
        change(layout = true) { d ->
            d.copy(devices = d.devices.map { dev ->
                if (dev.id != id) dev
                else if (room == null) dev.copy(roomId = null)
                else {
                    val inside = dev.mapPos?.let { room.contains(it) && dev.floorId == room.floorId } == true
                    dev.copy(roomId = room.id, floorId = room.floorId,
                        mapPos = if (inside) dev.mapPos else freeSpot(d, room))
                }
            })
        }
    }

    /** Moves a device on the map. Dropped inside a room, it belongs to that room. */
    fun moveDevice(id: String, floorId: String, pos: MapPos) {
        change(layout = true) { d ->
            val room = d.roomsOn(floorId).lastOrNull { it.contains(pos) }
            d.copy(devices = d.devices.map {
                if (it.id == id) it.copy(mapPos = pos, floorId = floorId, roomId = room?.id) else it
            })
        }
    }

    fun removeDevice(id: String) = change { d ->
        d.copy(devices = d.devices.filter { it.id != id },
            scenes = d.scenes.map { s -> s.copy(actions = s.actions.filter { it.deviceId != id }) })
    }

    /** Adds a virtual device (it lives only in the app). */
    fun addVirtualDevice(name: String, kind: DeviceKind, roomId: String?): Device {
        val demo = addIntegration("demo")
        val ext = "manual:${newId()}"
        val room = data.room(roomId)
        val dev = Device(
            id = Device.idFor(demo.id, ext), name = name.ifBlank { kind.label }, kind = kind, integrationId = demo.id,
            externalId = ext, roomId = room?.id, floorId = room?.floorId ?: data.floors.firstOrNull()?.id,
            mapPos = room?.let { freeSpot(data, it) },
            props = if (kind == DeviceKind.vacuum) jsonObjectOf("modes" to listOf("Quiet", "Balanced", "Turbo")) else JsonObject(emptyMap()),
            state = when (kind) {
                DeviceKind.light -> DeviceState(on = false, brightness = 1.0, colorTempK = 3000)
                DeviceKind.climate -> DeviceState(on = true, targetTemp = 21.0, currentTemp = 21.0)
                DeviceKind.cover, DeviceKind.garage -> DeviceState(position = 0.0)
                DeviceKind.lock -> DeviceState(locked = true)
                DeviceKind.vacuum, DeviceKind.mower -> DeviceState(activity = Activity.DOCKED, battery = 1.0)
                DeviceKind.alarm -> DeviceState(activity = Activity.DISARMED)
                DeviceKind.sensor -> DeviceState(readings = mapOf("Temperature" to "21 °C"))
                else -> DeviceState(on = false)
            },
        )
        devices { it + dev }
        return dev
    }

    // ---- Floors and rooms -------------------------------------------------------------------

    fun addFloor(name: String): Floor {
        val f = Floor("floor-${newId()}", name.ifBlank { "Floor ${data.floors.size + 1}" })
        change(layout = true) { it.copy(floors = it.floors + f) }
        return f
    }

    fun renameFloor(id: String, name: String) =
        change { d -> d.copy(floors = d.floors.map { if (it.id == id) it.copy(name = name.ifBlank { it.name }) else it }) }

    /** Removes a floor with its rooms. Its devices stay, without a room or a place on the map. */
    fun removeFloor(id: String) {
        if (data.floors.size <= 1) return
        change(layout = true) { d ->
            d.copy(
                floors = d.floors.filter { it.id != id },
                rooms = d.rooms.filter { it.floorId != id },
                devices = d.devices.map { if (it.floorId == id) it.copy(floorId = null, roomId = null, mapPos = null) else it },
            )
        }
    }

    /** Adds a room in the first free place on [floorId]. */
    fun addRoom(floorId: String, name: String, width: Double = 6.0, height: Double = 5.0): Room {
        val spot = freeRoomSpot(data.roomsOn(floorId), width, height)
        val r = Room("room-${newId()}", floorId, name.ifBlank { "Room" }, spot.x, spot.y, width, height)
        change(layout = true) { it.copy(rooms = it.rooms + r) }
        return r
    }

    fun renameRoom(id: String, name: String) =
        change { d -> d.copy(rooms = d.rooms.map { if (it.id == id) it.copy(name = name.ifBlank { it.name }) else it }) }

    /** Moves and resizes a room, snapped to the grid. Devices inside move with it. */
    fun setRoomRect(id: String, x: Double, y: Double, w: Double, h: Double, record: Boolean = true) {
        val old = data.room(id) ?: return
        val nx = snap(x).coerceAtLeast(0.0); val ny = snap(y).coerceAtLeast(0.0)
        val nw = snap(w).coerceAtLeast(MIN_ROOM); val nh = snap(h).coerceAtLeast(MIN_ROOM)
        if (nx == old.x && ny == old.y && nw == old.width && nh == old.height) return
        val dx = nx - old.x; val dy = ny - old.y
        val moved = w == old.width && h == old.height
        change(layout = record) { d ->
            d.copy(
                rooms = d.rooms.map { if (it.id == id) it.copy(x = nx, y = ny, width = nw, height = nh) else it },
                devices = d.devices.map { dev ->
                    val p = dev.mapPos
                    if (dev.roomId != id || p == null) dev
                    else if (moved) dev.copy(mapPos = MapPos(p.x + dx, p.y + dy))
                    else dev.copy(mapPos = MapPos(p.x.coerceIn(nx + 0.5, nx + nw - 0.5), p.y.coerceIn(ny + 0.5, ny + nh - 0.5)))
                },
            )
        }
    }

    /** Remembers the layout before a drag, so one undo takes back the whole drag. */
    fun beginLayoutChange() {
        undo.addLast(data)
        while (undo.size > 30) undo.removeFirst()
        _state.update { it.copy(canUndo = true) }
    }

    fun undoLayout() {
        val last = undo.removeLastOrNull() ?: return
        _state.update { it.copy(data = it.data.copy(floors = last.floors, rooms = last.rooms,
            devices = it.data.devices.map { d -> last.device(d.id)?.let { o -> d.copy(roomId = o.roomId, floorId = o.floorId, mapPos = o.mapPos) } ?: d }),
            canUndo = undo.isNotEmpty()) }
        saveSoon()
    }

    /** Removes a room. Its devices stay on the map, without a room. */
    fun removeRoom(id: String) = change(layout = true) { d ->
        d.copy(rooms = d.rooms.filter { it.id != id }, devices = d.devices.map { if (it.roomId == id) it.copy(roomId = null) else it })
    }

    // ---- Scenes -----------------------------------------------------------------------------

    fun saveScene(scene: Scene) = change { d ->
        d.copy(scenes = if (d.scenes.any { it.id == scene.id }) d.scenes.map { if (it.id == scene.id) scene else it } else d.scenes + scene)
    }

    fun newSceneId() = "scene-${newId()}"

    fun removeScene(id: String) = change { d -> d.copy(scenes = d.scenes.filter { it.id != id }) }

    /** Puts every device of a scene in its state, all at once. */
    fun runScene(id: String) {
        val scene = data.scenes.firstOrNull { it.id == id } ?: return
        scope.launch {
            val results = scene.actions.map { a -> async { send(a.deviceId, a.command) } }.awaitAll()
            val failed = results.count { !it }
            onMessage(if (failed == 0) "${scene.name}: done." else "${scene.name}: $failed devices did not answer.")
        }
    }

    /** Scenes with a time that is due now. Called once a minute while the app is open. */
    fun runDueScenes(day: Int, hour: Int, minute: Int) {
        for (s in data.scenes) {
            val t = s.schedule ?: continue
            if (t.hour == hour && t.minute == minute && day in t.days) runScene(s.id)
        }
    }

    // ---- Homes ------------------------------------------------------------------------------

    fun setTheme(mode: String) = change { it.copy(themeMode = mode) }

    fun addHome(name: String, sample: Boolean = false): HomeEntry {
        saveNow()
        val e = HomeEntry("home-${newId()}", name.ifBlank { DEFAULT_HOME })
        val d = if (sample) Seed.sampleHome() else Seed.emptyHome()
        storage.write(homeFile(e.id), d.toJson().toString())
        undo.clear()
        _state.update { it.copy(homes = it.homes + e, homeId = e.id, data = d, status = emptyMap(), canUndo = false) }
        writeHomes(_state.value.homes, e.id)
        startDrivers()
        return e
    }

    fun switchHome(id: String) {
        if (id == _state.value.homeId) return
        saveNow()
        val d = readHome(id) ?: Seed.emptyHome()
        undo.clear()
        _state.update { it.copy(homeId = id, data = d, status = emptyMap(), canUndo = false) }
        writeHomes(_state.value.homes, id)
        startDrivers()
    }

    fun renameHome(id: String, name: String) {
        _state.update { s -> s.copy(homes = s.homes.map { if (it.id == id) it.copy(name = name.ifBlank { it.name }) else it }) }
        writeHomes(_state.value.homes, _state.value.homeId)
    }

    fun removeHome(id: String) {
        val s = _state.value
        if (s.homes.size <= 1) return
        storage.delete(homeFile(id))
        val rest = s.homes.filter { it.id != id }
        if (id == s.homeId) {
            _state.update { it.copy(homes = rest, homeId = "") }
            switchHome(rest.first().id)
        } else {
            _state.update { it.copy(homes = rest) }
            writeHomes(rest, s.homeId)
        }
    }

    /** Swaps the sample home for an empty one. */
    fun clearSample() {
        change { Seed.emptyHome().copy(themeMode = it.themeMode) }
        startDrivers()
    }

    // ---- Backup -----------------------------------------------------------------------------

    /** Every home as one JSON text, in the same shape as the Flutter app's backup file. */
    fun exportAll(): String {
        saveNow()
        val s = _state.value
        val homes = s.homes.mapNotNull { h ->
            val d = (if (h.id == s.homeId) s.data else readHome(h.id)) ?: return@mapNotNull null
            jsonObjectOf("id" to h.id, "name" to h.name, "home" to d.toJson(withState = false))
        }
        return prettyJson.encodeToString(JsonObject.serializer(),
            jsonObjectOf("app" to "SmartMenuKJ", "backup" to "homes", "current" to s.homeId, "homes" to homes))
    }

    /**
     * Takes back the homes in a backup: a backup of every home replaces the homes here, a backup of one home replaces
     * the open home. Returns how many homes came back.
     */
    fun importAll(raw: String): Int {
        val j = runCatching { parseJson(raw).asObj() }.getOrNull() ?: throw IllegalArgumentException("That is not a SmartMenuKJ backup.")
        val list = j.list("homes")
        if (j.string("backup") != "homes" || list == null) {
            val d = HomeData.fromJson(j)
            if (d.floors.isEmpty()) throw IllegalArgumentException("That backup has no home in it.")
            undo.clear()
            _state.update { it.copy(data = d, status = emptyMap(), canUndo = false) }
            saveNow()
            startDrivers()
            return 1
        }
        val next = mutableListOf<Pair<HomeEntry, HomeData>>()
        for (h in list) {
            val o = h.asObj() ?: continue
            val id = o.string("id") ?: continue
            val d = o.obj("home")?.let { runCatching { HomeData.fromJson(it) }.getOrNull() } ?: continue
            if (d.floors.isEmpty() || next.any { it.first.id == id }) continue
            next += HomeEntry(id, o.string("name") ?: DEFAULT_HOME) to d
        }
        if (next.isEmpty()) throw IllegalArgumentException("That backup has no homes.")
        for (old in _state.value.homes) if (next.none { it.first.id == old.id }) storage.delete(homeFile(old.id))
        for ((e, d) in next) storage.write(homeFile(e.id), d.toJson().toString())
        val current = next.firstOrNull { it.first.id == j.string("current") } ?: next.first()
        undo.clear()
        _state.update { it.copy(homes = next.map { p -> p.first }, homeId = current.first.id, data = current.second,
            status = emptyMap(), canUndo = false) }
        writeHomes(_state.value.homes, current.first.id)
        startDrivers()
        return next.size
    }

    companion object {
        const val DEFAULT_HOME = "My home"
        const val HOMES = "homes.json"
        const val MIN_ROOM = 2.0
        fun homeFile(id: String) = "home-$id.json"

        fun snap(v: Double) = Math.round(v * 2) / 2.0

        /** A place inside [room] that no other device of the room is on. */
        fun freeSpot(d: HomeData, room: Room): MapPos {
            val taken = d.devices.filter { it.roomId == room.id }.mapNotNull { it.mapPos }
            val cols = floor(room.width - 1).toInt().coerceAtLeast(1)
            val rows = floor(room.height - 1).toInt().coerceAtLeast(1)
            for (r in 0 until rows) for (c in 0 until cols) {
                val p = MapPos(room.x + 1 + c, room.y + 1 + r)
                if (taken.none { kotlin.math.abs(it.x - p.x) < 0.9 && kotlin.math.abs(it.y - p.y) < 0.9 }) return p
            }
            return MapPos(room.x + room.width / 2, room.y + room.height / 2)
        }

        /** The top-left corner of the first gap on a floor where a room of this size fits. */
        fun freeRoomSpot(rooms: List<Room>, w: Double, h: Double): MapPos {
            for (y in 0..60) for (x in 0..40) {
                val fx = 1.0 + x; val fy = 1.0 + y
                val hit = rooms.any { fx < it.right && fx + w > it.x && fy < it.bottom && fy + h > it.y }
                if (!hit) return MapPos(fx, fy)
            }
            return MapPos(1.0, (rooms.maxOfOrNull { it.bottom } ?: 0.0) + 1)
        }
    }
}
