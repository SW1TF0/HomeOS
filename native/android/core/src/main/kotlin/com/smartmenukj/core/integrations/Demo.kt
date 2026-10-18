package com.smartmenukj.core.integrations

import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http

/**
 * Virtual devices that live only in the app. Handy for trying SmartMenuKJ, planning a home before buying hardware, or
 * as placeholders on the map.
 */
class DemoDriver(config: IntegrationConfig, http: Http) : IntegrationDriver(config, http) {
    override suspend fun discover(): List<Device> = emptyList()

    override suspend fun refresh(device: Device): DeviceState? = device.state

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        val s = device.state.applyCommand(command)
        // A virtual robot is home at once.
        return if (command.action == DeviceAction.dock) s.merge(DeviceState(activity = Activity.DOCKED)) else s
    }
}
