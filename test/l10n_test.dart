import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/memory_cloud.dart';
import 'package:smartmenukj/l10n/bg.dart';
import 'package:smartmenukj/integrations/weather.dart';
import 'package:smartmenukj/l10n/text.dart';
import 'package:smartmenukj/models/automation.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/models/scene.dart';
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
import 'package:smartmenukj/ui/screens/weather_sheet.dart';

import 'weather_fixture.dart';

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

  test('the weather, the sun and timers have their words in Bulgarian', () {
    L10n.use('bg');
    final lines = <String>{
      for (final c in [0, 1, 2, 3, 45, 51, 56, 61, 65, 71, 75, 80, 82, 85, 95, 96]) Weather.describe(c),
      for (final kind in [TriggerKind.sunrise, TriggerKind.sunset])
        for (final m in [-60, -30, -15, 0, 15, 30, 60, 90]) ...[
          AutomationTrigger(deviceId: AutomationTrigger.home, kind: kind, number: m.toDouble()).sunText,
          SceneSchedule.sun(kind.name, lat: 1, lon: 1, offset: m).label,
        ],
      for (final t in AutomationTrigger.homeChoices())
        if (t.kind != TriggerKind.sunrise && t.kind != TriggerKind.sunset) 'When ${t.copyWith(number: 5).event}',
      for (final m in [15, 30, 60, 120]) m < 60 ? '$m min' : '${m ~/ 60} h',
      'off in 25 min', 'on in 1 h', 'Turn off in', 'Turn on in',
      'Sunrise, sunset or the weather', 'The sun or the weather…', 'It starts to rain', 'It gets warmer outside than…',
      'It gets colder outside than…', 'When, around sunrise?', 'When, around sunset?', 'Warmer outside than',
      'Colder outside than', 'Degrees, e.g. 5', 'Minutes, e.g. 45', 'Other…', 'Set', 'Pick your town first',
      'By a timer', 'Town', 'Not set. For the weather, sunrise and sunset.', 'Change town', 'Add your town', 'Asking…',
      'No weather yet', 'The town search did not answer. Is the internet on?', 'No weather: no internet connection?',
      'The weather service sent nothing usable.', 'Asking for the weather…',
    };
    final left = [for (final l in lines) if (tr(l) == l) l];
    expect(left, isEmpty);
    expect(tr('30 min before sunset'), isNot(contains('sunset')));
    expect(trf('Feels like {0}°', ['10']), isNot(contains('Feels')));
    final at = DateTime(2026, 11, 7, 20);
    expect(timerText(DeviceTimer(deviceId: 'd', at: at.add(const Duration(minutes: 90)), on: true), at),
        'включва се след 1 ч 30 мин');
    expect(timerText(DeviceTimer(deviceId: 'd', at: at.add(const Duration(minutes: 25))), at), 'изключва се след 25 мин');
  });

  testWidgets('in Bulgarian, the main screens show Bulgarian', (tester) async {
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings();
    settings.language = 'bg';
    settings.name = 'Krasimir';
    L10n.missing = {};
    final store = HomeStore(repository: MemoryHomeRepository(), client: weatherClient(towns: const {'results': []}));
    await store.load();
    // The weather, a timer, a scene at sunset and automations by the sun and the weather.
    const town = HomePlace(name: 'София', region: 'София-град, България', lat: 42.6975, lon: 23.3242);
    store.setPlace(town);
    final lit = store.devices.firstWhere((d) => d.state.on == true);
    store.setTimer(lit, const Duration(minutes: 90));
    for (final (i, (kind, n)) in const [
      (TriggerKind.sunset, -30.0), (TriggerKind.sunrise, 0.0), (TriggerKind.sunrise, 60.0), (TriggerKind.rain, null),
      (TriggerKind.colderOutside, 3.0), (TriggerKind.warmerOutside, 25.0),
    ].indexed) {
      store.addAutomation(Automation(
          id: 'auto-$i',
          trigger: AutomationTrigger(deviceId: AutomationTrigger.home, kind: kind, number: n),
          then: AutomationStep.device(lit.id, on: true)));
    }
    await tester.pumpWidget(SmartMenuApp(store: store, settings: settings, poll: false));
    await tester.pump();
    expect(find.text('Изключи всичко'), findsOneWidget);
    expect(find.text('Начало'), findsWidgets, reason: 'the tab bar');
    expect(find.text('Любими'), findsOneWidget);
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);

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
    scene.schedule = SceneSchedule.sun('sunset', lat: town.lat, lon: town.lon, offset: -30, days: {1, 2, 3, 4, 5});
    await sheet(() => showSceneSheet(ctx, scene));
    await sheet(() => showWeatherSheet(ctx));
    for (final a in store.automations) {
      await sheet(() => showAutomationSheet(ctx, a));
    }
    unawaitedOpen(() => pickPlace(ctx));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('place-search')), 'Zzz');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('place-problem')), findsOneWidget);
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
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

    final gaps = L10n.missing!
        .where((s) => !_notWords(s) && s != settings.name && !store.devices.any((d) => d.name == s))
        .toList()
      ..sort();
    // ignore: avoid_print
    if (gaps.isNotEmpty) print('Not translated yet:\n${gaps.join('\n')}');
    expect(gaps, isEmpty);
  });

  testWidgets('in Bulgarian, the welcome and the sign-in screens show Bulgarian', (tester) async {
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings();
    settings.language = 'bg';
    L10n.missing = {};
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    final cloud = CloudSync(store: store, api: MemoryCloud().app(), delay: const Duration(milliseconds: 10), storageKey: 'w');
    await cloud.start();
    await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud, settings: settings, poll: false, intro: true));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('welcome-next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Продължи без профил'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-create')));
    await tester.pumpAndSettle();
    for (final password in ['abc', 'abcdef', 'abcdef12', 'Abcdefgh12', 'Abcdefghij12']) {
      await tester.enterText(find.byKey(const Key('account-password')), password);
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('auth-mode-signin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-forgot')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account-email')), 'k@example.com');
    await tester.tap(find.byKey(const Key('auth-forgot')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-note')), findsOneWidget);
    await tester.tap(find.byKey(const Key('auth-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pumpAndSettle();
    expect(settings.welcomed, isTrue);

    final gaps = L10n.missing!.where((s) => !_notWords(s)).toList()..sort();
    // ignore: avoid_print
    if (gaps.isNotEmpty) print('Not translated yet:\n${gaps.join('\n')}');
    expect(gaps, isEmpty);
    cloud.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}

void unawaitedOpen(Future<void> Function() open) {
  open();
}
