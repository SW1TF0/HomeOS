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
  vacuum,
  mower,
  purifier,
  humidifier,
  appliance,
  alarm,
  valve,
  siren,
  garage,
  button,
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
        DeviceKind.vacuum => 'Robot vacuum',
        DeviceKind.mower => 'Lawn mower',
        DeviceKind.purifier => 'Air purifier',
        DeviceKind.humidifier => 'Humidifier',
        DeviceKind.appliance => 'Appliance',
        DeviceKind.alarm => 'Alarm',
        DeviceKind.valve => 'Valve',
        DeviceKind.siren => 'Siren',
        DeviceKind.garage => 'Garage door',
        DeviceKind.button => 'Button',
        DeviceKind.other => 'Other',
      };

  static DeviceKind parse(String? name) => DeviceKind.values
      .firstWhere((k) => k.name == name, orElse: () => DeviceKind.other);
}

/// A thing a device can do. Controls are shown only for capabilities it has.
enum Capability {
  onOff,
  brightness,
  colorTemp,
  color,
  position,
  targetTemp,
  lock,
  readings,
  volume,
  remote,

  /// Start, pause and stop its job: cleaning, mowing, a wash.
  run,

  /// Send a robot back to its base.
  dock,

  /// Make a robot beep so it can be found.
  locate,

  /// Pick one of the modes in `props['modes']`: suction power, a preset, an input...
  mode,

  /// Fan speed.
  speed,

  /// Target humidity.
  humidity,

  /// Arm and disarm, in the ways listed in `props['arms']`.
  alarm,

  /// A button, scene or script that does something when pressed.
  press,

  /// A still picture from a camera.
  snapshot,
}

/// One-off things to ask of a device: run a robot or an appliance, arm an alarm, press a button.
enum DeviceAction {
  start,
  pause,
  stop,
  dock,
  locate,
  press,
  armHome,
  armAway,
  armNight,
  armVacation,
  disarm;

  static DeviceAction? parse(String? name) => DeviceAction.values.where((a) => a.name == name).firstOrNull;

  /// The alarm activity an arm or disarm action leads to.
  String? get alarmState => switch (this) {
        DeviceAction.armHome => Activity.armedHome,
        DeviceAction.armAway => Activity.armedAway,
        DeviceAction.armNight => Activity.armedNight,
        DeviceAction.armVacation => Activity.armedVacation,
        DeviceAction.disarm => Activity.disarmed,
        _ => null,
      };
}

/// What a robot, an appliance or an alarm is doing, as kept in [DeviceState.activity].
abstract final class Activity {
  // Robots and appliances.
  static const running = 'running';
  static const paused = 'paused';
  static const returning = 'returning';
  static const docked = 'docked';
  static const charging = 'charging';
  static const idle = 'idle';
  static const error = 'error';

  // Alarms (the same words as Home Assistant).
  static const disarmed = 'disarmed';
  static const armedHome = 'armed_home';
  static const armedAway = 'armed_away';
  static const armedNight = 'armed_night';
  static const armedVacation = 'armed_vacation';
  static const armedCustom = 'armed_custom_bypass';
  static const arming = 'arming';
  static const pending = 'pending';
  static const disarming = 'disarming';
  static const triggered = 'triggered';

  /// Busy doing its job, or guarding the home.
  static const busy = {
    running, returning, armedHome, armedAway, armedNight, armedVacation, armedCustom, arming, pending, triggered,
  };

  static String? after(DeviceAction? a) => switch (a) {
        DeviceAction.start => running,
        DeviceAction.pause => paused,
        DeviceAction.stop => idle,
        DeviceAction.dock => returning,
        DeviceAction.locate || DeviceAction.press || null => null,
        _ => a.alarmState,
      };
}

/// Buttons of a TV / media remote. Drivers map them to their own key codes.
enum RemoteKey {
  power,
  volumeUp,
  volumeDown,
  mute,
  channelUp,
  channelDown,
  up,
  down,
  left,
  right,
  ok,
  back,
  home,
  menu,
  playPause,
  stop,
  rewind,
  forward,
  source,
}

