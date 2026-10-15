import '../models/device.dart';
import 'integration.dart';

/// Virtual devices that live only in the app. Handy for trying SmartMenuKJ,
/// planning a home before buying hardware, or as placeholders on the map.
class DemoDriver extends IntegrationDriver {
  DemoDriver(super.config, super.client);

  @override
  Future<List<Device>> discover() async => const [];

  @override
  Future<DeviceState?> refresh(Device device) async => device.state;

  @override
  Future<DeviceState?> send(Device device, DeviceCommand command) async =>
      device.state.applyCommand(command);
}
