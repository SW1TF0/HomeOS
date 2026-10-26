import 'device.dart';

/// What happens to a device that sets an automation off.
enum TriggerKind { turnsOn, turnsOff, becomes, above, below, activity, locks, unlocks, opens, closes, offline, online }

/// One change on one device: "the hall sensor's Motion becomes Detected", "the lamp turns on", "it gets warmer than
/// 25". It fires once, when the change happens, not for as long as it stays that way.
class AutomationTrigger {
  const AutomationTrigger({required this.deviceId, required this.kind, this.label, this.value, this.number});

  final String deviceId;
  final TriggerKind kind;

  /// The reading watched by [TriggerKind.becomes], [TriggerKind.above] and [TriggerKind.below]: a name from the
  /// device's readings, or Temperature, Humidity or Battery.
  final String? label;

  /// The text a reading or an activity becomes.
  final String? value;

  /// Where [TriggerKind.above] and [TriggerKind.below] fire. Battery is in percent.
  final double? number;

  AutomationTrigger copyWith({double? number}) =>
      AutomationTrigger(deviceId: deviceId, kind: kind, label: label, value: value, number: number ?? this.number);

  /// Whether going from [before] to [now] is the change this waits for.
  bool fired(DeviceState before, DeviceState now) {
    if (kind == TriggerKind.offline) return before.reachable && !now.reachable;
    if (kind == TriggerKind.online) return !before.reachable && now.reachable;
    // A device that drops out and comes back has not changed: it was only out of reach.
    if (!before.reachable || !now.reachable) return false;
    switch (kind) {
      case TriggerKind.turnsOn:
        return before.on == false && now.on == true;
      case TriggerKind.turnsOff:
        return before.on == true && now.on == false;
      case TriggerKind.becomes:
        bool same(String? v) => v != null && v.toLowerCase() == value?.toLowerCase();
        return !same(before.readings[label]) && same(now.readings[label]);
      case TriggerKind.above || TriggerKind.below:
        final a = numberOf(before, label);
        final b = numberOf(now, label);
        final n = number;
        if (a == null || b == null || n == null) return false;
        return kind == TriggerKind.above ? a <= n && b > n : a >= n && b < n;
      case TriggerKind.activity:
        return before.activity != value && now.activity == value;
      case TriggerKind.locks:
        return before.locked == false && now.locked == true;
      case TriggerKind.unlocks:
        return before.locked == true && now.locked == false;
      case TriggerKind.opens:
        return (before.position ?? 1) <= 0.01 && (now.position ?? 0) > 0.01;
      case TriggerKind.closes:
        return (before.position ?? 0) > 0.01 && (now.position ?? 1) <= 0.01;
      case TriggerKind.offline || TriggerKind.online:
        return false;
    }
  }

  /// The number behind a reading: the device's own temperature, humidity or battery, else the first number in the
  /// reading's text ("21.5 °C").
  static double? numberOf(DeviceState s, String? label) {
    switch (label) {
      case 'Temperature' when s.currentTemp != null:
        return s.currentTemp;
      case 'Humidity' when s.currentHumidity != null:
        return s.currentHumidity;
      case 'Battery' when s.battery != null:
        return s.battery! * 100;
    }
    final text = s.readings[label];
    if (text == null) return null;
    final m = RegExp(r'-?\d+(?:[.,]\d+)?').firstMatch(text);
    return m == null ? null : double.tryParse(m.group(0)!.replaceAll(',', '.'));
  }

  /// Readings that are not worth watching: they change all the time or are not states.
  static const _skip = {'Address', 'Playing', 'Error', 'Status', 'Power', 'Energy', 'Signal', 'IP'};

  /// The other value a two-way reading takes, so "becomes Clear" can be offered while it shows Detected.
  static const _opposite = {
    'detected': 'Clear', 'clear': 'Detected', 'open': 'Closed', 'closed': 'Open', 'on': 'Off', 'off': 'On',
    'wet': 'Dry', 'dry': 'Wet', 'yes': 'No', 'no': 'Yes', 'home': 'Away', 'away': 'Home',
  };

