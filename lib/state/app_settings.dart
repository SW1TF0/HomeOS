import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/haptics.dart';

/// Choices for the app on this device, the same in every home. The theme is
/// kept by the home store, as it always was.
class AppSettings extends ChangeNotifier {
  AppSettings({this.storageKey = 'smartmenukj.settings.v1'});

  final String storageKey;

  /// 24-hour clock on the home screen, or 12-hour with AM / PM.
  bool get clock24 => _clock24;
  bool _clock24 = true;
  set clock24(bool v) => _set(() => _clock24 = v);

  /// Clicks felt while sliding, dragging and holding.
  bool get haptics => _haptics;
  bool _haptics = true;
  set haptics(bool v) => _set(() => Haptics.enabled = _haptics = v);

  /// The tab the app opens on: 0 home, 1 map, 2 devices.
  int get startTab => _startTab;
  int _startTab = 0;
  set startTab(int v) => _set(() => _startTab = v.clamp(0, 2));

  /// How often devices are asked what they are doing, in seconds.
  int get checkSeconds => _checkSeconds;
  int _checkSeconds = 10;
  set checkSeconds(int v) => _set(() => _checkSeconds = v.clamp(2, 600));

  static const checkChoices = [5, 10, 30, 60];

  Duration get checkEvery => Duration(seconds: _checkSeconds);

  void _set(void Function() change) {
    change();
    notifyListeners();
    _save();
  }

  Map<String, Object?> toJson() =>
      {'clock24': _clock24, 'haptics': _haptics, 'startTab': _startTab, 'checkSeconds': _checkSeconds};

  void _read(Map<String, dynamic> j) {
    _clock24 = j['clock24'] as bool? ?? true;
    _haptics = j['haptics'] as bool? ?? true;
    _startTab = ((j['startTab'] as num?)?.toInt() ?? 0).clamp(0, 2);
    _checkSeconds = ((j['checkSeconds'] as num?)?.toInt() ?? 10).clamp(2, 600);
    Haptics.enabled = _haptics;
  }

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(storageKey);
      if (raw != null) _read(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Settings could not be read: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(storageKey, jsonEncode(toJson()));
    } catch (e) {
      debugPrint('Settings could not be saved: $e');
    }
  }
}
