import '../models/device.dart';
import 'integration.dart';

/// Shelly relays, dimmers, plugs, roller shutters and H&T sensors over their
/// local HTTP API. Supports Gen1 and Gen2+ (Plus / Pro / Gen3 / Gen4).
class ShellyDriver extends HostListDriver {
  ShellyDriver(super.config, super.client);

  Uri _u(String host, String path, [Map<String, String>? q]) =>
      Uri.parse('http://$host$path').replace(queryParameters: q);

  @override
  Future<List<Device>> probe(String host) async {
    final info = await getJson(_u(host, '/shelly')) as Map;
    final gen = (info['gen'] as num?)?.toInt() ?? 1;
    final base = '${info['name'] ?? info['type'] ?? info['model'] ?? 'Shelly'}';
    return gen >= 2 ? _probeGen2(host, base) : _probeGen1(host, base);
  }

  Future<List<Device>> _probeGen2(String host, String base) async {
    final status = Map<String, dynamic>.from(await readHost(host) as Map);
    Map config = const {};
    try {
      config = await getJson(_u(host, '/rpc/Shelly.GetConfig')) as Map;
    } catch (_) {}
    final out = <Device>[];
    final readings = <String, String>{};
    for (final key in status.keys) {
      final parts = key.split(':');
      if (parts.length != 2) continue;
      final comp = parts[0];
      final ch = int.tryParse(parts[1]) ?? 0;
      final label = (config[key] as Map?)?['name'] as String?;
      String name(String fallback) => label ?? (ch == 0 ? base : '$base $fallback ${ch + 1}');
      final props = {'host': host, 'gen': 2, 'component': comp, 'channel': ch};
      switch (comp) {
        case 'switch':
          out.add(makeDevice(
              externalId: '$host#switch:$ch',
              name: name('switch'),
              kind: DeviceKind.outlet,
              props: props,
              state: _gen2State(comp, status[key])));
        case 'light':
          out.add(makeDevice(
              externalId: '$host#light:$ch',
              name: name('light'),
              kind: DeviceKind.light,
              capabilities: {Capability.onOff, Capability.brightness},
              props: props,
              state: _gen2State(comp, status[key])));
        case 'cover':
          out.add(makeDevice(
              externalId: '$host#cover:$ch',
              name: name('cover'),
              kind: DeviceKind.cover,
              props: props,
              state: _gen2State(comp, status[key])));
        case 'temperature' || 'humidity' || 'devicepower':
          readings.addAll(_gen2Readings({key: status[key]}));
      }
    }
    if (readings.isNotEmpty) {
      out.add(makeDevice(
          externalId: '$host#sensor',
          name: '$base sensor',
          kind: DeviceKind.sensor,
          props: {'host': host, 'gen': 2, 'component': 'sensor', 'channel': 0},
          state: DeviceState(readings: readings)));
    }
    return out;
  }

  Future<List<Device>> _probeGen1(String host, String base) async {
    final status = Map<String, dynamic>.from(await readHost(host) as Map);
    String mode = 'relay';
    try {
      mode = '${(await getJson(_u(host, '/settings')) as Map)['mode'] ?? 'relay'}';
    } catch (_) {}
    final out = <Device>[];
    void add(String comp, DeviceKind kind, int count, Set<Capability>? caps) {
      for (var ch = 0; ch < count; ch++) {
        out.add(makeDevice(
          externalId: '$host#$comp:$ch',
          name: count == 1 ? base : '$base ${ch + 1}',
          kind: kind,
          capabilities: caps,
          props: {'host': host, 'gen': 1, 'component': comp, 'channel': ch},
        )..state = _gen1State(comp, ch, status));
      }
    }

    final relays = (status['relays'] as List?)?.length ?? 0;
    final lights = (status['lights'] as List?)?.length ?? 0;
    final rollers = (status['rollers'] as List?)?.length ?? 0;
    if (mode == 'roller' && rollers > 0) {
      add('roller', DeviceKind.cover, rollers, null);
    } else if (relays > 0) {
      add('relay', DeviceKind.outlet, relays, null);
    }
    if (lights > 0) add('light', DeviceKind.light, lights, {Capability.onOff, Capability.brightness});
    final readings = _gen1Readings(status);
    if (readings.isNotEmpty) {
      out.add(makeDevice(
          externalId: '$host#sensor',
          name: '$base sensor',
          kind: DeviceKind.sensor,
          props: {'host': host, 'gen': 1, 'component': 'sensor', 'channel': 0},
          state: DeviceState(readings: readings)));
    }
    return out;
  }

