import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/integrations/network_scan.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/ui/screens/connect_screen.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/ui/screens/room_sheet.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/widgets/nothing_widgets.dart';

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

/// The home screen's own scroll view.
Finder homeScroll() => find.descendant(of: find.byType(HomeScreen), matching: find.byType(Scrollable)).first;

/// Scrolls the home screen to [f] and waits for it to settle.
Future<void> scrollHomeTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 250, scrollable: homeScroll());
  await tester.pumpAndSettle();
}

/// Opens a device's full controls from its tile on the home screen.
Future<void> openControls(WidgetTester tester, String name) async {
  await scrollHomeTo(tester, find.text(name).first);
  await tester.longPress(find.text(name).first);
  await tester.pumpAndSettle();
}

Future<void> openMapEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('tab-map')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('map-edit')));
  await tester.pumpAndSettle();
}

/// Answers a scan with a fixed list.
class FakeScanner extends NetworkScanner {
  FakeScanner(this.found) : super(sweep: false);
  final List<FoundService> found;

  @override
  Stream<FoundService> scan({Duration timeout = const Duration(seconds: 4)}) => Stream.fromIterable(found);
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
    await openControls(tester, 'Desk lamp');
    expect(find.text('BRIGHTNESS'), findsOneWidget);
    expect(find.text('WHITE'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Rename'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets('the arrow on a tile opens its controls too', (tester) async {
    final store = await pumpApp(tester);
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    await scrollHomeTo(tester, find.byKey(Key('open-${tv.id}')));
    await tester.tap(find.byKey(Key('open-${tv.id}')));
    await tester.pumpAndSettle();
    expect(find.text('VOLUME'), findsOneWidget);
    expect(tv.state.on, isFalse, reason: 'opening the controls does not switch it');
  });

  testWidgets('dragging sideways across a light tile dims it', (tester) async {
    final store = await pumpApp(tester);
    final light = store.devices.firstWhere((d) => d.name == 'Ceiling light');
    expect(light.state.brightness, closeTo(0.72, 0.001));
    final tile = find.ancestor(of: find.text('Ceiling light'), matching: find.byType(DeviceTile));
    await scrollHomeTo(tester, tile);
    await dragSlowly(tester, tester.getCenter(tile), const Offset(-100, 0));
    expect(light.state.brightness, lessThan(0.5));
    expect(light.state.on, isTrue);
    await dragSlowly(tester, tester.getCenter(tile), const Offset(-400, 0));
    expect(light.state.on, isFalse, reason: 'all the way left switches it off');
  });

  testWidgets('a lock only opens when held', (tester) async {
    final store = await pumpApp(tester);
    final door = store.devices.firstWhere((d) => d.name == 'Front door');
    await openControls(tester, 'Front door');
    final orb = find.byKey(const Key('lock-orb'));
    await tester.ensureVisible(orb);
    await tester.pumpAndSettle();
    await tester.tap(orb);
    await tester.pumpAndSettle();
    expect(door.state.locked, isTrue, reason: 'a tap is not enough');
    expect(find.text('KEEP HOLDING TO UNLOCK'), findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(orb));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(door.state.locked, isFalse);
    await tester.tap(orb);
    await tester.pumpAndSettle();
    expect(door.state.locked, isTrue, reason: 'locking takes one tap');
  });

  testWidgets('thermostat: buttons, presets and the dial set the target', (tester) async {
    final store = await pumpApp(tester);
    final t = store.devices.firstWhere((d) => d.name == 'Thermostat');
    await openControls(tester, 'Thermostat');
    await tester.tap(find.byKey(const Key('temp-up')));
    await tester.pumpAndSettle();
    expect(t.state.targetTemp, 22.0);
    expect(find.text('22.0°'), findsOneWidget);
    await tester.tap(find.text('Eco 18°'));
    await tester.pumpAndSettle();
    expect(t.state.targetTemp, 18.0);
    // The top of the arc is the middle of 5..35.
    final dial = find.byKey(const Key('temp-dial'));
    await tester.tapAt(tester.getTopLeft(dial) + Offset(tester.getSize(dial).width / 2, 16));
    await tester.pumpAndSettle();
    expect(t.state.targetTemp, 20.0);
  });

