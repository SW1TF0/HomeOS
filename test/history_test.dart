import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/history.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

void main() {
  late HomeStore store;
  late HomeHistory history;
  late MemoryHistoryStorage saved;

  Device named(String name) => store.devices.firstWhere((d) => d.name == name);

  setUp(() async {
    store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('nope', 500)));
    await store.load();
    saved = MemoryHistoryStorage();
    history = HomeHistory(storage: saved, saveAfter: Duration.zero);
    await store.keepHistory(history);
  });

  tearDown(() => store.dispose());

  test('nothing is noted before the first check, then what the app does is, with who did it', () async {
    final lamp = named('Floor lamp');
    await store.command(lamp, DeviceCommand(on: lamp.state.on != true));
    expect(history.events, isEmpty, reason: 'the home was not checked yet');

    await store.refreshAll();
    final wasOn = lamp.state.on == true;
    await store.command(lamp, DeviceCommand(on: !wasOn));
    final e = history.latest().single;
    expect(e.type, wasOn ? EventType.turnedOff : EventType.turnedOn);
    expect(e.deviceId, lamp.id);
    expect(e.by, 'app');

    // The lamp's own switch: nobody in the app did it.
    lamp.state = lamp.state.merge(DeviceState(on: wasOn));
    await store.refreshAll();
    expect(history.latest().first.type, wasOn ? EventType.turnedOn : EventType.turnedOff);
    expect(history.latest().first.by, isNull);
    expect(history.latest(deviceId: lamp.id).length, 2);
  });

  test('a scene is noted, and so is every device it changed, as done by the scene', () async {
    await store.refreshAll();
    final lamp = named('Floor lamp');
    await store.command(lamp, const DeviceCommand(on: false));
    final s = store.addScene('Evening', [lamp], turnOn: true);
    await store.runScene(s);
    final latest = history.latest(limit: 2);
    expect(latest.map((e) => e.type), containsAll([EventType.scene, EventType.turnedOn]));
    expect(latest.firstWhere((e) => e.type == EventType.turnedOn).by, 'scene:${s.id}');
    expect(latest.firstWhere((e) => e.type == EventType.scene).value, s.id);
  });

  test('a device is noted as gone only after a minute without answers, and again when it is back', () async {
    final start = DateTime(2026, 11, 7, 10);
    var now = start;
    await withClock(Clock(() => now), () async {
      await store.refreshAll();
      final lamp = named('Floor lamp');
      final was = lamp.state;
      lamp.state = DeviceState.unreachable;
      await store.refreshAll();
      expect(history.events, isEmpty, reason: 'one missed answer is not gone');
      now = start.add(const Duration(seconds: 70));
      await store.refreshAll();
      final off = history.latest().single;
      expect(off.type, EventType.offline);
      expect(off.at, start, reason: 'noted at the time it stopped answering');
      expect(off.isProblem, isTrue);

      lamp.state = was;
      now = start.add(const Duration(minutes: 3));
      await store.refreshAll();
      expect(history.latest().first.type, EventType.online);
      expect(history.events.length, 2);
    });
  });

  test('doors, locks and readings that are words become events; numbers become charts', () {
    final at = DateTime(2026, 11, 7, 12);
    final door = Device(id: 'd', name: 'Front door', kind: DeviceKind.lock, integrationId: 'x', externalId: 'd')
      ..capabilities = {Capability.lock};
    var found = HomeHistory.changes(door, const DeviceState(locked: true), const DeviceState(locked: false), at, null);
    expect(found.single.type, EventType.unlocked);
    expect(found.single.isSecurity, isTrue);

    final sensor = Device(id: 's', name: 'Hall', kind: DeviceKind.sensor, integrationId: 'x', externalId: 's');
    found = HomeHistory.changes(sensor, const DeviceState(readings: {'Motion': 'Clear', 'Temperature': '20 °C'}),
        const DeviceState(readings: {'Motion': 'Detected', 'Temperature': '21 °C'}), at, null);
    expect(found.single.label, 'Motion');
    expect(found.single.value, 'Detected');

    expect(HomeHistory.numberWithUnit('21.5 °C'), (21.5, '°C'));
    expect(HomeHistory.numberWithUnit('6 µg/m³'), (6.0, 'µg/m³'));
    expect(HomeHistory.numberWithUnit('45%'), (45.0, '%'));
    expect(HomeHistory.numberWithUnit('12:30'), isNull);
    expect(HomeHistory.numberWithUnit('Open'), isNull);
  });

  test('readings keep five-minute points for a day, then one an hour for a week', () {
    final s = Series(label: 'Temperature', unit: '°');
    final start = DateTime(2026, 11, 1);
    for (var m = 0; m <= 60 * 24 * 9; m += 5) {
      withClock(Clock.fixed(start.add(Duration(minutes: m))), () => s.add(clock.now(), 20 + (m % 60) / 60));
    }
    final end = start.add(const Duration(days: 9));
    final day = s.points.where((p) => end.difference(p.$1) <= const Duration(hours: 24)).length;
    expect(day, greaterThan(250), reason: 'every five minutes for the last day');
    final older = s.points.where((p) => end.difference(p.$1) > const Duration(hours: 25)).toList();
    expect(older.length, lessThan(7 * 24 + 2), reason: 'one an hour before that');
    expect(older.first.$1.isAfter(end.subtract(const Duration(days: 7, hours: 1))), isTrue, reason: 'a week at most');
    // Two readings in the same five minutes keep the newer.
    final t = Series(label: 'x', unit: '');
    t.add(DateTime(2026, 11, 1, 10, 0, 10), 1);
    t.add(DateTime(2026, 11, 1, 10, 3), 2);
    expect(t.points.single.$2, 2);
  });

  test('history is kept per home, survives a restart and drops the charts of removed devices', () async {
    await store.refreshAll();
    final lamp = named('Floor lamp');
    await store.command(lamp, DeviceCommand(on: lamp.state.on != true));
    store.history!.sample(store.devices);
    await history.save();
    expect(saved.saved[store.homeId], isNotNull);
    final raw = jsonDecode(saved.saved[store.homeId]!) as Map<String, dynamic>;
    expect((raw['events'] as List), isNotEmpty);

    final again = HomeHistory(storage: saved, saveAfter: Duration.zero);
    await again.open(store.homeId);
    expect(again.events.single.deviceId, lamp.id);
    expect(again.series, isNotEmpty);

    store.removeDevice(lamp);
    expect(history.series[lamp.id], isNull, reason: 'its charts go');
    expect(history.latest(deviceId: lamp.id).single.name, 'Floor lamp', reason: 'what it did stays, under its name');
  });
}
