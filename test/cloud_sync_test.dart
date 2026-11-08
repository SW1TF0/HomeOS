import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/firebase.dart';
import 'package:smartmenukj/cloud/memory_cloud.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

/// One phone or tablet with the app: its own saved homes and its own view of the cloud.
class Phone {
  Phone(this.name, MemoryCloud cloud) : api = cloud.app() {
    store = HomeStore(
      repository: MemoryHomeRepository(),
      client: MockClient((_) async {
        requests++;
        return devicesAnswer ? http.Response('{"POWER1":"ON"}', 200) : http.Response('', 500);
      }),
      onHomeNetwork: () async => atHome,
    );
    sync = CloudSync(store: store, api: api, deviceName: name, delay: const Duration(milliseconds: 20), storageKey: 'cloud.$name');
  }

  final String name;
  final MemoryCloudApi api;
  late final HomeStore store;
  late final CloudSync sync;

  /// On the home Wi-Fi, or on mobile data only.
  bool atHome = true;

  /// Whether devices on the network answer this phone, and how often it asked them.
  bool devicesAnswer = false;
  int requests = 0;

  Future<void> start() async {
    await store.load();
    await sync.start();
  }

  Device device(String name) => store.devices.firstWhere((d) => d.name == name);

  void dispose() {
    sync.dispose();
    store.dispose();
  }
}

