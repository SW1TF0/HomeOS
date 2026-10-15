import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

Future<HomeStore> pumpApp(WidgetTester tester, {Size size = const Size(420, 900)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final store = HomeStore(
    repository: MemoryHomeRepository(),
    client: MockClient((_) async => http.Response('[]', 200)),
  );
  await store.load();
  await tester.pumpWidget(SmartMenuApp(store: store, poll: false));
  await tester.pump();
  return store;
}

/// Drags in small steps, like a finger does.
Future<void> dragSlowly(WidgetTester tester, Offset from, Offset by) async {
  final g = await tester.startGesture(from);
  const steps = 12;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble());
    await tester.pump();
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('home shows favourites and tapping a tile switches it', (tester) async {
    final store = await pumpApp(tester);
    expect(find.text('SMARTMENUKJ'), findsOneWidget);
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    expect(tv.state.on, isFalse);
    await tester.tap(find.text('TV').first);
    await tester.pump();
    expect(tv.state.on, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('holding a tile opens its controls', (tester) async {
    await pumpApp(tester);
    await tester.longPress(find.text('Desk lamp').first);
    await tester.pumpAndSettle();
    expect(find.text('BRIGHTNESS'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets('map: tap a device to switch it', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-map')));
    await tester.pumpAndSettle();
    final fan = store.devices.firstWhere((d) => d.name == 'Bath fan');
    await tester.tap(find.byKey(Key('marker-${fan.id}')));
    await tester.pump();
    expect(fan.state.on, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('map edit: drag a room to move it and a device into another room', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-edit')));
    await tester.pumpAndSettle();

    final office = store.rooms.firstWhere((r) => r.name == 'Office');
    final x0 = office.x;
    await dragSlowly(tester, tester.getTopLeft(find.byKey(Key('room-${office.id}'))) + const Offset(20, 30), const Offset(120, 0));
    expect(office.x, greaterThan(x0), reason: 'the room followed the finger');

    final coffee = store.devices.firstWhere((d) => d.name == 'Coffee machine');
    final bedroom = store.rooms.firstWhere((r) => r.name == 'Bedroom');
    final from = tester.getCenter(find.byKey(Key('marker-${coffee.id}')));
    final to = tester.getTopLeft(find.byKey(Key('room-${bedroom.id}'))) + const Offset(40, 40);
    await dragSlowly(tester, from, to - from);
    expect(coffee.roomId, bedroom.id);
  });

  testWidgets('map edit: add a room', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-add-room')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Garage');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(store.rooms.map((r) => r.name), contains('Garage'));
    expect(find.text('GARAGE'), findsWidgets);
  });

  testWidgets('connect: add a Shelly by address', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('spec-shelly')), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const Key('spec-shelly')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-hosts')), '10.0.0.5');
    await tester.tap(find.byKey(const Key('integration-save')));
    await tester.pumpAndSettle();
    expect(store.integrations.map((i) => i.type), contains('shelly'));
    expect(store.integrations.firstWhere((i) => i.type == 'shelly').setting('hosts'), '10.0.0.5');
  });

  testWidgets('desktop width uses a side rail', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));
    expect(find.text('KJ'), findsOneWidget);
    expect(find.byKey(const Key('tab-map')), findsNothing);
  });
}
