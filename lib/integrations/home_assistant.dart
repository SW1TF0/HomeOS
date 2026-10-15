import '../models/device.dart';
import '../util/color_math.dart';
import 'integration.dart';

/// A Home Assistant server (free, self-hosted). Brings in every light, switch,
/// cover, climate, lock, fan, media player and useful sensor it knows about,
/// which covers thousands of brands, Matter, Zigbee and Z-Wave included.
class HomeAssistantDriver extends IntegrationDriver {
  HomeAssistantDriver(super.config, super.client);

  String get baseUrl {
    var url = config.setting('url');
    if (url.isEmpty) return url;
    if (!url.startsWith('http')) url = 'http://$url';
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer ${config.setting('token')}'};

  static const _sensorClasses = {
    'temperature', 'humidity', 'motion', 'occupancy', 'presence', 'door', 'window', 'opening',
    'power', 'energy', 'battery', 'illuminance', 'moisture', 'smoke', 'gas', 'co2', 'pm25',
  };

  Future<List<Map<String, dynamic>>> _states() async {
    if (baseUrl.isEmpty || config.setting('token').isEmpty) {
      throw IntegrationException('Enter the server address and a long-lived access token (Profile > Security in Home Assistant).');
    }
    final res = await getJson(Uri.parse('$baseUrl/api/states'), headers: _headers);
    return (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static DeviceKind? kindFor(Map<String, dynamic> entity) {
    final id = entity['entity_id'] as String;
    final domain = id.split('.').first;
    final attrs = (entity['attributes'] as Map?) ?? const {};
    return switch (domain) {
      'light' => DeviceKind.light,
      'switch' => attrs['device_class'] == 'outlet' ? DeviceKind.outlet : DeviceKind.toggle,
      'input_boolean' => DeviceKind.toggle,
      'fan' => DeviceKind.fan,
      'cover' => DeviceKind.cover,
      'climate' => DeviceKind.climate,
      'lock' => DeviceKind.lock,
      'media_player' => DeviceKind.media,
      'camera' => DeviceKind.camera,
      'sensor' || 'binary_sensor' => _sensorClasses.contains(attrs['device_class']) ? DeviceKind.sensor : null,
      _ => null,
    };
  }

  static Set<Capability> capabilitiesFor(Map<String, dynamic> entity, DeviceKind kind) {
    final attrs = (entity['attributes'] as Map?) ?? const {};
    if (kind == DeviceKind.light) {
      final modes = ((attrs['supported_color_modes'] as List?) ?? const []).map((e) => '$e').toSet();
      return {
        Capability.onOff,
        if (modes.any((m) => m != 'onoff')) Capability.brightness,
        if (modes.contains('color_temp')) Capability.colorTemp,
        if (modes.any((m) => const {'hs', 'xy', 'rgb', 'rgbw', 'rgbww'}.contains(m))) Capability.color,
      };
    }
    if (kind == DeviceKind.cover) {
      final features = (attrs['supported_features'] as num?)?.toInt() ?? 0;
      return {Capability.position, if (features & 4 == 0) Capability.onOff};
    }
    return defaultCapabilities(kind);
  }

  static DeviceState parseState(Map<String, dynamic> entity) {
    final id = entity['entity_id'] as String;
    final domain = id.split('.').first;
    final state = '${entity['state']}';
    final attrs = Map<String, dynamic>.from((entity['attributes'] as Map?) ?? const {});
    final reachable = state != 'unavailable';
    switch (domain) {
      case 'sensor' || 'binary_sensor':
        final label = '${attrs['friendly_name'] ?? id}';
        final unit = attrs['unit_of_measurement'];
        final value = domain == 'binary_sensor' ? (state == 'on' ? 'Detected' : 'Clear') : state;
        return DeviceState(readings: {label: unit == null ? value : '$value $unit'}, reachable: reachable);
      case 'cover':
        final pos = attrs['current_position'] as num?;
        return DeviceState(
            position: pos != null ? pos / 100 : (state == 'open' ? 1 : 0), on: state == 'open', reachable: reachable);
      case 'climate':
        return DeviceState(
          on: state != 'off',
          targetTemp: (attrs['temperature'] as num?)?.toDouble(),
          currentTemp: (attrs['current_temperature'] as num?)?.toDouble(),
          reachable: reachable,
        );
      case 'lock':
        return DeviceState(locked: state == 'locked', reachable: reachable);
      case 'media_player':
        return DeviceState(on: !const {'off', 'standby', 'unavailable'}.contains(state), reachable: reachable);
      case 'light':
        final rgb = attrs['rgb_color'] as List?;
        final mode = attrs['color_mode'];
        return DeviceState(
          on: state == 'on',
          brightness: attrs['brightness'] is num ? (attrs['brightness'] as num) / 255 : null,
          colorTempK: mode == 'color_temp' && attrs['color_temp_kelvin'] is num
              ? (attrs['color_temp_kelvin'] as num).toInt()
              : null,
          color: mode != 'color_temp' && rgb != null && rgb.length == 3
              ? rgbToInt((rgb[0] as num).toInt(), (rgb[1] as num).toInt(), (rgb[2] as num).toInt())
              : null,
          reachable: reachable,
        );
      default:
        return DeviceState(on: state == 'on', reachable: reachable);
    }
  }

  @override
  Future<List<Device>> discover() async {
    final out = <Device>[];
    for (final e in await _states()) {
      final kind = kindFor(e);
      if (kind == null) continue;
      final attrs = (e['attributes'] as Map?) ?? const {};
      out.add(makeDevice(
        externalId: e['entity_id'] as String,
        name: '${attrs['friendly_name'] ?? e['entity_id']}',
        kind: kind,
        capabilities: capabilitiesFor(e, kind),
        props: {'domain': (e['entity_id'] as String).split('.').first},
        state: parseState(e),
      ));
    }
    return out;
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    try {
      final byId = {for (final e in await _states()) e['entity_id'] as String: e};
      return {
        for (final d in devices)
          d.id: byId[d.externalId] == null
              ? d.state.merge(DeviceState.unreachable)
              : d.state.merge(parseState(byId[d.externalId]!)),
      };
    } catch (_) {
      return {for (final d in devices) d.id: d.state.merge(DeviceState.unreachable)};
    }
  }

  @override
  Future<DeviceState?> refresh(Device device) async {
    final e = await getJson(Uri.parse('$baseUrl/api/states/${device.externalId}'), headers: _headers);
    return parseState(Map<String, dynamic>.from(e as Map));
  }

  Future<void> _call(String domain, String service, Map<String, dynamic> data) =>
      sendJson('POST', Uri.parse('$baseUrl/api/services/$domain/$service'), data, headers: _headers);

  @override
  Future<DeviceState?> send(Device device, DeviceCommand c) async {
    final id = device.externalId;
    final domain = id.split('.').first;
    final target = {'entity_id': id};
    switch (domain) {
      case 'light':
        if (c.on == false) {
          await _call('light', 'turn_off', target);
        } else {
          await _call('light', 'turn_on', {
            ...target,
            if (c.brightness != null) 'brightness_pct': (c.brightness! * 100).round(),
            if (c.colorTempK != null) 'color_temp_kelvin': c.colorTempK,
            if (c.color != null) 'rgb_color': intToRgb(c.color!),
          });
        }
      case 'cover':
        if (c.position != null) {
          await _call('cover', 'set_cover_position', {...target, 'position': (c.position! * 100).round()});
        } else if (c.on != null) {
          await _call('cover', c.on! ? 'open_cover' : 'close_cover', target);
        }
      case 'climate':
        if (c.targetTemp != null) await _call('climate', 'set_temperature', {...target, 'temperature': c.targetTemp});
        if (c.on != null) await _call('climate', c.on! ? 'turn_on' : 'turn_off', target);
      case 'lock':
        if (c.locked != null) await _call('lock', c.locked! ? 'lock' : 'unlock', target);
      default:
        if (c.on != null) await _call(domain, c.on! ? 'turn_on' : 'turn_off', target);
    }
    return null;
  }
}