  /// Everything [d] can set an automation off with. Numbers are filled in later.
  static List<AutomationTrigger> choicesFor(Device d) {
    final s = d.state;
    AutomationTrigger t(TriggerKind kind, {String? label, String? value}) =>
        AutomationTrigger(deviceId: d.id, kind: kind, label: label, value: value);
    final robot = d.has(Capability.run);
    return [
      if (d.has(Capability.onOff)) ...[t(TriggerKind.turnsOn), t(TriggerKind.turnsOff)],
      if (d.has(Capability.position)) ...[t(TriggerKind.opens), t(TriggerKind.closes)],
      if (d.has(Capability.lock)) ...[t(TriggerKind.locks), t(TriggerKind.unlocks)],
      if (d.has(Capability.alarm))
        for (final a in const ['triggered', 'disarmed', 'armed_away', 'armed_home', 'armed_night'])
          t(TriggerKind.activity, value: a),
      if (robot)
        for (final a in const ['running', 'docked', 'idle', 'error']) t(TriggerKind.activity, value: a),
      if (s.currentTemp != null) ...[
        t(TriggerKind.above, label: 'Temperature'),
        t(TriggerKind.below, label: 'Temperature'),
      ],
      if (s.currentHumidity != null) ...[
        t(TriggerKind.above, label: 'Humidity'),
        t(TriggerKind.below, label: 'Humidity'),
      ],
      for (final e in s.readings.entries)
        if (!_skip.contains(e.key) && e.value.trim().isNotEmpty)
          if (numberOf(DeviceState(readings: {e.key: e.value}), e.key) != null) ...[
            t(TriggerKind.above, label: e.key),
            t(TriggerKind.below, label: e.key),
          ] else ...[
            t(TriggerKind.becomes, label: e.key, value: e.value.trim()),
            if (_opposite[e.value.trim().toLowerCase()] case final other?)
              t(TriggerKind.becomes, label: e.key, value: other),
          ],
      if (s.battery != null && !robot) t(TriggerKind.below, label: 'Battery'),
      t(TriggerKind.offline),
      t(TriggerKind.online),
    ];
  }

  static String activityText(String a) => switch (a) {
        'triggered' => 'goes off',
        'disarmed' => 'is disarmed',
        'armed_away' => 'is armed away',
        'armed_home' => 'is armed at home',
        'armed_night' => 'is armed for the night',
        'running' => 'starts its job',
        'docked' => 'is back at its base',
        'idle' => 'finishes',
        'error' => 'has a problem',
        _ => 'is $a',
      };

  static String _num(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  String get _unit => switch (label) {
        'Temperature' => '°',
        'Humidity' || 'Battery' => '%',
        _ => '',
      };

  /// What happens, without the device's name: "turns on", "Motion becomes Detected", "Temperature rises above 25°".
  String get event => switch (kind) {
        TriggerKind.turnsOn => 'turns on',
        TriggerKind.turnsOff => 'turns off',
        TriggerKind.becomes => '$label becomes $value',
        TriggerKind.above => '$label rises above ${number == null ? '…' : '${_num(number!)}$_unit'}',
        TriggerKind.below => '$label drops below ${number == null ? '…' : '${_num(number!)}$_unit'}',
        TriggerKind.activity => activityText(value ?? ''),
        TriggerKind.locks => 'locks',
        TriggerKind.unlocks => 'unlocks',
        TriggerKind.opens => 'opens',
        TriggerKind.closes => 'closes',
        TriggerKind.offline => 'stops answering',
        TriggerKind.online => 'answers again',
      };

  /// [event] said the way people say it about [deviceName]: "Hall sensor detects motion", "Back door opens".
  String eventFor(String deviceName) {
    if (kind != TriggerKind.becomes || label == null) return event;
    final l = label!;
    final named = deviceName.toLowerCase().contains(l.toLowerCase());
    return switch ((value ?? '').toLowerCase()) {
      'detected' => 'detects ${l.toLowerCase()}',
      'clear' => 'stops detecting ${l.toLowerCase()}',
      'open' => named ? 'opens' : '$l opens',
      'closed' => named ? 'closes' : '$l closes',
      _ => event,
    };
  }

  bool get needsNumber => (kind == TriggerKind.above || kind == TriggerKind.below) && number == null;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'kind': kind.name,
        'label': ?label,
        'value': ?value,
        'number': ?number,
      };

