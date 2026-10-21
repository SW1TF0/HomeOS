package com.smartmenukj.core

import com.smartmenukj.core.integrations.*
import com.smartmenukj.core.json.jsonObjectOf
import com.smartmenukj.core.model.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class DriversTest {
    private fun cfg(type: String, vararg settings: Pair<String, Any?>) =
        IntegrationConfig("$type-1", type, type, jsonObjectOf(*settings))

    @Test
    fun hueFindsLightsAndSendsXy() = runTest {
        val http = FakeHttp()
        http.on("GET", "http://10.0.0.2/api/key/lights", """{"1":{"name":"Desk","type":"Extended color light","modelid":"LCT015",
            "state":{"on":true,"bri":254,"ct":366,"xy":[0.3,0.3],"colormode":"ct","reachable":true}},
            "2":{"name":"Plug","type":"On/Off plug-in unit","state":{"on":false,"reachable":false}}}""")
        http.on("PUT", "http://10.0.0.2/api/key/lights/1/state", """[{"success":{}}]""")
        val hue = HueDriver(cfg("hue", "host" to "10.0.0.2", "username" to "key"), http)
        val found = hue.discover()
        assertEquals(2, found.size)
        val desk = found[0]
        assertEquals(setOf(Capability.onOff, Capability.brightness, Capability.colorTemp, Capability.color), desk.capabilities)
        assertEquals(1.0, desk.state.brightness)
        assertEquals(2732, desk.state.colorTempK)
        assertEquals(DeviceKind.outlet, found[1].kind)
        assertFalse(found[1].state.reachable)
        hue.send(desk, DeviceCommand(color = 0xFF0000))
        assertTrue(http.calls.last().contains("\"xy\":[0.64"), http.calls.last())
    }

    @Test
    fun hueExplainsPairing() = runTest {
        val http = FakeHttp()
        http.on("POST", "http://10.0.0.2/api", """[{"error":{"type":101,"description":"link button not pressed"}}]""")
        val e = assertFailsWith<IntegrationException> { HueDriver(cfg("hue", "host" to "10.0.0.2"), http).pair() }
        assertTrue(e.message!!.contains("link button not pressed"))
        http.on("POST", "http://10.0.0.2/api", """[{"success":{"username":"new-key"}}]""")
        assertEquals(mapOf("username" to "new-key"), HueDriver(cfg("hue", "host" to "10.0.0.2"), http).pair())
    }

    @Test
    fun shellyGen2() = runTest {
        val http = FakeHttp()
        http.on("GET", "http://10.0.0.5/shelly", """{"name":null,"model":"SNPL-00116EU","gen":2}""")
        http.on("GET", "http://10.0.0.5/rpc/Shelly.GetStatus", """{"switch:0":{"output":true,"apower":12.5},
            "temperature:0":{"tC":21.5},"cover:0":{"current_pos":40},"sys":{}}""")
        http.on("GET", "http://10.0.0.5/rpc/Shelly.GetConfig", """{"switch:0":{"name":"Kettle"}}""")
        http.on("GET", "http://10.0.0.5/rpc/Switch.Set?id=0&on=false", "{}")
        val shelly = ShellyDriver(cfg("shelly", "hosts" to "10.0.0.5"), http)
        val found = shelly.discover()
        assertEquals(listOf("Kettle", "SNPL-00116EU", "SNPL-00116EU sensor"), found.map { it.name })
        assertEquals(true, found[0].state.on)
        assertEquals("12.5 W", found[0].state.readings["Power"])
        assertEquals(0.4, found[1].state.position)
        assertEquals("21.5 °C", found[2].state.readings["Temperature"])
        shelly.send(found[0], DeviceCommand(on = false))
        assertEquals("GET http://10.0.0.5/rpc/Switch.Set?id=0&on=false", http.calls.last())
        val states = shelly.refreshAll(found)
        assertEquals(3, states.size)
        assertEquals(1, http.calls.count { it.endsWith("/rpc/Shelly.GetStatus") } - 1, "one read for the whole host")
    }

    @Test
    fun shellyGen1() = runTest {
        val http = FakeHttp()
        http.on("GET", "http://10.0.0.6/shelly", """{"type":"SHSW-25","mac":"AA"}""")
        http.on("GET", "http://10.0.0.6/status", """{"relays":[{"ison":true},{"ison":false}],"rollers":[{"current_pos":100}]}""")
        http.on("GET", "http://10.0.0.6/settings", """{"mode":"relay"}""")
        val found = ShellyDriver(cfg("shelly", "hosts" to "10.0.0.6"), http).discover()
        assertEquals(listOf("SHSW-25 1", "SHSW-25 2"), found.map { it.name })
        assertEquals(listOf(true, false), found.map { it.state.on })
    }

    @Test
    fun tasmota() = runTest {
        val http = FakeHttp()
        http.on("GET", "http://10.0.0.7/cm?cmnd=Status%200", """{"Status":{"DeviceName":"Bulb","FriendlyName":["Bulb"]},
            "StatusSTS":{"POWER":"ON","Dimmer":50,"CT":250,"White":100},"StatusSNS":{"AM2301":{"Temperature":20.1},"TempUnit":"C"}}""")
        val found = TasmotaDriver(cfg("tasmota", "hosts" to "10.0.0.7"), http).discover()
        assertEquals(2, found.size)
        assertEquals(DeviceKind.light, found[0].kind)
        assertEquals(0.5, found[0].state.brightness)
        assertEquals(4000, found[0].state.colorTempK)
        assertEquals("20.1 °C", found[1].state.readings["Temperature"])
    }

    @Test
    fun wled() = runTest {
        val http = FakeHttp()
        http.on("GET", "http://10.0.0.8/json", """{"info":{"name":"Shelf","leds":{"count":60}},
            "state":{"on":true,"bri":128,"seg":[{"col":[[255,0,0],[0,0,0]]}]}}""")
        val d = WledDriver(cfg("wled", "hosts" to "10.0.0.8"), http).discover().single()
        assertEquals("Shelf", d.name)
        assertEquals(0xFF0000, d.state.color)
    }

    @Test
    fun espHome() = runTest {
        val http = FakeHttp()
        http.on("STREAM", "http://10.0.0.9/events", """
            event: state
            data: {"id":"light-desk_lamp","name":"Desk lamp","state":"ON","brightness":255}

            event: state
            data: {"id":"sensor/Temperature","name":"Temperature","state":"21.0 °C","value":21}
        """.trimIndent())
        val found = EspHomeDriver(cfg("esphome", "hosts" to "10.0.0.9"), http).discover()
        assertEquals(listOf("Desk lamp", "10 sensors"), found.map { it.name })
        assertEquals(true, found[0].state.on)
        assertEquals(1.0, found[0].state.brightness)
        assertEquals("21.0 °C", found[1].state.readings["Temperature"])
    }

    @Test
    fun homeAssistant() = runTest {
        val http = FakeHttp()
        http.on("GET", "http://ha.local:8123/api/states", """[
            {"entity_id":"light.kitchen","state":"on","attributes":{"friendly_name":"Kitchen","brightness":128,
              "supported_color_modes":["color_temp","hs"],"color_mode":"color_temp","color_temp_kelvin":3000}},
            {"entity_id":"vacuum.rocky","state":"cleaning","attributes":{"friendly_name":"Rocky","supported_features":16440,
              "fan_speed_list":["quiet","max"],"fan_speed":"max"}},
            {"entity_id":"sensor.rocky_battery","state":"80","attributes":{"device_class":"battery"}},
            {"entity_id":"sensor.hall_temperature","state":"20.5","attributes":{"device_class":"temperature","unit_of_measurement":"°C","friendly_name":"Hall"}},
            {"entity_id":"automation.x","state":"on","attributes":{}}
        ]""")
        http.on("POST", "http://ha.local:8123/api/services/light/turn_on", "[]")
        val ha = HomeAssistantDriver(cfg("homeassistant", "url" to "ha.local:8123/", "token" to "t"), http)
        val found = ha.discover()
        assertEquals(listOf("Kitchen", "Rocky", "Hall"), found.map { it.name })
        val light = found[0]
        assertEquals(setOf(Capability.onOff, Capability.brightness, Capability.colorTemp, Capability.color), light.capabilities)
        assertEquals(3000, light.state.colorTempK)
        val rocky = found[1]
        assertEquals(Activity.RUNNING, rocky.state.activity)
        assertEquals(0.8, rocky.state.battery)
        assertTrue(rocky.has(Capability.dock) && rocky.has(Capability.mode))
        assertEquals("20.5 °C", found[2].state.readings["Hall"])
        ha.send(light, DeviceCommand(brightness = 0.5))
        assertEquals("""POST http://ha.local:8123/api/services/light/turn_on {"entity_id":"light.kitchen","brightness_pct":50}""", http.calls.last())
    }

    @Test
    fun hosts() {
        assertEquals(listOf("10.0.0.1", "shelly.local:8080", "10.0.0.2"), parseHosts("http://10.0.0.1/, shelly.local:8080\n10.0.0.2 10.0.0.1"))
    }
}
