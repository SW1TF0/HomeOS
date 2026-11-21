import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// IP cameras that stream over RTSP or ONVIF. A camera is added from a scan or by its address; where its video is
/// gets filled in once its login is entered (see `findCameraLinks`).
class CameraProtocol extends LanProtocol {
  const CameraProtocol();

  @override
  String get id => 'camera';

  @override
  String get label => 'Camera';

  /// The camera at [host]. [known] is what was learned before, so syncing keeps its picture.
  static Device make(LanContext ctx, String host, {String? name, Map<String, String> known = const {}}) => ctx.make(
        externalId: 'camera:$host',
        name: name ?? 'Camera',
        kind: DeviceKind.camera,
        capabilities: {if ((known['snapshotUrl'] ?? '').isNotEmpty) Capability.snapshot},
        props: {'host': host, 'protocol': 'camera', 'onvif': ?known['onvif']},
      );

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    if (hints['protocol'] != 'camera' && !await ctx.tcpOpen(host, 554)) return null;
    return [make(ctx, host, name: hints['name'], known: hints)];
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final host = device.props['host'] as String? ?? '';
    final stream = Uri.tryParse(device.props['streamUrl'] as String? ?? '');
    final port = stream != null && stream.hasPort ? stream.port : 554;
    if (await ctx.tcpOpen(host, port) || await ctx.tcpOpen(host, 80)) return const DeviceState(reachable: true);
    throw IntegrationException('${device.name} does not answer.');
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async =>
      throw unsupported(device, 'commands');
}
