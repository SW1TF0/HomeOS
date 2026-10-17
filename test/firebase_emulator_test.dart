// Runs against the local Firebase emulators, with the real database rules:
//   firebase emulators:exec --only auth,database \
//     "FIREBASE_EMULATOR=1 flutter test test/firebase_emulator_test.dart"
// (see firebase/firebase.json). Skipped otherwise.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/firebase.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

final emulator = FirebaseConfig.emulator(project: Platform.environment['FIREBASE_PROJECT'] ?? 'demo-smartmenukj');

/// Waits until [check] holds, or fails after a few seconds.
Future<void> until(bool Function() check, {String? reason}) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('Timed out${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class Phone {
  Phone(this.name) : api = FirebaseClient(emulator) {
    store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 500)));
    sync = CloudSync(store: store, api: api, deviceName: name, delay: const Duration(milliseconds: 100), storageKey: 'cloud.$name');
  }

  final String name;
  final FirebaseClient api;
  late final HomeStore store;
  late final CloudSync sync;

  Future<void> start() async {
    await store.load();
    await sync.start();
  }

  Device device(String n) => store.devices.firstWhere((d) => d.name == n);

  void dispose() {
    sync.dispose();
    store.dispose();
  }
}

void main() {
  final skip = Platform.environment['FIREBASE_EMULATOR'] == null ? 'needs the Firebase emulators' : null;
  final run = DateTime.now().millisecondsSinceEpoch;
  String email(String who) => '$who.$run@example.com';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('accounts: sign up, sign in, wrong password, existing email', () async {
    final api = FirebaseClient(emulator);
    final s = await api.signUp(email('ann'), 'secret1');
    expect(s.uid, isNotEmpty);
    await expectLater(api.signUp(email('ann'), 'secret1'), throwsA(isA<CloudException>().having((e) => e.code, 'code', 'EMAIL_EXISTS')));
    await expectLater(api.signIn(email('ann'), 'nope123'), throwsA(isA<CloudException>()));
    expect((await api.signIn(email('ann'), 'secret1')).uid, s.uid);
    await expectLater(api.signUp(email('weak'), '123'), throwsA(isA<CloudException>().having((e) => e.code, 'code', 'WEAK_PASSWORD')));
  }, skip: skip);

  test('the rules keep each account to its own homes', () async {
    final ann = FirebaseClient(emulator);
    final bob = FirebaseClient(emulator);
    final a = await ann.signUp(email('ann2'), 'secret1');
    final b = await bob.signUp(email('bob2'), 'secret1');
    final home = FirebaseClient.newId();
    await ann.put('homes/$home', {
      'members': {a.uid: 'owner'},
      'info': {'name': 'Flat'},
      'doc': '{}',
    });
    await ann.put('users/${a.uid}/homes/$home', true);
    expect(await ann.get('homes/$home/info/name'), 'Flat');
    await expectLater(bob.get('homes/$home'), throwsA(isA<CloudException>().having((e) => e.permissionDenied, 'denied', isTrue)));
    await expectLater(bob.put('homes/$home/info/name', 'Mine'), throwsA(isA<CloudException>()));
    await expectLater(bob.get('users/${a.uid}/homes'), throwsA(isA<CloudException>()));
    // A home cannot be made in someone else's name, or taken over.
    await expectLater(bob.put('homes/${FirebaseClient.newId()}', {'members': {a.uid: 'owner'}}), throwsA(isA<CloudException>()));
    await expectLater(bob.put('homes/$home/members/${b.uid}', 'owner'), throwsA(isA<CloudException>()));
    // A member may change the home and leave it, but only the owner may delete it.
    await ann.put('homes/$home/members/${b.uid}', 'member');
    expect(await bob.get('homes/$home/info/name'), 'Flat');
    await bob.put('homes/$home/info/name', 'Our flat');
    await expectLater(bob.delete('homes/$home'), throwsA(isA<CloudException>()));
    await bob.delete('homes/$home/members/${b.uid}');
    await expectLater(bob.get('homes/$home'), throwsA(isA<CloudException>()));
    await ann.delete('homes/$home');
    // Gone: nobody is a member of it any more.
    await expectLater(ann.get('homes/$home'), throwsA(isA<CloudException>()));
  }, skip: skip);

  test('live updates arrive, and keys with dots work', () async {
    final api = FirebaseClient(emulator);
    final me = await api.signUp(email('live'), 'secret1');
    final home = FirebaseClient.newId();
    await api.put('homes/$home', {
      'members': {me.uid: 'owner'},
    });
    final seen = <DbEvent>[];
    final sub = api.listen('homes/$home/live').listen(seen.add);
    await until(() => seen.isNotEmpty, reason: 'first snapshot');
    final key = FirebaseClient.key('lan:192.168.1.5');
    await api.patch('homes/$home/live/states', {key: '{"on":true}'});
    Map<String, Object?> tree() => seen.fold<Map<String, Object?>>({}, CloudSync.apply);
    await until(() => (tree()['states'] as Map?)?[key] == '{"on":true}', reason: 'the change');
    await sub.cancel();
  }, skip: skip);

  test('two devices on one account: sync, and switching through the device at home', () async {
    final phone = Phone('Phone');
    final tablet = Phone('Tablet');
    await phone.start();
    await tablet.start();
    phone.store.addVirtualDevice('demo', 'Porch light', DeviceKind.light);
    await phone.sync.signIn(email('home'), 'secret1', create: true);
    await tablet.sync.signIn(email('home'), 'secret1');
    expect(tablet.store.devices.any((d) => d.name == 'Porch light'), isTrue);

    phone.store.renameRoom(phone.store.rooms.firstWhere((r) => r.name == 'Kitchen'), 'Cuisine');
    await until(() => tablet.store.rooms.any((r) => r.name == 'Cuisine'), reason: 'the rename reaches the tablet');

    await tablet.sync.setHub(true);
    await until(() => phone.sync.online, reason: 'the tablet checks in');
    expect(phone.sync.hubName, 'Tablet');

    final porch = phone.device('Porch light');
    phone.store.viaHub.add(porch.id);
    expect(await phone.store.command(porch, const DeviceCommand(on: true)), isTrue);
    expect(tablet.device('Porch light').state.on, isTrue);
    await until(() => phone.sync.stateOf(porch.id)?.on == true, reason: 'the state comes back');

    phone.dispose();
    tablet.dispose();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
