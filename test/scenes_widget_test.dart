import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/state/scene_alarms.dart';
import 'package:smartmenukj/state/scenes_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late HomeStore store;
  setUp(() async {
    store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 500)));
    await store.load();
  });
  tearDown(() => store.dispose());

  Device named(String n) => store.devices.firstWhere((d) => d.name == n);

  /// Records what the app sends to the widget on [channel].
  List<MethodCall> record(MethodChannel channel) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return calls;
  }

  /// A tap on the widget while the app runs: Android asks the app to do it, and shows what it answers.
  Future<String?> tap(MethodChannel channel, String? scene) async {
    final reply = await messenger.handlePlatformMessage(
        channel.name, channel.codec.encodeMethodCall(MethodCall('run', {'scene': scene})), (_) {});
    return channel.codec.decodeEnvelope(reply!) as String?;
  }

  test('shows the open home\'s first four scenes, and changes only when they do', () async {
    const channel = MethodChannel('test/widget');
    final calls = record(channel);
    const ScenesWidget(channel).follow(store);
    expect(calls.single.method, 'show');
    expect(calls.single.arguments, {'home': 'My home', 'scenes': []});

    final names = ['Evening', 'Morning', 'Movie', 'Away', 'Party'];
    final scenes = [for (final n in names) store.addScene(n, [named('Floor lamp')], turnOn: true)];
    expect(calls.length, 5, reason: 'the fifth scene does not fit');
    expect((calls.last.arguments as Map)['scenes'], [
      for (final s in scenes.take(4)) {'id': s.id, 'name': s.name},
    ]);

    await store.command(named('Floor lamp'), const DeviceCommand(on: true));
    expect(calls.length, 5, reason: 'a lamp turning on changes nothing on the widget');
    store.moveScene(4, 0);
    expect(((calls.last.arguments as Map)['scenes'] as List).first, {'id': scenes[4].id, 'name': 'Party'});

    await store.addHome('Cabin');
    expect(calls.last.arguments, {'home': 'Cabin', 'scenes': []});
  });

  test('a tap runs the scene, or switches everything off, in the running app', () async {
    const channel = MethodChannel('test/widget-run');
    record(channel);
    const ScenesWidget(channel).follow(store);
    final kitchen = named('Kitchen lights');
    final evening = store.addScene('Evening', [kitchen], turnOn: true);

    expect(await tap(channel, evening.id), 'Evening: done.');
    expect(kitchen.state.on, isTrue);
    expect(store.message.value, isNot(contains('Evening')), reason: 'the widget says it, not the app');

    await store.command(named('TV'), const DeviceCommand(on: true));
    expect(await tap(channel, null), 'Everything is off.');
    expect(store.devices.where(HomeStore.switchedTogether).any((d) => d.state.on == true), isFalse);
    expect(named('Thermostat').state.on, isNot(false), reason: 'heating is left alone, as with All off');

    expect(await tap(channel, 'scene-gone'), 'That scene is gone.');
  });

  test('without the app running, a tap opens the scene\'s home first', () async {
    final fan = named('Bath fan');
    final scene = store.addScene('Fan', [fan], turnOn: true);
    await store.addHome('Office');
    expect(await runTapped(store, scene.id), 'That scene is in another home. Open it in SmartMenuKJ first.');
    expect(await runTapped(store, scene.id, anyHome: true), 'Fan: done.');
    expect(store.homeName, 'My home');
    expect(named('Bath fan').state.on, isTrue);
  });

  test('Android starts the app without a screen for a tap, and it says what happened', () async {
    SharedPreferences.setMockInitialValues({});
    final saved = HomeStore(repository: LocalHomeRepository(), client: MockClient((_) async => http.Response('', 500)));
    await saved.load();
    final scene = saved.addScene('Night', [saved.devices.firstWhere((d) => d.name == 'Kitchen lights')], turnOn: true);
    await saved.saveNow();
    saved.dispose();

    final calls = record(const MethodChannel('smartmenukj/alarms'));
    await runSceneAlarm(['scene', scene.id]);
    expect(calls.last.method, 'done');
    expect(calls.last.arguments, 'Night: done.');
    await runSceneAlarm(['alloff']);
    expect(calls.last.arguments, 'Everything is off.');
    await runSceneAlarm(['sync']);
    expect(calls.last.arguments, isNull, reason: 'nothing to say after booking the alarms');
  });
}
