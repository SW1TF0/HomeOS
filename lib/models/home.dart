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

/// Everything the app stores. Saved locally as JSON; nothing leaves the device.
class HomeData {
  HomeData({
    List<Floor>? floors,
    List<Room>? rooms,
    List<Device>? devices,
    List<IntegrationConfig>? integrations,
    List<Scene>? scenes,
    List<Automation>? automations,
    this.themeMode = 'dark',
  })  : scenes = scenes ?? [],
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
  String themeMode;

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
      };

  factory HomeData.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> list(String k) =>
        ((j[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return HomeData(
      themeMode: j['themeMode'] as String? ?? 'dark',
      floors: list('floors').map(Floor.fromJson).toList(),
      rooms: list('rooms').map(Room.fromJson).toList(),
      devices: list('devices').map(Device.fromJson).toList(),
      integrations: list('integrations').map(IntegrationConfig.fromJson).toList(),
      scenes: list('scenes').map(Scene.fromJson).toList(),
      automations: list('automations').map(Automation.fromJson).nonNulls.toList(),
    );
  }
}