Set<Capability> defaultCapabilities(DeviceKind kind) => switch (kind) {
      DeviceKind.light => {Capability.onOff, Capability.brightness, Capability.colorTemp, Capability.color},
      DeviceKind.outlet || DeviceKind.toggle || DeviceKind.fan || DeviceKind.valve || DeviceKind.siren => {Capability.onOff},
      DeviceKind.media => {Capability.onOff, Capability.volume, Capability.remote},
      DeviceKind.sensor => {Capability.readings},
      DeviceKind.climate => {Capability.onOff, Capability.targetTemp},
      DeviceKind.cover || DeviceKind.garage => {Capability.position},
      DeviceKind.lock => {Capability.lock},
      DeviceKind.vacuum => {Capability.run, Capability.dock, Capability.locate, Capability.mode},
      DeviceKind.mower => {Capability.run, Capability.dock},
      DeviceKind.purifier => {Capability.onOff, Capability.speed, Capability.mode},
      DeviceKind.humidifier => {Capability.onOff, Capability.humidity},
      DeviceKind.appliance => {Capability.run},
      DeviceKind.alarm => {Capability.alarm},
      DeviceKind.button => {Capability.press},
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
    this.volume,
    this.muted,
    this.key,
    this.action,
    this.mode,
    this.speed,
    this.targetHumidity,
    this.code,
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

  /// 0..1
  final double? volume;
  final bool? muted;

  /// A remote button press. Does not change the stored state by itself.
  final RemoteKey? key;
  final DeviceAction? action;

  /// One of the device's `props['modes']`.
  final String? mode;

  /// 0..1
  final double? speed;

  /// Percent.
  final double? targetHumidity;

  /// An alarm code, sent with arm and disarm. Never saved.
  final String? code;

  /// For sending a command to another device. Includes an alarm code, so it is never saved.
  Map<String, dynamic> toJson() => {
        'on': ?on,
        'brightness': ?brightness,
        'colorTempK': ?colorTempK,
        'color': ?color,
        'position': ?position,
        'targetTemp': ?targetTemp,
        'locked': ?locked,
        'volume': ?volume,
        'muted': ?muted,
        'key': ?key?.name,
        'action': ?action?.name,
        'mode': ?mode,
        'speed': ?speed,
        'targetHumidity': ?targetHumidity,
        'code': ?code,
      };

  factory DeviceCommand.fromJson(Map<String, dynamic> j) {
    double? number(String k) => (j[k] as num?)?.toDouble();
    return DeviceCommand(
      on: j['on'] as bool?,
      brightness: number('brightness'),
      colorTempK: (j['colorTempK'] as num?)?.toInt(),
      color: (j['color'] as num?)?.toInt(),
      position: number('position'),
      targetTemp: number('targetTemp'),
      locked: j['locked'] as bool?,
      volume: number('volume'),
      muted: j['muted'] as bool?,
      key: RemoteKey.values.where((k) => k.name == j['key']).firstOrNull,
      action: DeviceAction.parse(j['action'] as String?),
      mode: j['mode'] as String?,
      speed: number('speed'),
      targetHumidity: number('targetHumidity'),
      code: j['code'] as String?,
    );
  }

  @override
  String toString() =>
      'DeviceCommand(on: $on, brightness: $brightness, ct: $colorTempK, color: $color, position: $position, target: $targetTemp, locked: $locked, volume: $volume, muted: $muted, key: $key, action: ${action?.name}, mode: $mode, speed: $speed, humidity: $targetHumidity${code == null ? '' : ', code: ****'})';
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
    this.volume,
    this.muted,
    this.activity,
    this.battery,
    this.mode,
    this.speed,
    this.targetHumidity,
    this.currentHumidity,
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
  final double? volume;
  final bool? muted;

  /// What a robot, an appliance or an alarm is doing (see [Activity]).
  final String? activity;

  /// 0..1
  final double? battery;
  final String? mode;

  /// 0..1
  final double? speed;

  /// Percent.
  final double? targetHumidity;
  final double? currentHumidity;
  final Map<String, String> readings;
  final bool reachable;

  /// Whether the device counts as "active" for summaries and the map.
  bool get isActive =>
      on == true ||
      (position != null && position! > 0.01 && on == null) ||
      locked == false ||
      Activity.busy.contains(activity);

  DeviceState applyCommand(DeviceCommand c) => DeviceState(
        on: c.on ??
            ((c.brightness ?? c.speed ?? 0) > 0
                ? true
                : (c.key == RemoteKey.power && on != null ? !on! : on)),
        brightness: c.brightness ?? brightness,
        colorTempK: c.colorTempK ?? (c.color != null ? null : colorTempK),
        color: c.color ?? (c.colorTempK != null ? null : color),
        position: c.position ?? position,
        targetTemp: c.targetTemp ?? targetTemp,
        currentTemp: currentTemp,
        locked: c.locked ?? locked,
        volume: c.volume ?? volume,
        muted: c.muted ?? (c.key == RemoteKey.mute && muted != null ? !muted! : muted),
        activity: Activity.after(c.action) ?? activity,
        battery: battery,
        mode: c.mode ?? mode,
        speed: c.speed ?? speed,
        targetHumidity: c.targetHumidity ?? targetHumidity,
        currentHumidity: currentHumidity,
        readings: readings,
        reachable: reachable,
      );

  /// Overlays the known fields of [other] on this state. An empty mode or reading in [other] is a device saying
  /// it has none any more (a fan leaving its preset, a robot's problem fixed), so it is removed.
  DeviceState merge(DeviceState other) => DeviceState(
        on: other.on ?? on,
        brightness: other.brightness ?? brightness,
        colorTempK: other.colorTempK ?? colorTempK,
        color: other.color ?? color,
        position: other.position ?? position,
        targetTemp: other.targetTemp ?? targetTemp,
        currentTemp: other.currentTemp ?? currentTemp,
        locked: other.locked ?? locked,
        volume: other.volume ?? volume,
        muted: other.muted ?? muted,
        activity: other.activity ?? activity,
        battery: other.battery ?? battery,
        mode: other.mode == null ? mode : (other.mode!.isEmpty ? null : other.mode),
        speed: other.speed ?? speed,
        targetHumidity: other.targetHumidity ?? targetHumidity,
        currentHumidity: other.currentHumidity ?? currentHumidity,
        readings: other.readings.isEmpty
            ? readings
            : ({...readings, ...other.readings}..removeWhere((_, value) => value.isEmpty)),
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
        if (volume != null) 'volume': volume,
        if (muted != null) 'muted': muted,
        if (activity != null) 'activity': activity,
        if (battery != null) 'battery': battery,
        if (mode != null) 'mode': mode,
        if (speed != null) 'speed': speed,
        if (targetHumidity != null) 'targetHumidity': targetHumidity,
        if (currentHumidity != null) 'currentHumidity': currentHumidity,
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
        volume: (j['volume'] as num?)?.toDouble(),
        muted: j['muted'] as bool?,
        activity: j['activity'] as String?,
        battery: (j['battery'] as num?)?.toDouble(),
        mode: j['mode'] as String?,
        speed: (j['speed'] as num?)?.toDouble(),
        targetHumidity: (j['targetHumidity'] as num?)?.toDouble(),
        currentHumidity: (j['currentHumidity'] as num?)?.toDouble(),
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

  /// Counts towards "3 on" summaries. Locks and alarms are about safety, not power.
  bool get countsAsOn => state.isActive && kind != DeviceKind.lock && kind != DeviceKind.alarm;

  /// The choices of [Capability.mode] (suction powers, presets, inputs...).
  List<String> get modes => [for (final m in (props['modes'] as List? ?? const [])) '$m'];

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
