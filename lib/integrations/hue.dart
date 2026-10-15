import '../models/device.dart';
import '../util/color_math.dart';
import 'integration.dart';

/// Philips Hue bridge, over its local API. No Hue account or cloud needed.
class HueDriver extends IntegrationDriver {
  HueDriver(super.config, super.client);

  String get host => config.setting('host');
  String get username => config.setting('username');

  Uri _api(String path) => Uri.parse('http://$host/api/$username$path');

  void _requireSetup() {
    if (host.isEmpty) throw IntegrationException('Enter the bridge address, or use Scan network.');
    if (username.isEmpty) throw IntegrationException('Press the bridge\'s link button, then tap Pair.');
  }

  @override
  Future<Map<String, dynamic>> pair() async {
    if (host.isEmpty) throw IntegrationException('Enter the bridge address first.');
    final res = await sendJson('POST', Uri.parse('http://$host/api'), {'devicetype': 'smartmenukj#app'});
    final first = res is List && res.isNotEmpty ? res.first as Map : const {};
    final user = (first['success'] as Map?)?['username'];
    if (user is String) return {'username': user};
    final err = (first['error'] as Map?)?['description'] ?? 'unexpected reply';
    throw IntegrationException('Bridge said: $err. Press the round link button on the bridge, then tap Pair within 30 seconds.');
  }

  Future<Map<String, dynamic>> _lights() async {
    _requireSetup();
    final res = await getJson(_api('/lights'));
    _throwHueError(res);
    return Map<String, dynamic>.from(res as Map);
  }

  void _throwHueError(dynamic res) {
    if (res is List && res.isNotEmpty && res.first is Map && (res.first as Map).containsKey('error')) {
      final desc = ((res.first as Map)['error'] as Map)['description'];
      throw IntegrationException('Hue bridge: $desc');
    }
  }

  @override
  Future<List<Device>> discover() async {
    final lights = await _lights();
    return [
      for (final e in lights.entries)
        _toDevice(e.key, Map<String, dynamic>.from(e.value as Map)),
    ];
  }

  Device _toDevice(String id, Map<String, dynamic> light) {
    final st = Map<String, dynamic>.from(light['state'] as Map? ?? const {});
    final type = '${light['type']}'.toLowerCase();
    final caps = <Capability>{Capability.onOff};
    if (st.containsKey('bri')) caps.add(Capability.brightness);
    if (st.containsKey('ct')) caps.add(Capability.colorTemp);
    if (st.containsKey('xy')) caps.add(Capability.color);
    return makeDevice(
      externalId: id,
      name: '${light['name'] ?? 'Hue light $id'}',
      kind: type.contains('plug') ? DeviceKind.outlet : DeviceKind.light,
      capabilities: caps,
      props: {'model': light['modelid'], 'type': light['type']},
      state: parseState(st),
    );
  }

  static DeviceState parseState(Map<String, dynamic> st) {
    final xy = st['xy'] as List?;
    final mode = st['colormode'];
    return DeviceState(
      on: st['on'] as bool?,
      brightness: st['bri'] == null ? null : ((st['bri'] as num) - 1) / 253,
      colorTempK: mode == 'ct' && st['ct'] != null ? miredToKelvin(st['ct'] as num) : null,
      color: mode != 'ct' && xy != null && xy.length == 2
          ? xyToRgb((xy[0] as num).toDouble(), (xy[1] as num).toDouble())
          : null,
      reachable: st['reachable'] as bool? ?? true,
    );
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    try {
      final lights = await _lights();
      return {
        for (final d in devices)
          d.id: lights[d.externalId] == null
              ? d.state.merge(DeviceState.unreachable)
              : d.state.merge(parseState(Map<String, dynamic>.from(
                  (lights[d.externalId] as Map)['state'] as Map? ?? const {}))),
      };
    } catch (_) {
      return {for (final d in devices) d.id: d.state.merge(DeviceState.unreachable)};
    }
  }

  @override
  Future<DeviceState?> refresh(Device device) async {
    _requireSetup();
    final res = await getJson(_api('/lights/${device.externalId}'));
    _throwHueError(res);
    return parseState(Map<String, dynamic>.from((res as Map)['state'] as Map));
  }

  @override
  Future<DeviceState?> send(Device device, DeviceCommand c) async {
    _requireSetup();
    final body = <String, dynamic>{
      if (c.on != null) 'on': c.on,
      if (c.brightness != null) ...{
        'on': c.brightness! > 0,
        'bri': (c.brightness! * 253 + 1).round().clamp(1, 254),
      },
      if (c.colorTempK != null) 'ct': kelvinToMired(c.colorTempK!).clamp(153, 500),
      if (c.color != null) 'xy': rgbToXy(c.color!),
    };
    final res = await sendJson('PUT', _api('/lights/${device.externalId}/state'), body);
    _throwHueError(res);
    return null;
  }
}
