import 'dart:convert';

import '../models/device.dart';
import '../util/color_math.dart';

/// A message to publish on the broker.
class MqttOut {
  const MqttOut(this.topic, this.payload, {this.retain = false});
  final String topic;
  final String payload;
  final bool retain;

  @override
  String toString() => '$topic <- $payload';
}

/// Everything MQTT knows about devices, without any networking, so it can be
/// tested on its own. Understands three sources:
///  * Zigbee2MQTT (thousands of Zigbee devices from every brand),
///  * Home Assistant MQTT discovery (used by Tasmota, ESPHome, Shelly, OpenMQTTGateway, Zigbee2MQTT...),
///  * hand-made devices with topics the user types in.
class MqttModel {
  MqttModel({this.z2mBase = 'zigbee2mqtt', this.discoveryPrefix = 'homeassistant'});

  final String z2mBase;
  final String discoveryPrefix;

  /// Zigbee2MQTT friendly name to its bridge/devices entry.
  final Map<String, Map<String, dynamic>> z2mDevices = {};

  /// External id (`ha:<id>` or `manual:<id>`) to an expanded discovery config.
  final Map<String, Map<String, dynamic>> entities = {};

  /// Latest state per external id.
  final Map<String, DeviceState> states = {};

  /// Topic to what it updates: (external id, field).
  final Map<String, List<(String, String)>> _routes = {};

  List<String> get subscriptions => [
        '$z2mBase/#',
        '$discoveryPrefix/+/+/config',
        '$discoveryPrefix/+/+/+/config',
        ..._routes.keys,
      ];

  /// Processes one message. Returns states that changed, keyed by external id,
  /// and any new topics that need subscribing.
  (Map<String, DeviceState>, List<String>) handle(String topic, String payload) {
    final changed = <String, DeviceState>{};
    final newTopics = <String>[];

    if (topic == '$z2mBase/bridge/devices') {
      _readZ2mDevices(payload);
    } else if (topic.startsWith('$z2mBase/') && !topic.startsWith('$z2mBase/bridge/')) {
      final rest = topic.substring(z2mBase.length + 1);
      if (rest.endsWith('/availability')) {
        final name = rest.substring(0, rest.length - '/availability'.length);
        final online = payload.contains('online');
        final id = 'z2m:$name';
        changed[id] = states[id] = (states[id] ?? const DeviceState()).merge(DeviceState(reachable: online));
      } else if (!rest.endsWith('/set') && !rest.endsWith('/get')) {
        final parsed = parseZ2mState(payload);
        if (parsed != null) {
          final id = 'z2m:$rest';
          changed[id] = states[id] = (states[id] ?? const DeviceState()).merge(parsed);
        }
      }
    } else if (topic.startsWith('$discoveryPrefix/') && topic.endsWith('/config')) {
      newTopics.addAll(_readDiscovery(topic, payload));
    }

    for (final (id, field) in _routes[topic] ?? const <(String, String)>[]) {
      final cfg = entities[id];
      if (cfg == null) continue;
      final parsed = parseEntityState(cfg, field, payload);
      if (parsed != null) changed[id] = states[id] = (states[id] ?? const DeviceState()).merge(parsed);
    }
    return (changed, newTopics);
  }

  void _readZ2mDevices(String payload) {
    try {
      final list = jsonDecode(payload) as List;
      z2mDevices.clear();
      for (final d in list.whereType<Map>()) {
        if (d['type'] == 'Coordinator' || d['friendly_name'] == null) continue;
        z2mDevices['${d['friendly_name']}'] = Map<String, dynamic>.from(d);
      }
    } catch (_) {}
  }

