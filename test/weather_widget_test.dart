import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/models/automation.dart';
import 'package:smartmenukj/models/scene.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/ui/screens/scenes.dart';

import 'weather_fixture.dart';

Future<HomeStore> pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 900) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final store = HomeStore(repository: MemoryHomeRepository(), client: weatherClient());
  await store.load();
  await tester.pumpWidget(SmartMenuApp(store: store, poll: false));
  await tester.pump();
  return store;
}

/// Types a town in the town search and picks the first one found.
Future<void> pickSofia(WidgetTester tester) async {
  expect(find.text('Where is your home?'), findsOneWidget);
  await tester.enterText(find.byKey(const Key('place-search')), 'Sofia');
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  expect(find.text('Sofia-Capital, Bulgaria'), findsOneWidget);
  await tester.tap(find.byKey(const Key('place-0')));
  await tester.pumpAndSettle();
}

/// Scrolls the open sheet until [f] shows, dragging near its left edge.
Future<void> scrollSheetTo(WidgetTester tester, Finder f) async {
  final sheet = find.byType(Scrollable).last;
  for (var i = 0; i < 30 && f.hitTestable().evaluate().isEmpty; i++) {
    await tester.dragFrom(tester.getTopLeft(sheet) + const Offset(16, 200), const Offset(0, -200));
    await tester.pumpAndSettle();
  }
}

/// Picks [text] in the open list of choices.
Future<void> pick(WidgetTester tester, String text) async {
  final list = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).last;
  await tester.scrollUntilVisible(find.text(text), 120, scrollable: list);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the weather pill asks for the town, then shows the weather there', (tester) async {
    final store = await pumpHome(tester);
    final pill = find.byKey(const Key('status-weather'));
    expect(find.descendant(of: pill, matching: find.text('Add your town')), findsOneWidget);
    await tester.ensureVisible(pill);
    await tester.tap(pill);
    await tester.pumpAndSettle();
    await pickSofia(tester);
    expect(store.data.place?.name, 'Sofia');

    expect(find.byKey(const Key('weather-sheet')), findsOneWidget);
    expect(find.text('12°'), findsWidgets);
    expect(find.text('Partly cloudy'), findsOneWidget);
    expect(find.text('Feels like 10° · High 15° · Low 6°'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('Today'), findsWidgets);
    expect(find.text('71%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('weather-change')));
    await tester.pumpAndSettle();
    expect(find.text('Where is your home?'), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.descendant(of: pill, matching: find.text('12° · Partly cloudy')), findsOneWidget);
    expect(find.descendant(of: pill, matching: find.text('Sofia')), findsOneWidget);
  });

  testWidgets('a scene is timed half an hour before sunset', (tester) async {
    final store = await pumpHome(tester);
    final scene = store.addScene('Dusk', store.devices.take(2).toList())..schedule = SceneSchedule(hour: 7, minute: 0);
    showSceneSheet(tester.element(find.byType(HomeScreen)), scene);
    await tester.pumpAndSettle();
    await scrollSheetTo(tester, find.byKey(const Key('schedule-by-sunset')));
    await tester.tap(find.byKey(const Key('schedule-by-sunset')));
    await tester.pumpAndSettle();
    await pickSofia(tester);
    expect((scene.schedule!.sun, scene.schedule!.lat), ('sunset', store.data.place!.lat));
    expect(find.text('Sunset'), findsWidgets);

    await scrollSheetTo(tester, find.byKey(const Key('schedule-offset--30')));
    await tester.tap(find.byKey(const Key('schedule-offset--30')));
    await tester.pumpAndSettle();
    expect(scene.schedule!.offset, -30);
    expect(find.descendant(of: find.byKey(const Key('scene-schedule-time')), matching: find.text('30 min before sunset')),
        findsOneWidget);
    expect(
        find.descendant(of: find.byKey(const Key('scene-schedule-next')), matching: find.textContaining('next at ')),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('schedule-by-sunrise')));
    await tester.pumpAndSettle();
    expect((scene.schedule!.sun, scene.schedule!.offset), ('sunrise', 0), reason: 'no new town asked for');
  });

  testWidgets('an automation runs when it gets colder outside', (tester) async {
    final store = await pumpHome(tester);
    await tester.tap(find.byKey(const Key('automations-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('automation-add')));
    await tester.pumpAndSettle();
    await pick(tester, 'Sunrise, sunset or the weather');
    await pick(tester, 'It gets colder outside than…');
    await pickSofia(tester);
    expect(find.text('Colder outside than'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await pick(tester, 'Turn something on');
    await pick(tester, 'Bath fan');
    final a = store.automations.single;
    expect((a.trigger.kind, a.trigger.number, a.trigger.deviceId), (TriggerKind.colderOutside, 3.0, AutomationTrigger.home));
    expect(find.textContaining('In Sofia'), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('When it gets colder than 3° outside'), findsOneWidget);
  });

  testWidgets('an automation runs an hour after sunrise', (tester) async {
    final store = await pumpHome(tester);
    await tester.tap(find.byKey(const Key('automations-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('automation-add')));
    await tester.pumpAndSettle();
    await pick(tester, 'Sunrise, sunset or the weather');
    await pick(tester, 'Sunrise');
    await pickSofia(tester);
    await pick(tester, '1 h after sunrise');
    await pick(tester, 'Turn something on');
    await pick(tester, 'Bath fan');
    expect((store.automations.single.trigger.kind, store.automations.single.trigger.number), (TriggerKind.sunrise, 60.0));
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('1 h after sunrise'), findsOneWidget);
  });

  testWidgets('a device is turned off in 30 minutes, the tile counts down, and the timer is cancelled', (tester) async {
    final store = await pumpHome(tester);
    final light = store.devices.firstWhere((d) => d.name == 'Ceiling light');
    expect(light.state.on, isTrue);
    await tester.longPress(find.text('Ceiling light').first);
    await tester.pumpAndSettle();
    final chip = find.byKey(const Key('timer-30'));
    await scrollSheetTo(tester, chip);
    expect(find.text('Turn off in'), findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    final timer = store.timerFor(light.id)!;
    expect(timer.on, isFalse);
    expect(timer.at.difference(DateTime.now()).inMinutes, inInclusiveRange(29, 30));
    expect(find.byKey(const Key('timer-set')), findsOneWidget);
    expect(find.textContaining('Turns off at '), findsOneWidget);
    expect(find.text('off in 30 min'), findsOneWidget);

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.textContaining('off in 30 min'), findsWidgets, reason: 'on its tile');

    await tester.longPress(find.text('Ceiling light').first);
    await tester.pumpAndSettle();
    await scrollSheetTo(tester, find.byKey(const Key('timer-cancel')));
    await tester.tap(find.byKey(const Key('timer-cancel')));
    await tester.pumpAndSettle();
    expect(store.timers, isEmpty);
    expect(find.byKey(const Key('timer-30')), findsOneWidget);
  });
}
