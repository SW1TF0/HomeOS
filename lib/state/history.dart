import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/automation.dart';
import '../models/device.dart';

/// What kind of thing happened, for [HomeEvent].
enum EventType { turnedOn, turnedOff, opened, closed, locked, unlocked, reading, activity, offline, online, scene, automation }

/// One thing that happened in the home: a lamp turned on, a door opened, a scene ran. Shown under Activity.
class HomeEvent {
  const HomeEvent({required this.at, required this.type, this.deviceId, this.name, this.kind, this.label, this.value, this.by});

  final DateTime at;
  final EventType type;
  final String? deviceId;

  /// The device's, scene's or automation's name when it happened, in case it is renamed or removed later.
  final String? name;
  final DeviceKind? kind;

  /// The reading that changed ("Motion"), with its new value ("Detected"); an activity's new value.
  final String? label;
  final String? value;

  /// Who did it: `app` (someone in this app), `remote` (another phone, through this one), `scene:` or `automation:`
  /// and its id. Null when the device changed by itself, or someone used another app or a switch.
  final String? by;

  /// Doors, motion, locks, alarms, leaks and smoke.
  bool get isSecurity =>
      type == EventType.locked ||
      type == EventType.unlocked ||
      (type == EventType.opened && (kind == DeviceKind.garage || kind == DeviceKind.lock)) ||
      (type == EventType.reading && label != 'Error') ||
      (type == EventType.activity && kind == DeviceKind.alarm);

  /// Stopped answering, or reported a problem.
  bool get isProblem =>
      type == EventType.offline || (type == EventType.reading && label == 'Error') || (type == EventType.activity && value == Activity.error);

  Map<String, dynamic> toJson() => {
        't': at.millisecondsSinceEpoch,
        'type': type.name,
        'device': ?deviceId,
        'name': ?name,
        'kind': ?kind?.name,
        'label': ?label,
        'value': ?value,
        'by': ?by,
      };

  static HomeEvent? fromJson(Map<String, dynamic> j) {
    final type = EventType.values.where((t) => t.name == j['type']).firstOrNull;
    final t = (j['t'] as num?)?.toInt();
    if (type == null || t == null) return null;
    return HomeEvent(
      at: DateTime.fromMillisecondsSinceEpoch(t),
      type: type,
      deviceId: j['device'] as String?,
      name: j['name'] as String?,
      kind: j['kind'] == null ? null : DeviceKind.parse(j['kind'] as String?),
      label: j['label'] as String?,
      value: j['value'] as String?,
      by: j['by'] as String?,
    );
  }
}

/// One reading of one device over time, for its chart: every 5 minutes for the last day, every hour before that.
class Series {
  Series({required this.label, this.unit = '', List<(DateTime, double)>? points}) : points = points ?? [];

  final String label;
  String unit;
  final List<(DateTime, double)> points;

  static const fine = Duration(minutes: 5);
  static const coarse = Duration(hours: 1);
  static const fineFor = Duration(hours: 24);
  static const keep = Duration(days: 7);

  double? get latest => points.isEmpty ? null : points.last.$2;

  /// The points since [from].
  List<(DateTime, double)> since(DateTime from) => [for (final p in points) if (!p.$1.isBefore(from)) p];

  void add(DateTime at, double value) {
    final bucket = _bucket(at, fine);
    if (points.isNotEmpty && _bucket(points.last.$1, fine) == bucket) {
      points[points.length - 1] = (points.last.$1, value);
    } else if (points.isEmpty || at.isAfter(points.last.$1)) {
      points.add((at, value));
    }
    _compact(at);
  }

  /// Points older than a day become one an hour (their average); points older than a week go.
  void _compact(DateTime now) {
    final oldest = now.subtract(keep);
    points.removeWhere((p) => p.$1.isBefore(oldest));
    final edge = now.subtract(fineFor);
    final old = points.takeWhile((p) => p.$1.isBefore(edge)).toList();
    if (old.length < 2) return;
    final hours = <int, List<(DateTime, double)>>{};
    for (final p in old) {
      hours.putIfAbsent(_bucket(p.$1, coarse), () => []).add(p);
    }
    if (hours.length == old.length) return;
    points.removeRange(0, old.length);
    points.insertAll(0, [
      for (final h in hours.values) (h.first.$1, h.map((p) => p.$2).reduce((a, b) => a + b) / h.length),
    ]);
  }

  static int _bucket(DateTime t, Duration size) => t.millisecondsSinceEpoch ~/ size.inMilliseconds;

  Map<String, dynamic> toJson() => {
        'label': label,
        if (unit.isNotEmpty) 'unit': unit,
        // Minutes since 1970 and the value, rounded: about 12 bytes a point.
        'p': [for (final p in points) [p.$1.millisecondsSinceEpoch ~/ 60000, double.parse(p.$2.toStringAsFixed(2))]],
      };

