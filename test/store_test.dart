import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

void main() {
  late MemoryHomeRepository repo;
  late HomeStore store;

  setUp(() async {
    repo = MemoryHomeRepository();
    store = HomeStore(
      repository: repo,
      client: MockClient((req) async => http.Response('nope', 500)),
    );
    await store.load();
  });

  tearDown(() => store.dispose());

  test('first launch shows the sample home', () {
    expect(store.floors.single.name, 'Ground floor');
    expect(store.rooms.length, 6);
    expect(store.devices, isNotEmpty);
    expect(store.favorites, isNotEmpty);
  });

  test('dropping a device on the map puts it in that room', () {
    final lamp = store.devices.firstWhere((d) => d.name == 'Floor lamp');
    final kitchen = store.rooms.firstWhere((r) => r.name == 'Kitchen');
    store.placeDevice(lamp, kitchen.floorId, kitchen.rect.center);
    expect(lamp.roomId, kitchen.id);
    store.placeDevice(lamp, kitchen.floorId, const Offset(60, 60));
    expect(lamp.roomId, isNull, reason: 'outside every room');
  });

  test('moving a room carries its devices; resizing does not', () {
    final bath = store.rooms.firstWhere((r) => r.name == 'Bath');
    final fan = store.devicesIn(bath.id).single;
    final before = fan.mapPos!;
    store.setRoomRect(bath, x: bath.x + 3, y: bath.y + 1);
    expect(fan.mapPos, before.translate(3, 1));
    store.setRoomRect(bath, width: 1, height: 20, moveDevices: false);
    expect(bath.width, HomeStore.minRoomSize, reason: 'rooms never collapse');
    expect(fan.mapPos, before.translate(3, 1));
  });

  test('assigning a room on another spot moves the device into it', () {
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    final office = store.rooms.firstWhere((r) => r.name == 'Office');
    store.updateDevice(tv, roomId: office.id);
    expect(office.contains(tv.mapPos!), isTrue);
  });

  test('virtual devices switch instantly', () async {
    final tv = store.devices.firstWhere((d) => d.name == 'TV');
    expect(tv.state.on, isFalse);
    expect(await store.command(tv, const DeviceCommand(on: true)), isTrue);
    expect(tv.state.on, isTrue);
    await store.allOff();
    expect(store.devices.where((d) => d.has(Capability.onOff) && d.kind != DeviceKind.climate).every((d) => d.state.on != true),
        isTrue);
  });

  test('a device that refuses goes back to its old state and says why', () async {
    final cfg = store.addIntegration('shelly', settings: {'hosts': '10.0.0.5'});
    final d = store.addVirtualDevice(cfg.id, 'Relay', DeviceKind.outlet);
    d.props.addAll({'host': '10.0.0.5', 'gen': 2, 'component': 'switch', 'channel': 0});
    final ok = await store.command(d, const DeviceCommand(on: true));
    expect(ok, isFalse);
    expect(d.state.on, isFalse);
    expect(d.state.reachable, isFalse);
    expect(store.message.value, contains('Relay'));
  });

  test('syncing keeps the user\'s name, room and map spot', () async {
    final hue = HomeStore(
      repository: MemoryHomeRepository(),
      client: MockClient((req) async => http.Response(
          jsonEncode({
            '1': {'name': 'Hue 1', 'type': 'Dimmable light', 'state': {'on': true, 'bri': 100, 'reachable': true}},
          }),
          200)),
    );
    await hue.load();
    final cfg = hue.addIntegration('hue', settings: {'host': '10.0.0.2', 'username': 'u'});
    expect(await hue.sync(cfg), 1);
    final light = hue.devices.firstWhere((d) => d.integrationId == cfg.id);
    final living = hue.rooms.first;
    hue.updateDevice(light, name: 'Reading light', roomId: living.id);
    expect(await hue.sync(cfg), 0);
    final again = hue.devices.where((d) => d.integrationId == cfg.id).single;
    expect(again.name, 'Reading light');
    expect(again.roomId, living.id);
    hue.dispose();
  });

  test('saves locally and restores from a backup', () async {
    store.addRoom(store.floors.first.id, name: 'Garage');
    await store.saveNow();
    expect(repo.data!.rooms.map((r) => r.name), contains('Garage'));

    final backup = store.exportJson();
    store.removeRoom(store.rooms.firstWhere((r) => r.name == 'Garage'));
    await store.importJson(backup);
    expect(store.rooms.map((r) => r.name), contains('Garage'));
    expect(() => store.importJson('{"floors": []}'), throwsFormatException);
  });

  test('removing a floor takes its devices off the map', () {
    final up = store.addFloor('Upstairs');
    final room = store.addRoom(up.id, name: 'Attic');
    final lamp = store.devices.first;
    store.placeDevice(lamp, up.id, room.rect.center);
    store.removeFloor(up);
    expect(lamp.mapPos, isNull);
    expect(store.rooms.where((r) => r.floorId == up.id), isEmpty);
  });
}
