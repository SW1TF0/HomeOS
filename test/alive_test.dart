import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/screens/scenes.dart';
import 'package:smartmenukj/ui/widgets/alive.dart';
import 'package:smartmenukj/ui/widgets/kj_widgets.dart';
import 'package:smartmenukj/ui/widgets/motion.dart';

/// Lets the motion run, as in the real app, for one test.
void withMotion() {
  Motion.allowed = true;
  addTearDown(() => Motion.allowed = false);
}

Widget app(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

Device lamp({bool on = false}) => Device(
      id: 'lamp',
      name: 'Desk lamp',
      kind: DeviceKind.light,
      integrationId: 'demo',
      externalId: 'lamp',
      capabilities: {Capability.onOff, Capability.brightness, Capability.color},
      state: DeviceState(on: on, brightness: 0.6, color: 0xFF9500),
    );

int argb(Color c) => c.toARGB32();

void main() {
  DateTime at(int h, [int m = 0]) => DateTime(2026, 11, 8, h, m);

  group('the sky over the home', () {
    test('is daytime blue at noon with the sun high and no stars', () {
      final sky = Sky.at(at(12), dark: false);
      expect(argb(sky.top), 0xFFDAE8FA);
      expect(sky.stars, 0);
      expect(sky.glowAt.dx, closeTo(0.12 + 0.76 * 300 / 690, 1e-6));
      expect(sky.glowAt.dy, lessThan(0.05), reason: 'the sun is near the top at midday');
    });

    test('is dawn pink just before sunrise and golden before sunset', () {
      final rise = at(7, 30), set = at(17, 0);
      expect(argb(Sky.at(at(7, 20), rise: rise, set: set, dark: false).top), 0xFFFBE3DE);
      expect(argb(Sky.at(at(16, 35), rise: rise, set: set, dark: false).top), 0xFFFCE6CC);
      final low = Sky.at(at(7, 35), rise: rise, set: set, dark: false).glowAt;
      expect(low.dx, closeTo(0.12, 0.01), reason: 'the sun rises on the left');
      expect(low.dy, closeTo(0.235, 0.01), reason: 'low in the sky');
    });

    test('is a starry night on the dark theme, with the moon', () {
      final sky = Sky.at(at(2), dark: true);
      expect(argb(sky.top), 0xFF0D1530);
      expect(sky.stars, 1);
      expect(sky.glowAt.dx, greaterThan(0.5), reason: 'past midnight the moon is over to the right');
    });

    test('turns grey and hides the stars under rain', () {
      final clear = Sky.at(at(2), dark: true);
      final rain = Sky.at(at(2), dark: true, weather: 61);
      expect(rain.stars, closeTo(0.4, 1e-9));
      expect(rain.glowStrength, lessThan(clear.glowStrength));
      expect(argb(rain.top), argb(Color.lerp(const Color(0xFF0D1530), const Color(0xFF1A1F27), 0.6)!));
      expect(argb(Sky.at(at(12), dark: false, weather: 1).top), 0xFFDAE8FA, reason: 'mainly clear stays blue');
    });

    test('falls back to 07:00 and 18:30 when sunset is not after sunrise', () {
      expect(argb(Sky.at(at(12), rise: at(9), set: at(8), dark: false).top), 0xFFDAE8FA);
    });
  });

  group('rolling text', () {
    testWidgets('is plain text without animations', (tester) async {
      await tester.pumpWidget(app(const RollText('3 on')));
      expect(find.text('3 on'), findsOneWidget);
      expect(find.byType(AnimatedSwitcher), findsNothing);
    });

    testWidgets('rolls the new value in and the old one out', (tester) async {
      withMotion();
      await tester.pumpWidget(app(const RollText('3 on')));
      await tester.pumpWidget(app(const RollText('4 on')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('3 on'), findsOneWidget);
      expect(find.text('4 on'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('3 on'), findsNothing);
      expect(find.text('4 on'), findsOneWidget);
    });
  });

  testWidgets('a moving weather icon is a plain icon without animations, and moves with them', (tester) async {
    await tester.pumpWidget(app(const WeatherGlyph(key: Key('still'), code: 61, color: Colors.blue)));
    expect(find.descendant(of: find.byKey(const Key('still')), matching: find.byType(CustomPaint)), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);

    withMotion();
    await tester.pumpWidget(app(const WeatherGlyph(key: Key('rain'), code: 61, color: Colors.blue)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.descendant(of: find.byKey(const Key('rain')), matching: find.byType(CustomPaint)), findsOneWidget,
        reason: 'the falling drops');
    await tester.pumpWidget(app(const SizedBox()));
  });

  testWidgets('a tile lights up with a flash when its lamp turns on', (tester) async {
    withMotion();
    final d = lamp();
    Widget tile() => app(SizedBox(width: 180, height: 76, child: DeviceTile(device: d, onTap: () {}, onLongPress: () {})));
    await tester.pumpWidget(tile());
    expect(find.text('Off'), findsOneWidget);

    d.state = const DeviceState(on: true, brightness: 0.6, color: 0xFF9500);
    await tester.pumpWidget(tile());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final wash = find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_WashPainter');
    expect(wash, findsOneWidget, reason: 'the light spreads over the tile');
    await tester.pumpAndSettle();
    expect(wash, findsNothing, reason: 'and fades away');
    expect(find.textContaining('60%'), findsOneWidget);
  });

  testWidgets('a tile does not flash without animations', (tester) async {
    final d = lamp();
    Widget tile() => app(SizedBox(width: 180, height: 76, child: DeviceTile(device: d, onTap: () {}, onLongPress: () {})));
    await tester.pumpWidget(tile());
    d.state = const DeviceState(on: true, brightness: 0.6, color: 0xFF9500);
    await tester.pumpWidget(tile());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_WashPainter'), findsNothing);
  });

  testWidgets('a scene ends with a tick for a moment', (tester) async {
    SharedPreferences.setMockInitialValues({});
    withMotion();
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 500)));
    await store.load();
    addTearDown(store.dispose);
    final scene = store.addScene('Evening', store.devices.take(2).toList());
    await tester.pumpWidget(ChangeNotifierProvider.value(value: store, child: app(const ScenesRow())));
    await tester.tap(find.byKey(Key('scene-${scene.id}')));
    await tester.pump();
    for (var i = 0; i < 10 && find.text('Done').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Done'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsNothing);
    expect(find.text('2 devices'), findsOneWidget);
  });

  testWidgets('a sweep runs only while active and with animations', (tester) async {
    await tester.pumpWidget(app(const Sweep(color: Colors.white, child: SizedBox(width: 100, height: 40))));
    expect(tester.hasRunningAnimations, isFalse);
    withMotion();
    await tester.pumpWidget(app(const Sweep(key: Key('s'), color: Colors.white, child: SizedBox(width: 100, height: 40))));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(
        app(const Sweep(key: Key('s'), active: false, color: Colors.white, child: SizedBox(width: 100, height: 40))));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}