  factory Series.fromJson(Map<String, dynamic> j) => Series(
        label: j['label'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        points: [
          for (final p in (j['p'] as List? ?? const []))
            if (p is List && p.length == 2)
              (DateTime.fromMillisecondsSinceEpoch((p[0] as num).toInt() * 60000), (p[1] as num).toDouble()),
        ],
      );
}

/// Where a home's history is kept. On the phone it is the app's preferences; tests keep it in memory.
abstract class HistoryStorage {
  Future<String?> read(String homeId);
  Future<void> write(String homeId, String raw);
  Future<void> remove(String homeId);
}

class PrefsHistoryStorage implements HistoryStorage {
  const PrefsHistoryStorage();
  static String _key(String homeId) => 'smartmenukj.history.v1.$homeId';

  @override
  Future<String?> read(String homeId) async => (await SharedPreferences.getInstance()).getString(_key(homeId));

  @override
  Future<void> write(String homeId, String raw) async => (await SharedPreferences.getInstance()).setString(_key(homeId), raw);

  @override
  Future<void> remove(String homeId) async => (await SharedPreferences.getInstance()).remove(_key(homeId));
}

class MemoryHistoryStorage implements HistoryStorage {
  final Map<String, String> saved = {};

  @override
  Future<String?> read(String homeId) async => saved[homeId];

  @override
  Future<void> write(String homeId, String raw) async => saved[homeId] = raw;

  @override
  Future<void> remove(String homeId) async => saved.remove(homeId);
}

/// What happened in the open home, and how its readings went, kept on this device only. It fills while the app
/// is open (and on a device keeping the home online), so it shows what the app saw.
class HomeHistory extends ChangeNotifier {
  HomeHistory({HistoryStorage? storage, this.saveAfter = const Duration(seconds: 20)})
      : storage = storage ?? const PrefsHistoryStorage();

  final HistoryStorage storage;

  /// How long after a change the history is written; zero writes at once, without a timer.
  final Duration saveAfter;
  String? homeId;
  final List<HomeEvent> events = [];

  /// Each device's readings over time, by device id and then reading.
  final Map<String, Map<String, Series>> series = {};

  static const maxEvents = 600;
  static const keepEvents = Duration(days: 14);

  /// Readings that are not worth a chart: addresses, names, counters that only grow.
  static const _notCharted = {
    'Address', 'IP', 'MAC', 'Signal', 'Uptime', 'Firmware', 'Version', 'Model', 'Serial', 'Channel', 'Playing', 'Error',
    'Status', 'Energy', 'Total', 'Clients', 'Input',
  };

  /// Readings whose changes are not events: they change all the time or are numbers (those get charts).
  static const _notEvents = {'Address', 'Playing', 'Status', 'Signal', 'IP', 'Power', 'Energy', 'Input', 'Uptime', 'Firmware'};

  Timer? _saveTimer;
  bool _dirty = false;

  /// Opens the history of [id], saving the one that was open.
  Future<void> open(String id) async {
    if (id == homeId) return;
    await save();
    homeId = id;
    events.clear();
    series.clear();
    try {
      final raw = await storage.read(id);
      if (raw != null) _read(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('History could not be read: $e');
    }
    notifyListeners();
  }

  void _read(Map<String, dynamic> j) {
    for (final e in (j['events'] as List? ?? const [])) {
      final ev = e is Map ? HomeEvent.fromJson(Map<String, dynamic>.from(e)) : null;
      if (ev != null) events.add(ev);
    }
    final s = j['series'] as Map? ?? const {};
    for (final device in s.entries) {
      final byLabel = <String, Series>{};
      for (final one in (device.value as Map? ?? const {}).values) {
        if (one is! Map) continue;
        final read = Series.fromJson(Map<String, dynamic>.from(one));
        if (read.label.isNotEmpty && read.points.isNotEmpty) byLabel[read.label] = read;
      }
      if (byLabel.isNotEmpty) series['${device.key}'] = byLabel;
    }
  }

  Map<String, dynamic> toJson() => {
        'events': [for (final e in events) e.toJson()],
        'series': {
          for (final d in series.entries) d.key: {for (final s in d.value.entries) s.key: s.value.toJson()},
        },
      };

  Future<void> save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final id = homeId;
    if (id == null || !_dirty) return;
    _dirty = false;
    try {
      await storage.write(id, jsonEncode(toJson()));
    } catch (e) {
      debugPrint('History could not be saved: $e');
    }
  }

  void _touched() {
    _dirty = true;
    notifyListeners();
    if (saveAfter == Duration.zero) {
      unawaited(save());
    } else {
      _saveTimer ??= Timer(saveAfter, save);
    }
  }