/// Lets timers, live updates and saves run.
Future<void> settle([int ms = 200]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late MemoryCloud cloud;
  late Phone a, b;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cloud = MemoryCloud();
    a = Phone('Phone', cloud);
    b = Phone('Tablet', cloud);
    await a.start();
    await b.start();
  });

  tearDown(() {
    a.dispose();
    b.dispose();
  });

  /// Phone A makes the home its own and signs up; tablet B signs in to the same account.
  Future<void> shareHome() async {
    a.store.addVirtualDevice('demo', 'Porch light', DeviceKind.light);
    await a.sync.signIn('me@example.com', 'secret1', create: true);
    await b.sync.signIn('me@example.com', 'secret1');
    await settle();
  }

  test('a new account gets the homes of this device, and the sample home stays out', () async {
    await a.sync.signIn('me@example.com', 'secret1', create: true);
    expect(a.store.homes.single.cloudId, isNull, reason: 'the untouched sample home is not saved');
    a.store.addVirtualDevice('demo', 'Porch light', DeviceKind.light);
    await settle();
    final home = a.store.homes.single;
    expect(home.cloudId, isNotNull);
    expect(cloud.read('homes/${home.cloudId}/members'), {a.api.session!.uid: 'owner'});
    expect(cloud.read('users/${a.api.session!.uid}/homes'), {home.cloudId: true});
    expect(cloud.read('homes/${home.cloudId}/doc') as String, contains('Porch light'));
    expect(cloud.read('homes/${home.cloudId}/doc') as String, isNot(contains('"state"')));
  });

  test('another device signing in gets the homes, and its sample home goes', () async {
    await shareHome();
    expect(b.store.homes.length, 1);
    expect(b.store.homes.single.cloudId, a.store.homes.single.cloudId);
    expect(b.store.devices.any((d) => d.name == 'Porch light'), isTrue);
  });

  test('changes on one device reach the other', () async {
    await shareHome();
    a.store.renameRoom(a.store.rooms.firstWhere((r) => r.name == 'Kitchen'), 'Cuisine');
    await a.store.renameHome(a.store.homes.single, 'Flat');
    await settle(300);
    expect(b.store.rooms.any((r) => r.name == 'Cuisine'), isTrue);
    expect(b.store.homeName, 'Flat');
    b.store.addRoom(b.store.floors.first.id, name: 'Attic');
    await settle(300);
    expect(a.store.rooms.any((r) => r.name == 'Attic'), isTrue);
  });

  test('a second home made on one device shows up on the other', () async {
    await shareHome();
    await a.store.addHome('Cabin');
    a.store.addRoom(a.store.floors.first.id, name: 'Sauna');
    await settle();
    await b.sync.resumed();
    expect(b.store.homes.map((h) => h.name), containsAll(['My home', 'Cabin']));
  });

  test('a home deleted on one device goes from the other', () async {
    await shareHome();
    await a.store.addHome('Cabin');
    a.store.addRoom(a.store.floors.first.id, name: 'Sauna');
    await settle();
    await b.sync.resumed();
    final cabin = a.store.homes.firstWhere((h) => h.name == 'Cabin');
    await a.sync.forget(cabin);
    await a.store.removeHome(cabin);
    await b.sync.resumed();
    expect(b.store.homes.map((h) => h.name), ['My home']);
    expect(cloud.read('homes/${cabin.cloudId}'), isNull);
  });

  group('away from home', () {
    setUp(() async {
      await shareHome();
      await b.sync.setHub(true);
      await settle();
    });

    test('the device at home checks in and sends what devices are doing', () async {
      expect(b.sync.isHub, isTrue);
      expect(a.sync.online, isTrue);
      expect(a.sync.hubName, 'Tablet');
      await b.store.toggle(b.device('Coffee machine'));
      await settle();
      expect(a.sync.stateOf(a.device('Coffee machine').id)?.on, isTrue);
    });

    test('a device out of reach is switched through the device at home', () async {
      final porch = a.device('Porch light');
      // As if this phone's own try had failed: it now goes through the tablet.
      a.store.viaHub.add(porch.id);
      expect(await a.store.command(porch, const DeviceCommand(on: true)), isTrue);
      expect(b.device('Porch light').state.on, isTrue);
      await settle();
      expect(cloud.read('homes/${a.store.homes.single.cloudId}/commands'), isNull, reason: 'cleaned up');
    });

    test('states from the device at home show for devices this phone cannot reach', () async {
      final fan = a.device('Bath fan');
      a.store.applyHubStates({fan.id: const DeviceState(reachable: false)});
      expect(a.store.viaHub, isEmpty, reason: 'this phone still reaches it itself');
      fan.state = DeviceState.unreachable;
      await b.store.toggle(b.device('Bath fan'));
      await settle();
      expect(fan.state.on, isTrue);
      expect(a.store.viaHub, contains(fan.id));
    });

    test('a failed command on the device at home comes back as a message', () async {
      final porch = a.device('Porch light');
      a.store.viaHub.add(porch.id);
      await b.store.removeIntegration(b.store.integrations.single);
      expect(await a.store.command(porch, const DeviceCommand(on: true)), isFalse);
      expect(porch.state.on, isNot(true));
    });

    test('only the device that took the job last keeps the home online', () async {
      final c = Phone('Old phone', cloud);
      await c.start();
      await c.sync.signIn('me@example.com', 'secret1');
      await settle();
      await c.sync.setHub(true);
      await settle(300);
      expect(c.sync.isHub, isTrue);
      expect(b.sync.isHub, isFalse);
      expect(a.sync.hubName, 'Old phone');
      c.dispose();
    });

    test('off the home Wi-Fi, a command goes straight through the device at home', () async {
      final tasmota = a.store.addIntegration('tasmota');
      final plug = a.store.addVirtualDevice(tasmota.id, 'Porch plug', DeviceKind.outlet, props: {'host': '10.0.0.9'});
      await settle(300);
      await b.sync.resumed();
      expect(b.store.devices.any((d) => d.name == 'Porch plug'), isTrue);
      b.devicesAnswer = true;
      a.atHome = false;
      final asked = a.requests;
      expect(await a.store.command(plug, const DeviceCommand(on: true)), isTrue);
      expect(a.requests, asked, reason: 'nothing at home can hear this phone, so it does not try');
      expect(a.store.offHomeNetwork, isTrue);
      expect(b.device('Porch plug').state.on, isTrue);
      expect(b.requests, greaterThan(0));
    });

    test('signing out stops it', () async {
      b.sync.signOut();
      await settle();
      expect(b.sync.isHub, isFalse);
      expect(b.store.homes.single.cloudId, isNotNull, reason: 'the home stays on the tablet');
    });
  });

  test('away with nothing at home passing commands on, a command says what to do', () async {
    await shareHome();
    final tasmota = a.store.addIntegration('tasmota');
    final plug = a.store.addVirtualDevice(tasmota.id, 'Porch plug', DeviceKind.outlet, props: {'host': '10.0.0.9'});
    a.atHome = false;
    await a.store.checkHomeNetwork();
    expect(await a.store.command(plug, const DeviceCommand(on: true)), isFalse);
    expect(a.store.message.value, contains('only answers on your home Wi-Fi'));
    expect(a.store.networked(a.device('Coffee machine')), isFalse, reason: 'virtual devices work anywhere');
  });

  test('a device at home that is off the Wi-Fi does not check in', () async {
    await shareHome();
    b.atHome = false;
    await b.store.checkHomeNetwork();
    await b.sync.setHub(true);
    await settle();
    expect(b.sync.isHub, isTrue);
    expect(a.sync.online, isFalse);
  });

  test('a database without its rules is explained, with the rules to paste', () async {
    a.store.addVirtualDevice('demo', 'Porch light', DeviceKind.light);
    a.api.locked = true;
    await a.sync.signIn('me@example.com', 'secret1', create: true);
    expect(a.sync.needsRules, isTrue);
    expect(a.sync.problem, contains('still locked'));
    a.api.locked = false;
    await a.sync.syncAll();
    expect(a.sync.needsRules, isFalse);
    expect(a.sync.problem, isNull);
    expect(a.store.homes.single.cloudId, isNotNull);
  });

  test('the rules in the app are the ones in firebase/database.rules.json', () {
    expect(CloudSync.databaseRules.trim(), File('firebase/database.rules.json').readAsStringSync().trim());
  });

  test('database keys keep any device id', () {
    for (final id in ['lan:192.168.1.5', r'a#b$c[d]e/f', 'demo:manual:lamp', '100%']) {
      final k = FirebaseClient.key(id);
      expect(k, isNot(contains(RegExp(r'[.#$\[\]/]'))));
      expect(FirebaseClient.unkey(k), id);
    }
  });

  test('live updates are put together like the database', () {
    var t = CloudSync.apply({}, const DbEvent('/', {'a': 1, 'b': {'c': 2}}));
    t = CloudSync.apply(t, const DbEvent('/b/d', 3));
    t = CloudSync.apply(t, const DbEvent('/', {'a': null, 'e': 4}, patch: true));
    t = CloudSync.apply(t, const DbEvent('/b', {'c': null}, patch: true));
    expect(t, {
      'b': {'d': 3},
      'e': 4,
    });
  });
}
