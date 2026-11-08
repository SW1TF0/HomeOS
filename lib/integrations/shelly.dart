import 'package:clock/clock.dart';

import '../models/device.dart';
import 'integration.dart';
import 'shelly_cloud.dart';

/// Shelly relays, dimmers, plugs, roller shutters and H&T sensors over their
/// local HTTP API. Supports Gen1 and Gen2+ (Plus / Pro / Gen3 / Gen4). With a
/// Shelly Cloud key the same devices also answer from anywhere, and devices
/// in the Shelly app are added without an address.
class ShellyDriver extends HostListDriver {
  ShellyDriver(super.config, super.client);

  Uri _u(String host, String path, [Map<String, String>? q]) =>
      Uri.parse('http://$host$path').replace(queryParameters: q);

  ShellyCloud? _cloud;
  String? _cloudFor;

  /// The Shelly cloud, when its key and server are set.
  ShellyCloud? get cloud {
    final server = config.setting('cloud_server'), key = config.setting('cloud_key');
    if (key.isEmpty || server.isEmpty) return null;
    if (_cloud == null || _cloudFor != '$server $key') {
      _cloud = ShellyCloud(client, server: server, key: key);
      _cloudFor = '$server $key';
    }
    return _cloud;
  }

  /// Cloud ids by MAC, read from the account once. A Gen2 device's id is its MAC; older ones may differ.
  Map<String, String>? _idByMac;

  /// Hosts that did not answer lately, and when. Their devices go through the cloud for a while.
  final Map<String, DateTime> _down = {};
  static const _downFor = Duration(minutes: 2);

  /// Hosts whose MAC was asked for already.
  final Set<String> _macAsked = {};

  /// The last states from the cloud and when, so polling every few seconds stays within its limit.
  Map<String, ({bool online, Map<String, dynamic> status})>? _cloudStates;
  DateTime? _cloudAt;
  static const cloudPoll = Duration(seconds: 20);

  /// The device's id in the Shelly cloud, when it is known.
  String? cloudId(Device d) {
    final mac = ShellyCloud.idForMac(d.props['mac'] as String?);
    return d.props['cloudId'] as String? ?? (mac == null ? null : _idByMac?[mac] ?? mac);
  }

  @override
  bool reachesAnywhere(Device device) => (cloud?.usable ?? false) && cloudId(device) != null;

  /// Whether to try [host] on the home network first: not when it has no address, or when the cloud can take over
  /// while away or after it stopped answering.
  bool _local(String host) {
    if (host.isEmpty) return false;
    if (cloud == null) return true;
    if (away) return false;
    final down = _down[host];
    return down == null || clock.now().difference(down) > _downFor;
  }

  @override
  Future<List<Device>> discover() async {
    final c = cloud;
    if (hosts.isEmpty && c == null) {
      throw IntegrationException('Add at least one device address (for example 192.168.1.40), or your Shelly Cloud key.');
    }
    final out = <Device>[];
    final errors = <String>[];
    for (final host in hosts) {
      try {
        out.addAll(await probe(host));
      } catch (e) {
        errors.add('$host: $e');
      }
    }
    if (c != null) {
      try {
        out.addAll(await _cloudDevices(c, out));
      } catch (e) {
        errors.add('Shelly Cloud: $e');
      }
    }
    if (out.isEmpty && errors.isNotEmpty) {
      throw IntegrationException('Could not reach ${errors.join('; ')}');
    }
    return out;
  }

  /// The devices on the Shelly account that are not on the home network list already. Those that are learn their
  /// cloud id.
  Future<List<Device>> _cloudDevices(ShellyCloud c, List<Device> local) async {
    final all = await c.allStatus();
    final names = await c.names();
    _idByMac = {
      for (final e in all.entries)
        if (ShellyCloud.macOf(e.value) != null) ShellyCloud.macOf(e.value)!: e.key,
    };
    final out = <Device>[];
    for (final e in all.entries) {
      final id = e.key, status = e.value;
      final mac = ShellyCloud.macOf(status);
      final mine = local.where((d) => mac != null && ShellyCloud.idForMac(d.props['mac'] as String?) == mac).toList();
      if (mine.isNotEmpty) {
        for (final d in mine) {
          d.props['cloudId'] = id;
        }
        continue;
      }
      final info = status['_dev_info'] as Map? ?? const {};
      final base = names[id] ?? 'Shelly ${info['code'] ?? id.substring(id.length > 6 ? id.length - 6 : 0)}';
      final key = 'cloud-$id';
      final extra = {'cloudId': id, 'mac': ?mac};
      final found = ShellyCloud.isGen1(status)
          ? _gen1Devices(key, base, status, _gen1Mode(status), extra)
          : _gen2Devices(key, base, status, const {}, extra);
      final online = info['online'];
      out.addAll([
        for (final d in found)
          if (online == false) (d..state = d.state.merge(DeviceState.unreachable)) else d,
      ]);
    }
    return out;
  }

