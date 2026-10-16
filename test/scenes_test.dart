import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/models/scene.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

void main() {
  late HomeStore store;

  setUp(() async {
    store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 500)));
    await store.load();
  });

  tearDown(() => store.dispose());

  Device named(String n) => store.devices.firstWhere((d) => d.name == n);

  test('a scene remembers how devices are and brings them back', () async {
    final lamp = named('Floor lamp');
    final tv = named('TV');
    await store.command(lamp, const DeviceCommand(brightness: 0.2));
    final s = store.addScene('Movie night', [lamp, tv], icon: 'movie');
    expect(s.actions.length, 2);

    await store.command(lamp, const DeviceCommand(brightness: 1));
    await store.command(tv, const DeviceCommand(on: true));
    expect(await store.runScene(s), 2);
    expect(lamp.state.brightness, closeTo(0.2, 0.001));
    expect(tv.state.on, isFalse);
  });

  test('scenes survive a backup and lose devices that are removed', () async {
    final lamp = named('Floor lamp');
    final s = store.addScene('Evening', [lamp, named('Desk lamp')]);
    s.schedule = SceneSchedule(hour: 19, minute: 30, days: {1, 2, 3, 4, 5});
    final back = HomeData.fromJson(jsonDecode(store.exportJson()) as Map<String, dynamic>);
    expect(back.scenes.single.name, 'Evening');
    expect(back.scenes.single.schedule!.daysLabel, 'Weekdays');
    expect(back.scenes.single.actions.first.command.brightness, lamp.state.brightness);
    store.removeDevice(lamp);
    expect(s.actions.length, 1);
  });

  test('scheduled scenes run once at their minute', () async {
    final fan = named('Bath fan');
    final s = store.addScene('Fan on', [fan]);
    s.actions = [SceneAction(deviceId: fan.id, command: const DeviceCommand(on: true))];
    s.schedule = SceneSchedule(hour: 7, minute: 0, days: {4}); // Thursday
    store.runDueScenes(DateTime(2026, 10, 14, 7, 0)); // a Wednesday
    await Future<void>.delayed(Duration.zero);
    expect(fan.state.on, isFalse);
    store.runDueScenes(DateTime(2026, 10, 15, 7, 0));
    await Future<void>.delayed(Duration.zero);
    expect(fan.state.on, isTrue);
  });

  test('the sample home goes away once real devices are here', () async {
    expect(store.showSampleCleanup, isFalse, reason: 'nothing real yet');
    final cfg = store.addIntegration('shelly', settings: {'hosts': '10.0.0.5'});
    store.addVirtualDevice(cfg.id, 'Real plug', DeviceKind.outlet);
    final mine = store.addVirtualDevice('demo', 'My planned lamp', DeviceKind.light);
    expect(store.showSampleCleanup, isTrue);
    store.removeSampleHome();
    expect(store.sampleDevices, isEmpty);
    expect(store.devices.map((d) => d.name), containsAll(['Real plug', 'My planned lamp']));
    expect(store.device(mine.id), isNotNull);
    expect(store.rooms, isEmpty, reason: 'the sample rooms were empty');
  });
}
