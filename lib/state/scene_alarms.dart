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

  /// Alarm number to time (milliseconds since the epoch) of each timed scene's next run.
  static Map<String, int> plan(Iterable<Scene> scenes, DateTime now) => {
        for (final s in scenes)
          if (s.schedule?.nextAfter(now) case final next?) '${idOf(s.id)}': next.millisecondsSinceEpoch,
      };

  /// Books the next run of every timed scene and cancels every other alarm.
  Future<void> sync(Iterable<Scene> scenes, [DateTime? now]) =>
      _channel.invokeMethod<void>('sync', plan(scenes, now ?? DateTime.now()));

  /// Keeps the alarms in step with the scenes: now, and whenever a schedule changes.
  void follow(HomeStore store) {
    String? booked;
    void check() {
      final key = [
        for (final s in store.data.scenes)
          if (s.schedule != null) '${s.id} ${jsonEncode(s.schedule!.toJson())}',
      ].join('|');
      if (key == booked) return;
      booked = key;
      sync(store.data.scenes).catchError((Object e) => debugPrint('Scene alarms: $e'));
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

/// Runs the scene behind [alarm] if it is really due at [now] and has not run yet.
Future<bool> runDueAlarm(HomeStore store, int alarm, DateTime now) async {
  final scene = store.data.scenes.where((s) => SceneAlarms.idOf(s.id) == alarm).firstOrNull;
  final run = scene?.schedule?.runNear(now);
  if (scene == null || run == null) return false;
  final claim = store.claimRun;
  if (claim != null && !await claim(scene.id, SceneSchedule.slot(run))) return false;
  await store.whenStarted(timeout: const Duration(seconds: 3));
  await store.runScene(scene, quiet: true).timeout(const Duration(seconds: 5), onTimeout: () => 0);
  return true;
}

/// Started by Android without a screen: `run <alarm>` when a scene's alarm
/// goes off, `sync` after the phone restarts. It has about ten seconds, and
/// ends by telling Android it is done.
Future<void> runSceneAlarm(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel('smartmenukj/alarms');
  HomeStore? store;
  try {
    store = HomeStore(repository: _ReadOnly(LocalHomeRepository()), claimRun: claimSceneRun);
    await store.load();
    final alarm = args.length > 1 && args.first == 'run' ? int.tryParse(args[1]) : null;
    if (alarm != null) await runDueAlarm(store, alarm, DateTime.now());
    await SceneAlarms(channel).sync(store.data.scenes);
  } catch (e) {
    debugPrint('Scene alarm: $e');
  } finally {
    store?.dispose();
    try {
      await channel.invokeMethod<void>('done');
    } catch (_) {}
  }
}

/// Reads the saved home but never writes it, so a run in the background
/// cannot overwrite a change made in the open app at the same moment.
class _ReadOnly implements HomeRepository {
  _ReadOnly(this.inner);
  final HomeRepository inner;

  @override
  Future<HomeData?> load() => inner.load();

  @override
  Future<void> save(HomeData data) async {}
}
