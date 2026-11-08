package com.smartmenukj.core

import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.HomeStore
import com.smartmenukj.core.store.MemoryStorage
import com.smartmenukj.core.store.Seed
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class StoreTest {
    private var n = 0
    private fun store(scope: TestScope, storage: MemoryStorage = MemoryStorage(), http: FakeHttp = FakeHttp()) =
        HomeStore(storage, http, scope.backgroundScope, newId = { "id${n++}" }).also { it.load() }

    @Test
    fun startsWithTheSampleHome() = runTest {
        val s = store(this)
        assertTrue(Seed.isSample(s.data))
        assertEquals(1, s.state.value.homes.size)
    }

    @Test
    fun virtualDevicesSwitch() = runTest {
        val s = store(this)
        val lamp = s.data.devices.first { it.name == "Bedside lamp" }
        assertTrue(s.send(lamp.id, DeviceCommand(on = true, brightness = 0.6)))
        assertEquals(0.6, s.data.device(lamp.id)!!.state.brightness)
        s.toggle(lamp.id)
        runCurrent()
        assertEquals(false, s.data.device(lamp.id)!!.state.on)
    }

    @Test
    fun failedCommandsGoBack() = runTest {
        val http = FakeHttp()
        val s = store(this, http = http)
        val messages = mutableListOf<String>()
        s.onMessage = { messages += it }
        val cfg = s.addIntegration("shelly", settings = mapOf("hosts" to "10.0.0.5"))
        http.on("GET", "http://10.0.0.5/shelly", """{"gen":2,"name":"Plug"}""")
        http.on("GET", "http://10.0.0.5/rpc/Shelly.GetStatus", """{"switch:0":{"output":false}}""")
        assertEquals(1, s.sync(cfg.id))
        val plug = s.data.devices.first { it.integrationId == cfg.id }
        assertNull(plug.roomId)
        assertFalse(s.send(plug.id, DeviceCommand(on = true)))
        assertEquals(false, s.data.device(plug.id)!!.state.on)
        assertTrue(messages.last().startsWith("Plug:"), messages.last())
        // A second search keeps the room it was given.
        s.setRoom(plug.id, "room-kitchen")
        assertEquals(0, s.sync(cfg.id))
        assertEquals("room-kitchen", s.data.device(plug.id)!!.roomId)
        assertNotNull(s.data.device(plug.id)!!.mapPos)
        s.removeIntegration(cfg.id)
        assertNull(s.data.device(plug.id))
    }

    @Test
    fun roomsMoveWithTheirDevices() = runTest {
        val s = store(this)
        val living = s.data.room("room-living")!!
        val ceiling = s.data.devices.first { it.name == "Ceiling light" }
        s.setRoomRect(living.id, living.x + 2.2, living.y, living.width, living.height)
        assertEquals(3.0, s.data.room(living.id)!!.x, "snapped to half cells")
        assertEquals(ceiling.mapPos!!.x + 2, s.data.device(ceiling.id)!!.mapPos!!.x)
        s.undoLayout()
        assertEquals(living, s.data.room(living.id))
        assertEquals(ceiling.mapPos, s.data.device(ceiling.id)!!.mapPos)
    }

    @Test
    fun droppingADeviceInARoomPutsItThere() = runTest {
        val s = store(this)
        val lamp = s.data.devices.first { it.name == "Floor lamp" }
        val office = s.data.room("room-office")!!
        s.moveDevice(lamp.id, office.floorId, MapPos(office.x + 1, office.y + 1))
        assertEquals("room-office", s.data.device(lamp.id)!!.roomId)
    }

    @Test
    fun newRoomsGoWhereThereIsSpace() = runTest {
        val s = store(this)
        val r = s.addRoom("floor-ground", "Garage")
        val others = s.data.rooms.filter { it.id != r.id }
        assertTrue(others.none { r.x < it.right && r.right > it.x && r.y < it.bottom && r.bottom > it.y })
    }

    @Test
    fun scenesRunEveryDevice() = runTest {
        val s = store(this)
        val lights = s.data.devices.filter { it.kind == DeviceKind.light }
        s.saveScene(Scene("sc", "Off", actions = lights.mapNotNull { SceneAction.turn(it, false) }))
        s.runScene("sc")
        runCurrent()
        assertTrue(s.data.devices.filter { it.kind == DeviceKind.light }.all { it.state.on == false })
    }

    @Test
    fun homesAndBackups() = runTest {
        val storage = MemoryStorage()
        val s = store(this, storage)
        s.addHome("Cottage")
        assertEquals("Cottage", s.state.value.home!!.name)
        s.addRoom("floor-ground", "Porch")
        val backup = s.exportAll()

        val other = store(this, MemoryStorage())
        assertEquals(2, other.importAll(backup))
        assertEquals("Cottage", other.state.value.home!!.name)
        assertEquals(listOf("Porch"), other.data.rooms.map { it.name })
        other.switchHome(other.state.value.homes.first().id)
        assertTrue(Seed.isSample(other.data))

        // And it all comes back after a restart.
        val again = store(this, storage)
        assertEquals(2, again.state.value.homes.size)
        assertEquals("Cottage", again.state.value.home!!.name)
    }

    @Test
    fun readsAFlutterBackup() = runTest {
        val raw = """{"app":"SmartMenuKJ","backup":"homes","current":"b","homes":[
            {"id":"a","name":"Flat","home":{"floors":[{"id":"f","name":"G"}],"rooms":[],"devices":[],"integrations":[],"scenes":[]}},
            {"id":"b","name":"House","home":{"floors":[{"id":"f","name":"G"}],"rooms":[{"id":"r","floorId":"f","name":"Hall","x":0,"y":0,"width":4,"height":4}],
              "devices":[{"id":"mqtt-1::x","name":"Zigbee lamp","kind":"light","integrationId":"mqtt-1","externalId":"x"}],
              "integrations":[{"id":"mqtt-1","type":"mqtt","name":"MQTT","settings":{"host":"10.0.0.3"}}],"scenes":[]}}]}"""
        val s = store(this)
        assertEquals(2, s.importAll(raw))
        assertEquals("House", s.state.value.home!!.name)
        val lamp = s.data.devices.single()
        assertFalse(s.canControl(lamp), "MQTT is not in this version yet")
        assertFalse(s.send(lamp.id, DeviceCommand(on = true)))
        assertEquals("mqtt", s.data.integrations.single().type)
    }
}
