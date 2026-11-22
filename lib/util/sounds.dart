import 'package:flutter/services.dart';
import '../platform/platform.dart';

/// Short sounds for taps, switching things on and off and running scenes,
/// unless turned off in Settings. Played by Android (UiSounds.kt); elsewhere
/// a tap is the system click and the rest stay quiet.
class Sounds {
  static bool enabled = true;

  static const _channel = MethodChannel('smartmenukj/sounds');

  /// Buttons, tabs, chips and cards.
  static void tap() => _play('tap');

  /// A level set by sliding, or a choice picked.
  static void tick() => _play('tick');

  /// Something switched on, or off.
  static void power(bool on) => _play(on ? 'on' : 'off');

  /// A scene ran.
  static void scene() => _play('scene');

  static void _play(String name) {
    if (!enabled) return;
    final platform = AppPlatform.current;
    if (platform.appSounds) {
      _channel.invokeMethod<void>('play', name).catchError((Object _) {});
    } else if (name == 'tap' && platform.clickOnTap) {
      SystemSound.play(SystemSoundType.click);
    }
  }
}
