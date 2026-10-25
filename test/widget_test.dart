import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/memory_cloud.dart';
import 'package:smartmenukj/integrations/network_scan.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/app_settings.dart';
import 'package:smartmenukj/util/haptics.dart';
import 'package:smartmenukj/ui/screens/camera_playback.dart';
import 'package:smartmenukj/ui/screens/connect_screen.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/ui/screens/room_sheet.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/widgets/camera_live.dart';
import 'package:smartmenukj/ui/widgets/kj_widgets.dart';

Future<HomeStore> pumpApp(WidgetTester tester, {Size size = const Size(420, 900), http.Client? client}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final store = HomeStore(
    repository: MemoryHomeRepository(),
    client: client ?? MockClient((_) async => http.Response('[]', 200)),
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

/// Scrolls the open sheet until [f] shows, dragging near its left edge: a
/// drag in the middle of a light's sheet sets the brightness instead.
Future<void> scrollSheetTo(WidgetTester tester, Finder f) async {
  final sheet = find.byType(Scrollable).last;
  for (var i = 0; i < 30 && f.hitTestable().evaluate().isEmpty; i++) {
    await tester.dragFrom(tester.getTopLeft(sheet) + const Offset(16, 200), const Offset(0, -200));
    await tester.pumpAndSettle();
  }
}

/// Opens a device's full controls from its tile on the home screen.
Future<void> openControls(WidgetTester tester, String name) async {
  // Tiles far down are not built yet, and a .first finder cannot wait for them.
  for (var i = 0; i < 20 && find.text(name).evaluate().isEmpty; i++) {
    await tester.drag(homeScroll(), const Offset(0, -250));
    await tester.pump();
  }
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
    expect(find.text('My home'), findsOneWidget);
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
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.text('White'), findsOneWidget);
    await scrollSheetTo(tester, find.text('Rename'));
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets('the arrow on a tile opens its controls too', (tester) async {
    final store = await pumpApp(tester);
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    await scrollHomeTo(tester, find.byKey(Key('open-${tv.id}')));
    await tester.tap(find.byKey(Key('open-${tv.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Volume'), findsOneWidget);
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
    expect(find.text('Keep holding to unlock'), findsOneWidget);
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
    await scrollSheetTo(tester, ring);
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
    expect(find.text('Garage'), findsWidgets);
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

  testWidgets('map edit: resize a room from an edge, with + and -, and by pinching', (tester) async {
    final store = await pumpApp(tester);
    final office = store.rooms.firstWhere((r) => r.name == 'Office');
    final start = office.rect;
    await openMapEditor(tester);
    await tester.tapAt(tester.getTopLeft(find.byKey(Key('room-${office.id}'))) + const Offset(12, 12));
    await tester.pumpAndSettle();

    // The right edge: only the width changes.
    await dragSlowly(tester, tester.getCenter(find.byKey(Key('room-resize-r-${office.id}'))), const Offset(60, 0));
    expect(office.rect.left, start.left);
    expect(office.rect.width, greaterThan(start.width));
    expect(office.rect.height, start.height);

    // The size bar: one square per tap.
    final width = office.width, height = office.height;
    await tester.tap(find.byKey(const Key('room-width-more')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-height-less')));
    await tester.pump();
    expect(office.width, width + 1);
    expect(office.height, height - 1);
    expect(tester.widget<Text>(find.byKey(const Key('room-width'))).data, '${(width + 1).round()}');

    // Two fingers spread apart make it bigger around its middle (away from the desk lamp in the middle).
    final before = office.rect;
    final body = tester.getRect(find.byKey(Key('room-${office.id}')));
    final a = await tester.startGesture(body.topLeft + Offset(body.width * 0.25, body.height * 0.25), pointer: 7);
    final b = await tester.startGesture(body.topLeft + Offset(body.width * 0.4, body.height * 0.32), pointer: 8);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-6, -3));
      await b.moveBy(const Offset(6, 3));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(office.width, greaterThan(before.width));
    expect(office.height, greaterThan(before.height));
    expect((office.rect.center - before.center).distance, lessThan(1.01));
    await tester.tap(find.byKey(const Key('map-undo')));
    await tester.pumpAndSettle();
    expect(office.rect, before, reason: 'a pinch is one step to undo');
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
    expect(find.text('Empty floor'), findsOneWidget, reason: 'the new floor is shown');
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
    expect(find.text('3 on'), findsOneWidget);
    await tester.tap(find.byKey(const Key('status-lights')));
    await tester.pumpAndSettle();
    expect(find.text('Lights'), findsWidgets);
    await tester.tap(find.byKey(const Key('list-action')));
    await tester.pumpAndSettle();
    expect(store.devices.where((d) => d.kind == DeviceKind.light && d.state.on == true), isEmpty);
  });

  testWidgets('edit home: choose favourites and remove one', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit home'), findsWidgets);
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

  testWidgets('connect: control from anywhere shows what answers away and opens each cloud', (tester) async {
    final store = await pumpApp(tester);
    final shelly = store.addIntegration('shelly', settings: {'hosts': '10.0.0.5'});
    store.addVirtualDevice(shelly.id, 'Hall light', DeviceKind.outlet,
        props: {'host': '10.0.0.5', 'mac': 'a8032ab12345', 'gen': 2, 'component': 'switch', 'channel': 0});
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('control-anywhere')));
    await tester.pumpAndSettle();
    expect(find.text('Add the Shelly Cloud key'), findsOneWidget);
    expect(find.textContaining('of ${store.devices.where(store.networked).length} devices answer away from home'),
        findsOneWidget);
    await store.updateIntegration(shelly, settings: {'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'KEY'});
    await tester.pumpAndSettle();
    expect(find.text('Add the Shelly Cloud key'), findsNothing);
    expect(store.worksAnywhere(store.devices.firstWhere((d) => d.name == 'Hall light')), isTrue);
    await tester.tap(find.byKey(const Key('anywhere-tuya')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-access_id')), findsOneWidget);
    expect(find.textContaining('Link App Account'), findsOneWidget);
  });

  testWidgets('a TV opens with a remote and volume', (tester) async {
    final store = await pumpApp(tester);
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    await tester.longPress(find.text('TV').first);
    await tester.pumpAndSettle();
    expect(find.text('Volume'), findsOneWidget);
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

  testWidgets('scan says who made each device and what it probably is', (tester) async {
    await pumpApp(tester);
    showModalBottomSheet(
      context: tester.element(find.byType(Scaffold).first),
      isScrollControlled: true,
      builder: (_) => ScanSheet(
        scanner: FakeScanner(const [
          FoundService(name: 'Galaxy-S23', host: '192.168.88.21', port: 0, service: 'Network', integrationType: 'lan',
              hints: {'protocol': 'generic', 'vendor': 'Samsung', 'what': 'Samsung phone, tablet or TV'}),
          FoundService(name: 'iPhone or iPad', host: '192.168.88.22', port: 62078, service: 'Network', integrationType: 'lan',
              hints: {'protocol': 'generic', 'vendor': 'Apple', 'what': 'iPhone or iPad', 'guessed': '1'}),
          FoundService(name: '192.168.88.23', host: '192.168.88.23', port: 0, service: 'Network', integrationType: 'lan',
              hints: {'protocol': 'generic'}),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Samsung phone, tablet or TV · 192.168.88.21'), findsOneWidget);
    expect(find.text('Apple · 192.168.88.22'), findsOneWidget);
    expect(find.text('Network device · 192.168.88.23'), findsOneWidget);
  });

  testWidgets('make a scene on the home screen and run it', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('scene-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie night'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep them how they are now'));
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

  testWidgets('an All off scene turns everything off, and each device can be changed', (tester) async {
    final store = await pumpApp(tester);
    Device named(String n) => store.devices.firstWhere((d) => d.name == n);
    await tester.tap(find.byKey(const Key('scene-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'All off'));
    await tester.pumpAndSettle();
    expect(find.text('What should it do?'), findsNothing, reason: 'All off needs no question');
    expect(find.text('In this scene: Off'), findsWidgets);
    await tester.tap(find.byKey(const Key('pick-done')));
    await tester.pumpAndSettle();
    final scene = store.scenes.single;
    expect(scene.actions.length, store.devices.where(HomeStore.switchedTogether).length,
        reason: 'like the All off button: not heating, doors or blinds');
    expect(scene.actions.every((a) => a.isOff), isTrue);

    await store.command(named('Desk lamp'), const DeviceCommand(on: true));
    await store.command(named('Blinds'), const DeviceCommand(position: 0.8));
    await tester.tap(find.byKey(Key('scene-${scene.id}')));
    await tester.pumpAndSettle();
    expect(named('Desk lamp').state.on, isFalse);
    expect(named('Blinds').state.position, 0.8);

    // Keep the desk lamp on at half brightness.
    await tester.longPress(find.byKey(Key('scene-${scene.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('step-switch-Desk lamp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('step-switch-Desk lamp')));
    await tester.pumpAndSettle();
    expect(scene.actions.firstWhere((a) => a.deviceId == named('Desk lamp').id).command.on, isTrue);
    await tester.tap(find.byKey(const Key('scene-step-Desk lamp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scene-step-sheet')), findsOneWidget);
    await tester.tap(find.text('50%'));
    await tester.pumpAndSettle();
    final lamp = scene.actions.firstWhere((a) => a.deviceId == named('Desk lamp').id).command;
    expect((lamp.on, lamp.brightness), (true, 0.5));
    expect(named('Desk lamp').state.on, isFalse, reason: 'editing a scene does not touch the device');
    final stepList = find.descendant(of: find.byKey(const Key('scene-step-sheet')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('step-try')), 200, scrollable: stepList);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('step-try')));
    await tester.pumpAndSettle();
    expect((named('Desk lamp').state.on, named('Desk lamp').state.brightness), (true, 0.5));
    await tester.scrollUntilVisible(find.byKey(const Key('step-remove')), 200, scrollable: stepList);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('step-remove')));
    await tester.pumpAndSettle();
    expect(scene.actions.any((a) => a.deviceId == named('Desk lamp').id), isFalse);
  });

  testWidgets('desktop width uses a side rail', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));
    expect(find.text('KJ'), findsOneWidget);
    expect(find.byKey(const Key('tab-map')), findsNothing);
  });

  testWidgets('connect: Matter asks for the pairing code and explains a wrong one', (tester) async {
    const lock = MethodChannel('smartmenukj/multicast');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(lock, (_) async => true);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(lock, null));
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('spec-matter'));
    await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('Add Matter'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('matter-code')), '1234-567-8901');
    await tester.tap(find.byKey(const Key('matter-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('typo'), findsOneWidget);
    expect(find.text('Add Matter'), findsOneWidget, reason: 'the sheet stays open to try again');
    final matter = store.integrations.where((i) => i.type == 'matter').single;
    expect(matter.settings['fabric'], isA<Map>(), reason: 'the app keeps its Matter keys');
    expect(store.devices.where((d) => d.integrationId == matter.id), isEmpty);
  });

  testWidgets('a robot vacuum starts from its tile, then goes home, cleans harder and beeps', (tester) async {
    final store = await pumpApp(tester);
    final robot = store.devices.firstWhere((d) => d.name == 'Robot vacuum');
    expect(robot.state.activity, Activity.docked);
    await scrollHomeTo(tester, find.byKey(Key('open-${robot.id}')));
    await tester.tap(find.text('Robot vacuum').first);
    await tester.pump();
    expect(robot.state.activity, Activity.running);
    expect(find.text('Living · Cleaning · 100%'), findsOneWidget);

    await openControls(tester, 'Robot vacuum');
    await tester.tap(find.byKey(const Key('mode-Max')));
    await tester.pump();
    expect(robot.state.mode, 'Max');
    await tester.tap(find.byKey(const Key('robot-dock')));
    await tester.pump();
    expect(robot.state.activity, Activity.docked);
    await tester.tap(find.byKey(const Key('robot-orb')));
    await tester.pump();
    expect(robot.state.activity, Activity.running);
    await tester.tap(find.byKey(const Key('robot-orb')));
    await tester.pump();
    expect(robot.state.activity, Activity.paused);
    await tester.tap(find.byKey(const Key('robot-locate')));
    await tester.pump();
    expect(find.text('Robot vacuum is beeping.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('a working robot shows on the home screen and can be sent home from there', (tester) async {
    final store = await pumpApp(tester);
    final robot = store.devices.firstWhere((d) => d.name == 'Robot vacuum');
    expect(find.byKey(const Key('status-robots')), findsNothing);
    await store.command(robot, const DeviceCommand(action: DeviceAction.start));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('status-robots')), matching: find.text('Cleaning')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('status-robots')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('status-robots')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All go home'));
    await tester.pumpAndSettle();
    expect(robot.state.activity, Activity.docked);
  });

  testWidgets('smoke or a leak shows first on the home screen', (tester) async {
    final store = await pumpApp(tester);
    expect(find.byKey(const Key('status-danger')), findsNothing);
    final sensor = store.devices.firstWhere((d) => d.name == 'Bedroom sensor');
    sensor.state = sensor.state.merge(const DeviceState(readings: {'Smoke': 'Smoke!'}));
    store.notifyListeners();
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('status-danger')), matching: find.text('Smoke!')), findsOneWidget);
    await tester.tap(find.byKey(const Key('status-danger')));
    await tester.pumpAndSettle();
    expect(find.text('Smoke'), findsOneWidget, reason: 'the sensor opens with its readings');
    sensor.state = sensor.state.merge(const DeviceState(readings: {'Smoke': 'Clear'}));
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status-danger')), findsNothing);
  });

  testWidgets('an alarm opens its controls, arms, and asks before disarming', (tester) async {
    final store = await pumpApp(tester);
    final alarm = store.devices.firstWhere((d) => d.name == 'Alarm');
    expect(find.text('Alarm off'), findsOneWidget);
    await scrollHomeTo(tester, find.byKey(Key('open-${alarm.id}')));
    await tester.tap(find.text('Alarm').first);
    await tester.pumpAndSettle();
    expect(alarm.state.activity, Activity.disarmed, reason: 'a tap opens the controls, it does not arm');
    await tester.tap(find.byKey(const Key('arm-armAway')));
    await tester.pump();
    expect(alarm.state.activity, Activity.armedAway);

    await tester.tap(find.byKey(const Key('alarm-disarm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(alarm.state.activity, Activity.armedAway);
    await tester.tap(find.byKey(const Key('alarm-disarm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Disarm'));
    await tester.pumpAndSettle();
    expect(alarm.state.activity, Activity.disarmed);
  });

  testWidgets('an alarm with a code asks for it and never keeps it', (tester) async {
    final store = await pumpApp(tester);
    final alarm = store.devices.firstWhere((d) => d.name == 'Alarm');
    alarm.props['codeFormat'] = 'number';
    alarm.state = alarm.state.merge(const DeviceState(activity: Activity.armedHome));
    await openControls(tester, 'Alarm');
    await tester.tap(find.byKey(const Key('alarm-disarm')));
    await tester.pumpAndSettle();
    expect(find.text('Code to disarm'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    await tester.enterText(find.byType(TextField), '4321');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(alarm.state.activity, Activity.disarmed);
    expect(jsonEncode(store.data.toJson()), isNot(contains('4321')));
  });

  testWidgets('an air purifier sets its speed and preset', (tester) async {
    final store = await pumpApp(tester);
    final purifier = store.devices.firstWhere((d) => d.name == 'Air purifier');
    store.updateDevice(purifier, favorite: true);
    await tester.pump();
    await openControls(tester, 'Air purifier');
    await tester.scrollUntilVisible(find.byKey(const Key('mode-Sleep')), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const Key('mode-Sleep')));
    await tester.pump();
    expect(purifier.state.mode, 'Sleep');
    await tester.scrollUntilVisible(find.text('High'), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('High'));
    await tester.pump();
    expect((purifier.state.on, purifier.state.speed), (true, 1.0));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a button runs when its tile is tapped', (tester) async {
    final store = await pumpApp(tester);
    final scene = store.addVirtualDevice('demo', 'Movie scene', DeviceKind.button);
    store.updateDevice(scene, favorite: true);
    await tester.pump();
    await openControls(tester, 'Movie scene');
    expect(find.byKey(const Key('press-orb')), findsOneWidget);
    await tester.tap(find.byKey(const Key('press-orb')));
    await tester.pump();
    expect(find.text('Movie scene: done.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('a network camera shows the picture from its address', (tester) async {
    final pixel = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
    final asked = <String>[];
    final store = await pumpApp(tester, client: MockClient((req) async {
      asked.add('${req.url} ${req.headers['Authorization']}');
      return req.url.path == '/snap.jpg'
          ? http.Response.bytes(pixel, 200, headers: {'content-type': 'image/png'})
          : http.Response('[]', 200);
    }));
    final cam = store.addVirtualDevice('demo', 'Door camera', DeviceKind.camera);
    store.updateDevice(cam, favorite: true);
    await tester.pump();
    await openControls(tester, 'Door camera');
    expect(find.byKey(const Key('camera-view')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('camera-url')), 200, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.byKey(const Key('camera-url')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('camera-url')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'http://me:pw@10.0.0.9/snap.jpg');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(cam.has(Capability.snapshot), isTrue);
    await tester.scrollUntilVisible(find.byKey(const Key('camera-view')), -200, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-view')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(asked.last, 'http://10.0.0.9/snap.jpg Basic ${base64.encode(utf8.encode('me:pw'))}');
  });

  testWidgets('a camera without its login offers to set up live video and says what is missing', (tester) async {
    final store = await pumpApp(tester);
    final cam = store.addVirtualDevice('demo', 'Garden camera', DeviceKind.camera);
    store.updateDevice(cam, favorite: true);
    await tester.pump();
    await openControls(tester, 'Garden camera');
    expect(find.byKey(const Key('camera-setup-card')), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera-setup-start')));
    await tester.pumpAndSettle();
    expect(find.text('Live video'), findsWidgets);
    await tester.tap(find.byKey(const Key('brand-tapo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Camera account'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('camera-user'))).controller!.text, isEmpty,
        reason: 'Tapo has no default user');
    await tester.scrollUntilVisible(find.byKey(const Key('camera-connect')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('camera-setup')), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('camera-connect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-problem')), findsOneWidget);
    expect(find.textContaining('Type the camera'), findsOneWidget);
  });

  testWidgets('an MJPEG camera plays live, also full screen', (tester) async {
    final frame = [0xFF, 0xD8, ...base64.decode('iVBORw0KGgo='), 0xFF, 0xD9];
    final store = await pumpApp(tester,
        client: MockClient.streaming((req, _) async => req.url.path == '/video.mjpg'
            ? http.StreamedResponse(Stream.fromIterable([frame, frame]), 200,
                headers: {'content-type': 'multipart/x-mixed-replace; boundary=frame'})
            : http.StreamedResponse(Stream.value(utf8.encode('[]')), 200)));
    final cam = store.addVirtualDevice('demo', 'Porch camera', DeviceKind.camera);
    cam.props['mjpegUrl'] = 'http://10.0.0.9/video.mjpg';
    store.updateDevice(cam, favorite: true);
    await tester.pump();
    expect(describeState(cam), 'Live');
    await openControls(tester, 'Porch camera');
    expect(find.byKey(const Key('camera-live')), findsOneWidget);
    expect(find.text('Live'), findsWidgets);
    expect(find.descendant(of: find.byKey(const Key('camera-live')), matching: find.byType(Image)), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-rotate')), findsOneWidget);
    expect(find.text('Porch camera'), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera-close')));
    await tester.pumpAndSettle();
    expect(find.text('Playing full screen'), findsNothing);
  });

  testWidgets('an RTSP camera on a computer says where its live video plays', (tester) async {
    final store = await pumpApp(tester);
    final cam = store.addVirtualDevice('demo', 'Hall camera', DeviceKind.camera);
    cam.props['streamUrl'] = 'rtsp://10.0.0.9/stream1';
    store.updateDevice(cam, favorite: true);
    await tester.pump();
    await openControls(tester, 'Hall camera');
    expect(find.textContaining('plays in the Android app'), findsOneWidget);
    expect(find.byKey(const Key('camera-setup-tile')), findsOneWidget);
  });

  testWidgets('a Dahua or Imou camera plays its recordings from a clip, the line and the skip buttons', (tester) async {
    debugRtspPlays = true;
    debugRtspPlayer = (url) => Text('$url', key: const Key('fake-player'));
    final now = DateTime(2026, 10, 17, 18, 30);
    debugPlaybackClock = () => now;
    addTearDown(() {
      debugRtspPlays = null;
      debugRtspPlayer = null;
      debugPlaybackClock = null;
    });
    final days = <String>[];
    final store = await pumpApp(tester, client: MockClient((req) async {
      final q = req.url.queryParameters;
      if (req.url.path != '/cgi-bin/mediaFileFind.cgi') return http.Response('[]', 200);
      if (q['action'] == 'findFile') days.add(q['condition.StartTime']!.substring(0, 10));
      final day = days.isEmpty ? '' : days.last;
      return http.Response(
          switch (q['action']) {
            'factory.create' => 'result=7',
            'findNextFile' => 'found=2\r\n'
                'items[0].StartTime=$day 00:10:00\r\nitems[0].EndTime=$day 00:40:00\r\nitems[0].Flags[0]=Timing\r\n'
                'items[1].StartTime=$day 00:52:30\r\nitems[1].EndTime=$day 00:54:00\r\nitems[1].Events[0]=VideoMotion\r\n',
            _ => 'OK',
          },
          200);
    }));
    final cam = store.addVirtualDevice('demo', 'Yard camera', DeviceKind.camera);
    cam.props['streamUrl'] = 'rtsp://admin:L2AB34CD@10.0.0.7:554/cam/realmonitor?channel=1&subtype=0';
    store.updateDevice(cam, favorite: true);
    await tester.pump();
    await openControls(tester, 'Yard camera');
    expect(find.byKey(const Key('camera-live')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('camera-playback')));
    await tester.tap(find.byKey(const Key('camera-playback')));
    await tester.pumpAndSettle();

    expect(find.text('Recordings'), findsOneWidget);
    expect(find.textContaining('Tap the line below'), findsOneWidget);
    const today = '2026-10-17';
    expect(days, [today]);
    // Newest first, motion marked.
    expect(find.descendant(of: find.byKey(const Key('playback-clip-0')), matching: find.text('Motion · 1 min')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('playback-clip-1')), matching: find.text('00:10 – 00:40')), findsOneWidget);

    await tester.tap(find.byKey(const Key('playback-clip-0')));
    await tester.pumpAndSettle();
    final stamp = today.replaceAll('-', '_');
    String playing() => tester.widget<Text>(find.byKey(const Key('fake-player'))).data!;
    expect(playing(), startsWith('rtsp://admin:L2AB34CD@10.0.0.7:554/cam/playback?channel=1&subtype=0&starttime=${stamp}_00_52_30'));
    expect(find.textContaining('00:52:30'), findsOneWidget, reason: 'the time playing shows over the video');

    await tester.tap(find.byKey(const Key('playback-rewind')));
    await tester.pumpAndSettle();
    expect(playing(), contains('starttime=${stamp}_00_52_00'));
    await tester.tap(find.byKey(const Key('playback-forward')));
    await tester.pumpAndSettle();
    expect(playing(), contains('starttime=${stamp}_00_52_30'));

    // The whole day's line: its left end is midnight.
    final line = find.byKey(const Key('playback-timeline'));
    await tester.tapAt(tester.getBottomLeft(line) + const Offset(1, -20));
    await tester.pumpAndSettle();
    expect(playing(), contains('starttime=${stamp}_00_0'));

    await tester.tap(find.byKey(const Key('playback-day-1')));
    await tester.pumpAndSettle();
    expect(days.last, '2026-10-16');
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Thu 15'), findsOneWidget);
    await tester.tap(find.byKey(const Key('playback-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-live')), findsOneWidget);
  });

  testWidgets('a camera whose recordings stay in its own app has no Recordings button', (tester) async {
    debugRtspPlays = true;
    debugRtspPlayer = (url) => Text('$url');
    addTearDown(() {
      debugRtspPlays = null;
      debugRtspPlayer = null;
    });
    final store = await pumpApp(tester);
    final cam = store.addVirtualDevice('demo', 'Tapo camera', DeviceKind.camera);
    cam.props
      ..['streamUrl'] = 'rtsp://u:p@10.0.0.5/stream1'
      ..['cameraBrand'] = 'tapo';
    store.updateDevice(cam, favorite: true);
    await tester.pump();
    await openControls(tester, 'Tapo camera');
    expect(find.byKey(const Key('camera-live')), findsOneWidget);
    expect(find.byKey(const Key('camera-playback')), findsNothing);
  });

  testWidgets('an automation is made from the home screen and runs when its change happens', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('automations-open')));
    await tester.pumpAndSettle();
    expect(find.text('Automations'), findsOneWidget);
    expect(find.byKey(const Key('automations-empty')), findsOneWidget);

    Future<void> pick(String text) async {
      final list = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).last;
      await tester.scrollUntilVisible(find.text(text), 120, scrollable: list);
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('automation-add')));
    await tester.pumpAndSettle();
    await pick('Bedroom sensor');
    await pick('Temperature rises above …');
    expect(find.text('Temperature above'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '25');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await pick('Turn something on');
    await pick('Bath fan');

    expect(find.byKey(const Key('automation-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('off-after-15')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('hours-night')));
    await tester.tap(find.byKey(const Key('hours-night')));
    await tester.pumpAndSettle();
    final a = store.automations.single;
    expect((a.trigger.number, a.then.offAfter, a.from, a.to), (25.0, 15, 19 * 60, 7 * 60));

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('When Bedroom sensor Temperature rises above 25°'), findsOneWidget);
    expect(find.text('Turn Bath fan on, off again after 15 min'), findsOneWidget);

    // It gets warm at any hour: the fan turns on.
    a.from = a.to = null;
    final sensor = store.devices.firstWhere((d) => d.name == 'Bedroom sensor');
    final fan = store.devices.firstWhere((d) => d.name == 'Bath fan');
    expect(fan.state.on, isFalse);
    sensor.state = sensor.state.merge(const DeviceState(readings: {'Temperature': '25.4 °C'}));
    store.automationChanged(a);
    await tester.pumpAndSettle();
    expect(fan.state.on, isTrue);
    expect(find.textContaining('Ran '), findsOneWidget);

    await tester.tap(find.byKey(Key('automation-switch-${a.id}')));
    await tester.pump();
    expect(a.enabled, isFalse);
    await tester.tap(find.byKey(Key('automation-${a.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('automation-sheet')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('automation-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('automation-delete')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await tester.pumpAndSettle();
    expect(store.automations, isEmpty);
    expect(find.byKey(const Key('automations-empty')), findsOneWidget);
    await tester.pump(const Duration(minutes: 16));
  });

  testWidgets('the Connect tab has a way to add a camera', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tab-connect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-camera')), findsOneWidget);
  });

  testWidgets('a second home is added and opened from the home screen', (tester) async {
    final store = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Homes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Beach house');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Beach house'), findsOneWidget);
    expect(store.devices, isEmpty);
    expect(find.text('Everything is off.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My home'));
    await tester.pumpAndSettle();
    expect(find.text('My home'), findsOneWidget);
    expect(store.devices, isNotEmpty);
    await tester.tap(find.byKey(const Key('tab-map')));
    await tester.pumpAndSettle();
    final kitchen = store.rooms.firstWhere((r) => r.name == 'Kitchen');
    expect(find.byKey(Key('room-${kitchen.id}')), findsOneWidget);
  });

  testWidgets('an account is made from the profile menu, and the home device switch turns on', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 900) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    store.addVirtualDevice('demo', 'Porch light', DeviceKind.light);
    final cloud = CloudSync(store: store, api: MemoryCloud().app(), delay: const Duration(milliseconds: 10), storageKey: 'w');
    await cloud.start();
    await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud, poll: false));
    await tester.tap(find.byKey(const Key('profile-button')));
    await tester.pumpAndSettle();
    expect(find.text('Not signed in'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-sign-in')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-menu')), findsNothing);
    await tester.enterText(find.byKey(const Key('account-email')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('account-password')), '123');
    await tester.tap(find.byKey(const Key('account-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-error')), findsOneWidget, reason: 'too short');
    await tester.enterText(find.byKey(const Key('account-password')), 'secret1');
    await tester.tap(find.byKey(const Key('account-create')));
    await tester.pumpAndSettle();
    expect(cloud.signedIn, isTrue);
    expect(find.text('me@example.com'), findsWidgets);
    expect(store.homes.single.cloudId, isNotNull);
    expect(find.byKey(const Key('account-hub-status')), findsOneWidget, reason: 'nothing at home yet');
    await tester.tap(find.byKey(const Key('account-hub')));
    await tester.pumpAndSettle();
    expect(find.text('Does this device stay at home?'), findsOneWidget);
    await tester.tap(find.text('It stays at home'));
    await tester.pumpAndSettle();
    expect(cloud.isHub, isTrue);
    expect(find.textContaining('This device keeps My home online'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('account-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-sign-out')));
    await tester.pumpAndSettle();
    expect(cloud.signedIn, isFalse);
    cloud.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('away from the home Wi-Fi, the home screen says why nothing answers and how to fix it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 900) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var atHome = true;
    final store = HomeStore(
      repository: MemoryHomeRepository(),
      client: MockClient((_) async => http.Response('', 500)),
      onHomeNetwork: () async => atHome,
    );
    await store.load();
    final tasmota = store.addIntegration('tasmota');
    store.addVirtualDevice(tasmota.id, 'Porch plug', DeviceKind.outlet, props: {'host': '10.0.0.9'});
    final cloud = CloudSync(store: store, api: MemoryCloud().app(), delay: const Duration(milliseconds: 10), storageKey: 'w');
    await cloud.start();
    await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud, poll: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('away-card')), findsNothing);
    atHome = false;
    await store.checkHomeNetwork();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('away-card')), findsOneWidget);
    expect(find.textContaining('sign in and keep a second device at home online'), findsOneWidget);
    await tester.tap(find.byKey(const Key('away-set-up')));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 of 1 devices answer away from home'), findsOneWidget);
    expect(find.textContaining('Porch plug needs it'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('anywhere-hub')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('anywhere-hub')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-email')), findsOneWidget);
    cloud.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  group('profile menu and settings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<HomeStore> pumpWith(WidgetTester tester, AppSettings settings) async {
      tester.view.physicalSize = const Size(420, 900) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
      await store.load();
      await tester.pumpWidget(SmartMenuApp(store: store, settings: settings, poll: false));
      await tester.pump();
      return store;
    }

    testWidgets('the profile button is on every tab and switches homes', (tester) async {
      final store = await pumpApp(tester);
      await store.addHome('Cabin');
      await store.openHome(store.homes.first.id);
      await tester.pumpAndSettle();
      for (final tab in ['map', 'devices', 'connect', 'home']) {
        await tester.tap(find.byKey(Key('tab-$tab')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('profile-button')).hitTestable(), findsOneWidget, reason: tab);
      }
      await tester.tap(find.byKey(const Key('profile-button')).hitTestable());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile-menu')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('profile-home-${store.homes.last.id}')));
      await tester.pumpAndSettle();
      expect(store.homeName, 'Cabin');
      expect(find.byKey(const Key('profile-menu')), findsNothing);
      expect(find.text('Cabin'), findsOneWidget);
    });

    testWidgets('settings change the clock, the check interval and vibration, and are kept', (tester) async {
      final settings = AppSettings();
      final store = await pumpWith(tester, settings);
      await tester.tap(find.byKey(const Key('profile-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      await tester.tap(find.byKey(const Key('choice-12-hour')));
      await tester.pumpAndSettle();
      expect(settings.clock24, isFalse);

      final list = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const Key('choice-30 s')), 200, scrollable: list);
      await tester.tap(find.byKey(const Key('choice-30 s')));
      await tester.pumpAndSettle();
      expect(store.pollInterval, const Duration(seconds: 30));

      await tester.scrollUntilVisible(find.byKey(const Key('settings-haptics')), 200, scrollable: list);
      await tester.tap(find.byKey(const Key('settings-haptics')));
      await tester.pumpAndSettle();
      expect(Haptics.enabled, isFalse);

      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'^ (AM|PM) ')), findsOneWidget, reason: 'the 12-hour clock says AM or PM');

      final again = AppSettings();
      await again.load();
      expect(again.toJson(), {
        'clock24': false,
        'haptics': false,
        'startTab': 0,
        'checkSeconds': 30,
        'autoBackup': true,
        'restoreAsked': false,
      });
      again.haptics = true;
    });

    testWidgets('the app opens on the tab picked in settings', (tester) async {
      final settings = AppSettings()..startTab = 1;
      await pumpWith(tester, settings);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map-edit')).hitTestable(), findsOneWidget);
    });

    testWidgets('help answers open', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('profile-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-help')));
      await tester.pumpAndSettle();
      expect(find.text('Help'), findsOneWidget);
      await tester.tap(find.text('Add your devices'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Scan network'), findsWidgets);
    });
  });
}
