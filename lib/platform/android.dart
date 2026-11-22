import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// Android phones and tablets. Only Android fixes go here.
class AndroidProfile extends PlatformProfile {
  const AndroidProfile();

  static const _hub = MethodChannel('smartmenukj/hub');

  @override
  AppOS get os => AppOS.android;
  @override
  String get label => 'Android';

  @override
  bool get keepsRunningInBackground => true;
  @override
  bool get homeScreenWidget => true;
  @override
  bool get timedSceneAlarms => true;
  @override
  bool get backupFolder => true;
  @override
  bool get playsRtsp => true;
  @override
  bool get appSounds => true;
  @override
  String? get downloadAsset => 'SmartMenuKJ-android.apk';

  /// /proc/net/arp, closed to apps since Android 10, then `ip neigh`.
  @override
  Future<String?> readArpTable() async {
    try {
      final t = await File('/proc/net/arp').readAsString();
      if (t.split('\n').length > 1) return t;
    } on FileSystemException {
      // Android 10 and later.
    }
    final r = await Process.run('ip', ['neigh', 'show']).timeout(const Duration(seconds: 2));
    return '${r.stdout}';
  }

  @override
  Future<String> deviceName() async {
    try {
      return await _hub.invokeMethod<String>('name') ?? 'Android device';
    } catch (_) {
      return 'Android device';
    }
  }

  @override
  Future<void> keepRunning(bool on) =>
      _hub.invokeMethod<void>(on ? 'start' : 'stop').catchError((Object e) => debugPrint('Home device service: $e'));
}
