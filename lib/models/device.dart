import 'dart:ui' show Offset;

/// What a device is, used for its icon and which controls it shows.
enum DeviceKind {
  light,
  outlet,
  toggle,
  sensor,
  climate,
  cover,
  fan,
  lock,
  media,
  camera,
  other;

  String get label => switch (this) {
        DeviceKind.light => 'Light',
        DeviceKind.outlet => 'Plug',
        DeviceKind.toggle => 'Switch',
        DeviceKind.sensor => 'Sensor',
        DeviceKind.climate => 'Climate',
        DeviceKind.cover => 'Blind',
        DeviceKind.fan => 'Fan',
        DeviceKind.lock => 'Lock',
        DeviceKind.media => 'Media',
        DeviceKind.camera => 'Camera',
        DeviceKind.other => 'Other',
      };

  static DeviceKind parse(String? name) => DeviceKind.values
      .firstWhere((k) => k.name == name, orElse: () => DeviceKind.other);
}

/// A thing a device can do. Controls are shown only for capabilities it has.
enum Capability { onOff, brightness, colorTemp, color, position, targetTemp, lock, readings }

Set<Capability> defaultCapabilities(DeviceKind kind) => switch (kind) {
      DeviceKind.light => {Capability.onOff, Capability.brightness, Capability.colorTemp, Capability.color},
      DeviceKind.outlet || DeviceKind.toggle || DeviceKind.fan || DeviceKind.media => {Capability.onOff},
      DeviceKind.sensor => {Capability.readings},
      DeviceKind.climate => {Capability.onOff, Capability.targetTemp},
      DeviceKind.cover => {Capability.position},
      DeviceKind.lock => {Capability.lock},
      DeviceKind.camera || DeviceKind.other => {},
    };

/// A requested change. Null fields are left as they are.
class DeviceCommand {
  const DeviceCommand({
    this.on,
    this.brightness,
    this.colorTempK,
    this.color,
    this.position,
    this.targetTemp,
    this.locked,
  });

  final bool? on;

  /// 0..1
  final double? brightness;
  final int? colorTempK;

  /// 0xRRGGBB
  final int? color;

  /// 0 (closed) .. 1 (open)
  final double? position;
  final double? targetTemp;
  final bool? locked;

  @override
  String toString() =>
      'DeviceCommand(on: $on, brightness: $brightness, ct: $colorTempK, color: $color, position: $position, target: $targetTemp, locked: $locked)';
}

/// The last known state of a device.
class DeviceState {
  const DeviceState({
    this.on,
    this.brightness,
    this.colorTempK,
    this.color,
    this.position,
    this.targetTemp,
    this.currentTemp,
    this.locked,
    this.readings = const {},
    this.reachable = true,
  });

  static const unreachable = DeviceState(reachable: false);

  final bool? on;
  final double? brightness;
  final int? colorTempK;
  final int? color;
  final double? position;
  final double? targetTemp;
  final double? currentTemp;
  final bool? locked;
  final Map<String, String> readings;
  final bool reachable;

  /// Whether the device counts as "active" for summaries and the map.
  bool get isActive =>
      on == true || (position != null && position! > 0.01 && on == null) || locked == false;

  DeviceState applyCommand(DeviceCommand c) => DeviceState(
        on: c.on ?? (c.brightness != null && c.brightness! > 0 ? true : on),
        brightness: c.brightness ?? brightness,
        colorTempK: c.colorTempK ?? (c.color != null ? null : colorTempK),
        color: c.color ?? (c.colorTempK != null ? null : color),
        position: c.position ?? position,
        targetTemp: c.targetTemp ?? targetTemp,
        currentTemp: currentTemp,
        locked: c.locked ?? locked,
        readings: readings,
        reachable: reachable,
      );

