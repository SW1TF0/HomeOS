// Opens every screen of the app as each platform would show it, on a phone and on a computer, so a change made
// and checked on one computer (a Mac) cannot quietly break another (Windows, Linux, Android).
//
// Flutter draws the same widgets everywhere, but some behave differently by platform: scrolling, text selection,
// keyboard focus, menus, back buttons, page transitions, scrollbars on desktops. Each test here sets the platform
// with debugDefaultTargetPlatformOverride; any exception, overflow or missing widget fails it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/platform/platform.dart';
import 'package:smartmenukj/state/updates.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/screens/device_sheet.dart';
import 'package:smartmenukj/ui/screens/diagnostics_screen.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/util/app_log.dart';

final _platforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
});

const _sizes = {'phone': Size(390, 844), 'desktop': Size(1280, 800)};

Future<HomeStore> _pump(WidgetTester tester, Size size, {double textScale = 1}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
  await store.load();
  await tester.pumpWidget(SmartMenuApp(store: store, poll: false));
  await tester.pumpAndSettle();
  return store;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  // Only what was opened on top: some buttons (an account without a cloud) open nothing.
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  if (navigator.canPop()) navigator.pop();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    {
      testWidgets('$name: every tab and page opens without errors', variant: _platforms, (tester) async {
        final store = await _pump(tester, size);

        for (final tab in ['rooms', 'automate', 'more', 'home']) {
          await tester.tap(find.byKey(Key('tab-$tab')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $tab');
        }

        // Every page in More, and back.
        for (final key in ['more-devices', 'more-connect', 'more-settings', 'more-diagnostics']) {
          await tester.tap(find.byKey(const Key('tab-more')));
          await tester.pumpAndSettle();
          await _tap(tester, find.byKey(Key(key)));
          expect(find.byKey(Key(key)).hitTestable(), findsNothing, reason: '$key opened a page on top');
          await _back(tester);
        }
        for (final key in ['more-activity', 'more-homes', 'more-weather', 'more-help', 'more-account']) {
          await tester.tap(find.byKey(const Key('tab-more')));
          await tester.pumpAndSettle();
          await _tap(tester, find.byKey(Key(key)));
          await _back(tester);
        }

        // The controls of every kind of device in the sample home.
        await tester.tap(find.byKey(const Key('tab-home')));
        await tester.pumpAndSettle();
        final ctx = tester.element(find.byType(HomeScreen));
        final seen = <Object>{};
        for (final d in store.devices.where((d) => seen.add(d.kind))) {
          // ignore: unawaited_futures
          showDeviceSheet(ctx, d);
          await tester.pumpAndSettle();
          await _back(tester);
        }

        // Narrowing the home list to a room and back.
        final room = store.rooms.first;
        await _tap(tester, find.byKey(Key('room-filter-${room.id}')));
        expect(find.byKey(Key('room-card-${room.id}')), findsOneWidget);
        // Tapping the picked room again shows everything again.
        await _tap(tester, find.byKey(Key('room-filter-${room.id}')));
        expect(find.text('Favourites'), findsOneWidget);
      });
    }
  }

  {
    testWidgets('a tap on a device row switches it, on every platform', variant: _platforms, (tester) async {
      final store = await _pump(tester, _sizes['phone']!);
      final light = store.devices.firstWhere((d) => d.name == 'Ceiling light');
      final before = light.state.on;
      await tester.tap(find.text('Ceiling light').first);
      await tester.pumpAndSettle();
      expect(light.state.on, isNot(before));
    });
  }

  // Windows laptops usually scale the screen by 125%, 150% or 175%: hairlines and rounding look different there.
  for (final scale in [1.0, 1.25, 1.5, 1.75]) {
    testWidgets('Windows at ${(scale * 100).round()}% screen scaling: every tab draws without overflow',
        variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      tester.view.physicalSize = const Size(1366, 768) * scale;
      tester.view.devicePixelRatio = scale;
      addTearDown(tester.view.reset);
      final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
      await store.load();
      await tester.pumpWidget(SmartMenuApp(store: store, poll: false));
      await tester.pumpAndSettle();
      for (final tab in ['rooms', 'automate', 'more', 'home']) {
        await tester.tap(find.byKey(Key('tab-$tab')));
        await tester.pumpAndSettle();
      }
    });
  }

  group('platform profiles', () {
    test('only Android runs in the background, keeps a widget, timed scenes, backups and RTSP', () {
      for (final os in AppOS.values) {
        final p = AppPlatform.of(os);
        final android = os == AppOS.android;
        expect([p.keepsRunningInBackground, p.homeScreenWidget, p.timedSceneAlarms, p.backupFolder, p.playsRtsp],
            everyElement(android), reason: os.name);
      }
    });

    test('Windows waits long enough to hear a connection turned down; the others do not wait longer', () {
      const usual = Duration(milliseconds: 600);
      expect(AppPlatform.of(AppOS.windows).connectWait(usual), greaterThanOrEqualTo(const Duration(seconds: 2)));
      for (final os in [AppOS.macos, AppOS.linux, AppOS.android, AppOS.ios]) {
        expect(AppPlatform.of(os).connectWait(usual), usual, reason: os.name);
      }
    });

    test('a refused connection is recognised by each system\'s own error code', () {
      expect(AppPlatform.of(AppOS.windows).connectionRefused(1225), isTrue, reason: 'what Windows really reports');
      expect(AppPlatform.of(AppOS.windows).connectionRefused(10061), isTrue);
      expect(AppPlatform.of(AppOS.linux).connectionRefused(111), isTrue);
      expect(AppPlatform.of(AppOS.macos).connectionRefused(61), isTrue);
      expect(AppPlatform.of(AppOS.windows).connectionRefused(10060), isFalse, reason: 'a timeout is not a refusal');
    });

    test('each computer downloads its own update', () {
      for (final (os, update) in [
        (AppOS.android, UpdatePlatform.android),
        (AppOS.windows, UpdatePlatform.windows),
        (AppOS.macos, UpdatePlatform.macos),
        (AppOS.linux, UpdatePlatform.linux),
      ]) {
        expect(AppPlatform.of(os).downloadAsset, update.asset, reason: os.name);
      }
      expect(AppPlatform.of(AppOS.ios).downloadAsset, isNull);
    });

    test('desktops are desktops', () {
      expect(AppOS.values.where((o) => AppPlatform.of(o).isDesktop), {AppOS.macos, AppOS.windows, AppOS.linux});
    });
  });

  testWidgets('Diagnostics can make the app pretend to be Windows, and back', (tester) async {
    await _pump(tester, _sizes['phone']!);
    addTearDown(() => AppPlatform.pretend(null));
    await tester.tap(find.byKey(const Key('tab-more')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('more-diagnostics')));
    await tester.scrollUntilVisible(find.byKey(const Key('pretend-windows')), 200,
        scrollable: find.byType(Scrollable).last);
    await _tap(tester, find.byKey(const Key('pretend-windows')));
    expect(AppPlatform.pretending, AppOS.windows);
    expect(defaultTargetPlatform, TargetPlatform.windows);
    expect(Theme.of(tester.element(find.byKey(const Key('tab-home')))).platform, TargetPlatform.windows);
    AppPlatform.pretend(null);
    await tester.pumpAndSettle();
    expect(AppPlatform.pretending, isNull);
  });

  testWidgets('big text (130%) still fits on a phone', (tester) async {
    await _pump(tester, _sizes['phone']!, textScale: 1.3);
    for (final tab in ['rooms', 'automate', 'more', 'home']) {
      await tester.tap(find.byKey(Key('tab-$tab')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('diagnostics shows the system, a failed device and the log, and copies a report',
      variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    final store = await _pump(tester, _sizes['phone']!);
    AppLog.instance.clear();
    AppLog.error('test', 'Something broke on purpose');
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    store.lastErrors[tv.id] = (at: DateTime(2026), error: 'Connection refused');

    await tester.tap(find.byKey(const Key('tab-more')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 error'), findsOneWidget, reason: 'More says something went wrong');
    await _tap(tester, find.byKey(const Key('more-diagnostics')));
    expect(find.byKey(const Key('diagnostics-system')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('diagnostics-system')), matching: find.text('windows')), findsWidgets,
        reason: 'the platform the app looks like');

    final ctx = tester.element(find.byType(DiagnosticsScreen));
    final report = diagnosticsReport(ctx);
    expect(report, contains('Look: windows'));
    expect(report, contains('TV'));
    expect(report, contains('Connection refused'));
    expect(report, contains('Something broke on purpose'));

    await tester.scrollUntilVisible(find.byKey(Key('diagnostics-device-${tv.id}')), 200,
        scrollable: find.byType(Scrollable).last);
    await _tap(tester, find.byKey(Key('diagnostics-device-${tv.id}')));
    expect(find.byKey(const Key('raw-device')), findsOneWidget);
    expect(find.textContaining('"integrationId"'), findsOneWidget);
    await _back(tester);

    await tester.scrollUntilVisible(find.byKey(const Key('diagnostics-log')), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Something broke on purpose'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('diagnostics-clear')));
    expect(AppLog.instance.entries, isEmpty);
  });

  test('the log keeps the newest lines and says how serious each is', () {
    final log = AppLog.instance..clear();
    for (var i = 0; i < AppLog.capacity + 20; i++) {
      AppLog.info('test', 'line $i');
    }
    expect(log.entries.length, AppLog.capacity);
    expect(log.entries.first.message, 'line 20');
    AppLog.error('test', 'bad', StackTrace.current);
    expect(log.errorCount, 1);
    expect(log.entries.last.toString(), contains('ERR [test] bad'));
    log.clear();
  });

  test('messages shown to the user land in the log too', () async {
    AppLog.instance.clear();
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    store.toast('Hello');
    expect(AppLog.instance.entries.last.message, 'Hello');
    expect(AppLog.instance.entries.last.source, 'message');
    store.dispose();
  });
}
