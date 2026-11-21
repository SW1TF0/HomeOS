package com.smartmenukj.core

import com.smartmenukj.core.json.asObj
import com.smartmenukj.core.json.parseJson
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.Seed
import kotlin.test.*

class ModelsTest {
    /** A home as the Flutter app saves it. */
    private val flutterHome = """
        {"app":"SmartMenuKJ","version":1,"themeMode":"light",
         "floors":[{"id":"f1","name":"Ground"}],
         "rooms":[{"id":"r1","floorId":"f1","name":"Living","x":1,"y":1.5,"width":10,"height":8}],
         "devices":[{"id":"hue-1::3","name":"Lamp","kind":"light","integrationId":"hue-1","externalId":"3",
           "capabilities":["onOff","brightness","somethingNew"],"props":{"model":"LCT015","modes":["a","b"]},
           "roomId":"r1","floorId":"f1","mapPos":[4,5.5],"favorite":true,
           "state":{"on":true,"brightness":0.5,"color":16711680,"readings":{"Power":"3 W"},"reachable":true}}],
         "integrations":[{"id":"hue-1","type":"hue","name":"Hue","settings":{"host":"192.168.1.2","username":"abc"},"enabled":true},
                         {"id":"lan-1","type":"lan","name":"Network devices","settings":{}}],
         "scenes":[{"id":"s1","name":"Movie","icon":"movie","actions":[{"deviceId":"hue-1::3","on":true,"brightness":0.2}],
                    "schedule":{"hour":20,"minute":30,"days":[5,6]}}],
         "automations":[{"id":"a1","name":"keep me"}]}
    """.trimIndent()

    @Test
    fun readsAFlutterHome() {
        val d = HomeData.fromJson(parseJson(flutterHome).asObj()!!)
        assertEquals("light", d.themeMode)
        assertEquals(1, d.rooms.size)
        assertEquals(1.5, d.rooms[0].y)
        val lamp = d.devices.single()
        assertEquals(DeviceKind.light, lamp.kind)
        assertEquals(setOf(Capability.onOff, Capability.brightness), lamp.capabilities)
        assertEquals(MapPos(4.0, 5.5), lamp.mapPos)
        assertEquals(listOf("a", "b"), lamp.modes)
        assertEquals(0xFF0000, lamp.state.color)
        assertEquals("3 W", lamp.state.readings["Power"])
        assertEquals("192.168.1.2", d.integrations[0].setting("host"))
        assertEquals(SceneSchedule(20, 30, setOf(5, 6)), d.scenes[0].schedule)
        assertEquals(0.2, d.scenes[0].actions[0].command.brightness)
        assertEquals(1, d.automations.size)
    }

    @Test
    fun savesWhatItReads() {
        val d = HomeData.fromJson(parseJson(flutterHome).asObj()!!)
        val again = HomeData.fromJson(parseJson(d.toJson().toString()).asObj()!!)
        assertEquals(d, again)
    }

    @Test
    fun sampleHomeSurvivesSaving() {
        val d = Seed.sampleHome()
        assertEquals(d, HomeData.fromJson(parseJson(d.toJson().toString()).asObj()!!))
        assertTrue(Seed.isSample(d))
    }

    @Test
    fun commandsChangeState() {
        val s = DeviceState(on = false, colorTempK = 3000)
        val lit = s.applyCommand(DeviceCommand(brightness = 0.4))
        assertEquals(true, lit.on)
        val red = lit.applyCommand(DeviceCommand(color = 0xFF0000))
        assertNull(red.colorTempK)
        assertEquals(0xFF0000, red.color)
        assertEquals(Activity.RETURNING, DeviceState().applyCommand(DeviceCommand(action = DeviceAction.dock)).activity)
    }

    @Test
    fun mergeDropsEmptyReadings() {
        val s = DeviceState(mode = "Turbo", readings = mapOf("Error" to "Stuck", "PM2.5" to "4"))
        val m = s.merge(DeviceState(mode = "", readings = mapOf("Error" to "")))
        assertNull(m.mode)
        assertEquals(mapOf("PM2.5" to "4"), m.readings)
    }

    @Test
    fun scenesTurnThingsOff() {
        val d = Seed.sampleHome()
        val blinds = d.devices.first { it.kind == DeviceKind.cover }
        assertEquals(0.0, SceneAction.turn(blinds, false)!!.command.position)
        val door = d.devices.first { it.kind == DeviceKind.lock }
        assertNull(SceneAction.turn(door, true))
        assertTrue(SceneAction.turn(door, false)!!.isOff)
        val vacuum = d.devices.first { it.kind == DeviceKind.vacuum }
        assertEquals(DeviceAction.dock, SceneAction.capture(vacuum).command.action)
    }
}
