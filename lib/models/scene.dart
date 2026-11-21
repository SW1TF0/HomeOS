import '../util/sun.dart';
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
        mode: d.has(Capability.mode) && lit ? s.mode : null,
        speed: d.has(Capability.speed) && lit ? s.speed : null,
        targetHumidity: d.has(Capability.humidity) && lit ? s.targetHumidity : null,
        action: _action(d),
      ),
    );
  }

  /// Turns [d] off or on. Things that do not switch do the nearest thing: a blind closes or opens, a robot goes home
  /// or cleans, a lock locks. Null when there is nothing like that (a scene never unlocks a door by "on").
  static SceneAction? turn(Device d, bool on) {
    final robot = d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower);
    final c = d.has(Capability.onOff)
        ? DeviceCommand(on: on)
        : d.has(Capability.position)
            ? DeviceCommand(position: on ? 1 : 0)
            : d.has(Capability.lock)
                ? (on ? null : const DeviceCommand(locked: true))
                : robot
                    ? (on
                        ? const DeviceCommand(action: DeviceAction.start)
                        : d.has(Capability.dock)
                            ? const DeviceCommand(action: DeviceAction.dock)
                            : null)
                    : null;
    return c == null ? null : SceneAction(deviceId: d.id, command: c);
  }

  /// Whether this turns its device off (or closes, locks, sends home).
  bool get isOff {
    final c = command;
    return c.on == false || c.locked == true || c.action == DeviceAction.dock || (c.on == null && c.position == 0);
  }

  /// A robot that is out cleaning starts again, one at home goes home. An armed alarm is armed again, but scenes
  /// never disarm one (that needs its code, which is not saved).
  static DeviceAction? _action(Device d) {
    final a = d.state.activity;
    if (d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower)) {
      if (a == Activity.running) return DeviceAction.start;
      if (d.has(Capability.dock) && const {Activity.returning, Activity.docked, Activity.charging}.contains(a)) {
        return DeviceAction.dock;
      }
    }
    if (d.has(Capability.alarm) && d.props['codeArmRequired'] != true) {
      return DeviceAction.values.where((x) => x != DeviceAction.disarm && x.alarmState == a).firstOrNull;
    }
    return null;
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
      'mode': ?c.mode,
      'speed': ?c.speed,
      'targetHumidity': ?c.targetHumidity,
      'action': ?c.action?.name,
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
          mode: j['mode'] as String?,
          speed: (j['speed'] as num?)?.toDouble(),
          targetHumidity: (j['targetHumidity'] as num?)?.toDouble(),
          action: DeviceAction.parse(j['action'] as String?),
        ),
      );
}

/// When a scene runs by itself: a time of day, or sunrise or sunset give or take some minutes, on some weekdays
/// (1 = Monday).
class SceneSchedule {
  SceneSchedule({required this.hour, required this.minute, Set<int>? days})
      : days = days ?? {1, 2, 3, 4, 5, 6, 7},
        sun = null,
        offset = 0,
        lat = null,
        lon = null;

  /// At sunrise or sunset at the home's place ([lat], [lon]), [offset] minutes after (or before, when negative).
  SceneSchedule.sun(String this.sun,
      {required double this.lat, required double this.lon, this.offset = 0, Set<int>? days})
      : hour = 0,
        minute = 0,
        days = days ?? {1, 2, 3, 4, 5, 6, 7};

  int hour;
  int minute;
  Set<int> days;

  /// 'sunrise' or 'sunset', or null for a time of day.
  final String? sun;
  final int offset;
  final double? lat;
  final double? lon;

  bool get bySun => sun != null && lat != null && lon != null;

  /// The same, somewhere else: when the home moves to another town.
  SceneSchedule at(double lat, double lon) =>
      bySun ? SceneSchedule.sun(sun!, lat: lat, lon: lon, offset: offset, days: days) : this;

  /// When it is due on the local day of [day] (to the minute), whatever the weekday. Null when the sun does not
  /// rise or set that day.
  DateTime? timeOn(DateTime day) {
    if (!bySun) return DateTime(day.year, day.month, day.day, hour, minute);
    final times = SunTimes.on(day, lat!, lon!);
    final t = (sun == 'sunrise' ? times.rise : times.set)?.toLocal().add(Duration(minutes: offset));
    return t == null ? null : DateTime(t.year, t.month, t.day, t.hour, t.minute);
  }

  bool matches(DateTime t) {
    if (!days.contains(t.weekday)) return false;
    final due = timeOn(t);
    return due != null && slot(due) == slot(t);
  }

  /// The next time after [now] this is due, or null when no day is picked.
  DateTime? nextAfter(DateTime now) {
    for (var i = 0; i <= 7; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
      if (!days.contains(day.weekday)) continue;
      final t = timeOn(day);
      if (t != null && t.isAfter(now)) return t;
    }
    return null;
  }

  /// The run this belongs to when it fires at [now], allowing for a late or
  /// slightly early alarm. Null when [now] is not close to a run.
  DateTime? runNear(DateTime now, {Duration late = const Duration(minutes: 15)}) {
    for (final back in [0, 1]) {
      final day = DateTime(now.year, now.month, now.day - back);
      final t = timeOn(day);
      if (t == null) continue;
      final after = now.difference(t);
      if (days.contains(day.weekday) && after >= const Duration(minutes: -1) && after <= late) return t;
    }
    return null;
  }

  /// Names one run, e.g. "2026-10-17 7:30", so it is not run twice.
  static String slot(DateTime t) => '${t.year}-${t.month}-${t.day} ${t.hour}:${t.minute}';

  String get time => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// "07:30", "Sunset", "30 min before sunrise".
  String get label {
    if (!bySun) return time;
    final name = sun == 'sunrise' ? 'sunrise' : 'sunset';
    if (offset == 0) return name == 'sunrise' ? 'Sunrise' : 'Sunset';
    final m = offset.abs();
    final span = m < 60 || m % 60 != 0 ? '$m min' : '${m ~/ 60} h';
    return offset < 0 ? '$span before $name' : '$span after $name';
  }

  String get daysLabel {
    if (days.length == 7) return 'Every day';
    if (days.length == 5 && days.containsAll({1, 2, 3, 4, 5})) return 'Weekdays';
    if (days.length == 2 && days.containsAll({6, 7})) return 'Weekends';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return (days.toList()..sort()).map((d) => names[d - 1]).join(' ');
  }

  Map<String, dynamic> toJson() => {
        'hour': hour,
        'minute': minute,
        'days': days.toList()..sort(),
        if (bySun) ...{'sun': sun, 'offset': offset, 'lat': lat, 'lon': lon},
      };

  factory SceneSchedule.fromJson(Map<String, dynamic> j) {
    final days = (j['days'] as List?)?.map((e) => (e as num).toInt()).toSet();
    if (j['sun'] case final String sun when j['lat'] is num && j['lon'] is num) {
      return SceneSchedule.sun(sun,
          lat: (j['lat'] as num).toDouble(),
          lon: (j['lon'] as num).toDouble(),
          offset: (j['offset'] as num?)?.toInt() ?? 0,
          days: days);
    }
    return SceneSchedule(hour: (j['hour'] as num).toInt(), minute: (j['minute'] as num).toInt(), days: days);
  }
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
  ('All off', 'off'),
  ('Good morning', 'morning'),
  ('Movie night', 'movie'),
  ('Good night', 'night'),
  ('Away', 'away'),
  ('Dinner', 'dinner'),
  ('Focus', 'focus'),
];
