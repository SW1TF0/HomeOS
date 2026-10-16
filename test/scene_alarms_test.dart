import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/scene.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/state/scene_alarms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 2026-10-15 is a Thursday (weekday 4).
  final thursday7 = DateTime(2026, 10, 15, 7, 0);

  group('schedule times', () {
    test('the next run is later today, or on the next picked day', () {
      final s = SceneSchedule(hour: 7, minute: 0, days: {4, 6});
      expect(s.nextAfter(DateTime(2026, 10, 15, 6, 59)), thursday7);
      expect(s.nextAfter(thursday7), DateTime(2026, 10, 17, 7, 0), reason: 'Saturday, not today again');
      expect(s.nextAfter(DateTime(2026, 10, 17, 8, 0)), DateTime(2026, 10, 22, 7, 0));
      expect(SceneSchedule(hour: 7, minute: 0, days: {}).nextAfter(thursday7), isNull);
    });

    test('an alarm a bit early or late still belongs to its run', () {
      final s = SceneSchedule(hour: 7, minute: 0, days: {4});
      expect(s.runNear(thursday7.add(const Duration(seconds: 2))), thursday7);
      expect(s.runNear(thursday7.subtract(const Duration(seconds: 30))), thursday7);
      expect(s.runNear(thursday7.add(const Duration(minutes: 12))), thursday7);
      expect(s.runNear(thursday7.add(const Duration(minutes: 40))), isNull, reason: 'too late, skip it');
      expect(s.runNear(DateTime(2026, 10, 16, 7, 0)), isNull, reason: 'Friday is not picked');
    });

    test('a run just before midnight that fires after it counts for the day before', () {
      final s = SceneSchedule(hour: 23, minute: 58, days: {4});
      expect(s.runNear(DateTime(2026, 10, 16, 0, 3)), DateTime(2026, 10, 15, 23, 58));
    });
  });

  group('alarms', () {
    test('alarm numbers are fixed and fit in 31 bits', () {
      expect(SceneAlarms.idOf('scene-abc'), SceneAlarms.idOf('scene-abc'));
      expect(SceneAlarms.idOf('scene-abc'), isNot(SceneAlarms.idOf('scene-abd')));
      expect(SceneAlarms.idOf('scene-abc'), 118119662, reason: 'FNV-1a, the same on every run');
      for (final id in ['', 'x', 'scene-${'z' * 200}']) {
        expect(SceneAlarms.idOf(id), inInclusiveRange(0, 0x7fffffff));
      }
    });

    test('only timed scenes get an alarm, at their next run', () {
      final timed = Scene(id: 'a', name: 'Morning', schedule: SceneSchedule(hour: 7, minute: 30));
      final plain = Scene(id: 'b', name: 'Movie');
      final plan = SceneAlarms.plan([timed, plain], thursday7);
      expect(plan, {'${SceneAlarms.idOf('a')}': DateTime(2026, 10, 15, 7, 30).millisecondsSinceEpoch});
    });

    test('sync hands Android the whole plan', () async {
      const channel = MethodChannel('test/alarms');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await SceneAlarms(channel).sync([Scene(id: 'a', name: 'A', schedule: SceneSchedule(hour: 8, minute: 0))], thursday7);
      expect(calls.single.method, 'sync');
      expect(calls.single.arguments, {'${SceneAlarms.idOf('a')}': DateTime(2026, 10, 15, 8, 0).millisecondsSinceEpoch});
    });
  });

  group('running', () {
    late HomeStore store;
    late Map<String, String> claimed;

    setUp(() async {
      claimed = {};
      store = HomeStore(
        repository: MemoryHomeRepository(),
        client: MockClient((_) async => http.Response('', 500)),
        claimRun: (scene, slot) async {
          if (claimed[scene] == slot) return false;
          claimed[scene] = slot;
          return true;
        },
      );
      await store.load();
    });

    tearDown(() => store.dispose());

    Scene fanOn() {
      final fan = store.devices.firstWhere((d) => d.name == 'Bath fan');
      return store.addScene('Fan on', [fan])
        ..actions = [SceneAction(deviceId: fan.id, command: const DeviceCommand(on: true))]
        ..schedule = SceneSchedule(hour: 7, minute: 0, days: {4});
    }

    bool fanIsOn() => store.devices.firstWhere((d) => d.name == 'Bath fan').state.on == true;

    test('an alarm runs its scene once, even if it goes off twice', () async {
      final s = fanOn();
      final alarm = SceneAlarms.idOf(s.id);
      expect(await runDueAlarm(store, alarm, thursday7.add(const Duration(seconds: 1))), isTrue);
      expect(fanIsOn(), isTrue);
      expect(await runDueAlarm(store, alarm, thursday7.add(const Duration(seconds: 20))), isFalse);
    });

    test('an alarm at the wrong time or for a deleted scene does nothing', () async {
      final s = fanOn();
      expect(await runDueAlarm(store, SceneAlarms.idOf(s.id), DateTime(2026, 10, 15, 9, 0)), isFalse);
      expect(await runDueAlarm(store, SceneAlarms.idOf('gone'), thursday7), isFalse);
      expect(fanIsOn(), isFalse);
    });

    test('the open app skips a run the alarm already did', () async {
      final s = fanOn();
      claimed[s.id] = SceneSchedule.slot(thursday7);
      store.runDueScenes(thursday7);
      await Future<void>.delayed(Duration.zero);
      expect(fanIsOn(), isFalse);
    });
  });
}
