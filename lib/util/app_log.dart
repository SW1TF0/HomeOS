import 'dart:async';
import 'dart:collection';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// How serious a log line is.
enum LogLevel { debug, info, warning, error }

/// One line in the app's log.
@immutable
class LogEntry {
  const LogEntry(this.time, this.level, this.source, this.message, [this.stack]);
  final DateTime time;
  final LogLevel level;

  /// Where it came from: "flutter", "device", "integration hue", "toast"...
  final String source;
  final String message;
  final String? stack;

  String get levelTag => switch (level) {
        LogLevel.debug => 'DBG',
        LogLevel.info => 'INF',
        LogLevel.warning => 'WRN',
        LogLevel.error => 'ERR',
      };

  @override
  String toString() {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}';
    return '$t $levelTag [$source] $message${stack == null ? '' : '\n$stack'}';
  }
}

/// The app's in-memory log: the last [capacity] lines, shown in Settings > Diagnostics and copied into bug reports.
///
/// Everything that goes wrong lands here: Flutter errors, uncaught async errors, failed device commands, failed
/// connections and the messages shown to the user. Nothing is written to disk or sent anywhere.
class AppLog extends ChangeNotifier {
  AppLog._();

  /// The one log of the running app.
  static final AppLog instance = AppLog._();

  static const capacity = 500;
  final _lines = ListQueue<LogEntry>();

  /// Oldest first.
  List<LogEntry> get entries => List.unmodifiable(_lines);

  int get errorCount => _lines.where((e) => e.level == LogLevel.error).length;

  void add(LogLevel level, String source, Object message, [StackTrace? stack]) {
    _lines.addLast(LogEntry(clock.now(), level, source, '$message', stack?.toString().trimRight()));
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
    // Logging can happen in the middle of a build (an error while laying out): tell listeners after it.
    scheduleMicrotask(notifyListeners);
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  static void debug(String source, Object message) => instance.add(LogLevel.debug, source, message);
  static void info(String source, Object message) => instance.add(LogLevel.info, source, message);
  static void warn(String source, Object message) => instance.add(LogLevel.warning, source, message);
  static void error(String source, Object message, [StackTrace? stack]) =>
      instance.add(LogLevel.error, source, message, stack);

  /// The whole log as text, newest last.
  String dump() => _lines.join('\n');

  /// Catches Flutter framework errors, uncaught async errors and debugPrint output, keeping the default
  /// behaviour (red screen in debug, console output) as it was. Call once, early in main().
  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      error('flutter', details.exceptionAsString(), details.stack);
      previous?.call(details);
    };
    final platformPrevious = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (e, stack) {
      error('uncaught', e, stack);
      return platformPrevious?.call(e, stack) ?? false;
    };
    final printPrevious = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) debug('print', message);
      printPrevious(message, wrapWidth: wrapWidth);
    };
  }
}
