// Renders the README screenshots with the real fonts.
// Run: flutter test tool/screenshots_test.dart --update-goldens
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/memory_cloud.dart';
import 'package:smartmenukj/l10n/l10n.dart';
import 'package:smartmenukj/models/automation.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/models/scene.dart';
import 'package:smartmenukj/state/app_settings.dart';
import 'package:smartmenukj/state/backup_files.dart';
import 'package:smartmenukj/state/history.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/screens/camera_playback.dart';
import 'package:smartmenukj/ui/screens/device_sheet.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/ui/screens/router_screen.dart';
import 'package:smartmenukj/ui/widgets/camera_live.dart';
import 'package:smartmenukj/ui/widgets/motion.dart';

import '../test/weather_fixture.dart';

Future<void> _loadFonts() async {
  final inter = FontLoader('Inter');
  for (final w in [400, 500, 600, 700, 800]) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$w.ttf'));
  }
  await inter.load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
  final cupertino = File('${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/cupertino_icons-1.0.9/assets/CupertinoIcons.ttf');
  if (cupertino.existsSync()) {
    final loader = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(Future.value(ByteData.sublistView(cupertino.readAsBytesSync())));
    await loader.load();
  }
}

Future<HomeStore> _app(WidgetTester tester, Size size,
    {String theme = 'light', CloudSync? cloud, http.Client? client, BackupFiles? backups, String language = 'en'}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final store = HomeStore(
      repository: MemoryHomeRepository(), client: client ?? MockClient((_) async => http.Response('[]', 200)));
  await store.load();
  store.data.themeMode = theme;
  // A pretend cloud, signed out, so the account card shows as it does in the app.
  final settings = AppSettings()..language = language;
  addTearDown(() => L10n.use('en'));
  await tester.pumpWidget(SmartMenuApp(
      store: store,
      cloud: cloud ?? CloudSync(store: store, api: MemoryCloud().app()),
      backups: backups,
      settings: settings,
      poll: false));
  await tester.pumpAndSettle();
  return store;
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../docs/screenshots/$name.png'));
}

