import '../models/device.dart';
import 'integration.dart';

/// Virtual devices that live only in the app. Handy for trying SmartHomeKJ,
/// planning a home before buying hardware, or as placeholders on the map.
class DemoDriver extends IntegrationDriver {
  DemoDriver(super.config, super.client);

  @override
  Future<List<Device>> discover() async => const [];

  @override
  Future<DeviceState?> refresh(Device device) async => device.state;

  @override
  Future<DeviceState?> send(Device device, DeviceCommand command) async {
    final s = device.state.applyCommand(command);
    // A virtual robot is home at once.
    return command.action == DeviceAction.dock ? s.merge(const DeviceState(activity: Activity.docked)) : s;
  }
}
