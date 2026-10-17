import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'cloud/cloud_config.dart';
import 'cloud/cloud_sync.dart';
import 'cloud/firebase.dart';
import 'integrations/lan/net.dart';
import 'state/app_settings.dart';
import 'state/home_store.dart';
import 'state/repository.dart';
import 'state/scene_alarms.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings();
  await settings.load();
  final store = HomeStore(
    repository: LocalHomeRepository(),
    pollInterval: settings.checkEvery,
    claimRun: SceneAlarms.supported ? claimSceneRun : null,
    onHomeNetwork: hasHomeNetwork,
  );
  await store.load();
  if (SceneAlarms.supported) SceneAlarms().follow(store);
  final cloud = CloudSync(
    store: store,
    api: FirebaseClient(firebaseConfig),
    deviceName: await _deviceName(),
    onHubChanged: _keepRunning,
  );
  unawaited(cloud.start());
  runApp(SmartMenuApp(store: store, cloud: cloud, settings: settings));
}

const _hub = MethodChannel('smartmenukj/hub');

/// What this device is called when it keeps a home online: the phone's model, or the computer's name.
Future<String> _deviceName() async {
  try {
    if (!kIsWeb && Platform.isAndroid) return await _hub.invokeMethod<String>('name') ?? 'Android device';
    if (!kIsWeb) return Platform.localHostname;
  } catch (_) {}
  return 'Home device';
}

/// On Android a device that keeps a home online runs on in the background, with a notification saying so.
void _keepRunning(bool on) {
  if (kIsWeb || !Platform.isAndroid) return;
  _hub.invokeMethod<void>(on ? 'start' : 'stop').catchError((Object e) => debugPrint('Home device service: $e'));
}

/// Started by Android without a screen when a timed scene is due (see SceneAlarmReceiver.kt).
@pragma('vm:entry-point')
Future<void> sceneAlarmMain(List<String> args) => runSceneAlarm(args);
