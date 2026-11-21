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

  test('a scene can turn things off: lights off, blinds closed, doors locked, robots home', () async {
    final lamp = named('Floor lamp');
    final blinds = named('Blinds');
    final door = named('Front door');
    final robot = named('Robot vacuum');
    final alarm = named('Alarm');
    expect(SceneAction.turn(alarm, false), isNull, reason: 'an alarm has no off');
    expect(SceneAction.turn(door, true), isNull, reason: 'scenes never unlock a door by turning things on');
    final s = store.addScene('Good night', [lamp, blinds, door, robot, alarm], turnOn: false);
    expect(s.actions.take(4).every((a) => a.isOff), isTrue);
    expect(s.actions.last.command.action, isNull, reason: 'the alarm keeps how it is now');

    await store.command(lamp, const DeviceCommand(on: true, brightness: 0.8));
    await store.command(blinds, const DeviceCommand(position: 0.7));
    await store.command(door, const DeviceCommand(locked: false));
    await store.command(robot, const DeviceCommand(action: DeviceAction.start));
    await store.runScene(s);
    expect((lamp.state.on, blinds.state.position, door.state.locked), (false, 0, true));
    expect(const {Activity.returning, Activity.docked}.contains(robot.state.activity), isTrue);

    final on = store.addScene('Wake up', [lamp, blinds], turnOn: true);
    await store.runScene(on);
    expect((lamp.state.on, blinds.state.position), (true, 1));

    store.setSceneStep(on, SceneAction(deviceId: lamp.id, command: const DeviceCommand(on: true, brightness: 0.3)));
    expect(on.actions.length, 2);
    expect(on.actions.first.command.brightness, 0.3);
    store.removeSceneStep(on, blinds.id);
    expect(on.actions.map((a) => a.deviceId), [lamp.id]);
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

  test('scenes send robots out or home and arm alarms, but never disarm', () async {
    final robot = named('Robot vacuum');
    final alarm = named('Alarm');
    expect(SceneAction.capture(robot).command.action, DeviceAction.dock);
    expect(SceneAction.capture(alarm).command.action, isNull, reason: 'disarming needs a person');
    await store.command(robot, const DeviceCommand(action: DeviceAction.start, mode: 'Turbo'));
    await store.command(alarm, const DeviceCommand(action: DeviceAction.armAway));
    final s = store.addScene('Leaving', [robot, alarm]);
    expect(s.actions.map((a) => a.command.action), [DeviceAction.start, DeviceAction.armAway]);
    expect(s.actions.first.command.mode, 'Turbo');

    final back = HomeData.fromJson(jsonDecode(store.exportJson()) as Map<String, dynamic>).scenes.single;
    expect(back.actions.map((a) => a.command.action), [DeviceAction.start, DeviceAction.armAway]);

    await store.command(robot, const DeviceCommand(action: DeviceAction.dock));
    await store.command(alarm, const DeviceCommand(action: DeviceAction.disarm));
    await store.runScene(s);
    expect((robot.state.activity, robot.state.mode, alarm.state.activity), (Activity.running, 'Turbo', Activity.armedAway));

    alarm.props['codeArmRequired'] = true;
    expect(SceneAction.capture(alarm).command.action, isNull, reason: 'its code is not saved');
  });

  test('all off leaves water valves, garage doors and heating alone', () async {
    final valve = store.addVirtualDevice('demo', 'Main water', DeviceKind.valve);
    final garage = store.addVirtualDevice('demo', 'Garage', DeviceKind.garage);
    final siren = store.addVirtualDevice('demo', 'Siren', DeviceKind.siren);
    await store.command(valve, const DeviceCommand(on: true));
    await store.command(garage, const DeviceCommand(position: 1));
    await store.command(siren, const DeviceCommand(on: true));
    await store.allOff();
    expect((valve.state.on, garage.state.position, siren.state.on), (true, 1, false));
  });

  test('a virtual device that changes kind gets the controls of its new kind', () {
    final lamp = named('Desk lamp');
    store.updateDevice(lamp, kind: DeviceKind.vacuum);
    expect(lamp.capabilities, containsAll([Capability.run, Capability.dock]));
    expect(lamp.state.activity, Activity.docked);
    expect(lamp.modes, isNotEmpty);
    expect(HomeStore.tapControls(lamp), isTrue);
    store.updateDevice(lamp, kind: DeviceKind.alarm);
    expect(HomeStore.tapControls(lamp), isFalse, reason: 'an alarm opens its controls');
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
