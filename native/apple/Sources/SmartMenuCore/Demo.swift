import Foundation

/// Virtual devices that live only in the app. Handy for trying SmartMenuKJ, planning a home before buying hardware, or
/// as placeholders on the map.
public final class DemoDriver: IntegrationDriver, @unchecked Sendable {
    public override func refresh(_ d: Device) async throws -> DeviceState? { d.state }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        let s = d.state.applying(c)
        // A virtual robot is home at once.
        return c.action == .dock ? s.merging(DeviceState(activity: Activity.docked)) : s
    }
}
