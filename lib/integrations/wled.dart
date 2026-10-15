import '../models/device.dart';
import '../util/color_math.dart';
import 'integration.dart';

/// LED strips running the open WLED firmware, over its JSON API.
class WledDriver extends HostListDriver {
  WledDriver(super.config, super.client);

  @override
  Future<dynamic> readHost(String host) => getJson(Uri.parse('http://$host/json/state'));

  @override
  Future<List<Device>> probe(String host) async {
    final data = Map<String, dynamic>.from(await getJson(Uri.parse('http://$host/json')) as Map);
    final info = Map<String, dynamic>.from(data['info'] as Map? ?? const {});
    final d = makeDevice(
      externalId: host,
      name: '${info['name'] ?? 'WLED'}',
      kind: DeviceKind.light,
      capabilities: {Capability.onOff, Capability.brightness, Capability.color},
      props: {'host': host, 'leds': (info['leds'] as Map?)?['count']},
    );
    d.state = stateFrom(d, data['state']) ?? const DeviceState();
    return [d];
  }

  @override
  DeviceState? stateFrom(Device d, dynamic data) {
    final st = Map<String, dynamic>.from(data as Map);
    int? color;
    final seg = st['seg'] as List?;
    if (seg != null && seg.isNotEmpty) {
      final col = (seg.first as Map)['col'] as List?;
      if (col != null && col.isNotEmpty && col.first is List && (col.first as List).length >= 3) {
        final c = (col.first as List).cast<num>();
        color = rgbToInt(c[0].toInt(), c[1].toInt(), c[2].toInt());
      }
    }
    return DeviceState(
      on: st['on'] as bool?,
      brightness: st['bri'] == null ? null : (st['bri'] as num) / 255,
      color: color,
    );
  }

  @override
  Future<DeviceState?> send(Device d, DeviceCommand c) async {
    final host = d.props['host'] as String;
    final body = <String, dynamic>{
      if (c.on != null) 'on': c.on,
      if (c.brightness != null) ...{'on': c.brightness! > 0, 'bri': (c.brightness! * 255).round().clamp(1, 255)},
      if (c.color != null)
        'seg': [
          {'col': [intToRgb(c.color!)]}
        ],
    };
    final res = await sendJson('POST', Uri.parse('http://$host/json/state'), {...body, 'v': true});
    return res is Map ? stateFrom(d, res) : null;
  }
}
