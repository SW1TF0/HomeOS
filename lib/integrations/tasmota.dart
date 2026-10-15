import '../models/device.dart';
import '../util/color_math.dart';
import 'integration.dart';

/// Devices running the open Tasmota firmware, over its HTTP command API.
class TasmotaDriver extends HostListDriver {
  TasmotaDriver(super.config, super.client);

  String get password => config.setting('password');

  Future<dynamic> _cmd(String host, String command) => getJson(Uri.parse('http://$host/cm').replace(
        queryParameters: {
          if (password.isNotEmpty) ...{'user': 'admin', 'password': password},
          'cmnd': command,
        },
      ));

  @override
  Future<dynamic> readHost(String host) => _cmd(host, 'Status 0');

  @override
  Future<List<Device>> probe(String host) async {
    final data = Map<String, dynamic>.from(await readHost(host) as Map);
    final status = Map<String, dynamic>.from(data['Status'] as Map? ?? const {});
    final sts = Map<String, dynamic>.from(data['StatusSTS'] as Map? ?? const {});
    final names = (status['FriendlyName'] as List?)?.map((e) => '$e').toList() ?? const [];
    final deviceName = '${status['DeviceName'] ?? (names.isNotEmpty ? names.first : 'Tasmota')}';
    final powerKeys = sts.keys.where((k) => RegExp(r'^POWER\d*$').hasMatch(k)).toList()..sort();
    final isLight = sts.containsKey('Dimmer');
    final out = <Device>[];
    for (final key in powerKeys) {
      final idx = key == 'POWER' ? 1 : int.parse(key.substring(5));
      final caps = <Capability>{Capability.onOff};
      if (isLight && idx == 1) {
        caps.add(Capability.brightness);
        if (sts.containsKey('CT')) caps.add(Capability.colorTemp);
        if (sts.containsKey('HSBColor')) caps.add(Capability.color);
      }
      final name = idx - 1 < names.length && names[idx - 1].isNotEmpty
          ? names[idx - 1]
          : (powerKeys.length == 1 ? deviceName : '$deviceName $idx');
      final d = makeDevice(
        externalId: '$host#$idx',
        name: name,
        kind: isLight && idx == 1 ? DeviceKind.light : DeviceKind.outlet,
        capabilities: caps,
        props: {'host': host, 'channel': idx},
      );
      d.state = stateFrom(d, data) ?? const DeviceState();
      out.add(d);
    }
    final readings = _readings(data['StatusSNS']);
    if (readings.isNotEmpty) {
      out.add(makeDevice(
        externalId: '$host#sensor',
        name: '$deviceName sensor',
        kind: DeviceKind.sensor,
        props: {'host': host, 'channel': 0},
        state: DeviceState(readings: readings),
      ));
    }
    return out;
  }

  static Map<String, String> _readings(dynamic sns) {
    final out = <String, String>{};
    if (sns is! Map) return out;
    final unit = sns['TempUnit'] ?? 'C';
    sns.forEach((sensor, values) {
      if (values is! Map) return;
      values.forEach((k, v) {
        if (v is! num) return;
        final label = switch ('$k') {
          'Temperature' => 'Temperature',
          'Humidity' => 'Humidity',
          'Pressure' => 'Pressure',
          'Power' => 'Power',
          'Voltage' => 'Voltage',
          'Today' => 'Energy today',
          _ => null,
        };
        if (label == null) return;
        final u = switch (label) {
          'Temperature' => ' °$unit',
          'Humidity' => ' %',
          'Pressure' => ' hPa',
          'Power' => ' W',
          'Voltage' => ' V',
          'Energy today' => ' kWh',
          _ => '',
        };
        out[label] = '$v$u';
      });
    });
    return out;
  }

  @override
  DeviceState? stateFrom(Device d, dynamic data) {
    final map = Map<String, dynamic>.from(data as Map);
    final idx = (d.props['channel'] as num?)?.toInt() ?? 1;
    if (idx == 0) return DeviceState(readings: _readings(map['StatusSNS']));
    final sts = Map<String, dynamic>.from(map['StatusSTS'] as Map? ?? map);
    final power = sts['POWER$idx'] ?? (idx == 1 ? sts['POWER'] : null);
    final hsb = sts['HSBColor'] as String?;
    final white = sts['White'] as num?;
    return DeviceState(
      on: power == null ? null : '$power' == 'ON',
      brightness: d.has(Capability.brightness) && sts['Dimmer'] != null ? (sts['Dimmer'] as num) / 100 : null,
      colorTempK: d.has(Capability.colorTemp) && sts['CT'] != null && (white == null || white > 0)
          ? miredToKelvin(sts['CT'] as num)
          : null,
      color: d.has(Capability.color) && hsb != null && (white == null || white == 0) ? _hsbToRgb(hsb) : null,
    );
  }

  static int? _hsbToRgb(String hsb) {
    final p = hsb.split(',').map((e) => double.tryParse(e) ?? 0).toList();
    if (p.length < 3) return null;
    final h = p[0] / 60, s = p[1] / 100;
    final c = s, x = c * (1 - ((h % 2) - 1).abs()), m = 1 - c;
    final (r, g, b) = switch (h.floor() % 6) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    int ch(double v) => ((v + m) * 255).round().clamp(0, 255);
    return rgbToInt(ch(r), ch(g), ch(b));
  }

  @override
  Future<DeviceState?> send(Device d, DeviceCommand c) async {
    final host = d.props['host'] as String;
    final idx = (d.props['channel'] as num?)?.toInt() ?? 1;
    if (c.on != null) await _cmd(host, 'Power$idx ${c.on! ? 'On' : 'Off'}');
    if (c.brightness != null) await _cmd(host, 'Dimmer ${(c.brightness! * 100).round()}');
    if (c.colorTempK != null) await _cmd(host, 'CT ${kelvinToMired(c.colorTempK!).clamp(153, 500)}');
    if (c.color != null) await _cmd(host, 'Color ${intToHex(c.color!)}');
    return null;
  }
}
