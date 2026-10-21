import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../models/scene.dart';
import 'home_store.dart';

/// The SmartHomeKJ widget on the Android home screen (ScenesWidget.kt): the open home's first scenes and All off.
/// The All off tile in Quick Settings (AllOffTile.kt) comes through here too.
class ScenesWidget {
  const ScenesWidget([this.channel = const MethodChannel('smartmenukj/widget')]);
  final MethodChannel channel;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// How many scenes the widget has room for.
  static const shown = 4;

  /// What the widget shows for the open home.
  static Map<String, Object?> contentOf(HomeStore store) => {
        'home': store.homeName,
        'scenes': [
          for (final s in store.data.scenes.take(shown)) {'id': s.id, 'name': s.name},
        ],
      };

  /// Keeps the widget in step with the open home, and does what is tapped on it while the app runs.
  void follow(HomeStore store) {
    String? sent;
    void check() {
      if (!store.loaded) return;
      final content = contentOf(store);
      final key = jsonEncode(content);
      if (key == sent) return;
      sent = key;
      channel.invokeMethod<void>('show', content).catchError((Object e) => debugPrint('Widget: $e'));
    }

    store.addListener(check);
    check();
    channel.setMethodCallHandler((call) async {
      if (call.method != 'run') throw MissingPluginException();
      final args = call.arguments is Map ? call.arguments as Map : const {};
      return runTapped(store, args['scene'] as String?)
          .timeout(const Duration(seconds: 7), onTimeout: () => 'Sent. Some devices are slow to answer.');
    });
  }

  /// Puts the widget on the home screen, where the launcher lets apps do that. False when it has to be added by hand.
  Future<bool> pin() async => await channel.invokeMethod<bool>('pin') ?? false;

  /// Offers to add the All off tile to Quick Settings (Android 13 and later). False when it has to be added by hand.
  Future<bool> addTile() async => await channel.invokeMethod<bool>('tile') ?? false;
}

/// Does what was tapped on the widget: the scene with [sceneId], or All off when it is null. With [anyHome] (when the
/// app is not running) the scene's home is opened first when it is not the open one. Returns what to say after it.
Future<String> runTapped(HomeStore store, String? sceneId, {bool anyHome = false}) async {
  if (sceneId == null) {
    final devices = store.devices.where(HomeStore.switchedTogether).toList();
    if (devices.isEmpty) return 'Nothing to switch off.';
    final ok = (await Future.wait([for (final d in devices) store.command(d, const DeviceCommand(on: false))]))
        .where((r) => r)
        .length;
    return ok == devices.length ? 'Everything is off.' : '${devices.length - ok} of ${devices.length} did not answer.';
  }
  bool isIt(Scene s) => s.id == sceneId;
  if (anyHome && !store.data.scenes.any(isIt)) {
    final home = store.otherScenes.entries.where((e) => e.value.any(isIt)).firstOrNull?.key;
    if (home != null) {
      await store.openHome(home);
      await store.whenStarted(timeout: const Duration(seconds: 3));
    }
  }
  final scene = store.data.scenes.where(isIt).firstOrNull;
  if (scene == null) {
    return store.allScenes.any(isIt) ? 'That scene is in another home. Open it in SmartHomeKJ first.' : 'That scene is gone.';
  }
  final ok = await store.runScene(scene, quiet: true);
  final total = scene.actions.where((a) => store.device(a.deviceId) != null).length;
  return ok == total ? '${scene.name}: done.' : '${scene.name}: ${total - ok} of $total did not answer.';
}