  static AutomationTrigger? fromJson(Map<String, dynamic> j) {
    final kind = TriggerKind.values.where((k) => k.name == j['kind']).firstOrNull;
    final device = j['deviceId'];
    if (kind == null || device is! String) return null;
    return AutomationTrigger(
      deviceId: device,
      kind: kind,
      label: j['label'] as String?,
      value: j['value'] as String?,
      number: (j['number'] as num?)?.toDouble(),
    );
  }
}

/// What an automation does: runs a scene, or turns one device on or off (and maybe off again a while later).
class AutomationStep {
  const AutomationStep.scene(String this.sceneId)
      : deviceId = null,
        on = true,
        offAfter = null;
  const AutomationStep.device(String this.deviceId, {required this.on, this.offAfter}) : sceneId = null;

  final String? sceneId;
  final String? deviceId;
  final bool on;

  /// Minutes after which a device it turned on is turned off again, like a light after motion.
  final int? offAfter;

  /// The same without turning off again, to name what it does first.
  AutomationStep get withoutOff => deviceId == null ? this : AutomationStep.device(deviceId!, on: on);

  AutomationStep withOffAfter(int? minutes) =>
      AutomationStep.device(deviceId!, on: on, offAfter: minutes == null || minutes <= 0 ? null : minutes);

  Map<String, dynamic> toJson() => {
        'sceneId': ?sceneId,
        'deviceId': ?deviceId,
        if (deviceId != null) 'on': on,
        'offAfter': ?offAfter,
      };

  static AutomationStep? fromJson(Map<String, dynamic> j) {
    if (j['sceneId'] case final String id) return AutomationStep.scene(id);
    if (j['deviceId'] case final String id) {
      return AutomationStep.device(id, on: j['on'] as bool? ?? true, offAfter: (j['offAfter'] as num?)?.toInt());
    }
    return null;
  }
}

/// "When this happens, do that": a trigger on one device, a step, and maybe only some hours of the day.
class Automation {
  Automation({required this.id, required this.trigger, required this.then, this.enabled = true, this.from, this.to});

  final String id;
  AutomationTrigger trigger;
  AutomationStep then;
  bool enabled;

  /// Only between these minutes of the day. The span can run past midnight (from 22:00 to 06:00).
  int? from;
  int? to;

  bool get anyTime => from == null || to == null || from == to;

  bool allowedAt(DateTime t) {
    if (anyTime) return true;
    final m = t.hour * 60 + t.minute;
    return from! < to! ? m >= from! && m < to! : m >= from! || m < to!;
  }

  static String clock(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'enabled': enabled,
        'trigger': trigger.toJson(),
        'then': then.toJson(),
        'from': ?from,
        'to': ?to,
      };

  static Automation? fromJson(Map<String, dynamic> j) {
    final trigger = AutomationTrigger.fromJson(Map<String, dynamic>.from(j['trigger'] as Map? ?? const {}));
    final then = AutomationStep.fromJson(Map<String, dynamic>.from(j['then'] as Map? ?? const {}));
    final id = j['id'];
    if (trigger == null || then == null || id is! String) return null;
    return Automation(
      id: id,
      trigger: trigger,
      then: then,
      enabled: j['enabled'] as bool? ?? true,
      from: (j['from'] as num?)?.toInt(),
      to: (j['to'] as num?)?.toInt(),
    );
  }
}
