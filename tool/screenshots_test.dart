// Renders the README screenshots with the real fonts.
// Run: flutter test tool/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/memory_cloud.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

Future<void> _loadFonts() async {
  Future<void> asset(String family, String path) async {
    final loader = FontLoader(family)..addFont(rootBundle.load(path));
    await loader.load();
  }

  await asset('Doto', 'assets/fonts/Doto.ttf');
  await asset('SpaceGrotesk', 'assets/fonts/SpaceGrotesk.ttf');
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

Future<HomeStore> _app(WidgetTester tester, Size size, {String theme = 'dark', CloudSync? cloud}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
  await store.load();
  store.data.themeMode = theme;
  // A pretend cloud, signed out, so the account card shows as it does in the app.
  await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud ?? CloudSync(store: store, api: MemoryCloud().app()), poll: false));
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

  testWidgets('phone map', (tester) async {
    final store = await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-map')));
    await _shot(tester, 'phone-map');
    store.unplaceDevice(store.devices.firstWhere((d) => d.name == 'Bath fan'));
    await tester.tap(find.byKey(const Key('map-edit')));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(find.textContaining('KITCHEN')) + const Offset(4, 4));
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

  testWidgets('phone light theme', (tester) async {
    await _app(tester, phone, theme: 'light');
    await tester.tap(find.byKey(const Key('tab-devices')));
    await _shot(tester, 'phone-devices-light');
  });

  testWidgets('desktop map', (tester) async {
    await _app(tester, desktop);
    await tester.tap(find.text('MAP'));
    await _shot(tester, 'desktop-map');
  });

  testWidgets('desktop home', (tester) async {
    await _app(tester, desktop);
    await _shot(tester, 'desktop-home');
  });
}
