import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/l10n/bg.dart';
import 'package:smartmenukj/l10n/text.dart';
import 'package:smartmenukj/state/app_settings.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/screens/account_sheet.dart';
import 'package:smartmenukj/ui/screens/activity_sheet.dart';
import 'package:smartmenukj/ui/screens/anywhere_sheet.dart';
import 'package:smartmenukj/ui/screens/camera_sheet.dart';
import 'package:smartmenukj/ui/screens/homes_sheet.dart';
import 'package:smartmenukj/ui/screens/profile_menu.dart';
import 'package:smartmenukj/ui/screens/room_sheet.dart';
import 'package:smartmenukj/ui/screens/scenes.dart';
import 'package:smartmenukj/ui/screens/automations.dart';
import 'package:smartmenukj/ui/screens/device_sheet.dart';
import 'package:smartmenukj/ui/screens/help_sheet.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/ui/screens/settings_screen.dart';

/// Lines a screen shows that are names (of the sample home, brands, the app) or not words at all.
bool _notWords(String s) =>
    !RegExp(r'[A-Za-z]').hasMatch(s) ||
    RegExp(r'^[\d\s.,°%·+-]*[A-Za-zµ/³°]{0,6}$').hasMatch(s.trim()) ||
    RegExp(r'[А-Яа-я]').hasMatch(s) ||
    RegExp(r'^(SmartHomeKJ|SMARTHOMEKJ|Wi-Fi|MikroTik|Matter|Shelly|Hue|Tuya|Imou|MQTT|ESPHome|Tasmota|WLED|KJ|OK|'
            r'English|Home Assistant|iRobot Roomba|Philips Hue|Reolink|Hikvision / Ezviz|Dahua / Imou / Amcrest|PM2\.5|[A-Z]|'
            r'github\.com.*)$')
        .hasMatch(s.trim());

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    L10n.use('en');
    L10n.missing = null;
  });

  test('every pattern fills in the parts it takes', () {
    final slot = RegExp(r'\{\d\}');
    for (final e in bgPatterns.entries) {
      final from = slot.allMatches(e.key).map((m) => m[0]).toSet();
      final to = slot.allMatches(e.value).map((m) => m[0]).toSet();
      expect(to, from, reason: e.key);
    }
  });

  test('lines are found word for word and through their patterns, with the parts looked up too', () {
    L10n.use('bg');
    expect(tr('All off'), 'Изключи всичко');
    expect(tr('3 of 7 devices active.'), '3 от 7 устройства са включени.');
    expect(tr('Kitchen · 2 on'), 'Кухня · 2 вкл.');
    expect(tr('DEVICES'), 'УСТРОЙСТВА');
    expect(tr('Motion: Detected'), 'Движение: Засечено');
    expect(tr('My lamp'), 'My lamp', reason: 'names people give stay as they are');
    expect(tr('21.5 °C'), '21.5 °C');
    expect(trf('When {0} {1}', ['Hall sensor', tr('detects motion')]), 'Когато Hall sensor усети движение');
    expect(tc('Open', 'action'), 'Отвори');
    expect(tr('Open'), 'Отворено');
    expect(weekdayShort(1), 'Пн');
    L10n.use('en');
    expect(tr('All off'), 'All off');
    expect(tc('Open', 'action'), 'Open');
  });

  testWidgets('in Bulgarian, the main screens show Bulgarian', (tester) async {
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings();
    settings.language = 'bg';
    L10n.missing = {};
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    await tester.pumpWidget(SmartMenuApp(store: store, settings: settings, poll: false));
    await tester.pump();
    expect(find.text('Изключи всичко'), findsOneWidget);
    expect(find.text('Начало'), findsWidgets, reason: 'the tab bar');
    expect(find.text('Любими'), findsOneWidget);

    final ctx = tester.element(find.byType(HomeScreen));
    for (final tab in ['tab-map', 'tab-devices', 'tab-connect', 'tab-home']) {
      await tester.tap(find.byKey(Key(tab)));
      await tester.pumpAndSettle();
    }
    Future<void> sheet(Future<void> Function() open) async {
      unawaitedOpen(open);
      await tester.pumpAndSettle();
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
    }

    for (final d in store.devices) {
      await sheet(() => showDeviceSheet(ctx, d));
    }
    for (final r in store.rooms) {
      await sheet(() => showRoomSheet(ctx, r.id));
    }
    final scene = store.addScene('Movie night', store.devices.take(3).toList());
    await sheet(() => showSceneSheet(ctx, scene));
    await sheet(() => showActivitySheet(ctx));
    await sheet(() => showAutomations(ctx));
    await sheet(() => showHelpSheet(ctx));
    await sheet(() => showAccountSheet(ctx));
    await sheet(() => showAnywhereSheet(ctx));
    await sheet(() => showHomesSheet(ctx));
    await sheet(() => showHomeEditor(ctx));
    await sheet(() => showProfileMenu(ctx));
    // It looks for cameras while open, so it never settles.
    unawaitedOpen(() => showCameraSetup(ctx));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    unawaitedOpen(() => openSettings(ctx));
    await tester.pumpAndSettle();
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Език'), findsOneWidget);

    // Switching back is at once, on every screen.
    await tester.tap(find.byKey(const Key('choice-English')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(L10n.code, 'en');

    final gaps = L10n.missing!.where((s) => !_notWords(s) && !store.devices.any((d) => d.name == s)).toList()..sort();
    // ignore: avoid_print
    if (gaps.isNotEmpty) print('Not translated yet:\n${gaps.join('\n')}');
    expect(gaps, isEmpty);
  });
}

void unawaitedOpen(Future<void> Function() open) {
  open();
}