  testWidgets('a colour light picks its colour on the ring', (tester) async {
    final store = await pumpApp(tester);
    final lamp = store.devices.firstWhere((d) => d.name == 'Floor lamp');
    lamp.favorite = true;
    store.updateDevice(lamp);
    await tester.pumpAndSettle();
    await openControls(tester, 'Floor lamp');
    final ring = find.byKey(const Key('color-ring'));
    await tester.scrollUntilVisible(ring, 200, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    // The right-hand side of the ring is a hue of 90 degrees: yellow-green.
    final box = tester.getRect(ring);
    await tester.tapAt(Offset(box.right - 16, box.center.dy));
    await tester.pumpAndSettle();
    expect(lamp.state.color, isNotNull);
    final rgb = lamp.state.color!;
    expect((rgb >> 8) & 0xff, greaterThan(200), reason: 'green is up');
    expect(rgb & 0xff, lessThan(100), reason: 'blue is down');
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

  testWidgets('map edit: add a ready-made room in a free spot, then undo it', (tester) async {
    final store = await pumpApp(tester);
    await openMapEditor(tester);
    expect(tester.widget<IconButton>(find.byKey(const Key('map-undo'))).onPressed, isNull, reason: 'nothing to undo yet');
    await tester.tap(find.byKey(const Key('map-add-room')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garage'));
    await tester.pumpAndSettle();
    final garage = store.rooms.firstWhere((r) => r.name == 'Garage');
    expect(garage.rect.size, const Size(6, 6));
    expect(store.rooms.where((r) => r != garage).any((r) => r.rect.overlaps(garage.rect)), isFalse);
    expect(find.text('GARAGE'), findsWidgets);
    expect(find.byKey(Key('room-resize-tl-${garage.id}')), findsOneWidget, reason: 'the new room is selected');
    await tester.tap(find.byKey(const Key('map-undo')));
    await tester.pumpAndSettle();
    expect(store.rooms.map((r) => r.name), isNot(contains('Garage')));
  });

  testWidgets('map edit: draw a room by dragging', (tester) async {
    final store = await pumpApp(tester);
    final before = store.rooms.length;
    await openMapEditor(tester);
    await tester.tap(find.byKey(const Key('map-draw')));
    await tester.pumpAndSettle();
    final start = tester.getBottomLeft(find.byKey(const Key('room-room-bedroom'))) + const Offset(8, 24);
    await dragSlowly(tester, start, const Offset(150, 90));
    await tester.tap(find.text('Kids room'));
    await tester.pumpAndSettle();
    expect(store.rooms.length, before + 1);
    final kids = store.rooms.firstWhere((r) => r.name == 'Kids room');
    expect(kids.width, greaterThanOrEqualTo(6), reason: 'the drawn size, not the template size');
    expect(kids.height, greaterThanOrEqualTo(3));
    expect(kids.y, greaterThanOrEqualTo(21), reason: 'drawn below the bedroom');
    expect(find.byKey(const Key('map-draw-stop')), findsOneWidget, reason: 'still drawing, for the next room');
  });

  testWidgets('map edit: resize a room from its top-left corner', (tester) async {
    final store = await pumpApp(tester);
    final office = store.rooms.firstWhere((r) => r.name == 'Office');
    final right = office.rect.right, bottom = office.rect.bottom;
    await openMapEditor(tester);
    // Tap an empty corner of the room (its middle is where the desk lamp sits).
    await tester.tapAt(tester.getTopLeft(find.byKey(Key('room-${office.id}'))) + const Offset(12, 12));
    await tester.pumpAndSettle();
    final handle = find.byKey(Key('room-resize-tl-${office.id}'));
    await dragSlowly(tester, tester.getCenter(handle), const Offset(40, 40));
    expect(office.x, greaterThan(19));
    expect(office.rect.right, right, reason: 'the opposite corner stays put');
    expect(office.rect.bottom, bottom);
  });

  testWidgets('map edit: drag a device from the tray into a room', (tester) async {
    final store = await pumpApp(tester);
    final lamp = store.devices.firstWhere((d) => d.name == 'Desk lamp');
    store.unplaceDevice(lamp);
    await openMapEditor(tester);
    expect(find.byKey(const Key('map-tray')), findsOneWidget);
    final kitchen = store.rooms.firstWhere((r) => r.name == 'Kitchen');
    final from = tester.getCenter(find.byKey(Key('tray-${lamp.id}')));
    final to = tester.getTopLeft(find.byKey(Key('room-${kitchen.id}'))) + const Offset(30, 40);
    await dragSlowly(tester, from, to - from);
    expect(lamp.mapPos, isNotNull);
    expect(lamp.roomId, kitchen.id);
    expect(find.byKey(const Key('map-tray')), findsNothing, reason: 'nothing left off the map');
  });

  testWidgets('map edit on a phone: add a floor from the floor menu', (tester) async {
    final store = await pumpApp(tester);
    await openMapEditor(tester);
    expect(find.byKey(const Key('map-add-floor')), findsNothing, reason: 'the bar has no room for it on a phone');
    await tester.tap(find.byKey(Key('floor-${store.floors.first.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a floor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Attic');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(store.floors.map((f) => f.name), contains('Attic'));
    expect(find.text('EMPTY FLOOR'), findsOneWidget, reason: 'the new floor is shown');
  });

  testWidgets('map: tap a room to see it, then edit it from there', (tester) async {
    final store = await pumpApp(tester);
    final bath = store.rooms.firstWhere((r) => r.name == 'Bath');
    await tester.tap(find.byKey(const Key('tab-map')));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(find.byKey(Key('room-${bath.id}'))) + const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(RoomSheet), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('room-edit-map')));
    await tester.tap(find.byKey(const Key('room-edit-map')));
    await tester.pumpAndSettle();
    expect(find.byType(RoomSheet), findsNothing);
    expect(find.byKey(const Key('map-done')), findsOneWidget, reason: 'the map is in edit mode');
    expect(find.byKey(Key('room-resize-${bath.id}')), findsOneWidget, reason: 'with the bath selected');
  });

  testWidgets('a room card switches the room off and its lights back on', (tester) async {
    final store = await pumpApp(tester);
    final living = store.rooms.firstWhere((r) => r.name == 'Living');
    final ceiling = store.devices.firstWhere((d) => d.name == 'Ceiling light');
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    final power = find.byKey(Key('room-power-${living.id}'));
    await scrollHomeTo(tester, power);
    await tester.tap(power);
    await tester.pumpAndSettle();
    expect(store.devicesIn(living.id).where((d) => d.state.on == true), isEmpty);
    await tester.tap(power);
    await tester.pumpAndSettle();
    expect(ceiling.state.on, isTrue);
    expect(tv.state.on, isFalse, reason: 'room power brings back the lights only');
  });

  testWidgets('a room sheet sets all its lights at once', (tester) async {
    final store = await pumpApp(tester);
    final living = store.rooms.firstWhere((r) => r.name == 'Living');
    final card = find.byKey(Key('room-card-${living.id}'));
    await scrollHomeTo(tester, card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('room-lights')), matching: find.text('50%')));
    await tester.pumpAndSettle();
    final lights = store.devicesIn(living.id).where((d) => d.kind == DeviceKind.light);
    expect(lights, isNotEmpty);
    for (final d in lights) {
      expect(d.state.brightness, 0.5);
      expect(d.state.on, isTrue);
    }
  });

  testWidgets('the status strip lists the lights that are on and turns them off', (tester) async {
    final store = await pumpApp(tester);
    expect(find.text('3 lights on'), findsOneWidget);
    await tester.tap(find.byKey(const Key('status-lights')));
    await tester.pumpAndSettle();
    expect(find.text('LIGHTS'), findsWidgets);
    await tester.tap(find.byKey(const Key('list-action')));
    await tester.pumpAndSettle();
    expect(store.devices.where((d) => d.kind == DeviceKind.light && d.state.on == true), isEmpty);
  });

  testWidgets('edit home: choose favourites and remove one', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-edit')));
    await tester.pumpAndSettle();
    expect(find.text('EDIT HOME'), findsOneWidget);
    final before = store.favorites.length;
    await tester.tap(find.byTooltip('Remove from favourites').first);
    await tester.pumpAndSettle();
    expect(store.favorites.length, before - 1);
    await tester.tap(find.byKey(const Key('favourites-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-Blinds')));
    await tester.tap(find.byKey(const Key('pick-done')));
    await tester.pumpAndSettle();
    expect(store.favorites.map((d) => d.name), contains('Blinds'));
  });

  testWidgets('connect: add a Shelly by address', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('spec-shelly')), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.byKey(const Key('spec-shelly')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('spec-shelly')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-hosts')), '10.0.0.5');
    await tester.tap(find.byKey(const Key('integration-save')));
    await tester.pumpAndSettle();
    expect(store.integrations.map((i) => i.type), contains('shelly'));
    expect(store.integrations.firstWhere((i) => i.type == 'shelly').setting('hosts'), '10.0.0.5');
  });

  testWidgets('a TV opens with a remote and volume', (tester) async {
    final store = await pumpApp(tester);
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    await tester.longPress(find.text('TV').first);
    await tester.pumpAndSettle();
    expect(find.text('VOLUME'), findsOneWidget);
    final mute = find.byKey(const Key('mute-toggle'));
    await tester.ensureVisible(mute);
    await tester.pumpAndSettle();
    await tester.tap(mute);
    await tester.pumpAndSettle();
    expect(tv.state.muted, isTrue);
    final key = find.byKey(const Key('remote-ok'));
    await tester.scrollUntilVisible(key, 200, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(store.message.value ?? '', isNot(startsWith('TV:')), reason: 'the key press went through');
  });

  testWidgets('scan lists every device once and hides what a hub already covers', (tester) async {
    await pumpApp(tester);
    showModalBottomSheet(
      context: tester.element(find.byType(Scaffold).first),
      isScrollControlled: true,
      builder: (_) => ScanSheet(
        scanner: FakeScanner(const [
          FoundService(name: '10.0.0.5', host: '10.0.0.5', port: 8001, service: 'port', integrationType: 'lan',
              hints: {'protocol': 'samsung'}),
          FoundService(name: '[TV] Samsung', host: '10.0.0.5', port: 7676, service: 'UPnP', integrationType: 'lan',
              hints: {'protocol': 'samsung'}),
          FoundService(name: 'shelly1-abc', host: '10.0.0.9', port: 80, service: '_shelly._tcp', integrationType: 'shelly'),
          FoundService(name: 'shelly1-abc', host: '10.0.0.9', port: 80, service: 'UPnP', integrationType: 'lan'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('[TV] Samsung'), findsOneWidget);
    expect(find.text('Samsung TV · 10.0.0.5'), findsOneWidget);
    expect(find.text('shelly1-abc'), findsOneWidget);
    expect(find.byKey(const Key('add-by-address')), findsOneWidget);
  });

  testWidgets('make a scene on the home screen and run it', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('scene-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie night'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-done')));
    await tester.pumpAndSettle();
    final scene = store.scenes.single;
    expect(scene.name, 'Movie night');
    expect(scene.actions, isNotEmpty, reason: 'devices that are on are picked by default');
    await store.allOff();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('scene-${scene.id}')));
    await tester.pumpAndSettle();
    expect(store.devices.firstWhere((d) => d.name == 'Desk lamp').state.on, isTrue);
  });

  testWidgets('desktop width uses a side rail', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));
    expect(find.text('KJ'), findsOneWidget);
    expect(find.byKey(const Key('tab-map')), findsNothing);
  });
}
