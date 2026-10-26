import 'package:flutter/services.dart';

/// Clicks felt in the hand while sliding, dragging and holding, unless turned off in Settings.
class Haptics {
  static bool enabled = true;

  static Future<void> selectionClick() => enabled ? HapticFeedback.selectionClick() : Future.value();
  static Future<void> mediumImpact() => enabled ? HapticFeedback.mediumImpact() : Future.value();
  static Future<void> heavyImpact() => enabled ? HapticFeedback.heavyImpact() : Future.value();
}