  static const _abbreviations = {
    'cmd_t': 'command_topic',
    'stat_t': 'state_topic',
    'pl_on': 'payload_on',
    'pl_off': 'payload_off',
    'stat_on': 'state_on',
    'stat_off': 'state_off',
    'bri_cmd_t': 'brightness_command_topic',
    'bri_stat_t': 'brightness_state_topic',
    'bri_scl': 'brightness_scale',
    'bri_val_tpl': 'brightness_value_template',
    'val_tpl': 'value_template',
    'stat_val_tpl': 'state_value_template',
    'uniq_id': 'unique_id',
    'unit_of_meas': 'unit_of_measurement',
    'dev_cla': 'device_class',
    'pos_t': 'position_topic',
    'set_pos_t': 'set_position_topic',
    'pos_open': 'position_open',
    'pos_clsd': 'position_closed',
    'pl_open': 'payload_open',
    'pl_cls': 'payload_close',
    'pl_lock': 'payload_lock',
    'pl_unlk': 'payload_unlock',
    'stat_locked': 'state_locked',
    'stat_unlocked': 'state_unlocked',
    'clr_temp_cmd_t': 'color_temp_command_topic',
    'rgb_cmd_t': 'rgb_command_topic',
    'dev': 'device',
    'avty_t': 'availability_topic',
  };

  static const supportedComponents = {'switch', 'light', 'sensor', 'binary_sensor', 'cover', 'fan', 'lock'};

  /// Expands abbreviated keys and the "~" base topic of a discovery config.
  static Map<String, dynamic> expandConfig(Map<String, dynamic> raw) {
    final base = raw['~'] as String?;
    final out = <String, dynamic>{};
    raw.forEach((k, v) {
      final key = _abbreviations[k] ?? k;
      if (v is String && base != null && key.endsWith('_topic')) {
        v = v.startsWith('~') ? '$base${v.substring(1)}' : (v.endsWith('~') ? '${v.substring(0, v.length - 1)}$base' : v);
      }
      out[key] = v;
    });
    if (out['device'] is Map) {
      final dev = Map<String, dynamic>.from(out['device'] as Map);
      if (dev['name'] == null && dev.containsKey('name')) dev.remove('name');
      out['device'] = dev;
    }
    return out;
  }

  List<String> _readDiscovery(String topic, String payload) {
    final parts = topic.split('/');
    final component = parts[1];
    if (!supportedComponents.contains(component)) return const [];
    final key = parts.sublist(2, parts.length - 1).join('/');
    final id = 'ha:$component/$key';
    if (payload.trim().isEmpty) {
      entities.remove(id);
      return const [];
    }
    try {
      final cfg = expandConfig(Map<String, dynamic>.from(jsonDecode(payload) as Map));
      // Zigbee2MQTT devices are already read from its own topics.
      final stateTopic = '${cfg['state_topic'] ?? ''}';
      if (stateTopic.startsWith('$z2mBase/') && z2mDevices.isNotEmpty) return const [];
      cfg['component'] = component;
      return register(id, cfg);
    } catch (_) {
      return const [];
    }
  }

  /// Adds a discovery-style entity and returns the topics to subscribe.
  List<String> register(String id, Map<String, dynamic> cfg) {
    entities[id] = cfg;
    final topics = <String>[];
    void route(String? topic, String field) {
      if (topic == null || topic.isEmpty) return;
      final list = _routes.putIfAbsent(topic, () => []);
      if (!list.contains((id, field))) list.add((id, field));
      topics.add(topic);
    }

    route(cfg['state_topic'] as String?, 'state');
    route(cfg['brightness_state_topic'] as String?, 'brightness');
    route(cfg['position_topic'] as String?, 'position');
    return topics;
  }

  // ---- Values and templates -------------------------------------------------

