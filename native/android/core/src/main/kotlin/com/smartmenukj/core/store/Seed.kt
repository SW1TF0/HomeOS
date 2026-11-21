package com.smartmenukj.core.store

import com.smartmenukj.core.json.jsonObjectOf
import com.smartmenukj.core.model.*

object Seed {
    const val DEMO_ID = "demo"
    private const val FLOOR = "floor-ground"

    /** A new home: one floor and nothing on it yet. */
    fun emptyHome() = HomeData(floors = listOf(Floor(FLOOR, "Ground floor")))

    /** Whether [d] is still just the sample home: only its example devices, no real connections and no scenes. */
    fun isSample(d: HomeData): Boolean {
        val ids = sampleHome().devices.map { it.id }.toSet()
        return d.devices.isNotEmpty() && d.integrations.all { it.type == "demo" } && d.devices.all { it.id in ids } &&
            d.scenes.isEmpty()
    }

    /** The sample home shown on first launch, so the app is alive before any hardware is connected. */
    fun sampleHome(): HomeData {
        fun room(id: String, name: String, x: Double, y: Double, w: Double, h: Double) = Room(id, FLOOR, name, x, y, w, h)
        fun dev(
            id: String, name: String, kind: DeviceKind, roomId: String, x: Double, y: Double, state: DeviceState,
            favorite: Boolean = false, caps: Set<Capability>? = null, modes: List<String>? = null,
            arms: List<String>? = null,
        ) = Device(
            id = Device.idFor(DEMO_ID, "manual:$id"), name = name, kind = kind, integrationId = DEMO_ID,
            externalId = "manual:$id", capabilities = caps ?: defaultCapabilities(kind),
            props = jsonObjectOf("modes" to modes, "arms" to arms), roomId = roomId, floorId = FLOOR,
            mapPos = MapPos(x, y), favorite = favorite, state = state,
        )
        return HomeData(
            floors = listOf(Floor(FLOOR, "Ground floor")),
            rooms = listOf(
                room("room-living", "Living", 1.0, 1.0, 15.0, 11.0),
                room("room-kitchen", "Kitchen", 16.0, 1.0, 10.0, 7.0),
                room("room-hall", "Hall", 16.0, 8.0, 10.0, 4.0),
                room("room-bedroom", "Bedroom", 1.0, 12.0, 12.0, 9.0),
                room("room-bath", "Bath", 13.0, 12.0, 6.0, 9.0),
                room("room-office", "Office", 19.0, 12.0, 7.0, 9.0),
            ),
            integrations = listOf(IntegrationConfig(DEMO_ID, "demo", "Virtual devices")),
            devices = listOf(
                dev("ceiling", "Ceiling light", DeviceKind.light, "room-living", 8.0, 5.0,
                    DeviceState(on = true, brightness = 0.72, colorTempK = 2700), favorite = true),
                dev("lamp", "Floor lamp", DeviceKind.light, "room-living", 3.0, 9.0,
                    DeviceState(on = true, brightness = 0.45, color = 0xFF5A36)),
                dev("tv", "TV", DeviceKind.media, "room-living", 13.0, 9.0, DeviceState(on = false), favorite = true),
                dev("blinds", "Blinds", DeviceKind.cover, "room-living", 8.0, 2.0, DeviceState(position = 0.6)),
                dev("vacuum", "Robot vacuum", DeviceKind.vacuum, "room-living", 4.0, 4.5,
                    DeviceState(activity = Activity.DOCKED, battery = 1.0, mode = "Balanced"), favorite = true,
                    modes = listOf("Quiet", "Balanced", "Turbo", "Max")),
                dev("thermostat", "Thermostat", DeviceKind.climate, "room-hall", 21.0, 10.0,
                    DeviceState(on = true, targetTemp = 21.5, currentTemp = 20.8), favorite = true),
                dev("door", "Front door", DeviceKind.lock, "room-hall", 25.0, 10.0, DeviceState(locked = true), favorite = true),
                dev("alarm", "Alarm", DeviceKind.alarm, "room-hall", 18.0, 10.0, DeviceState(activity = Activity.DISARMED),
                    favorite = true, arms = listOf("home", "away", "night")),
                dev("kitchen", "Kitchen lights", DeviceKind.light, "room-kitchen", 21.0, 4.0,
                    DeviceState(on = false, brightness = 1.0, colorTempK = 4000),
                    caps = setOf(Capability.onOff, Capability.brightness, Capability.colorTemp)),
                dev("coffee", "Coffee machine", DeviceKind.outlet, "room-kitchen", 24.0, 2.0, DeviceState(on = false), favorite = true),
                dev("bedside", "Bedside lamp", DeviceKind.light, "room-bedroom", 3.0, 14.0,
                    DeviceState(on = false, brightness = 0.3, colorTempK = 2200)),
                dev("climate-bed", "Bedroom sensor", DeviceKind.sensor, "room-bedroom", 11.0, 19.0,
                    DeviceState(readings = mapOf("Temperature" to "19.6 °C", "Humidity" to "48 %"))),
                dev("purifier", "Air purifier", DeviceKind.purifier, "room-bedroom", 7.0, 17.0,
                    DeviceState(on = false, speed = 0.4, mode = "Auto", readings = mapOf("PM2.5" to "6 µg/m³")),
                    modes = listOf("Auto", "Sleep", "Turbo")),
                dev("fan", "Bath fan", DeviceKind.fan, "room-bath", 16.0, 15.0, DeviceState(on = false)),
                dev("desk", "Desk lamp", DeviceKind.light, "room-office", 22.0, 16.0,
                    DeviceState(on = true, brightness = 0.9, colorTempK = 5000), favorite = true),
            ),
        )
    }
}
