// Renders the README screenshots with the real fonts.
// Run: flutter test tool/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/app.dart';
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

Future<HomeStore> _app(WidgetTester tester, Size size, {String theme = 'dark'}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
  await store.load();
  store.data.themeMode = theme;
  await tester.pumpWidget(SmartMenuApp(store: store, poll: false));
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
    await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-map')));
    await _shot(tester, 'phone-map');
    await tester.tap(find.byKey(const Key('map-edit')));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(find.textContaining('KITCHEN')) + const Offset(4, 4));
    await _shot(tester, 'phone-map-edit');
  });

  testWidgets('phone device controls', (tester) async {
    await _app(tester, phone);
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Desk lamp').first);
    await _shot(tester, 'phone-device');
  });

  testWidgets('phone connect', (tester) async {
    await _app(tester, phone);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await _shot(tester, 'phone-connect');
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