  /// Without the device's settings: a roller when it reports a position.
  static String _gen1Mode(Map status) {
    final rollers = status['rollers'] as List?;
    final relays = status['relays'] as List?;
    return rollers != null && rollers.isNotEmpty && (relays == null || relays.isEmpty || (rollers.first as Map)['positioning'] == true)
        ? 'roller'
        : 'relay';
  }

  @override
  Future<List<Device>> probe(String host) async {
    final info = await getJson(_u(host, '/shelly')) as Map;
    final gen = (info['gen'] as num?)?.toInt() ?? 1;
    final base = '${info['name'] ?? info['type'] ?? info['model'] ?? 'Shelly'}';
    final mac = ShellyCloud.idForMac(info['mac'] as String?);
    _macAsked.add(host);
    final extra = {'host': host, 'mac': ?mac};
    return gen >= 2 ? _probeGen2(host, base, extra) : _probeGen1(host, base, extra);
  }

  Future<List<Device>> _probeGen2(String host, String base, Map<String, dynamic> extra) async {
    final status = Map<String, dynamic>.from(await readHost(host) as Map);
    Map config = const {};
    try {
      config = await getJson(_u(host, '/rpc/Shelly.GetConfig')) as Map;
    } catch (_) {}
    return _gen2Devices(host, base, status, config, extra);
  }

  /// The switches, lights, covers and sensor of a Gen2+ device, with ids starting with [key] (its address, or
  /// `cloud-<id>` for one only in the cloud).
  List<Device> _gen2Devices(String key, String base, Map<String, dynamic> status, Map config, Map<String, dynamic> extra) {
    final out = <Device>[];
    final readings = <String, String>{};
    for (final part in status.keys) {
      final parts = part.split(':');
      if (parts.length != 2) continue;
      final comp = parts[0];
      final ch = int.tryParse(parts[1]) ?? 0;
      final label = (config[part] as Map?)?['name'] as String?;
      String name(String fallback) => label ?? (ch == 0 ? base : '$base $fallback ${ch + 1}');
      final props = {...extra, 'gen': 2, 'component': comp, 'channel': ch};
      switch (comp) {
        case 'switch':
          out.add(makeDevice(
              externalId: '$key#switch:$ch',
              name: name('switch'),
              kind: DeviceKind.outlet,
              props: props,
              state: _gen2State(comp, status[part])));
        case 'light':
          out.add(makeDevice(
              externalId: '$key#light:$ch',
              name: name('light'),
              kind: DeviceKind.light,
              capabilities: {Capability.onOff, Capability.brightness},
              props: props,
              state: _gen2State(comp, status[part])));
        case 'cover':
          out.add(makeDevice(
              externalId: '$key#cover:$ch',
              name: name('cover'),
              kind: DeviceKind.cover,
              props: props,
              state: _gen2State(comp, status[part])));
        case 'temperature' || 'humidity' || 'devicepower':
          readings.addAll(_gen2Readings({part: status[part]}));
      }
    }
    if (readings.isNotEmpty) {
      out.add(makeDevice(
          externalId: '$key#sensor',
          name: '$base sensor',
          kind: DeviceKind.sensor,
          props: {...extra, 'gen': 2, 'component': 'sensor', 'channel': 0},
          state: DeviceState(readings: readings)));
    }
    return out;
  }

  Future<List<Device>> _probeGen1(String host, String base, Map<String, dynamic> extra) async {
    final status = Map<String, dynamic>.from(await readHost(host) as Map);
    String mode = 'relay';
    try {
      mode = '${(await getJson(_u(host, '/settings')) as Map)['mode'] ?? 'relay'}';
    } catch (_) {}
    return _gen1Devices(host, base, status, mode, extra);
  }

