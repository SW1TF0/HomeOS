import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/home.dart';
import 'app_settings.dart';
import 'home_store.dart';
import 'repository.dart';

/// A copy of every home kept in a file on the phone, in Downloads/SmartHomeKJ. The file stays when the app is
/// uninstalled, so a new install can take the homes back from it. Android only (BackupFiles.kt); elsewhere the
/// backup is copied and pasted as text.
class BackupFiles extends ChangeNotifier {
  BackupFiles({
    this.available = false,
    this.channel = const MethodChannel('smartmenukj/backup'),
    this.wait = const Duration(seconds: 10),
  });

  /// For the device the app runs on.
  factory BackupFiles.here() => BackupFiles(available: !kIsWeb && Platform.isAndroid);

  /// Whether this device keeps a backup file.
  final bool available;
  final MethodChannel channel;

  /// How long after a change the file is written, so a run of changes writes it once.
  final Duration wait;

  /// When the file was last written, and whether the last try did not work.
  DateTime? savedAt;
  bool failed = false;

  /// Writes [text] to the backup file.
  Future<bool> write(String text) async => await channel.invokeMethod<bool>('save', {'text': text}) ?? false;

  /// Lets the owner pick a backup file, and reads it. Null when nothing was picked.
  Future<String?> pick() => channel.invokeMethod<String>('open');

  /// Writes later copies into the file that was just picked, instead of starting a new file next to it.
  Future<void> keepPicked() => channel.invokeMethod<void>('keep');

  void Function()? _soon;
  String? _written;

  /// Wraps [inner] so that every save of a home soon writes the file again.
  HomeRepository watch(HomeRepository inner) => _Watched(inner, () => _soon?.call());

  /// Keeps the file in step with [store]: soon after starting, and after every change that is saved.
  void follow(HomeStore store, AppSettings settings) {
    Timer? timer;
    Future<void> run() async {
      timer = null;
      if (!settings.autoBackup || !store.loaded) return;
      try {
        final backup = await store.exportAll();
        final body = jsonEncode(backup);
        if (body == _written) return;
        final text = const JsonEncoder.withIndent(' ')
            .convert({...backup, 'saved': clock.now().toUtc().toIso8601String()});
        final ok = await write(text);
        if (ok) {
          _written = body;
          savedAt = clock.now();
        }
        failed = !ok;
      } catch (e) {
        debugPrint('Backup file: $e');
        failed = true;
      }
      notifyListeners();
    }

    _soon = () => timer ??= Timer(wait, run);
    var on = settings.autoBackup;
    settings.addListener(() {
      if (settings.autoBackup == on) return;
      on = settings.autoBackup;
      if (on) _soon!();
    });
    _soon!();
  }

  /// Lets the owner pick a backup file and takes its homes back. Null when nothing was picked; throws when the file
  /// is not a backup.
  Future<int?> restore(HomeStore store) async {
    final raw = await pick();
    if (raw == null) return null;
    final count = await store.importAll(raw);
    if (HomeStore.isAllHomes(raw)) {
      try {
        await keepPicked();
      } catch (e) {
        debugPrint('Backup file: $e');
      }
    }
    _written = null;
    _soon?.call();
    return count;
  }
}

class _Watched implements HomeRepository {
  _Watched(this.inner, this.changed);
  final HomeRepository inner;
  final VoidCallback changed;

  @override
  Future<HomeList> homes() => inner.homes();

  @override
  Future<void> saveHomes(HomeList list) async {
    await inner.saveHomes(list);
    changed();
  }

  @override
  Future<HomeData?> load(String homeId) => inner.load(homeId);

  @override
  Future<void> save(String homeId, HomeData data) async {
    await inner.save(homeId, data);
    changed();
  }

  @override
  Future<void> remove(String homeId) async {
    await inner.remove(homeId);
    changed();
  }
}