  @override
  Future<dynamic> readHost(String host) async {
    // Gen2 answers /rpc; Gen1 answers /status.
    try {
      return await getJson(_u(host, '/rpc/Shelly.GetStatus'));
    } catch (_) {
      return await getJson(_u(host, '/status'));
    }
  }

  @override
  DeviceState? stateFrom(Device d, dynamic data) {
    final status = Map<String, dynamic>.from(data as Map);
    final comp = d.props['component'] as String;
    final ch = (d.props['channel'] as num?)?.toInt() ?? 0;
    if (d.props['gen'] == 1) {
      if (comp == 'sensor') return DeviceState(readings: _gen1Readings(status));
      return _gen1State(comp, ch, status);
    }
    if (comp == 'sensor') return DeviceState(readings: _gen2Readings(status));
    return _gen2State(comp, status['$comp:$ch']);
  }

  static DeviceState _gen2State(String comp, dynamic raw) {
    final s = Map<String, dynamic>.from(raw as Map? ?? const {});
    return switch (comp) {
      'cover' => DeviceState(position: ((s['current_pos'] as num?) ?? 0) / 100),
      'light' => DeviceState(
          on: s['output'] as bool?,
          brightness: s['brightness'] == null ? null : (s['brightness'] as num) / 100),
      _ => DeviceState(
          on: s['output'] as bool?,
          readings: {if (s['apower'] != null) 'Power': '${s['apower']} W'}),
    };
  }

  static Map<String, String> _gen2Readings(Map status) {
    final out = <String, String>{};
    status.forEach((k, v) {
      if (v is! Map) return;
      if ('$k'.startsWith('temperature:') && v['tC'] != null) out['Temperature'] = '${v['tC']} °C';
      if ('$k'.startsWith('humidity:') && v['rh'] != null) out['Humidity'] = '${v['rh']} %';
      if ('$k'.startsWith('devicepower:') && v['battery'] is Map) {
        out['Battery'] = '${(v['battery'] as Map)['percent']} %';
      }
    });
    return out;
  }

  static DeviceState _gen1State(String comp, int ch, Map status) {
    Map item(String key) {
      final list = status[key] as List?;
      return list != null && ch < list.length ? list[ch] as Map : const {};
    }

    return switch (comp) {
      'roller' => DeviceState(position: ((item('rollers')['current_pos'] as num?) ?? 0) / 100),
      'light' => DeviceState(
          on: item('lights')['ison'] as bool?,
          brightness: item('lights')['brightness'] == null
              ? null
              : (item('lights')['brightness'] as num) / 100),
      _ => DeviceState(on: item('relays')['ison'] as bool?),
    };
  }

  static Map<String, String> _gen1Readings(Map status) {
    final out = <String, String>{};
    final tmp = status['tmp'];
    if (tmp is Map && tmp['value'] != null) out['Temperature'] = '${tmp['value']} °${tmp['units'] ?? 'C'}';
    final hum = status['hum'];
    if (hum is Map && hum['value'] != null) out['Humidity'] = '${hum['value']} %';
    final bat = status['bat'];
    if (bat is Map && bat['value'] != null) out['Battery'] = '${bat['value']} %';
    return out;
  }

  @override
  Future<DeviceState?> send(Device d, DeviceCommand c) async {
    final host = d.props['host'] as String;
    final comp = d.props['component'] as String;
    final ch = '${d.props['channel'] ?? 0}';
    if (d.props['gen'] == 1) {
      switch (comp) {
        case 'roller':
          if (c.position != null) {
            await getJson(_u(host, '/roller/$ch', {'go': 'to_pos', 'roller_pos': '${(c.position! * 100).round()}'}));
          }
        case 'light':
          await getJson(_u(host, '/light/$ch', {
            if (c.on != null) 'turn': c.on! ? 'on' : 'off',
            if (c.brightness != null) ...{'turn': 'on', 'brightness': '${(c.brightness! * 100).round().clamp(1, 100)}'},
          }));
        default:
          if (c.on != null) await getJson(_u(host, '/relay/$ch', {'turn': c.on! ? 'on' : 'off'}));
      }
      return null;
    }
    switch (comp) {
      case 'cover':
        if (c.position != null) {
          await getJson(_u(host, '/rpc/Cover.GoToPosition', {'id': ch, 'pos': '${(c.position! * 100).round()}'}));
        }
      case 'light':
        await getJson(_u(host, '/rpc/Light.Set', {
          'id': ch,
          if (c.on != null) 'on': '${c.on}',
          if (c.brightness != null) ...{'on': 'true', 'brightness': '${(c.brightness! * 100).round().clamp(1, 100)}'},
        }));
      default:
        if (c.on != null) await getJson(_u(host, '/rpc/Switch.Set', {'id': ch, 'on': '${c.on}'}));
    }
    return null;
  }
}
