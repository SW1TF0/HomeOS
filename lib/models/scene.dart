import 'device.dart';

/// One device's part in a scene: the state to put it in.
class SceneAction {
  SceneAction({required this.deviceId, required this.command});

  final String deviceId;
  final DeviceCommand command;

  /// The command that recreates what [d] is doing now, limited to what it can do.
  static SceneAction capture(Device d) {
    final s = d.state;
    final on = d.has(Capability.onOff) ? s.on : null;
    final lit = on != false;
    return SceneAction(
      deviceId: d.id,
      command: DeviceCommand(
        on: on,
        brightness: d.has(Capability.brightness) && lit ? s.brightness : null,
        colorTempK: d.has(Capability.colorTemp) && lit && s.color == null ? s.colorTempK : null,
        color: d.has(Capability.color) && lit ? s.color : null,
        position: d.has(Capability.position) ? s.position : null,
        targetTemp: d.has(Capability.targetTemp) && lit ? s.targetTemp : null,
        locked: d.has(Capability.lock) ? s.locked : null,
        volume: d.has(Capability.volume) && lit ? s.volume : null,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    final c = command;
    return {
      'deviceId': deviceId,
      'on': ?c.on,
      'brightness': ?c.brightness,
      'colorTempK': ?c.colorTempK,
      'color': ?c.color,
      'position': ?c.position,
      'targetTemp': ?c.targetTemp,
      'locked': ?c.locked,
      'volume': ?c.volume,
    };
  }

  factory SceneAction.fromJson(Map<String, dynamic> j) => SceneAction(
        deviceId: j['deviceId'] as String,
        command: DeviceCommand(
          on: j['on'] as bool?,
          brightness: (j['brightness'] as num?)?.toDouble(),
          colorTempK: (j['colorTempK'] as num?)?.toInt(),
          color: (j['color'] as num?)?.toInt(),
          position: (j['position'] as num?)?.toDouble(),
          targetTemp: (j['targetTemp'] as num?)?.toDouble(),
          locked: j['locked'] as bool?,
          volume: (j['volume'] as num?)?.toDouble(),
        ),
      );
}

/// When a scene runs by itself: a time of day on some weekdays (1 = Monday).
class SceneSchedule {
  SceneSchedule({required this.hour, required this.minute, Set<int>? days})
      : days = days ?? {1, 2, 3, 4, 5, 6, 7};

  int hour;
  int minute;
  Set<int> days;

  bool matches(DateTime t) => t.hour == hour && t.minute == minute && days.contains(t.weekday);

  /// The next time after [now] this is due, or null when no day is picked.
  DateTime? nextAfter(DateTime now) {
    for (var i = 0; i <= 7; i++) {
      final t = DateTime(now.year, now.month, now.day + i, hour, minute);
      if (t.isAfter(now) && days.contains(t.weekday)) return t;
    }
    return null;
  }

  /// The run this belongs to when it fires at [now], allowing for a late or
  /// slightly early alarm. Null when [now] is not close to a run.
  DateTime? runNear(DateTime now, {Duration late = const Duration(minutes: 15)}) {
    for (final back in [0, 1]) {
      final t = DateTime(now.year, now.month, now.day - back, hour, minute);
      final after = now.difference(t);
      if (days.contains(t.weekday) && after >= const Duration(minutes: -1) && after <= late) return t;
    }
    return null;
  }

  /// Names one run, e.g. "2026-10-17 7:30", so it is not run twice.
  static String slot(DateTime t) => '${t.year}-${t.month}-${t.day} ${t.hour}:${t.minute}';

  String get time => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  String get daysLabel {
    if (days.length == 7) return 'Every day';
    if (days.length == 5 && days.containsAll({1, 2, 3, 4, 5})) return 'Weekdays';
    if (days.length == 2 && days.containsAll({6, 7})) return 'Weekends';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return (days.toList()..sort()).map((d) => names[d - 1]).join(' ');
  }

  Map<String, dynamic> toJson() => {'hour': hour, 'minute': minute, 'days': days.toList()..sort()};

  factory SceneSchedule.fromJson(Map<String, dynamic> j) => SceneSchedule(
        hour: (j['hour'] as num).toInt(),
        minute: (j['minute'] as num).toInt(),
        days: (j['days'] as List?)?.map((e) => (e as num).toInt()).toSet(),
      );
}

/// A named set of device states applied with one tap, e.g. "Movie night".
class Scene {
  Scene({required this.id, required this.name, this.icon = 'auto', List<SceneAction>? actions, this.schedule})
      : actions = actions ?? [];

  final String id;
  String name;

  /// A key from [sceneIcons].
  String icon;
  List<SceneAction> actions;
  SceneSchedule? schedule;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon,
        'actions': actions.map((a) => a.toJson()).toList(),
        if (schedule != null) 'schedule': schedule!.toJson(),
      };

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Scene',
        icon: j['icon'] as String? ?? 'auto',
        actions: ((j['actions'] as List?) ?? const [])
            .map((e) => SceneAction.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        schedule: j['schedule'] == null ? null : SceneSchedule.fromJson(Map<String, dynamic>.from(j['schedule'] as Map)),
      );
}

/// Ready-made scenes offered when creating one.
const sceneTemplates = [
  ('Good morning', 'morning'),
  ('Movie night', 'movie'),
  ('Good night', 'night'),
  ('Away', 'away'),
  ('Dinner', 'dinner'),
  ('Focus', 'focus'),
];