  /// Overlays the known fields of [other] on this state.
  DeviceState merge(DeviceState other) => DeviceState(
        on: other.on ?? on,
        brightness: other.brightness ?? brightness,
        colorTempK: other.colorTempK ?? colorTempK,
        color: other.color ?? color,
        position: other.position ?? position,
        targetTemp: other.targetTemp ?? targetTemp,
        currentTemp: other.currentTemp ?? currentTemp,
        locked: other.locked ?? locked,
        readings: other.readings.isEmpty ? readings : {...readings, ...other.readings},
        reachable: other.reachable,
      );

  Map<String, dynamic> toJson() => {
        if (on != null) 'on': on,
        if (brightness != null) 'brightness': brightness,
        if (colorTempK != null) 'colorTempK': colorTempK,
        if (color != null) 'color': color,
        if (position != null) 'position': position,
        if (targetTemp != null) 'targetTemp': targetTemp,
        if (currentTemp != null) 'currentTemp': currentTemp,
        if (locked != null) 'locked': locked,
        if (readings.isNotEmpty) 'readings': readings,
        'reachable': reachable,
      };

  factory DeviceState.fromJson(Map<String, dynamic> j) => DeviceState(
        on: j['on'] as bool?,
        brightness: (j['brightness'] as num?)?.toDouble(),
        colorTempK: (j['colorTempK'] as num?)?.toInt(),
        color: (j['color'] as num?)?.toInt(),
        position: (j['position'] as num?)?.toDouble(),
        targetTemp: (j['targetTemp'] as num?)?.toDouble(),
        currentTemp: (j['currentTemp'] as num?)?.toDouble(),
        locked: j['locked'] as bool?,
        readings: (j['readings'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
        reachable: j['reachable'] as bool? ?? true,
      );
}

class Device {
  Device({
    required this.id,
    required this.name,
    required this.kind,
    required this.integrationId,
    required this.externalId,
    Set<Capability>? capabilities,
    Map<String, dynamic>? props,
    this.roomId,
    this.floorId,
    this.mapPos,
    this.favorite = false,
    this.state = const DeviceState(),
  })  : capabilities = capabilities ?? defaultCapabilities(kind),
        props = props ?? {};

  /// Stable id built from the integration and the device's id inside it, so
  /// re-syncing an integration updates devices instead of duplicating them.
  static String idFor(String integrationId, String externalId) => '$integrationId::$externalId';

  final String id;
  String name;
  DeviceKind kind;
  final String integrationId;

  /// The device's address inside its integration (a Hue light id, an entity id, a host...).
  final String externalId;
  Set<Capability> capabilities;

  /// Integration-specific details (host, channel, topics...).
  Map<String, dynamic> props;
  String? roomId;
  String? floorId;

  /// Position on its floor's map, in map units. Null when not placed yet.
  Offset? mapPos;
  bool favorite;
  DeviceState state;

  bool has(Capability c) => capabilities.contains(c);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'integrationId': integrationId,
        'externalId': externalId,
        'capabilities': capabilities.map((c) => c.name).toList(),
        'props': props,
        if (roomId != null) 'roomId': roomId,
        if (floorId != null) 'floorId': floorId,
        if (mapPos != null) 'mapPos': [mapPos!.dx, mapPos!.dy],
        'favorite': favorite,
        'state': state.toJson(),
      };

  factory Device.fromJson(Map<String, dynamic> j) {
    final pos = j['mapPos'] as List?;
    final kind = DeviceKind.parse(j['kind'] as String?);
    return Device(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Device',
      kind: kind,
      integrationId: j['integrationId'] as String,
      externalId: j['externalId'] as String,
      capabilities: (j['capabilities'] as List?)
          ?.map((n) => Capability.values.where((c) => c.name == n))
          .expand((e) => e)
          .toSet(),
      props: Map<String, dynamic>.from(j['props'] as Map? ?? const {}),
      roomId: j['roomId'] as String?,
      floorId: j['floorId'] as String?,
      mapPos: pos == null ? null : Offset((pos[0] as num).toDouble(), (pos[1] as num).toDouble()),
      favorite: j['favorite'] as bool? ?? false,
      state: DeviceState.fromJson(Map<String, dynamic>.from(j['state'] as Map? ?? const {})),
    );
  }
}
