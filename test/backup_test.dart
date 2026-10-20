import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/models/automation.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/app_settings.dart';
import 'package:smartmenukj/state/backup_files.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

/// Backup files without Android: written files are kept in memory, and the picked file is [file].
class FakeBackups extends BackupFiles {
  FakeBackups({this.file}) : super(available: true);
  String? file;
  final writes = <String>[];
  int kept = 0;

  @override
  Future<bool> write(String text) async {
    writes.add(text);
    return true;
  }

  @override
  Future<String?> pick() async => file;

  @override
  Future<void> keepPicked() async => kept++;
}

HomeStore newStore(HomeRepository repo) =>
    HomeStore(repository: repo, client: MockClient((_) async => http.Response('', 500)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a backup of every home', () {
    test('brings back every home on a new install, without device states or account links', () async {
      final old = newStore(MemoryHomeRepository());
      await old.load();
      final lamp = old.devices.firstWhere((d) => d.name == 'Bedside lamp');
      await old.command(lamp, const DeviceCommand(on: true));
      old.addAutomation(Automation(
          id: 'auto-1',
          trigger: AutomationTrigger(deviceId: lamp.id, kind: TriggerKind.turnsOn),
          then: AutomationStep.device(lamp.id, on: false, offAfter: 10)));
      old.homes.first
        ..cloudId = 'cloud-1'
        ..account = 'someone'
        ..hub = true;
      final cabin = await old.addHome('Cabin');
      old.addRoom(old.floors.first.id, name: 'Loft');
      final backup = await old.exportAll();
      expect(backup['current'], cabin.id);
      final text = jsonEncode(backup);
      expect(text, isNot(contains('"state"')));
      expect(text, isNot(contains('cloud-1')));

      final repo = MemoryHomeRepository();
      final fresh = newStore(repo);
      await fresh.load();
      expect(await fresh.importAll(text), 2);
      expect([for (final h in fresh.homes) h.name], ['My home', 'Cabin']);
      expect(fresh.homes.first.cloudId, isNull);
      expect(fresh.homes.first.hub, isFalse);
      expect(fresh.homeId, cabin.id, reason: 'the home that was open opens');
      expect(fresh.rooms.map((r) => r.name), ['Loft']);

      // Everything was saved on the new install, and the other home is back with its automation.
      final reopened = newStore(repo);
      await reopened.load();
      expect(reopened.homes.length, 2);
      await reopened.openHome(firstHomeId);
      expect(reopened.devices.map((d) => d.name), contains('Bedside lamp'));
      expect(reopened.automations.single.then.offAfter, 10);
      for (final s in [old, fresh, reopened]) {
        s.dispose();
      }
    });

    test('replaces the homes already there; a backup of one home replaces the open one', () async {
      final repo = MemoryHomeRepository();
      final store = newStore(repo);
      await store.load();
      final office = await store.addHome('Office');
      final one = newStore(MemoryHomeRepository());
      await one.load();
      one.addRoom(one.floors.first.id, name: 'Garage');
      final all = jsonEncode(await one.exportAll());

      expect(await store.importAll(all), 1);
      expect(store.homes.map((h) => h.id), [firstHomeId]);
      expect(await repo.load(office.id), isNull, reason: 'a home that is not in the backup goes');

      store.addRoom(store.floors.first.id, name: 'Shed');
      final single = store.exportJson();
      store.removeRoom(store.rooms.firstWhere((r) => r.name == 'Shed'));
      expect(HomeStore.isAllHomes(single), isFalse);
      expect(await store.importAll(single), 1);
      expect(store.rooms.map((r) => r.name), contains('Shed'));

      await expectLater(store.importAll('{"backup": "homes", "homes": []}'), throwsFormatException);
      await expectLater(store.importAll('not a backup'), throwsFormatException);
      expect(store.rooms.map((r) => r.name), contains('Shed'), reason: 'a bad file changes nothing');
      store.dispose();
      one.dispose();
    });
  });

  group('the backup file', () {
    testWidgets('is written soon after a change, and not again when nothing that is kept changed', (tester) async {
      final backups = FakeBackups();
      final settings = AppSettings();
      final store = newStore(backups.watch(MemoryHomeRepository()));
      await store.load();
      backups.follow(store, settings);
      await tester.pump(const Duration(seconds: 11));
      expect(backups.writes.length, 1, reason: 'the first copy, right after the app starts');
      final first = jsonDecode(backups.writes.single) as Map<String, dynamic>;
      expect((first['app'], first['backup']), ('SmartHomeKJ', 'homes'));
      expect(first['saved'], isA<String>());
      expect(backups.savedAt, isNotNull);

      await store.command(store.devices.firstWhere((d) => d.name == 'Desk lamp'), const DeviceCommand(on: true));
      await tester.pump(const Duration(seconds: 11));
      expect(backups.writes.length, 1, reason: 'a lamp turning on is not kept in the file');

      store.addRoom(store.floors.first.id, name: 'Attic');
      await tester.pump(const Duration(seconds: 1));
      store.addRoom(store.floors.first.id, name: 'Cellar');
      await tester.pump(const Duration(seconds: 11));
      expect(backups.writes.length, 2, reason: 'two changes close together write once');
      expect(backups.writes.last, contains('Cellar'));

      settings.autoBackup = false;
      store.addRoom(store.floors.first.id, name: 'Porch');
      await tester.pump(const Duration(seconds: 11));
      expect(backups.writes.length, 2, reason: 'switched off');
      settings.autoBackup = true;
      await tester.pump(const Duration(seconds: 11));
      expect(backups.writes.length, 3);
      expect(backups.writes.last, contains('Porch'));
      store.dispose();
    });

    testWidgets('a new install offers to take the homes back from it', (tester) async {
      tester.view.physicalSize = const Size(420, 900) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final old = newStore(MemoryHomeRepository());
      await old.load();
      old.addRoom(old.floors.first.id, name: 'Workshop');
      await old.addHome('Cabin');
      final backups = FakeBackups(file: jsonEncode(await old.exportAll()));
      old.dispose();

      final store = newStore(MemoryHomeRepository());
      await store.load();
      final settings = AppSettings();
      await tester.pumpWidget(SmartMenuApp(store: store, poll: false, settings: settings, backups: backups));
      await tester.pump();
      expect(find.byKey(const Key('restore-backup')), findsOneWidget);
      expect(find.text('Had this app before?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('restore-pick')));
      await tester.pumpAndSettle();
      expect(store.homes.map((h) => h.name), ['My home', 'Cabin']);
      expect(find.text('2 homes restored.'), findsOneWidget);
      expect(backups.kept, 1, reason: 'later copies go into the file that was picked');
      expect(find.byKey(const Key('restore-backup')), findsNothing);
      expect(settings.restoreAsked, isTrue);
    });

    testWidgets('settings switch the file off, and restore from one after asking', (tester) async {
      tester.view.physicalSize = const Size(420, 900) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final old = newStore(MemoryHomeRepository());
      await old.load();
      await old.renameHome(old.homes.first, 'Flat');
      final backups = FakeBackups(file: jsonEncode(await old.exportAll()));
      old.dispose();
      final store = newStore(MemoryHomeRepository());
      await store.load();
      final settings = AppSettings();
      await tester.pumpWidget(SmartMenuApp(store: store, poll: false, settings: settings, backups: backups));
      await tester.pump();
      await tester.tap(find.byKey(const Key('profile-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-settings')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('settings-restore-file')), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Downloads/SmartHomeKJ'), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings-backup-file')));
      await tester.pumpAndSettle();
      expect(settings.autoBackup, isFalse);

      await tester.tap(find.byKey(const Key('settings-restore-file')));
      await tester.pumpAndSettle();
      expect(find.text('Restore from a file?'), findsOneWidget);
      await tester.tap(find.text('Pick file'));
      await tester.pumpAndSettle();
      expect(store.homeName, 'Flat');
      expect(find.text('Home restored.'), findsOneWidget);
    });

    testWidgets('the offer goes away for good with No thanks, and is not made once the home is set up', (tester) async {
      tester.view.physicalSize = const Size(420, 900) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final store = newStore(MemoryHomeRepository());
      await store.load();
      final settings = AppSettings();
      await tester.pumpWidget(SmartMenuApp(store: store, poll: false, settings: settings, backups: FakeBackups()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('restore-later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restore-backup')), findsNothing);

      settings.restoreAsked = false;
      store.addScene('Evening', [store.devices.first], turnOn: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restore-backup')), findsNothing, reason: 'this home is in use');

      // Without a backup file (on a computer) there is no offer at all.
      final computer = newStore(MemoryHomeRepository());
      await computer.load();
      await tester.pumpWidget(SmartMenuApp(store: computer, poll: false));
      await tester.pump();
      expect(find.byKey(const Key('restore-backup')), findsNothing);
    });
  });
}