void main() {
  const phone = Size(390, 844);
  const desktop = Size(1280, 800);

  setUpAll(_loadFonts);

  testWidgets('phone home', (tester) async {
    await _app(tester, phone);
    await _shot(tester, 'phone-home');
  });

  testWidgets('phone home dark', (tester) async {
    await _app(tester, phone, theme: 'dark');
    await _shot(tester, 'phone-home-dark');
  });

  testWidgets('phone restore', (tester) async {
    // A new install on Android, with the offer to take the homes back from the backup file.
    await _app(tester, phone, backups: BackupFiles(available: true));
    await _shot(tester, 'phone-restore');
  });

  testWidgets('phone map', (tester) async {
    final store = await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-map')));
    await _shot(tester, 'phone-map');
    store.unplaceDevice(store.devices.firstWhere((d) => d.name == 'Bath fan'));
    await tester.tap(find.byKey(const Key('map-edit')));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(find.textContaining('Kitchen').first) + const Offset(4, 4));
    await _shot(tester, 'phone-map-edit');
  });

  testWidgets('phone map drawing', (tester) async {
    await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-draw')));
    await tester.pumpAndSettle();
    final start = tester.getBottomLeft(find.byKey(const Key('room-room-bedroom'))) + const Offset(6, 18);
    final g = await tester.startGesture(start);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(14, 7));
      await tester.pump();
    }
    await _shot(tester, 'phone-map-draw');
    await g.up();
  });

  Future<void> openControls(WidgetTester tester, String name) async {
    await tester.scrollUntilVisible(find.text(name), 250, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.longPress(find.text(name).first);
    await tester.pumpAndSettle();
  }

  testWidgets('phone device controls', (tester) async {
    await _app(tester, phone);
    await openControls(tester, 'Desk lamp');
    await _shot(tester, 'phone-device');
  });

  testWidgets('phone colour light', (tester) async {
    final store = await _app(tester, phone);
    store.updateDevice(store.devices.firstWhere((d) => d.name == 'Floor lamp'), favorite: true);
    await tester.pumpAndSettle();
    await openControls(tester, 'Floor lamp');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -330));
    await _shot(tester, 'phone-colour');
  });

  testWidgets('phone thermostat', (tester) async {
    await _app(tester, phone);
    await openControls(tester, 'Thermostat');
    await _shot(tester, 'phone-thermostat');
  });

  testWidgets('phone robot vacuum', (tester) async {
    final store = await _app(tester, phone);
    final robot = store.devices.firstWhere((d) => d.name == 'Robot vacuum');
    robot.state = robot.state.merge(const DeviceState(activity: Activity.running, battery: 0.72));
    await openControls(tester, 'Robot vacuum');
    await _shot(tester, 'phone-vacuum');
  });

  testWidgets('phone alarm', (tester) async {
    final store = await _app(tester, phone);
    final alarm = store.devices.firstWhere((d) => d.name == 'Alarm');
    alarm.state = alarm.state.merge(const DeviceState(activity: Activity.armedAway));
    await openControls(tester, 'Alarm');
    await _shot(tester, 'phone-alarm');
  });

  testWidgets('phone room', (tester) async {
    await _app(tester, phone);
    final card = find.byKey(const Key('room-card-room-living'));
    await tester.scrollUntilVisible(card, 250, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await _shot(tester, 'phone-room');
  });

  testWidgets('phone home editor', (tester) async {
    await _app(tester, phone);
    await tester.tap(find.byKey(const Key('home-edit')));
    await _shot(tester, 'phone-home-edit');
  });

  testWidgets('phone connect', (tester) async {
    await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await _shot(tester, 'phone-connect');
  });

  testWidgets('phone control from anywhere', (tester) async {
    final store = await _app(tester, phone);
    final shelly = store.addIntegration('shelly',
        settings: {'hosts': '192.168.1.40', 'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'key'});
    store.addVirtualDevice(shelly.id, 'Porch light', DeviceKind.outlet,
        props: {'host': '192.168.1.40', 'mac': 'a8032ab12345', 'gen': 2, 'component': 'switch', 'channel': 0});
    store.addIntegration('tuya', settings: {'access_id': 'id', 'access_secret': 'secret', 'region': 'eu'});
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('control-anywhere')));
    await _shot(tester, 'phone-anywhere');
  });

  testWidgets('phone matter pairing', (tester) async {
    await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('spec-matter'));
    await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('matter-code')), '3497-011-2332');
    await _shot(tester, 'phone-matter');
  });

  testWidgets('phone homes', (tester) async {
    final store = await _app(tester, phone);
    await store.addHome('Beach house');
    await store.addHome('Office');
    await store.openHome(store.homes.first.id);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-switch')));
    await _shot(tester, 'phone-homes');
  });

  /// The app signed in, with this device keeping the home online.
  Future<(HomeStore, CloudSync)> signedIn(WidgetTester tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    store.addVirtualDevice('demo', 'Porch light', DeviceKind.light);
    final cloud = CloudSync(store: store, api: MemoryCloud().app(), deviceName: 'Kitchen tablet', delay: const Duration(milliseconds: 10));
    await cloud.start();
    await cloud.signIn('kj@example.com', 'secret1', create: true);
    await cloud.setHub(true);
    await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud, poll: false));
    await tester.pumpAndSettle();
    return (store, cloud);
  }

  Future<void> signOff(WidgetTester tester, CloudSync cloud) async {
    cloud.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('phone profile', (tester) async {
    final (store, cloud) = await signedIn(tester);
    await store.addHome('Beach house');
    await store.openHome(store.homes.first.id);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-button')));
    await _shot(tester, 'phone-profile');
    await signOff(tester, cloud);
  });

  testWidgets('phone settings', (tester) async {
    final (_, cloud) = await signedIn(tester);
    await tester.tap(find.byKey(const Key('profile-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-settings')));
    await _shot(tester, 'phone-settings');
    await signOff(tester, cloud);
  });

  testWidgets('phone account', (tester) async {
    final (_, cloud) = await signedIn(tester);
    await tester.tap(find.byKey(const Key('profile-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-account')));
    await _shot(tester, 'phone-account');
    await signOff(tester, cloud);
  });

  testWidgets('phone scene', (tester) async {
    final store = await _app(tester, phone);
    final night = store.addScene('Good night',
        store.devices.where((d) => SceneAction.turn(d, false) != null && d.kind != DeviceKind.alarm).take(6),
        icon: 'night', turnOn: false);
    final lamp = store.devices.firstWhere((d) => d.name == 'Floor lamp');
    store.setSceneStep(night, SceneAction(deviceId: lamp.id, command: const DeviceCommand(on: true, brightness: 0.2)));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(Key('scene-${night.id}')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(DraggableScrollableSheet), const Offset(0, -300));
    await _shot(tester, 'phone-scene');
    await tester.tap(find.byKey(const Key('scene-step-Floor lamp')));
    await _shot(tester, 'phone-scene-step');
  });

  testWidgets('phone camera setup', (tester) async {
    final store = await _app(tester, phone);
    final cam = store.addVirtualDevice('demo', 'Garden camera', DeviceKind.camera, props: {'host': '192.168.1.30'});
    store.updateDevice(cam, favorite: true);
    await tester.pumpAndSettle();
    await openControls(tester, 'Garden camera');
    await _shot(tester, 'phone-camera');
    await tester.tap(find.byKey(const Key('camera-setup-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('brand-tapo')));
    await tester.enterText(find.byKey(const Key('camera-user')), 'garden');
    await tester.enterText(find.byKey(const Key('camera-pass')), 'secret12');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shot(tester, 'phone-camera-setup');
  });

  testWidgets('phone camera playback', (tester) async {
    final now = DateTime(2026, 10, 17, 18, 40);
    debugPlaybackClock = () => now;
    debugRtspPlays = true;
    // A stand-in picture of a yard at dusk.
    debugRtspPlayer = (_) => const DecoratedBox(
        decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2B3440), Color(0xFF4A4F45), Color(0xFF23271F)])));
    addTearDown(() {
      debugPlaybackClock = null;
      debugRtspPlays = null;
      debugRtspPlayer = null;
    });
    String item(int i, String from, String to, bool motion) => 'items[$i].StartTime=2026-10-17 $from\r\n'
        'items[$i].EndTime=2026-10-17 $to\r\nitems[$i].Flags[0]=${motion ? 'Event' : 'Timing'}\r\n';
    final clips = [
      ('07:00:00', '08:10:00', false),
      ('08:10:00', '08:12:30', true),
      ('08:12:30', '12:00:00', false),
      ('12:40:15', '12:42:00', true),
      ('13:00:00', '17:05:00', false),
      ('17:05:00', '17:08:40', true),
      ('17:08:40', '18:21:00', false),
      ('18:21:00', '18:23:10', true),
    ];
    final store = await _app(tester, phone, client: MockClient((req) async {
      final action = req.url.queryParameters['action'];
      return http.Response(
          action == 'factory.create'
              ? 'result=1'
              : action == 'findNextFile'
                  ? 'found=${clips.length}\r\n${[for (final (i, c) in clips.indexed) item(i, c.$1, c.$2, c.$3)].join()}'
                  : 'OK',
          200);
    }));
    final cam = store.addVirtualDevice('demo', 'Yard camera', DeviceKind.camera);
    cam.props['streamUrl'] = 'rtsp://admin:pw@192.168.1.30/cam/realmonitor?channel=1&subtype=0';
    store.updateDevice(cam, favorite: true);
    await tester.pumpAndSettle();
    await openControls(tester, 'Yard camera');
    await tester.ensureVisible(find.byKey(const Key('camera-playback')));
    await tester.tap(find.byKey(const Key('camera-playback')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playback-clip-0')));
    await _shot(tester, 'phone-camera-playback');
  });

  testWidgets('phone router', (tester) async {
    String rest(String path) => switch (path) {
          '/rest/system/resource' => '{"uptime":"6d4h12m","cpu-load":"3","board-name":"hAP ax3","version":"7.16.1 (stable)",'
              '"free-memory":"702000000","total-memory":"1073741824"}',
          '/rest/system/identity' => '{"name":"Home router"}',
          '/rest/interface/wifi' => '[{".id":"*1","name":"wifi1","configuration.ssid":"Home","channel.band":"5ghz-ax",'
              '"disabled":"false","running":"true"},{".id":"*2","name":"wifi2","configuration.ssid":"Home","channel.band":'
              '"2ghz-ax","disabled":"false","running":"true"},{".id":"*3","name":"wifi3","configuration.ssid":"Guests",'
              '"channel.band":"2ghz-ax","disabled":"true"}]',
          '/rest/ip/dhcp-server/lease' => '[{".id":"*a","address":"192.168.88.12","host-name":"Roomba-3145C","mac-address":'
              '"50:14:79:12:AB:01","status":"bound","dynamic":"true"},{".id":"*b","address":"192.168.88.20","comment":'
              '"Living room TV","mac-address":"A8:23:FE:01:22:33","status":"bound","dynamic":"false"},{".id":"*c",'
              '"address":"192.168.88.31","host-name":"Pixel-8","mac-address":"3C:28:6D:44:55:66","status":"bound",'
              '"dynamic":"true"}]',
          '/rest/interface' => '[{".id":"*1","name":"ether1","type":"ether","running":"true","disabled":"false","comment":'
              '"Internet"},{".id":"*2","name":"ether2","type":"ether","running":"true","disabled":"false"},{".id":"*3",'
              '"name":"ether3","type":"ether","running":"false","disabled":"false"}]',
          _ => '[]',
        };
    final store = await _app(tester, phone, theme: 'light', client: MockClient((req) async => http.Response(rest(req.url.path), 200)));
    await tester.runAsync(() => store.addNetworkDevice('192.168.88.1', hints: {'protocol': 'mikrotik', 'password': 'pw'}));
    final router = store.devices.firstWhere((d) => d.kind == DeviceKind.router);
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).clearSnackBars(); // the "Added" message
    await tester.pumpAndSettle();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => RouterScreen(deviceId: router.id)));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await _shot(tester, 'phone-router');
  });

  testWidgets('phone automations', (tester) async {
    final store = await _app(tester, phone);
    Device named(String n) => store.devices.firstWhere((d) => d.name == n);
    final hall = store.addVirtualDevice('demo', 'Hall motion', DeviceKind.sensor);
    hall.state = const DeviceState(readings: {'Motion': 'Clear'});
    final movie = store.addScene('Movie night', [named('Floor lamp'), named('TV')], icon: 'movie');
    store
      ..addAutomation(Automation(
          id: 'auto-hall',
          trigger: AutomationTrigger(deviceId: hall.id, kind: TriggerKind.becomes, label: 'Motion', value: 'Detected'),
          then: AutomationStep.device(named('Ceiling light').id, on: true, offAfter: 5),
          from: 19 * 60,
          to: 7 * 60))
      ..addAutomation(Automation(
          id: 'auto-tv',
          trigger: AutomationTrigger(deviceId: named('TV').id, kind: TriggerKind.turnsOn),
          then: AutomationStep.scene(movie.id)))
      ..addAutomation(Automation(
          id: 'auto-cold',
          trigger: AutomationTrigger(deviceId: named('Bedroom sensor').id, kind: TriggerKind.below, label: 'Temperature', number: 18),
          then: AutomationStep.device(named('Thermostat').id, on: true)))
      ..addAutomation(Automation(
          id: 'auto-door',
          enabled: false,
          trigger: AutomationTrigger(deviceId: named('Front door').id, kind: TriggerKind.unlocks),
          then: AutomationStep.device(named('Kitchen lights').id, on: true)))
      ..addAutomation(Automation(
          id: 'auto-dusk',
          trigger: const AutomationTrigger(deviceId: AutomationTrigger.home, kind: TriggerKind.sunset, number: -15),
          then: AutomationStep.device(named('Floor lamp').id, on: true)))
      ..addAutomation(Automation(
          id: 'auto-rain',
          trigger: const AutomationTrigger(deviceId: AutomationTrigger.home, kind: TriggerKind.rain),
          then: AutomationStep.device(named('Blinds').id, on: false)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('automations-open')));
    await _shot(tester, 'phone-automations');
    await tester.tap(find.byKey(const Key('automation-auto-hall')));
    await _shot(tester, 'phone-automation');
  });

  testWidgets('phone light theme', (tester) async {
    await _app(tester, phone, theme: 'light');
    await tester.tap(find.byKey(const Key('tab-devices')));
    await _shot(tester, 'phone-devices-light');
  });

  testWidgets('desktop map', (tester) async {
    await _app(tester, desktop);
    await tester.tap(find.text('Map'));
    await _shot(tester, 'desktop-map');
  });

  testWidgets('desktop home', (tester) async {
    await _app(tester, desktop);
    await _shot(tester, 'desktop-home');
  });

  /// A day of the sample home: lamps going on and off, the door, and the bedroom getting warmer.
  Future<HomeStore> lived(WidgetTester tester, {String language = 'en'}) async {
    final store = await _app(tester, phone, language: language);
    final now = DateTime.now();
    final sensor = store.devices.firstWhere((d) => d.name == 'Bedroom sensor');
    for (var i = 24 * 12; i >= 0; i--) {
      final h = i / 12;
      final t = 20.4 + 1.6 * math.sin((24 - h) / 24 * math.pi * 2 - 1.2) + (i % 7) * 0.03;
      sensor.state = DeviceState(readings: {'Temperature': '${t.toStringAsFixed(1)} °C', 'Humidity': '${(48 - (t - 20) * 3).round()} %'});
      withClock(Clock.fixed(now.subtract(Duration(minutes: i * 5))), () => store.history!.sample(store.devices));
    }
    HomeEvent e(int minutesAgo, EventType type, String name, {String? label, String? value, String? by}) {
      final d = store.devices.firstWhere((d) => d.name == name);
      return HomeEvent(
          at: now.subtract(Duration(minutes: minutesAgo)),
          type: type,
          deviceId: d.id,
          name: d.name,
          kind: d.kind,
          label: label,
          value: value,
          by: by);
    }
    for (final ev in [
      e(1500, EventType.turnedOn, 'Coffee machine', by: 'app'),
      e(1440, EventType.unlocked, 'Front door'),
      e(1438, EventType.locked, 'Front door', by: 'app'),
      e(260, EventType.turnedOn, 'Floor lamp', by: 'app'),
      e(95, EventType.turnedOff, 'Bedside lamp'),
      e(42, EventType.unlocked, 'Front door', by: 'remote'),
      e(41, EventType.turnedOn, 'Ceiling light', by: 'automation:a'),
      e(6, EventType.offline, 'Bath fan'),
      e(2, EventType.turnedOn, 'Desk lamp', by: 'app'),
    ]) {
      store.history!.add(ev);
    }
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('phone activity', (tester) async {
    await lived(tester);
    await tester.ensureVisible(find.byKey(const Key('status-activity')));
    await tester.tap(find.byKey(const Key('status-activity')));
    await _shot(tester, 'phone-activity');
  });

  testWidgets('phone sensor history', (tester) async {
    final store = await lived(tester);
    final sensor = store.devices.firstWhere((d) => d.name == 'Bedroom sensor');
    showDeviceSheet(tester.element(find.byType(HomeScreen)), sensor);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -260));
    await _shot(tester, 'phone-sensor-history');
  });

  testWidgets('phone home in Bulgarian', (tester) async {
    await lived(tester, language: 'bg');
    await _shot(tester, 'phone-home-bg');
  });

  testWidgets('phone activity in Bulgarian', (tester) async {
    await lived(tester, language: 'bg');
    await tester.ensureVisible(find.byKey(const Key('status-activity')));
    await tester.tap(find.byKey(const Key('status-activity')));
    await _shot(tester, 'phone-activity-bg');
  });

  testWidgets('phone device in Bulgarian', (tester) async {
    await _app(tester, phone, language: 'bg');
    await openControls(tester, 'Настолна лампа');
    await _shot(tester, 'phone-device-bg');
  });

  /// A new install with its opening animation and welcome, which never stand still, so pictures are taken at a
  /// moment rather than once everything settles.
  Future<CloudSync> firstOpen(WidgetTester tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    Motion.allowed = true;
    addTearDown(() {
      Motion.allowed = false;
      Motion.revealed.value = true;
    });
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    final cloud = CloudSync(store: store, api: MemoryCloud().app(), delay: const Duration(milliseconds: 10));
    await cloud.start();
    await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud, settings: AppSettings(), poll: false, intro: true));
    return cloud;
  }

  Future<void> run(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> still(WidgetTester tester, String name) =>
      expectLater(find.byType(MaterialApp), matchesGoldenFile('../docs/screenshots/$name.png'));

  testWidgets('phone opening animation and welcome', (tester) async {
    final cloud = await firstOpen(tester);
    await tester.pump(const Duration(milliseconds: 1420));
    await still(tester, 'phone-launch');
    await run(tester, 2400);
    await still(tester, 'phone-welcome');
    await tester.tap(find.byKey(const Key('welcome-skip')));
    await run(tester, 2000);
    await tester.enterText(find.byKey(const Key('welcome-name')), 'Krasimir');
    await run(tester, 300);
    FocusManager.instance.primaryFocus?.unfocus();
    await run(tester, 300);
    await still(tester, 'phone-welcome-name');
    await tester.tap(find.byKey(const Key('welcome-create')));
    await run(tester, 1200);
    await tester.enterText(find.byKey(const Key('account-email')), 'krasimir@example.com');
    await tester.enterText(find.byKey(const Key('account-password')), 'Sofia-2026!');
    FocusManager.instance.primaryFocus?.unfocus();
    await run(tester, 600);
    await still(tester, 'phone-sign-up');
    await tester.tap(find.byKey(const Key('auth-close')));
    await run(tester, 600);
    await signOff(tester, cloud);
  });

  testWidgets('phone settings in Bulgarian', (tester) async {
    await _app(tester, phone, language: 'bg');
    await tester.tap(find.byKey(const Key('profile-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-settings')));
    await _shot(tester, 'phone-settings-bg');
  });

  /// The sample home in Sofia, with its weather.
  Future<HomeStore> inSofia(WidgetTester tester, {String language = 'en'}) async {
    final store = await _app(tester, phone, language: language, client: weatherClient(forecast: () => sampleForecast(DateTime.now(), temp: 14)));
    store.setPlace(language == 'bg'
        ? const HomePlace(name: 'София', region: 'София-град, България', lat: 42.6975, lon: 23.3242)
        : const HomePlace(name: 'Sofia', region: 'Sofia-Capital, Bulgaria', lat: 42.6975, lon: 23.3242));
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('phone weather', (tester) async {
    await inSofia(tester);
    await tester.ensureVisible(find.byKey(const Key('status-weather')));
    await tester.tap(find.byKey(const Key('status-weather')));
    await _shot(tester, 'phone-weather');
  });

  testWidgets('phone weather in Bulgarian', (tester) async {
    await inSofia(tester, language: 'bg');
    await tester.ensureVisible(find.byKey(const Key('status-weather')));
    await tester.tap(find.byKey(const Key('status-weather')));
    await _shot(tester, 'phone-weather-bg');
  });

  testWidgets('phone timer', (tester) async {
    final store = await inSofia(tester);
    final lamp = store.devices.firstWhere((d) => d.name == 'Ceiling light');
    store.setTimer(lamp, const Duration(minutes: 45));
    await tester.pumpAndSettle();
    await openControls(tester, 'Ceiling light');
    final sheet = find.byType(Scrollable).last;
    for (var i = 0; i < 20 && find.byKey(const Key('timer-set')).hitTestable().evaluate().isEmpty; i++) {
      await tester.dragFrom(tester.getTopLeft(sheet) + const Offset(16, 200), const Offset(0, -150));
      await tester.pumpAndSettle();
    }
    await tester.dragFrom(tester.getTopLeft(sheet) + const Offset(16, 200), const Offset(0, -120));
    await _shot(tester, 'phone-timer');
  });

  testWidgets('phone scene at sunset', (tester) async {
    final store = await inSofia(tester);
    final evening = store.addScene('Evening',
        store.devices.where((d) => d.kind == DeviceKind.light || d.kind == DeviceKind.cover).take(5),
        icon: 'relax', turnOn: true);
    store.updateScene(evening,
        schedule: SceneSchedule.sun('sunset', lat: 42.6975, lon: 23.3242, offset: -15));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(Key('scene-${evening.id}')));
    await tester.pumpAndSettle();
    final sheet = find.byType(Scrollable).last;
    for (var i = 0; i < 20 && find.byKey(const Key('schedule-offset--15')).hitTestable().evaluate().isEmpty; i++) {
      await tester.dragFrom(tester.getTopLeft(sheet) + const Offset(16, 200), const Offset(0, -150));
      await tester.pumpAndSettle();
    }
    await tester.dragFrom(tester.getTopLeft(sheet) + const Offset(16, 200), const Offset(0, -100));
    await _shot(tester, 'phone-scene-sunset');
  });
}
