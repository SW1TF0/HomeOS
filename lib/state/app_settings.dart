import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../util/haptics.dart';
import '../util/sounds.dart';

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

  /// Sounds for taps, switching things on and off and running scenes.
  bool get sounds => _sounds;
  bool _sounds = true;
  set sounds(bool v) => _set(() => Sounds.enabled = _sounds = v);

  /// The tab the app opens on: 0 home, 1 map, 2 devices.
  int get startTab => _startTab;
  int _startTab = 0;
  set startTab(int v) => _set(() => _startTab = v.clamp(0, 2));

  /// How often devices are asked what they are doing, in seconds.
  int get checkSeconds => _checkSeconds;
  int _checkSeconds = 10;
  set checkSeconds(int v) => _set(() => _checkSeconds = v.clamp(2, 600));

  static const checkChoices = [5, 10, 30, 60];

  /// A copy of every home kept in a file on the phone, which stays when the app is uninstalled (BackupFiles).
  bool get autoBackup => _autoBackup;
  bool _autoBackup = true;
  set autoBackup(bool v) => _set(() => _autoBackup = v);

  /// Whether the offer to take the homes back from a backup file was answered, on a new install.
  bool get restoreAsked => _restoreAsked;
  bool _restoreAsked = false;
  set restoreAsked(bool v) => _set(() => _restoreAsked = v);

  /// Whether the white Apple look was switched on once for this device (1.16.0); dark stays a choice in Settings.
  bool get whiteLook => _whiteLook;
  bool _whiteLook = false;
  set whiteLook(bool v) => _set(() => _whiteLook = v);

  /// The app's language: 'auto' (the phone's), 'en' or 'bg'.
  String get language => _language;
  String _language = 'auto';
  set language(String v) => _set(() => L10n.use(_language = L10n.choices.containsKey(v) ? v : 'auto'));

  /// What the app calls the person using it: the home screen greets them by it. Empty when not given.
  String get name => _name;
  String _name = '';
  set name(String v) => _set(() => _name = v.trim().length > 40 ? v.trim().substring(0, 40) : v.trim());

  /// Whether the welcome screens were gone through once on this device.
  bool get welcomed => _welcomed;
  bool _welcomed = false;
  set welcomed(bool v) => _set(() => _welcomed = v);

  /// The opening animation, and screens and tiles gliding in.
  bool get animations => _animations;
  bool _animations = true;
  set animations(bool v) => _set(() => _animations = v);

  Duration get checkEvery => Duration(seconds: _checkSeconds);

  void _set(void Function() change) {
    change();
    notifyListeners();
    _save();
  }

  Map<String, Object?> toJson() => {
        'clock24': _clock24,
        'haptics': _haptics,
        'sounds': _sounds,
        'startTab': _startTab,
        'checkSeconds': _checkSeconds,
        'autoBackup': _autoBackup,
        'restoreAsked': _restoreAsked,
        'whiteLook': _whiteLook,
        'language': _language,
        'name': _name,
        'welcomed': _welcomed,
        'animations': _animations,
      };

  void _read(Map<String, dynamic> j) {
    _clock24 = j['clock24'] as bool? ?? true;
    _haptics = j['haptics'] as bool? ?? true;
    _startTab = ((j['startTab'] as num?)?.toInt() ?? 0).clamp(0, 2);
    _checkSeconds = ((j['checkSeconds'] as num?)?.toInt() ?? 10).clamp(2, 600);
    _autoBackup = j['autoBackup'] as bool? ?? true;
    _restoreAsked = j['restoreAsked'] as bool? ?? false;
    _whiteLook = j['whiteLook'] as bool? ?? false;
    _sounds = j['sounds'] as bool? ?? true;
    final lang = j['language'] as String? ?? 'auto';
    _language = L10n.choices.containsKey(lang) ? lang : 'auto';
    _name = j['name'] as String? ?? '';
    _welcomed = j['welcomed'] as bool? ?? false;
    _animations = j['animations'] as bool? ?? true;
    Haptics.enabled = _haptics;
    Sounds.enabled = _sounds;
  }

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(storageKey);
      if (raw != null) _read(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Settings could not be read: $e');
    }
    L10n.use(_language);
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
