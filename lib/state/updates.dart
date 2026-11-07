import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';

/// Asks GitHub, at most twice a day, whether a newer SmartHomeKJ is out, so the home screen can offer it.
class UpdateCheck extends ChangeNotifier {
  UpdateCheck({http.Client? client, this.current = appVersion, UpdatePlatform? platform})
      : _client = client ?? http.Client(),
        platform = platform ?? UpdatePlatform.here,
        enabled = true;

  /// One that never asks (tests, and builds that are not ours).
  UpdateCheck.off({this.current = appVersion, UpdatePlatform? platform})
      : _client = null,
        platform = platform ?? UpdatePlatform.here,
        enabled = false;

  final http.Client? _client;
  final bool enabled;
  final String current;
  final UpdatePlatform platform;

  static const _key = 'smartmenukj.updates.v1';
  static const every = Duration(hours: 12);
  static const releasesApi = 'https://api.github.com/repos/SW1TF0/HomeOS/releases/latest';
  static const allDownloads = '$appSourceUrl/releases/latest';

  /// The newest version GitHub has, as "1.18.0", once asked.
  String? latest;
  DateTime? checkedAt;

  /// The version the person said "Later" to; it is not offered again, a newer one is.
  String? skipped;

  bool checking = false;

  /// A newer version than this one is out and was not put off.
  bool get offer => latest != null && isNewer(latest!, current) && latest != skipped;

  /// The newest version is this one.
  bool get upToDate => latest != null && !isNewer(latest!, current);

  /// Where this phone or computer downloads the newest version; the page of every download elsewhere.
  String get downloadUrl => platform.asset == null ? allDownloads : '$appSourceUrl/releases/latest/download/${platform.asset}';

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      latest = j['latest'] as String?;
      skipped = j['skipped'] as String?;
      final at = j['at'];
      if (at is int) checkedAt = DateTime.fromMillisecondsSinceEpoch(at);
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      (await SharedPreferences.getInstance()).setString(
          _key,
          jsonEncode({
            'latest': ?latest,
            'skipped': ?skipped,
            if (checkedAt != null) 'at': checkedAt!.millisecondsSinceEpoch,
          }));
    } catch (_) {}
  }

  /// Asks GitHub unless it was asked lately; [now] asks anyway (Settings > Check for updates). False when GitHub
  /// could not be reached.
  Future<bool> check({bool now = false}) async {
    final client = _client;
    if (!enabled || client == null || checking) return false;
    if (!now && checkedAt != null && clock.now().difference(checkedAt!) < every) return true;
    checking = true;
    notifyListeners();
    try {
      final r = await client.get(Uri.parse(releasesApi),
          headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return false;
      final tag = (jsonDecode(r.body) as Map<String, dynamic>)['tag_name'] as String?;
      final v = tag == null ? null : versionOf(tag);
      if (v == null) return false;
      latest = v;
      checkedAt = clock.now();
      unawaited(_save());
      return true;
    } catch (e) {
      debugPrint('Update check: $e');
      return false;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  void later() {
    skipped = latest;
    notifyListeners();
    unawaited(_save());
  }

  /// "v1.18.0" → "1.18.0"; null for tags that are not a version (the native apps' "native-latest").
  static String? versionOf(String tag) {
    final m = RegExp(r'^v?(\d+(?:\.\d+){1,3})$').firstMatch(tag.trim());
    return m?.group(1);
  }

  /// Whether [a] is a later version than [b]: 1.18.0 after 1.9.2.
  static bool isNewer(String a, String b) {
    List<int> parts(String v) => [for (final p in v.split('.')) int.tryParse(p) ?? 0];
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 4; i++) {
      final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
      if (p != q) return p > q;
    }
    return false;
  }
}

/// Which download fits the device the app runs on.
enum UpdatePlatform {
  android('SmartMenuKJ-android.apk'),
  windows('SmartMenuKJ-windows.zip'),
  macos('SmartMenuKJ-macos.zip'),
  linux('SmartMenuKJ-linux.tar.gz'),
  other(null);

  const UpdatePlatform(this.asset);
  final String? asset;

  static UpdatePlatform get here {
    if (kIsWeb) return other;
    if (Platform.isAndroid) return android;
    if (Platform.isWindows) return windows;
    if (Platform.isMacOS) return macos;
    if (Platform.isLinux) return linux;
    return other;
  }
}
