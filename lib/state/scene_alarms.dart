import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/home.dart';
import '../models/scene.dart';
import 'home_store.dart';
import 'repository.dart';
import 'scenes_widget.dart';

/// Timed scenes that run even when the app is closed, on Android.
///
/// The app books the next run of every timed scene with Android's alarm
/// manager (SceneAlarms.kt). When one is due, Android starts the app's Dart
/// code without a screen ([runSceneAlarm]), which runs the scene and books
/// the next run.
class SceneAlarms {
  SceneAlarms([this._channel = const MethodChannel('smartmenukj/alarms')]);
  final MethodChannel _channel;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// The alarm number of a scene. A fixed hash, since String.hashCode may
  /// change between runs of the app.
  static int idOf(String sceneId) {
    var h = 0x811c9dc5;
    for (final c in sceneId.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }

  /// Alarm number to time (milliseconds since the epoch) of each timed scene's next run, and of each device timer.
  static Map<String, int> plan(Iterable<Scene> scenes, DateTime now, [Iterable<DeviceTimer> timers = const []]) => {
        for (final s in scenes)
          if (s.schedule?.nextAfter(now) case final next?) '${idOf(s.id)}': next.millisecondsSinceEpoch,
        for (final t in timers)
          if (t.at.isAfter(now)) '${timerAlarm(t.deviceId)}': t.at.millisecondsSinceEpoch,
      };

  /// The alarm number of a device's timer.
  static int timerAlarm(String deviceId) => idOf('timer:$deviceId');

  /// Books the next run of every timed scene and device timer, and cancels every other alarm.
  Future<void> sync(Iterable<Scene> scenes, [DateTime? now, Iterable<DeviceTimer> timers = const []]) =>
      _channel.invokeMethod<void>('sync', plan(scenes, now ?? DateTime.now(), timers));

  /// Keeps the alarms in step with the scenes of every home: now, and whenever a schedule changes.
  void follow(HomeStore store) {
    String? booked;
    void check() {
      final scenes = store.allScenes;
      final key = [
        for (final s in scenes)
          if (s.schedule != null) '${s.id} ${jsonEncode(s.schedule!.toJson())}',
        for (final t in store.timers) t.slot,
      ].join('|');
      if (key == booked) return;
      booked = key;
      sync(scenes, null, store.timers).catchError((Object e) => debugPrint('Scene alarms: $e'));
    }

    store.addListener(check);
    check();
  }
}

/// Lets a timed scene run once per [slot], whichever gets there first: the
/// open app or the alarm. They run in separate isolates, so this goes
/// through the shared preferences on disk.
Future<bool> claimSceneRun(String sceneId, String slot) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final key = 'smartmenukj.sceneRun.$sceneId';
    if (prefs.getString(key) == slot) return false;
    await prefs.setString(key, slot);
  } catch (e) {
    debugPrint('Scene run check: $e');
  }
  return true;
}

/// Runs the scene behind [alarm] if it is really due at [now] and has not run yet,
/// opening the home it belongs to when that is not the open one.
Future<bool> runDueAlarm(HomeStore store, int alarm, DateTime now) async {
  final timer = store.timers.where((t) => SceneAlarms.timerAlarm(t.deviceId) == alarm).firstOrNull;
  if (timer != null) {
    final late = now.difference(timer.at);
    if (late < const Duration(minutes: -1) || late > const Duration(minutes: 15)) return false;
    final claim = store.claimRun;
    if (claim != null && !await claim('timer-${timer.deviceId}', timer.slot)) return false;
    final d = store.device(timer.deviceId);
    final turn = d == null ? null : SceneAction.turn(d, timer.on);
    if (d == null || turn == null) return false;
    await store.whenStarted(timeout: const Duration(seconds: 3));
    await store.command(d, turn.command).timeout(const Duration(seconds: 5), onTimeout: () => false);
    return true;
  }
  bool isIt(Scene s) => SceneAlarms.idOf(s.id) == alarm;
  if (!store.data.scenes.any(isIt)) {
    final home = store.otherScenes.entries.where((e) => e.value.any(isIt)).firstOrNull?.key;
    if (home != null) await store.openHome(home);
  }
  final scene = store.data.scenes.where(isIt).firstOrNull;
  final run = scene?.schedule?.runNear(now);
  if (scene == null || run == null) return false;
  final claim = store.claimRun;
  if (claim != null && !await claim(scene.id, SceneSchedule.slot(run))) return false;
  await store.whenStarted(timeout: const Duration(seconds: 3));
  await store.runScene(scene, quiet: true).timeout(const Duration(seconds: 5), onTimeout: () => 0);
  return true;
}

/// Started by Android without a screen: `run <alarm>` when a scene's alarm
/// goes off, `sync` after the phone restarts, `scene <id>` or `alloff` for a
/// tap on the home-screen widget or the All off tile. It has about ten
/// seconds, and ends by telling Android it is done, with what to say.
Future<void> runSceneAlarm(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel('smartmenukj/alarms');
  HomeStore? store;
  String? said;
  try {
    store = HomeStore(repository: _ReadOnly(LocalHomeRepository()), claimRun: claimSceneRun, automate: false);
    await store.load();
    final alarm = args.length > 1 && args.first == 'run' ? int.tryParse(args[1]) : null;
    if (alarm != null) await runDueAlarm(store, alarm, DateTime.now());
    if (args.firstOrNull == 'scene' || args.firstOrNull == 'alloff') {
      await store.whenStarted(timeout: const Duration(seconds: 3));
      said = await runTapped(store, args.first == 'scene' ? args.elementAtOrNull(1) : null, anyHome: true)
          .timeout(const Duration(seconds: 5), onTimeout: () => 'Sent. Some devices are slow to answer.');
    }
    await SceneAlarms(channel).sync(store.allScenes, null, store.timers);
  } catch (e) {
    debugPrint('Scene alarm: $e');
  } finally {
    store?.dispose();
    try {
      await channel.invokeMethod<void>('done', said);
    } catch (_) {}
  }
}

/// Reads the saved homes but never writes them, so a run in the background
/// cannot overwrite a change made in the open app at the same moment, or
/// change which home the app opens.
class _ReadOnly implements HomeRepository {
  _ReadOnly(this.inner);
  final HomeRepository inner;

  @override
  Future<HomeList> homes() => inner.homes();

  @override
  Future<void> saveHomes(HomeList list) async {}

  @override
  Future<HomeData?> load(String homeId) => inner.load(homeId);

  @override
  Future<void> save(String homeId, HomeData data) async {}

  @override
  Future<void> remove(String homeId) async {}
}