  /// Applies the simple Home Assistant templates devices use in practice:
  /// `{{ value }}`, `{{ value_json.a.b }}` and `{{ value_json['a'] }}`.
  static String applyTemplate(String? template, String payload) {
    if (template == null || template.trim().isEmpty) return payload.trim();
    final m = RegExp(r'''value_json((?:\.\w+|\[['"][^'"]+['"]\]|\[\d+\])+)''').firstMatch(template);
    if (m == null) return payload.trim();
    dynamic node;
    try {
      node = jsonDecode(payload);
    } catch (_) {
      return payload.trim();
    }
    for (final seg in RegExp(r'''\.(\w+)|\[['"]([^'"]+)['"]\]|\[(\d+)\]''').allMatches(m.group(1)!)) {
      final key = seg.group(1) ?? seg.group(2);
      if (key != null && node is Map) {
        node = node[key];
      } else if (seg.group(3) != null && node is List) {
        final i = int.parse(seg.group(3)!);
        node = i < node.length ? node[i] : null;
      } else {
        node = null;
      }
    }
    return node == null ? '' : (node is String ? node : jsonEncode(node)).trim();
  }

  static String entityName(Map<String, dynamic> cfg) {
    final dev = cfg['device'] as Map?;
    final devName = dev?['name'] as String?;
    final name = cfg['name'] as String?;
    if (name == null || name.isEmpty) return devName ?? cfg['unique_id'] as String? ?? 'MQTT device';
    if (devName != null && !name.toLowerCase().startsWith(devName.toLowerCase())) return '$devName $name';
    return name;
  }

  static DeviceKind kindForComponent(String component, Map<String, dynamic> cfg) => switch (component) {
        'light' => DeviceKind.light,
        'switch' => cfg['device_class'] == 'outlet' ? DeviceKind.outlet : DeviceKind.toggle,
        'fan' => DeviceKind.fan,
        'cover' => DeviceKind.cover,
        'lock' => DeviceKind.lock,
        _ => DeviceKind.sensor,
      };

  static Set<Capability> capabilitiesForEntity(Map<String, dynamic> cfg) {
    final component = cfg['component'] as String;
    final json = cfg['schema'] == 'json';
    switch (component) {
      case 'light':
        final modes = ((cfg['supported_color_modes'] as List?) ?? const []).map((e) => '$e').toSet();
        return {
          Capability.onOff,
          if (cfg['brightness_command_topic'] != null || (json && (cfg['brightness'] == true || modes.any((m) => m != 'onoff'))))
            Capability.brightness,
          if (cfg['color_temp_command_topic'] != null || modes.contains('color_temp')) Capability.colorTemp,
          if (cfg['rgb_command_topic'] != null || modes.any((m) => const {'rgb', 'hs', 'xy', 'rgbw', 'rgbww'}.contains(m)))
            Capability.color,
        };
      case 'cover':
        return {Capability.position};
      case 'lock':
        return {Capability.lock};
      case 'sensor' || 'binary_sensor':
        return {Capability.readings};
      default:
        return {Capability.onOff};
    }
  }

