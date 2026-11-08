import 'dart:ui' show Offset, Rect;

import 'automation.dart';
import 'device.dart';
import 'scene.dart';

class Floor {
  Floor({required this.id, required this.name});

  final String id;
  String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Floor.fromJson(Map<String, dynamic> j) =>
      Floor(id: j['id'] as String, name: j['name'] as String? ?? 'Floor');
}

/// A room drawn on a floor plan. Coordinates are map units (one grid cell).
class Room {
  Room({
    required this.id,
    required this.floorId,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final String id;
  String floorId;
  String name;
  double x;
  double y;
  double width;
  double height;

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  bool contains(Offset p) => rect.contains(p);

  Map<String, dynamic> toJson() => {
        'id': id,
        'floorId': floorId,
        'name': name,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  factory Room.fromJson(Map<String, dynamic> j) => Room(
        id: j['id'] as String,
        floorId: j['floorId'] as String,
        name: j['name'] as String? ?? 'Room',
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
      );
}

/// One configured connection: a Hue bridge, a Home Assistant server, an MQTT broker...
class IntegrationConfig {
  IntegrationConfig({
    required this.id,
    required this.type,
    required this.name,
    Map<String, dynamic>? settings,
    this.enabled = true,
  }) : settings = settings ?? {};

  final String id;
  final String type;
  String name;
  Map<String, dynamic> settings;
  bool enabled;

  String setting(String key, [String fallback = '']) {
    final v = settings[key];
    return v == null || '$v'.trim().isEmpty ? fallback : '$v'.trim();
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'type': type, 'name': name, 'settings': settings, 'enabled': enabled};

  factory IntegrationConfig.fromJson(Map<String, dynamic> j) => IntegrationConfig(
        id: j['id'] as String,
        type: j['type'] as String,
        name: j['name'] as String? ?? j['type'] as String,
        settings: Map<String, dynamic>.from(j['settings'] as Map? ?? const {}),
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// Where a home is: a town picked from a search, for its weather and its sunrise and sunset.
class HomePlace {
  const HomePlace({required this.name, required this.lat, required this.lon, this.region = ''});

  final String name;

  /// The region and country, to tell two towns of the same name apart.
  final String region;
  final double lat;
  final double lon;

  Map<String, dynamic> toJson() => {'name': name, 'region': region, 'lat': lat, 'lon': lon};

  static HomePlace? fromJson(Object? j) {
    if (j is! Map || j['lat'] is! num || j['lon'] is! num) return null;
    return HomePlace(
      name: j['name'] as String? ?? '',
      region: j['region'] as String? ?? '',
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
    );
  }
}

/// "Turn the heater off in 30 minutes": what one device does, and when.
class DeviceTimer {
  const DeviceTimer({required this.deviceId, required this.at, this.on = false});

  final String deviceId;
  final DateTime at;

  /// Whether it turns the device on, rather than off.
  final bool on;

  /// Names this run, so it is not done twice (by the app and by an Android alarm).
  String get slot => 'timer:$deviceId:${at.millisecondsSinceEpoch}';

  Map<String, dynamic> toJson() => {'deviceId': deviceId, 'at': at.millisecondsSinceEpoch, 'on': on};

  static DeviceTimer? fromJson(Map<String, dynamic> j) {
    final id = j['deviceId'];
    final at = j['at'];
    if (id is! String || at is! num) return null;
    return DeviceTimer(deviceId: id, at: DateTime.fromMillisecondsSinceEpoch(at.toInt()), on: j['on'] as bool? ?? false);
  }
}

/// Everything the app stores. Saved locally as JSON; nothing leaves the device.
class HomeData {
  HomeData({
    List<Floor>? floors,
    List<Room>? rooms,
    List<Device>? devices,
    List<IntegrationConfig>? integrations,
    List<Scene>? scenes,
    List<Automation>? automations,
    List<DeviceTimer>? timers,
    this.themeMode = 'light',
    this.place,
  })  : scenes = scenes ?? [],
        timers = timers ?? [],
        automations = automations ?? [],
        floors = floors ?? [],
        rooms = rooms ?? [],
        devices = devices ?? [],
        integrations = integrations ?? [];

  static const schemaVersion = 1;

  final List<Floor> floors;
  final List<Room> rooms;
  final List<Device> devices;
  final List<IntegrationConfig> integrations;
  final List<Scene> scenes;
  final List<Automation> automations;
  final List<DeviceTimer> timers;
  String themeMode;

  /// Where the home is, once a town is picked.
  HomePlace? place;

  Map<String, dynamic> toJson() => {
        'app': 'SmartHomeKJ',
        'version': schemaVersion,
        'themeMode': themeMode,
        'floors': floors.map((e) => e.toJson()).toList(),
        'rooms': rooms.map((e) => e.toJson()).toList(),
        'devices': devices.map((e) => e.toJson()).toList(),
        'integrations': integrations.map((e) => e.toJson()).toList(),
        'scenes': scenes.map((e) => e.toJson()).toList(),
        if (automations.isNotEmpty) 'automations': automations.map((e) => e.toJson()).toList(),
        if (timers.isNotEmpty) 'timers': timers.map((e) => e.toJson()).toList(),
        'place': ?place?.toJson(),
      };

  factory HomeData.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> list(String k) =>
        ((j[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return HomeData(
      themeMode: j['themeMode'] as String? ?? 'light',
      floors: list('floors').map(Floor.fromJson).toList(),
      rooms: list('rooms').map(Room.fromJson).toList(),
      devices: list('devices').map(Device.fromJson).toList(),
      integrations: list('integrations').map(IntegrationConfig.fromJson).toList(),
      scenes: list('scenes').map(Scene.fromJson).toList(),
      automations: list('automations').map(Automation.fromJson).nonNulls.toList(),
      timers: list('timers').map(DeviceTimer.fromJson).nonNulls.toList(),
      place: HomePlace.fromJson(j['place']),
    );
  }
}
