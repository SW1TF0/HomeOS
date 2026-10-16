import 'package:flutter/material.dart';

import 'app.dart';
import 'state/home_store.dart';
import 'state/repository.dart';
import 'state/scene_alarms.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = HomeStore(repository: LocalHomeRepository(), claimRun: SceneAlarms.supported ? claimSceneRun : null);
  await store.load();
  if (SceneAlarms.supported) SceneAlarms().follow(store);
  runApp(SmartMenuApp(store: store));
}

/// Started by Android without a screen when a timed scene is due (see SceneAlarmReceiver.kt).
@pragma('vm:entry-point')
Future<void> sceneAlarmMain(List<String> args) => runSceneAlarm(args);