  List<Device> _gen1Devices(String key, String base, Map<String, dynamic> status, String mode, Map<String, dynamic> extra) {
    final out = <Device>[];
    void add(String comp, DeviceKind kind, int count, Set<Capability>? caps) {
      for (var ch = 0; ch < count; ch++) {
        out.add(makeDevice(
          externalId: '$key#$comp:$ch',
          name: count == 1 ? base : '$base ${ch + 1}',
          kind: kind,
          capabilities: caps,
          props: {...extra, 'gen': 1, 'component': comp, 'channel': ch},
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
          externalId: '$key#sensor',
          name: '$base sensor',
          kind: DeviceKind.sensor,
          props: {...extra, 'gen': 1, 'component': 'sensor', 'channel': 0},
          state: DeviceState(readings: readings)));
    }
    return out;
  }

  /// Home devices answer on the Wi-Fi; away from it, or when they do not answer, the Shelly cloud says what they
  /// are doing.
  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    final cache = <String, Future<dynamic>>{};
    final out = <String, DeviceState>{};
    final far = <Device>[];
    for (final d in devices) {
      final host = d.props['host'] as String? ?? '';
      if (!_local(host)) {
        far.add(d);
        continue;
      }
      try {
        final data = await cache.putIfAbsent(host, () => readHost(host));
        out[d.id] = d.state.merge(stateFrom(d, data) ?? const DeviceState());
        await _learnMac(d, host);
      } catch (_) {
        _down[host] = clock.now();
        far.add(d);
      }
    }
    if (far.isEmpty) return out;
    final states = await _fromCloud(far);
    for (final d in far) {
      final s = states[cloudId(d)];
      out[d.id] = s == null || !s.online
          ? d.state.merge(DeviceState.unreachable)
          : d.state.merge(stateFrom(d, s.status) ?? const DeviceState());
    }
    return out;
  }

  @override
  Future<DeviceState?> refresh(Device device) async => (await refreshAll([device]))[device.id];

  /// What the cloud says about [devices], at most every [cloudPoll].
  Future<Map<String, ({bool online, Map<String, dynamic> status})>> _fromCloud(List<Device> devices) async {
    final c = cloud;
    if (c == null) return const {};
    try {
      if (_idByMac == null && devices.any((d) => d.props['cloudId'] == null)) await _learnIds(c);
      final ids = {for (final d in devices) ?cloudId(d)};
      final cached = _cloudStates;
      if (cached != null && _cloudAt != null && clock.now().difference(_cloudAt!) < cloudPoll && ids.every(cached.containsKey)) {
        return cached;
      }
      final states = await c.statusOf(ids);
      _cloudStates = states;
      _cloudAt = clock.now();
      return states;
    } catch (_) {
      return _cloudStates ?? const {};
    }
  }

  Future<void> _learnIds(ShellyCloud c) async {
    try {
      final all = await c.allStatus();
      _idByMac = {
        for (final e in all.entries)
          if (ShellyCloud.macOf(e.value) != null) ShellyCloud.macOf(e.value)!: e.key,
      };
    } catch (_) {
      _idByMac = const {};
    }
  }

  /// Devices added before the cloud key learn their MAC, which finds them in the cloud.
  Future<void> _learnMac(Device d, String host) async {
    if (d.props['mac'] != null || cloud == null || !_macAsked.add(host)) return;
    try {
      final mac = ShellyCloud.idForMac((await getJson(_u(host, '/shelly')) as Map)['mac'] as String?);
      if (mac != null) d.props['mac'] = mac;
    } catch (_) {}
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
    final host = d.props['host'] as String? ?? '';
    final cl = cloud;
    final id = cloudId(d);
    if (cl == null || id == null) {
      if (host.isEmpty) throw IntegrationException('${d.name} has no address. Add the Shelly Cloud key again.');
      return _sendLocal(d, c, host);
    }
    if (_local(host)) {
      try {
        return await _sendLocal(d, c, host);
      } catch (_) {
        _down[host] = clock.now();
      }
    }
    _cloudStates = null;
    final ch = (d.props['channel'] as num?)?.toInt() ?? 0;
    switch (d.props['component']) {
      case 'cover' || 'roller':
        if (c.position != null) await cl.setCover(id, ch, (c.position! * 100).round());
      case 'light':
        await cl.setLight(id, ch, on: c.on, brightness: c.brightness == null ? null : (c.brightness! * 100).round().clamp(1, 100));
      default:
        if (c.on != null) await cl.setSwitch(id, ch, c.on!);
    }
    return null;
  }

  Future<DeviceState?> _sendLocal(Device d, DeviceCommand c, String host) async {
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