  static DeviceState? parseEntityState(Map<String, dynamic> cfg, String field, String payload) {
    final component = cfg['component'] as String;
    if (field == 'brightness') {
      final v = double.tryParse(applyTemplate(cfg['brightness_value_template'] as String?, payload));
      final scale = (cfg['brightness_scale'] as num?)?.toDouble() ?? 255;
      return v == null ? null : DeviceState(brightness: (v / scale).clamp(0, 1));
    }
    if (field == 'position') {
      final v = double.tryParse(applyTemplate(cfg['position_template'] as String?, payload));
      final open = (cfg['position_open'] as num?)?.toDouble() ?? 100;
      return v == null ? null : DeviceState(position: (v / open).clamp(0, 1));
    }
    if (component == 'light' && cfg['schema'] == 'json') {
      try {
        final j = jsonDecode(payload) as Map;
        final scale = (cfg['brightness_scale'] as num?)?.toDouble() ?? 255;
        final col = j['color'] as Map?;
        return DeviceState(
          on: j['state'] == null ? null : '${j['state']}'.toUpperCase() == 'ON',
          brightness: j['brightness'] is num ? ((j['brightness'] as num) / scale).clamp(0, 1) : null,
          colorTempK: j['color_temp'] is num && j['color_mode'] != 'rgb' ? miredToKelvin(j['color_temp'] as num) : null,
          color: col != null && col['r'] is num
              ? rgbToInt((col['r'] as num).toInt(), (col['g'] as num).toInt(), (col['b'] as num).toInt())
              : null,
        );
      } catch (_) {
        return null;
      }
    }
    final value = applyTemplate((cfg['state_value_template'] ?? cfg['value_template']) as String?, payload);
    switch (component) {
      case 'sensor':
        final unit = cfg['unit_of_measurement'];
        return DeviceState(readings: {_readingLabel(cfg): unit == null ? value : '$value $unit'});
      case 'binary_sensor':
        final on = value == '${cfg['payload_on'] ?? 'ON'}';
        final cls = cfg['device_class'];
        final text = const {'door', 'window', 'opening', 'garage_door'}.contains(cls)
            ? (on ? 'Open' : 'Closed')
            : (on ? 'Detected' : 'Clear');
        return DeviceState(readings: {_readingLabel(cfg): text});
      case 'cover':
        final v = value.toLowerCase();
        if (v == 'open' || v == 'opening') return const DeviceState(position: 1);
        if (v == 'closed' || v == 'closing') return const DeviceState(position: 0);
        return null;
      case 'lock':
        return DeviceState(locked: value == '${cfg['state_locked'] ?? 'LOCKED'}');
      default:
        final onValue = '${cfg['state_on'] ?? cfg['payload_on'] ?? 'ON'}';
        return DeviceState(on: value == onValue || value.toLowerCase() == 'on' || value == 'true');
    }
  }

  static String _readingLabel(Map<String, dynamic> cfg) {
    final cls = cfg['device_class'] as String?;
    final name = cfg['name'] as String?;
    if (name != null && name.isNotEmpty) return name;
    if (cls != null) return cls[0].toUpperCase() + cls.substring(1).replaceAll('_', ' ');
    return 'Value';
  }

  // ---- Zigbee2MQTT ------------------------------------------------------------

