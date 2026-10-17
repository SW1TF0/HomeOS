import 'dart:typed_data';

import '../models/device.dart';
import '../util/color_math.dart';
import 'integration.dart';

/// A Home Assistant server (free, self-hosted). Brings in every light, switch,
/// cover, climate, lock, fan, media player, robot vacuum, mower, alarm,
/// valve, camera, scene and useful sensor it knows about, which covers
/// thousands of brands, Matter, Zigbee and Z-Wave included.
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
    'temperature', 'humidity', 'motion', 'occupancy', 'presence', 'door', 'window', 'opening', 'garage_door',
    'power', 'energy', 'battery', 'illuminance', 'moisture', 'smoke', 'gas', 'carbon_monoxide', 'carbon_dioxide',
    'co2', 'pm25', 'pm10', 'pm1', 'volatile_organic_compounds', 'aqi', 'pressure', 'atmospheric_pressure',
    'vibration', 'sound',
  };

  /// Words in the name of a fan that is really an air purifier.
  static const _purifierWords = ['purif', 'air clean', 'luftrein', 'пречиств', 'очист', 'depurat', 'oczyszcz'];

  Future<List<Map<String, dynamic>>> _states() async {
    if (baseUrl.isEmpty || config.setting('token').isEmpty) {
      throw IntegrationException('Enter the server address and a long-lived access token (Profile > Security in Home Assistant).');
    }
    final res = await getJson(Uri.parse('$baseUrl/api/states'), headers: _headers);
    return (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static String _domain(Map<String, dynamic> entity) => (entity['entity_id'] as String).split('.').first;

  static Map _attrs(Map<String, dynamic> entity) => (entity['attributes'] as Map?) ?? const {};

  static int _features(Map attrs) => (attrs['supported_features'] as num?)?.toInt() ?? 0;

  static List<String> _list(Object? v) => [for (final x in (v as List? ?? const [])) '$x'];

  static DeviceKind? kindFor(Map<String, dynamic> entity) {
    final id = entity['entity_id'] as String;
    final attrs = _attrs(entity);
    return switch (_domain(entity)) {
      'light' => DeviceKind.light,
      'switch' => attrs['device_class'] == 'outlet' ? DeviceKind.outlet : DeviceKind.toggle,
      'input_boolean' => DeviceKind.toggle,
      'fan' => _purifierWords.any('$id ${attrs['friendly_name'] ?? ''}'.toLowerCase().contains)
          ? DeviceKind.purifier
          : DeviceKind.fan,
      'cover' => const {'garage', 'gate'}.contains(attrs['device_class']) ? DeviceKind.garage : DeviceKind.cover,
      'climate' || 'water_heater' => DeviceKind.climate,
      'humidifier' => DeviceKind.humidifier,
      'lock' => DeviceKind.lock,
      'media_player' => DeviceKind.media,
      'camera' => DeviceKind.camera,
      'vacuum' => DeviceKind.vacuum,
      'lawn_mower' => DeviceKind.mower,
      'alarm_control_panel' => DeviceKind.alarm,
      'valve' => DeviceKind.valve,
      'siren' => DeviceKind.siren,
      // Device "button" entities are left out: most restart or reset something.
      'scene' || 'script' || 'input_button' => DeviceKind.button,
      'sensor' || 'binary_sensor' => _sensorClasses.contains(attrs['device_class']) ? DeviceKind.sensor : null,
      _ => null,
    };
  }

  static Set<Capability> capabilitiesFor(Map<String, dynamic> entity, DeviceKind kind) {
    final attrs = _attrs(entity);
    final f = _features(attrs);
    switch (_domain(entity)) {
      case 'light':
        final modes = _list(attrs['supported_color_modes']).toSet();
        return {
          Capability.onOff,
          if (modes.any((m) => m != 'onoff')) Capability.brightness,
          if (modes.contains('color_temp')) Capability.colorTemp,
          if (modes.any((m) => const {'hs', 'xy', 'rgb', 'rgbw', 'rgbww'}.contains(m))) Capability.color,
        };
      case 'cover':
        return {Capability.position, if (f & 4 == 0) Capability.onOff};
      case 'fan':
        return {
          Capability.onOff,
          if (f & 1 != 0) Capability.speed,
          if (f & 8 != 0 && _list(attrs['preset_modes']).isNotEmpty) Capability.mode,
        };
      case 'humidifier':
        return {Capability.onOff, Capability.humidity, if (_list(attrs['available_modes']).isNotEmpty) Capability.mode};
      case 'climate':
        return {Capability.onOff, Capability.targetTemp, if (_climateModes(attrs).length > 1) Capability.mode};
      case 'water_heater':
        return {
          if (f & 8 != 0) Capability.onOff,
          Capability.targetTemp,
          if (f & 2 != 0 && _list(attrs['operation_list']).isNotEmpty) Capability.mode,
        };
      case 'vacuum':
        return {
          Capability.run,
          if (f & 16 != 0) Capability.dock,
          if (f & 512 != 0) Capability.locate,
          if (f & 32 != 0 && _list(attrs['fan_speed_list']).isNotEmpty) Capability.mode,
        };
      case 'lawn_mower':
        return {Capability.run, if (f & 4 != 0) Capability.dock};
      case 'media_player':
        return {
          if (f & (128 | 256) != 0) Capability.onOff,
          if (f & 4 != 0) Capability.volume,
          if (_mediaKeys(f).isNotEmpty) Capability.remote,
          if (f & 2048 != 0 && _list(attrs['source_list']).isNotEmpty) Capability.mode,
        };
      case 'alarm_control_panel':
        return {Capability.alarm};
      case 'valve' || 'siren':
        return {Capability.onOff};
      case 'camera':
        return {Capability.snapshot};
      case 'scene' || 'script' || 'input_button':
        return {Capability.press};
    }
    return defaultCapabilities(kind);
  }

  static List<String> _climateModes(Map attrs) => _list(attrs['hvac_modes']).where((m) => m != 'off').toList();

  /// Remote keys a media player has, by its supported features.
  static List<String> _mediaKeys(int f) => [
        if (f & (4 | 1024) != 0) ...['volumeUp', 'volumeDown'],
        if (f & 8 != 0) 'mute',
        if (f & (1 | 16384) != 0) 'playPause',
        if (f & 4096 != 0) 'stop',
        if (f & 16 != 0) 'rewind',
        if (f & 32 != 0) 'forward',
      ];

  /// What the app needs to know besides the state: modes to pick from, how an alarm is armed...
  static Map<String, dynamic> propsFor(Map<String, dynamic> entity) {
    final domain = _domain(entity);
    final attrs = _attrs(entity);
    final f = _features(attrs);
    final arms = [
      if (f & 1 != 0) 'home',
      if (f & 2 != 0) 'away',
      if (f & 4 != 0) 'night',
      if (f & 32 != 0) 'vacation',
    ];
    final modes = switch (domain) {
      'fan' => _list(attrs['preset_modes']),
      'humidifier' => _list(attrs['available_modes']),
      'climate' => _climateModes(attrs),
      'water_heater' => _list(attrs['operation_list']).where((m) => m != 'off').toList(),
      'vacuum' => _list(attrs['fan_speed_list']),
      'media_player' => _list(attrs['source_list']),
      _ => const <String>[],
    };
    return {
      'domain': domain,
      if (modes.isNotEmpty) 'modes': modes,
      if (domain == 'humidifier') ...{
        'minHumidity': (attrs['min_humidity'] as num?)?.toDouble() ?? 30,
        'maxHumidity': (attrs['max_humidity'] as num?)?.toDouble() ?? 80,
      },
      if (domain == 'vacuum' && f & 8 == 0) 'noStop': true,
      if (domain == 'media_player') 'keys': _mediaKeys(f),
      if (domain == 'alarm_control_panel') ...{
        if (arms.isNotEmpty) 'arms': arms,
        'codeFormat': ?attrs['code_format'] as String?,
        'codeArmRequired': attrs['code_arm_required'] as bool? ?? true,
      },
    };
  }

  static DeviceState parseState(Map<String, dynamic> entity) {
    final id = entity['entity_id'] as String;
    final domain = id.split('.').first;
    final state = '${entity['state']}';
    final attrs = Map<String, dynamic>.from(_attrs(entity));
    final reachable = state != 'unavailable';
    switch (domain) {
      case 'sensor' || 'binary_sensor':
        final label = '${attrs['friendly_name'] ?? id}';
        final unit = attrs['unit_of_measurement'];
        final value = domain == 'binary_sensor' ? (state == 'on' ? 'Detected' : 'Clear') : state;
        return DeviceState(readings: {label: unit == null ? value : '$value $unit'}, reachable: reachable);
      case 'cover':
        final pos = attrs['current_position'] as num?;
        final open = state == 'open' || state == 'opening';
        return DeviceState(position: pos != null ? pos / 100 : (open ? 1 : 0), on: open, reachable: reachable);
      case 'climate':
        return DeviceState(
          on: state != 'off',
          targetTemp: (attrs['temperature'] as num?)?.toDouble(),
          currentTemp: (attrs['current_temperature'] as num?)?.toDouble(),
          mode: state == 'off' || !reachable ? null : state,
          reachable: reachable,
        );
      case 'water_heater':
        return DeviceState(
          on: state != 'off',
          targetTemp: (attrs['temperature'] as num?)?.toDouble(),
          currentTemp: (attrs['current_temperature'] as num?)?.toDouble(),
          mode: state == 'off' || !reachable ? null : (attrs['operation_mode'] as String? ?? state),
          reachable: reachable,
        );
      case 'humidifier':
        return DeviceState(
          on: state == 'on',
          targetHumidity: (attrs['humidity'] as num?)?.toDouble(),
          currentHumidity: (attrs['current_humidity'] as num?)?.toDouble(),
          mode: attrs['mode'] as String?,
          reachable: reachable,
        );
      case 'fan':
        final pct = attrs['percentage'] as num?;
        return DeviceState(
          on: state == 'on',
          speed: state == 'on' && pct != null && pct > 0 ? pct / 100 : null,
          mode: attrs['preset_mode'] as String? ?? '',
          reachable: reachable,
        );
      case 'lock':
        return DeviceState(locked: state == 'locked', reachable: reachable);
      case 'media_player':
        final title = attrs['media_title'] as String?;
        final artist = attrs['media_artist'] as String?;
        final on = !const {'off', 'standby', 'unavailable'}.contains(state);
        return DeviceState(
          on: on,
          volume: (attrs['volume_level'] as num?)?.toDouble(),
          muted: attrs['is_volume_muted'] as bool?,
          mode: attrs['source'] as String?,
          readings: {'Playing': !on || title == null ? 'Nothing' : (artist == null ? title : '$artist - $title')},
          reachable: reachable,
        );
      case 'vacuum':
        final activity = switch (state) {
          'cleaning' => Activity.running,
          'paused' => Activity.paused,
          'returning' => Activity.returning,
          'docked' => Activity.docked,
          'idle' => Activity.idle,
          'error' => Activity.error,
          _ => null,
        };
        final battery = attrs['battery_level'] as num?;
        final status = attrs['status'];
        return DeviceState(
          activity: activity,
          battery: battery == null ? null : battery.clamp(0, 100) / 100,
          mode: attrs['fan_speed'] as String?,
          readings: {'Error': activity == Activity.error && status is String ? status : ''},
          reachable: reachable,
        );
      case 'lawn_mower':
        return DeviceState(
          activity: switch (state) {
            'mowing' => Activity.running,
            'paused' => Activity.paused,
            'returning' => Activity.returning,
            'docked' => Activity.docked,
            'error' => Activity.error,
            _ => null,
          },
          reachable: reachable,
        );
      case 'alarm_control_panel':
        return DeviceState(activity: reachable && state != 'unknown' ? state : null, reachable: reachable);
      case 'valve':
        return DeviceState(on: state == 'open' || state == 'opening', reachable: reachable);
      case 'scene' || 'script' || 'input_button' || 'camera':
        return DeviceState(reachable: reachable);
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

  /// The battery sensor of a robot (`sensor.<robot>_battery`): Home Assistant
  /// no longer puts the battery in the robot's own state.
  static Map<String, dynamic>? _batterySensorOf(String robotId, Iterable<Map<String, dynamic>> all) {
    final object = robotId.split('.').last;
    for (final e in all) {
      if ((e['entity_id'] as String).startsWith('sensor.$object') && _attrs(e)['device_class'] == 'battery') return e;
    }
    return null;
  }

  static DeviceState _withBattery(String id, DeviceState s, Iterable<Map<String, dynamic>> all) {
    if (s.battery != null || !(id.startsWith('vacuum.') || id.startsWith('lawn_mower.'))) return s;
    final level = double.tryParse('${_batterySensorOf(id, all)?['state']}');
    return level == null ? s : s.merge(DeviceState(battery: level.clamp(0, 100) / 100, reachable: s.reachable));
  }

  @override
  Future<List<Device>> discover() async {
    final all = await _states();
    // A robot's battery shows on the robot, not as a sensor of its own.
    final robotBatteries = {
      for (final e in all)
        if (const {'vacuum', 'lawn_mower'}.contains(_domain(e))) _batterySensorOf(e['entity_id'] as String, all)?['entity_id'],
    };
    final out = <Device>[];
    for (final e in all) {
      final kind = kindFor(e);
      final id = e['entity_id'] as String;
      if (kind == null || robotBatteries.contains(id)) continue;
      out.add(makeDevice(
        externalId: id,
        name: '${_attrs(e)['friendly_name'] ?? id}',
        kind: kind,
        capabilities: capabilitiesFor(e, kind),
        props: propsFor(e),
        state: _withBattery(id, parseState(e), all),
      ));
    }
    return out;
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    try {
      final all = await _states();
      final byId = {for (final e in all) e['entity_id'] as String: e};
      return {
        for (final d in devices)
          d.id: byId[d.externalId] == null
              ? d.state.merge(DeviceState.unreachable)
              : d.state.merge(_withBattery(d.externalId, parseState(byId[d.externalId]!), all)),
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

  @override
  Future<Uint8List?> snapshot(Device device) async {
    if (device.props['snapshotUrl'] != null) return super.snapshot(device);
    if (!device.externalId.startsWith('camera.')) return null;
    return getImage(Uri.parse('$baseUrl/api/camera_proxy/${device.externalId}'), headers: _headers);
  }

  /// Home Assistant turns every camera into moving pictures (MJPEG) that play on any device.
  @override
  CameraStream? liveStream(Device device) =>
      super.liveStream(device) ??
      (device.externalId.startsWith('camera.')
          ? CameraStream(mjpeg: Uri.parse('$baseUrl/api/camera_proxy_stream/${device.externalId}'), headers: _headers)
          : null);

  Future<void> _call(String domain, String service, Map<String, dynamic> data) =>
      sendJson('POST', Uri.parse('$baseUrl/api/services/$domain/$service'), data, headers: _headers);

  @override
  Future<DeviceState?> send(Device device, DeviceCommand c) async {
    final id = device.externalId;
    final domain = id.split('.').first;
    final target = {'entity_id': id};
    final action = c.action;
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
        // Switch on first: turning on picks a mode by itself, which the chosen mode then replaces.
        if (c.on == true) await _call('climate', 'turn_on', target);
        if (c.mode != null) await _call('climate', 'set_hvac_mode', {...target, 'hvac_mode': c.mode});
        if (c.targetTemp != null) await _call('climate', 'set_temperature', {...target, 'temperature': c.targetTemp});
        if (c.on == false) await _call('climate', 'turn_off', target);
      case 'water_heater':
        if (c.on == true) await _call('water_heater', 'turn_on', target);
        if (c.mode != null) await _call('water_heater', 'set_operation_mode', {...target, 'operation_mode': c.mode});
        if (c.targetTemp != null) await _call('water_heater', 'set_temperature', {...target, 'temperature': c.targetTemp});
        if (c.on == false) await _call('water_heater', 'turn_off', target);
      case 'humidifier':
        if (c.on == true) await _call('humidifier', 'turn_on', target);
        if (c.mode != null) await _call('humidifier', 'set_mode', {...target, 'mode': c.mode});
        if (c.targetHumidity != null) {
          await _call('humidifier', 'set_humidity', {...target, 'humidity': c.targetHumidity!.round()});
        }
        if (c.on == false) await _call('humidifier', 'turn_off', target);
      case 'fan':
        if (c.on == false) {
          await _call('fan', 'turn_off', target);
        } else {
          if (c.speed != null) {
            await _call('fan', 'set_percentage', {...target, 'percentage': (c.speed! * 100).round().clamp(1, 100)});
          }
          if (c.mode != null) await _call('fan', 'set_preset_mode', {...target, 'preset_mode': c.mode});
          if (c.on == true && c.speed == null && c.mode == null) await _call('fan', 'turn_on', target);
        }
      case 'lock':
        if (c.locked != null) await _call('lock', c.locked! ? 'lock' : 'unlock', target);
      case 'media_player':
        if (c.on != null) await _call('media_player', c.on! ? 'turn_on' : 'turn_off', target);
        if (c.volume != null) await _call('media_player', 'volume_set', {...target, 'volume_level': c.volume});
        if (c.muted != null) await _call('media_player', 'volume_mute', {...target, 'is_volume_muted': c.muted});
        if (c.mode != null) await _call('media_player', 'select_source', {...target, 'source': c.mode});
        if (c.key == RemoteKey.mute) {
          // The screen has already flipped it, so this is the wanted state.
          await _call('media_player', 'volume_mute', {...target, 'is_volume_muted': device.state.muted ?? true});
        } else if (c.key != null) {
          final service = switch (c.key!) {
            RemoteKey.power => 'toggle',
            RemoteKey.volumeUp => 'volume_up',
            RemoteKey.volumeDown => 'volume_down',
            RemoteKey.playPause => 'media_play_pause',
            RemoteKey.stop => 'media_stop',
            RemoteKey.rewind => 'media_previous_track',
            RemoteKey.forward => 'media_next_track',
            _ => null,
          };
          if (service != null) await _call('media_player', service, target);
        }
      case 'vacuum':
        final service = switch (action) {
          DeviceAction.start => 'start',
          DeviceAction.pause => 'pause',
          DeviceAction.stop => 'stop',
          DeviceAction.dock => 'return_to_base',
          DeviceAction.locate => 'locate',
          _ => null,
        };
        if (c.mode != null) await _call('vacuum', 'set_fan_speed', {...target, 'fan_speed': c.mode});
        if (service != null) await _call('vacuum', service, target);
      case 'lawn_mower':
        final service = switch (action) {
          DeviceAction.start => 'start_mowing',
          DeviceAction.pause => 'pause',
          DeviceAction.dock => 'dock',
          _ => null,
        };
        if (service != null) await _call('lawn_mower', service, target);
      case 'alarm_control_panel':
        final service = switch (action) {
          DeviceAction.armHome => 'alarm_arm_home',
          DeviceAction.armAway => 'alarm_arm_away',
          DeviceAction.armNight => 'alarm_arm_night',
          DeviceAction.armVacation => 'alarm_arm_vacation',
          DeviceAction.disarm => 'alarm_disarm',
          _ => null,
        };
        if (service != null) await _call('alarm_control_panel', service, {...target, 'code': ?c.code});
      case 'valve':
        if (c.on != null) await _call('valve', c.on! ? 'open_valve' : 'close_valve', target);
      case 'scene' || 'script':
        if (action == DeviceAction.press) await _call(domain, 'turn_on', target);
      case 'input_button':
        if (action == DeviceAction.press) await _call('input_button', 'press', target);
      default:
        if (c.on != null) await _call(domain, c.on! ? 'turn_on' : 'turn_off', target);
    }
    return null;
  }
}