  void add(HomeEvent e) {
    events.add(e);
    final oldest = clock.now().subtract(keepEvents);
    events.removeWhere((x) => x.at.isBefore(oldest));
    if (events.length > maxEvents) events.removeRange(0, events.length - maxEvents);
    _touched();
  }

  /// The newest first, of one device or of the whole home.
  List<HomeEvent> latest({String? deviceId, int? limit}) {
    final out = <HomeEvent>[];
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (deviceId != null && e.deviceId != deviceId) continue;
      out.add(e);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  Future<void> clear() async {
    events.clear();
    series.clear();
    _touched();
    await save();
  }

  void forgetDevice(String deviceId) {
    if (series.remove(deviceId) != null) _touched();
  }

  /// A device's charts, the ones with something to draw first.
  List<Series> seriesOf(String deviceId) =>
      [for (final s in (series[deviceId] ?? const <String, Series>{}).values) if (s.points.length > 1) s];

  /// Notes every number [devices] show now: temperatures, humidity, battery, power, air quality...
  void sample(Iterable<Device> devices) {
    final now = clock.now();
    var any = false;
    for (final d in devices) {
      final s = d.state;
      if (!s.reachable) continue;
      final values = <String, (double, String)>{};
      if (s.currentTemp != null) values['Temperature'] = (s.currentTemp!, '°');
      if (s.currentHumidity != null) values['Humidity'] = (s.currentHumidity!, '%');
      if (s.battery != null) values['Battery'] = (s.battery! * 100, '%');
      for (final r in s.readings.entries) {
        if (values.containsKey(r.key) || _notCharted.contains(r.key)) continue;
        final parsed = numberWithUnit(r.value);
        if (parsed != null) values[r.key] = parsed;
      }
      if (values.isEmpty) continue;
      final mine = series.putIfAbsent(d.id, () => {});
      for (final v in values.entries) {
        if (!mine.containsKey(v.key) && mine.length >= 8) continue;
        final one = mine.putIfAbsent(v.key, () => Series(label: v.key, unit: v.value.$2));
        one.unit = v.value.$2;
        one.add(now, v.value.$1);
        any = true;
      }
    }
    if (any) _touched();
  }

  /// "21.5 °C" → (21.5, "°C"); "45%" → (45, "%"); "Open" → null. Times ("12:30") and dates are not numbers here.
  static (double, String)? numberWithUnit(String text) {
    final m = RegExp(r'^\s*(-?\d+(?:[.,]\d+)?)\s*([^\d\s:/][^\d:]{0,9})?\s*$').firstMatch(text);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    if (v == null) return null;
    return (v, (m.group(2) ?? '').trim());
  }

  /// The events in going from [before] to [now] on [d], with who did it.
  static List<HomeEvent> changes(Device d, DeviceState before, DeviceState now, DateTime at, String? by) {
    HomeEvent e(EventType type, {String? label, String? value}) =>
        HomeEvent(at: at, type: type, deviceId: d.id, name: d.name, kind: d.kind, label: label, value: value, by: by);
    final out = <HomeEvent>[];
    if (before.on != null && now.on != null && before.on != now.on && d.has(Capability.onOff)) {
      out.add(e(now.on! ? EventType.turnedOn : EventType.turnedOff));
    }
    final wasOpen = (before.position ?? -1) > 0.01;
    final isOpen = (now.position ?? -1) > 0.01;
    if (before.position != null && now.position != null && wasOpen != isOpen) {
      out.add(e(isOpen ? EventType.opened : EventType.closed));
    }
    if (before.locked != null && now.locked != null && before.locked != now.locked) {
      out.add(e(now.locked! ? EventType.locked : EventType.unlocked));
    }
    if (now.activity != null && before.activity != now.activity && before.activity != null) {
      out.add(e(EventType.activity, value: now.activity));
    }
    for (final r in now.readings.entries) {
      if (_notEvents.contains(r.key)) continue;
      final was = before.readings[r.key];
      final v = r.value.trim();
      if (v.isEmpty || was == null || was.trim().toLowerCase() == v.toLowerCase()) continue;
      // Numbers go on charts; only words that change ("Detected", "Open", "Leak!") are events.
      if (AutomationTrigger.numberOf(DeviceState(readings: {r.key: v}), r.key) != null) continue;
      out.add(e(EventType.reading, label: r.key, value: v));
    }
    // A problem that appears ("Bin full") is news even with no value before it.
    final error = now.readings['Error']?.trim();
    if (error != null && error.isNotEmpty && before.readings['Error'] == null) {
      out.add(e(EventType.reading, label: 'Error', value: error));
    }
    return out;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