  static List<Map<String, dynamic>> _flatExposes(Map<String, dynamic> device) {
    final exposes = ((device['definition'] as Map?)?['exposes'] as List?) ?? const [];
    return exposes.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static const _sensorReadings = {
    'temperature', 'humidity', 'battery', 'illuminance', 'illuminance_lux', 'power', 'energy',
    'occupancy', 'presence', 'contact', 'water_leak', 'smoke', 'pressure', 'co2', 'voltage',
  };

  /// Kind, capabilities and extra props of a Zigbee2MQTT device from its "exposes".
  static (DeviceKind, Set<Capability>, Map<String, dynamic>) describeZ2m(Map<String, dynamic> device) {
    final exposes = _flatExposes(device);
    DeviceKind? kind;
    final caps = <Capability>{};
    final props = <String, dynamic>{};
    for (final e in exposes) {
      final type = e['type'];
      final features = ((e['features'] as List?) ?? const []).whereType<Map>().map((f) => '${f['name']}').toSet();
      switch (type) {
        case 'light':
          kind ??= DeviceKind.light;
          caps.add(Capability.onOff);
          if (features.contains('brightness')) caps.add(Capability.brightness);
          if (features.contains('color_temp')) caps.add(Capability.colorTemp);
          if (features.contains('color_xy') || features.contains('color_hs')) caps.add(Capability.color);
        case 'switch':
          kind ??= DeviceKind.outlet;
          caps.add(Capability.onOff);
        case 'cover':
          kind ??= DeviceKind.cover;
          caps.add(Capability.position);
        case 'lock':
          kind ??= DeviceKind.lock;
          caps.add(Capability.lock);
        case 'fan':
          kind ??= DeviceKind.fan;
          caps.add(Capability.onOff);
        case 'climate':
          kind ??= DeviceKind.climate;
          caps.add(Capability.targetTemp);
          props['setpoint'] = features.contains('current_heating_setpoint')
              ? 'current_heating_setpoint'
              : (features.contains('occupied_heating_setpoint') ? 'occupied_heating_setpoint' : 'current_heating_setpoint');
        default:
          if (_sensorReadings.contains(e['name'])) caps.add(Capability.readings);
      }
    }
    return (kind ?? DeviceKind.sensor, caps, props);
  }

  static DeviceState? parseZ2mState(String payload) {
    Map j;
    try {
      final d = jsonDecode(payload);
      if (d is! Map) return null;
      j = d;
    } catch (_) {
      return null;
    }
    final state = j['state'] is String ? (j['state'] as String).toUpperCase() : null;
    final color = j['color'] as Map?;
    final mode = j['color_mode'];
    final readings = <String, String>{};
    void r(String key, String label, String Function(dynamic v) fmt) {
      if (j[key] != null) readings[label] = fmt(j[key]);
    }

    r('temperature', 'Temperature', (v) => '$v °C');
    r('humidity', 'Humidity', (v) => '$v %');
    r('illuminance_lux', 'Light', (v) => '$v lx');
    if (j['illuminance_lux'] == null) r('illuminance', 'Light', (v) => '$v lx');
    r('power', 'Power', (v) => '$v W');
    r('pressure', 'Pressure', (v) => '$v hPa');
    r('co2', 'CO2', (v) => '$v ppm');
    r('occupancy', 'Motion', (v) => v == true ? 'Detected' : 'Clear');
    r('presence', 'Presence', (v) => v == true ? 'Detected' : 'Clear');
    r('contact', 'Contact', (v) => v == true ? 'Closed' : 'Open');
    r('water_leak', 'Leak', (v) => v == true ? 'Leak!' : 'Dry');
    r('smoke', 'Smoke', (v) => v == true ? 'Smoke!' : 'Clear');
    r('battery', 'Battery', (v) => '$v %');

    final setpoint = j['current_heating_setpoint'] ?? j['occupied_heating_setpoint'];
    return DeviceState(
      on: state == 'ON' ? true : (state == 'OFF' ? false : null),
      brightness: j['brightness'] is num ? ((j['brightness'] as num) / 254).clamp(0, 1) : null,
      colorTempK: j['color_temp'] is num && mode == 'color_temp' ? miredToKelvin(j['color_temp'] as num) : null,
      color: color != null && color['x'] is num && mode != 'color_temp'
          ? xyToRgb((color['x'] as num).toDouble(), (color['y'] as num).toDouble())
          : null,
      position: j['position'] is num ? (j['position'] as num) / 100 : null,
      targetTemp: setpoint is num ? setpoint.toDouble() : null,
      currentTemp: j['local_temperature'] is num ? (j['local_temperature'] as num).toDouble() : null,
      locked: j['lock_state'] != null
          ? j['lock_state'] == 'locked'
          : (state == 'LOCK' ? true : (state == 'UNLOCK' ? false : null)),
      readings: readings,
    );
  }

  // ---- Commands ---------------------------------------------------------------

  /// Messages that carry out [c] on [device].
  List<MqttOut> commandsFor(Device device, DeviceCommand c) {
    final z2m = device.props['z2m'] as String?;
    if (z2m != null) {
      final body = <String, dynamic>{};
      if (c.on != null) body['state'] = c.on! ? 'ON' : 'OFF';
      if (c.locked != null) body['state'] = c.locked! ? 'LOCK' : 'UNLOCK';
      if (c.brightness != null) body['brightness'] = (c.brightness! * 254).round();
      if (c.colorTempK != null) body['color_temp'] = kelvinToMired(c.colorTempK!);
      if (c.color != null) body['color'] = {'hex': intToHex(c.color!)};
      if (c.position != null) body['position'] = (c.position! * 100).round();
      if (c.targetTemp != null) body['${device.props['setpoint'] ?? 'current_heating_setpoint'}'] = c.targetTemp;
      return [MqttOut('$z2mBase/$z2m/set', jsonEncode(body))];
    }
    final cfg = device.props;
    final cmd = cfg['command_topic'] as String?;
    final out = <MqttOut>[];
    final scale = (cfg['brightness_scale'] as num?)?.toDouble() ?? 255;
    switch (cfg['component']) {
      case 'light' when cfg['schema'] == 'json':
        if (cmd == null) return out;
        out.add(MqttOut(
            cmd,
            jsonEncode({
              'state': c.on == false ? 'OFF' : 'ON',
              if (c.brightness != null) 'brightness': (c.brightness! * scale).round(),
              if (c.colorTempK != null) 'color_temp': kelvinToMired(c.colorTempK!),
              if (c.color != null) 'color': {'r': intToRgb(c.color!)[0], 'g': intToRgb(c.color!)[1], 'b': intToRgb(c.color!)[2]},
            })));
      case 'light':
        if (c.on != null && cmd != null) out.add(MqttOut(cmd, '${c.on! ? cfg['payload_on'] ?? 'ON' : cfg['payload_off'] ?? 'OFF'}'));
        final bri = cfg['brightness_command_topic'] as String?;
        if (c.brightness != null && bri != null) out.add(MqttOut(bri, '${(c.brightness! * scale).round()}'));
        final ct = cfg['color_temp_command_topic'] as String?;
        if (c.colorTempK != null && ct != null) out.add(MqttOut(ct, '${kelvinToMired(c.colorTempK!)}'));
        final rgb = cfg['rgb_command_topic'] as String?;
        if (c.color != null && rgb != null) out.add(MqttOut(rgb, intToRgb(c.color!).join(',')));
      case 'cover':
        final setPos = cfg['set_position_topic'] as String?;
        if (c.position != null && setPos != null) {
          final open = (cfg['position_open'] as num?)?.toDouble() ?? 100;
          out.add(MqttOut(setPos, '${(c.position! * open).round()}'));
        } else if (c.position != null && cmd != null) {
          out.add(MqttOut(cmd, '${c.position! > 0.5 ? cfg['payload_open'] ?? 'OPEN' : cfg['payload_close'] ?? 'CLOSE'}'));
        }
      case 'lock':
        if (c.locked != null && cmd != null) {
          out.add(MqttOut(cmd, '${c.locked! ? cfg['payload_lock'] ?? 'LOCK' : cfg['payload_unlock'] ?? 'UNLOCK'}'));
        }
      case 'sensor' || 'binary_sensor':
        break;
      default:
        if (c.on != null && cmd != null) out.add(MqttOut(cmd, '${c.on! ? cfg['payload_on'] ?? 'ON' : cfg['payload_off'] ?? 'OFF'}'));
    }
    return out;
  }

  /// Devices known from Zigbee2MQTT and discovery, built with [make].
  List<Device> devices(
      Device Function(String externalId, String name, DeviceKind kind, Set<Capability> caps, Map<String, dynamic> props,
              DeviceState state)
          make) {
    final out = <Device>[];
    z2mDevices.forEach((name, d) {
      final (kind, caps, props) = describeZ2m(d);
      if (caps.isEmpty) return;
      final def = d['definition'] as Map?;
      out.add(make('z2m:$name', name, kind, caps,
          {'z2m': name, ...props, if (def != null) 'model': '${def['vendor']} ${def['model']}'}, states['z2m:$name'] ?? const DeviceState()));
    });
    entities.forEach((id, cfg) {
      if (id.startsWith('manual:')) return;
      final component = cfg['component'] as String;
      out.add(make(id, entityName(cfg), kindForComponent(component, cfg), capabilitiesForEntity(cfg), cfg,
          states[id] ?? const DeviceState()));
    });
    return out;
  }
}
