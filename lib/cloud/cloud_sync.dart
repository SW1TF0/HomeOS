import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/home.dart';
import '../state/home_store.dart';
import '../state/repository.dart';
import '../state/seed.dart';
import 'firebase.dart';

/// Keeps the homes on this device in step with the signed-in account, and
/// lets one device that stays at home carry out what the others ask for,
/// from anywhere.
///
/// What is kept in the database (rules in firebase/database.rules.json):
/// - users/UID/homes/HOME: true for each home the account can open
/// - homes/HOME/members/UID: "owner" or "member"
/// - homes/HOME/info: name, stamp (new with every save), by (the device that saved)
/// - homes/HOME/doc: the home as JSON text, without what devices are doing
/// - homes/HOME/live/hub: the device at home (device, name, seen)
/// - homes/HOME/live/states/DEVICE: what each device is doing, as the device at home sees it
/// - homes/HOME/commands/ID: device, command, by, at, status, error
class CloudSync extends ChangeNotifier implements RemoteControl {
  CloudSync({
    required this.store,
    required CloudApi this.api,
    this.deviceName = 'Home device',
    this.onHubChanged,
    this.delay = const Duration(seconds: 2),
    this.storageKey = 'smartmenukj.cloud',
  });

  /// No cloud project set up: accounts stay hidden.
  CloudSync.disabled(this.store)
      : api = null,
        deviceName = '',
        onHubChanged = null,
        delay = Duration.zero,
        storageKey = '';

  final HomeStore store;
  final CloudApi? api;

  /// How this device is called when it keeps a home online.
  final String deviceName;

  /// Told when this device starts or stops keeping a home online, so the app can keep running in the background.
  final void Function(bool on)? onHubChanged;

  /// How long changes gather before they are saved to the account.
  final Duration delay;

  /// Where this device's sign-in and id are kept in the preferences.
  final String storageKey;

  /// How long the device at home may stay silent and still count as online. It checks in every minute.
  static const hubTimeout = Duration(minutes: 3);

  bool get available => api != null;
  CloudSession? get account => api?.session;
  bool get signedIn => account != null;

  /// This install, so a device can tell its own saves from other devices' saves.
  String deviceId = '';

  bool busy = false;
  String? problem;
  DateTime? lastSync;

  bool _started = false;
  bool _syncing = false;
  bool _wasOnline = false;
  Timer? _tick;

  // ---- Starting, signing in and out -------------------------------------------------

  Future<void> start() async {
    final api = this.api;
    if (api == null || _started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    deviceId = prefs.getString('$storageKey.device') ?? FirebaseClient.newId(12);
    await prefs.setString('$storageKey.device', deviceId);
    final saved = prefs.getString('$storageKey.session');
    if (saved != null && api.session == null) {
      try {
        api.session = CloudSession.fromJson(Map<String, dynamic>.from(jsonDecode(saved) as Map));
      } catch (_) {}
    }
    api.onSession = (s) {
      if (s == null) {
        prefs.remove('$storageKey.session');
        _signedOut();
      } else {
        prefs.setString('$storageKey.session', jsonEncode(s.toJson()));
      }
    };
    store.addListener(_storeChanged);
    _tick = Timer.periodic(const Duration(seconds: 20), (_) => _checkOnline());
    if (signedIn) await syncAll();
    _follow();
  }

  /// Signs in, or makes a new account with [create]. Throws a [CloudException] with a message for the user.
  Future<void> signIn(String email, String password, {bool create = false}) async {
    final api = this.api!;
    busy = true;
    problem = null;
    notifyListeners();
    try {
      create ? await api.signUp(email, password) : await api.signIn(email, password);
    } finally {
      busy = false;
      notifyListeners();
    }
    await syncAll();
    _follow();
  }

  Future<void> resetPassword(String email) => api!.sendPasswordReset(email);

  /// Signs out. The homes stay on this device and sync again after the next sign-in.
  void signOut() => api?.signOut();

  void _signedOut() {
    _unfollow();
    store.remote = null;
    store.viaHub.clear();
    onHubChanged?.call(false);
    notifyListeners();
  }

  /// Back in the app: catch up with what other devices saved meanwhile.
  Future<void> resumed() async {
    if (!signedIn) return;
    await syncAll();
    _follow();
  }

  // ---- Homes --------------------------------------------------------------------------

  /// The home as it is saved in the account: no device states, no theme.
  static Map<String, dynamic> docOf(HomeData d) {
    final j = d.toJson()..remove('themeMode');
    for (final device in j['devices'] as List) {
      (device as Map).remove('state');
    }
    return j;
  }

  /// A short fingerprint, to tell whether a home changed since it was last saved or read.
  static String fingerprint(String doc, String name) {
    var h = 0x811c9dc5;
    for (final c in '$name\n$doc'.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return '${'$name\n$doc'.length}-${h.toRadixString(36)}';
  }

  bool _mine(HomeEntry h) => h.cloudId != null && h.account != null && h.account == account?.uid;

  Future<bool> _changedHere(HomeEntry h) async {
    final d = await store.homeData(h.id);
    return d != null && fingerprint(jsonEncode(docOf(d)), h.name) != h.synced;
  }

  /// Brings this device and the account in step: saves new and changed homes,
  /// takes in homes changed or added on other devices, and removes deleted ones.
  Future<void> syncAll() async {
    final api = this.api;
    final me = account;
    if (api == null || me == null || _syncing) return;
    _syncing = true;
    busy = true;
    notifyListeners();
    try {
      final ids = await api.get('users/${me.uid}/homes', shallow: true);
      final there = <String, Map>{};
      for (final id in ids is Map ? ids.keys.map((k) => '$k') : const <String>[]) {
        try {
          final info = await api.get('homes/$id/info');
          if (info is Map) {
            there[id] = info;
          } else {
            await api.delete('users/${me.uid}/homes/$id');
          }
        } on CloudException catch (e) {
          if (!e.permissionDenied) rethrow;
          await api.delete('users/${me.uid}/homes/$id');
        }
      }
      for (final h in List.of(store.homes)) {
        if (!_mine(h)) continue;
        final info = there[h.cloudId];
        if (info == null) {
          await _gone(h);
        } else if (await _changedHere(h)) {
          await _push(h);
        } else if (info['stamp'] != h.stamp) {
          await _pull(h);
        }
      }
      // Homes only on this device go to the account, unless they are just the sample home.
      for (final h in List.of(store.homes)) {
        if (h.account != null) continue;
        final d = await store.homeData(h.id);
        if (d != null && !isSampleHome(d)) await _create(h, d);
      }
      final here = {for (final h in store.homes) if (_mine(h)) h.cloudId};
      var added = false;
      for (final e in there.entries) {
        if (here.contains(e.key)) continue;
        if (await _download(e.key, e.value)) added = true;
      }
      // On a new phone, the sample home goes once the account's own homes are here.
      if (added) {
        for (final h in List.of(store.homes)) {
          if (h.account != null || store.homes.length <= 1) continue;
          final d = await store.homeData(h.id);
          if (d != null && isSampleHome(d)) {
            if (h.id == store.homeId) await store.openHome(store.homes.firstWhere(_mine).id);
            await store.removeHome(h);
          }
        }
      }
      problem = null;
      lastSync = DateTime.now();
    } on CloudException catch (e) {
      problem = e.message;
    } finally {
      _syncing = false;
      busy = false;
      await store.saveHomeList();
      notifyListeners();
    }
  }

  Future<void> _create(HomeEntry h, HomeData d) async {
    final me = account!;
    final id = FirebaseClient.newId();
    final doc = jsonEncode(docOf(d));
    final stamp = FirebaseClient.newId(10);
    await api!.put('homes/$id', {
      'members': {me.uid: 'owner'},
      'info': {'name': h.name, 'stamp': stamp, 'by': deviceId, 'saved': FirebaseClient.serverTime},
      'doc': doc,
    });
    await api!.put('users/${me.uid}/homes/$id', true);
    h
      ..cloudId = id
      ..account = me.uid
      ..stamp = stamp
      ..synced = fingerprint(doc, h.name);
  }

  Future<void> _push(HomeEntry h) async {
    final d = await store.homeData(h.id);
    if (d == null) return;
    final doc = jsonEncode(docOf(d));
    final stamp = FirebaseClient.newId(10);
    await api!.patch('homes/${h.cloudId}', {
      'doc': doc,
      'info': {'name': h.name, 'stamp': stamp, 'by': deviceId, 'saved': FirebaseClient.serverTime},
    });
    h
      ..stamp = stamp
      ..synced = fingerprint(doc, h.name);
  }

  Future<void> _pull(HomeEntry h) async {
    final raw = await api!.get('homes/${h.cloudId}/doc');
    final info = await api!.get('homes/${h.cloudId}/info');
    if (raw is! String || info is! Map) return;
    final d = HomeData.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    if (info['name'] case final String name) h.name = name;
    h
      ..stamp = info['stamp'] as String?
      ..synced = fingerprint(jsonEncode(docOf(d)), h.name);
    await store.replaceHome(h.id, d);
  }

  Future<bool> _download(String id, Map info) async {
    final raw = await api!.get('homes/$id/doc');
    if (raw is! String) return false;
    final d = HomeData.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    final name = info['name'] as String? ?? defaultHomeName;
    await store.addSavedHome(
        HomeEntry(
          id: store.newId('home'),
          name: name,
          cloudId: id,
          account: account!.uid,
          stamp: info['stamp'] as String?,
          synced: fingerprint(jsonEncode(docOf(d)), name),
        ),
        d);
    return true;
  }

  /// The home was deleted on another device, or is no longer shared with this account.
  Future<void> _gone(HomeEntry h) async {
    if (store.homes.length > 1) {
      await store.removeHome(h);
    } else {
      h.unlink();
    }
  }

  /// Deletes a home from the account too (or, when someone else owns it, leaves it). Call before deleting it here.
  Future<void> forget(HomeEntry h) async {
    final api = this.api;
    final me = account;
    if (api == null || me == null || !_mine(h)) return;
    final id = h.cloudId!;
    if (h.id == store.homeId) _unfollow();
    final role = await api.get('homes/$id/members/${me.uid}');
    if (role == 'owner') {
      await api.delete('homes/$id');
    } else {
      await api.delete('homes/$id/members/${me.uid}');
    }
    await api.delete('users/${me.uid}/homes/$id');
    h.unlink();
  }

  // ---- Following the open home ---------------------------------------------------------

  String? _followKey;
  String? _followedHome;
  StreamSubscription<DbEvent>? _infoSub, _liveSub, _commandSub, _hubSub;
  Map<String, Object?> _info = {};
  Map<String, Object?> _live = {};
  Map<String, Object?> _commands = {};
  final Set<String> _handled = {};
  Timer? _pushTimer, _statesTimer, _beatTimer;
  Map<String, String> _pushedStates = {};
  Map<String, Object?> _hubNode = {};
  int? _since;
  bool _saving = false;

  /// Whether this device keeps the open home online for the others.
  bool get isHub => _followKey != null && store.openHomeEntry.hub;

  String? get _cloudId => _followKey == null ? null : store.openHomeEntry.cloudId;

  void _follow() {
    final h = store.openHomeEntry;
    _followedHome = store.homeId;
    final key = signedIn && _mine(h) ? '${h.cloudId} ${h.hub}' : null;
    if (key == _followKey) return;
    _unfollow();
    _followKey = key;
    if (key == null) {
      onHubChanged?.call(false);
      notifyListeners();
      return;
    }
    final api = this.api!;
    final id = h.cloudId!;
    _infoSub = api.listen('homes/$id/info').listen(_onInfo, onError: _onListenError);
    if (h.hub) {
      store.remote = null;
      _commandSub = api.listen('homes/$id/commands').listen(_onCommands, onError: _onListenError);
      _hubSub = api.listen('homes/$id/live/hub').listen(_onOtherHub, onError: _onListenError);
      _beat();
      _beatTimer = Timer.periodic(const Duration(seconds: 60), (_) => _beat());
      _pushStates();
    } else {
      _liveSub = api.listen('homes/$id/live').listen(_onLive, onError: _onListenError);
      store.remote = this;
    }
    onHubChanged?.call(h.hub);
    notifyListeners();
  }

  void _unfollow() {
    for (final s in [_infoSub, _liveSub, _commandSub, _hubSub]) {
      s?.cancel();
    }
    _infoSub = _liveSub = _commandSub = _hubSub = null;
    for (final t in [_pushTimer, _statesTimer, _beatTimer]) {
      t?.cancel();
    }
    _pushTimer = _statesTimer = _beatTimer = null;
    _info = {};
    _live = {};
    _commands = {};
    _handled.clear();
    _pushedStates = {};
    _hubNode = {};
    _since = null;
    _followKey = null;
    if (store.remote == this) store.remote = null;
    store.viaHub.clear();
  }

  void _onListenError(Object e) {
    if (e is CloudException) {
      problem = e.message;
      notifyListeners();
      // A home that cannot be read any more was probably deleted or unshared.
      if (e.permissionDenied) unawaited(syncAll().then((_) => _follow()));
    }
  }

  /// Puts a live update into a local copy of that part of the database.
  static Map<String, Object?> apply(Map<String, Object?> tree, DbEvent e) {
    final keys = e.keys;
    final data = _own(e.data);
    if (keys.isEmpty) {
      if (!e.patch) return data is Map<String, Object?> ? data : {};
      return {...tree, ...?(data as Map<String, Object?>?)}..removeWhere((_, v) => v == null);
    }
    Map<String, Object?> node = tree;
    for (final k in keys.take(keys.length - 1)) {
      final next = node[k];
      node = next is Map<String, Object?> ? next : (node[k] = <String, Object?>{});
    }
    final last = keys.last;
    if (e.patch) {
      final current = node[last];
      node[last] = {if (current is Map<String, Object?>) ...current, ...?(data as Map<String, Object?>?)}
        ..removeWhere((_, v) => v == null);
    } else if (data == null) {
      node.remove(last);
    } else {
      node[last] = data;
    }
    return tree;
  }

  /// A changeable copy of database data.
  static Object? _own(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': _own(e.value)} : v;

  void _onInfo(DbEvent e) {
    _info = apply(_info, e);
    final h = store.openHomeEntry;
    if (!_mine(h)) return;
    if (_info.isEmpty) {
      // Deleted from the account.
      unawaited(syncAll().then((_) => _follow()));
      return;
    }
    if (_info['stamp'] != h.stamp && _info['by'] != deviceId && !_syncing) {
      unawaited(_catchUp(h));
    }
  }

  Future<void> _catchUp(HomeEntry h) async {
    try {
      if (await _changedHere(h)) {
        await _push(h);
      } else {
        await _pull(h);
      }
      await store.saveHomeList();
    } on CloudException catch (e) {
      problem = e.message;
      notifyListeners();
    }
  }

  void _storeChanged() {
    if (!signedIn) return;
    if (store.homeId != _followedHome) _follow();
    _pushTimer?.cancel();
    _pushTimer = Timer(delay, _saveOpenHome);
    if (isHub) _statesTimer ??= Timer(delay * 0.75, _pushStates);
    _checkOnline();
  }

  /// Saves the open home to the account if it changed, or puts it there if it is new.
  Future<void> _saveOpenHome() async {
    final h = store.openHomeEntry;
    if (_syncing || _saving || !signedIn) return;
    _saving = true;
    try {
      if (_mine(h)) {
        if (await _changedHere(h)) {
          await _push(h);
          await store.saveHomeList();
        }
      } else if (h.account == null && !isSampleHome(store.data)) {
        await _create(h, store.data);
        await store.saveHomeList();
        _follow();
      }
    } on CloudException catch (e) {
      problem = e.message;
      notifyListeners();
    } finally {
      _saving = false;
    }
  }

  // ---- The device at home ------------------------------------------------------------

  /// Makes this device keep the open home online for the others, or stops it.
  Future<void> setHub(bool on) async {
    final h = store.openHomeEntry;
    if (!_mine(h) || h.hub == on) return;
    h.hub = on;
    await store.saveHomeList();
    _follow();
  }

  /// Checks in as the device at home. [_since] is when this device took the job (server time).
  Future<void> _beat() async {
    final id = _cloudId;
    if (id == null) return;
    try {
      await api!.patch('homes/$id/live/hub', {
        'device': deviceId,
        'name': deviceName,
        'seen': FirebaseClient.serverTime,
        'since': _since ?? FirebaseClient.serverTime,
      });
      _since ??= (await api!.get('homes/$id/live/hub/since') as num?)?.toInt();
    } on CloudException catch (_) {
      // Offline for a moment: the next check-in tries again.
    }
  }

  /// Only one device keeps a home online: the one that took the job last.
  void _onOtherHub(DbEvent e) {
    _hubNode = apply(_hubNode, e);
    final mine = _since;
    final since = (_hubNode['since'] as num?)?.toInt();
    final other = _hubNode['device'];
    if (mine == null || since == null || other == null || other == deviceId || since <= mine) return;
    store.openHomeEntry.hub = false;
    store.toast('${_hubNode['name'] ?? 'Another device'} keeps this home online now.');
    unawaited(store.saveHomeList());
    _follow();
  }

  Future<void> _pushStates() async {
    _statesTimer = null;
    final id = _cloudId;
    if (id == null || !isHub) return;
    final now = {for (final d in store.devices) FirebaseClient.key(d.id): jsonEncode(d.state.toJson())};
    final changes = <String, Object?>{
      for (final e in now.entries)
        if (_pushedStates[e.key] != e.value) e.key: e.value,
      for (final k in _pushedStates.keys)
        if (!now.containsKey(k)) k: null,
    };
    if (changes.isEmpty) return;
    try {
      if (_pushedStates.isEmpty) {
        await api!.put('homes/$id/live/states', now);
      } else {
        await api!.patch('homes/$id/live/states', changes);
      }
      _pushedStates = now;
    } on CloudException catch (_) {
      // Sent again with the next change.
    }
  }

  void _onCommands(DbEvent e) {
    _commands = apply(_commands, e);
    final id = _cloudId;
    if (id == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _commands.entries.toList()) {
      final row = entry.value;
      if (row is! Map) continue;
      final at = (row['at'] as num?)?.toInt();
      final fresh = at != null && (now - at).abs() < 60000;
      if (row['status'] == 'new' && fresh && row['device'] is String && _handled.add(entry.key)) {
        unawaited(_run(id, entry.key, row));
      } else if (at == null || now - at > 120000) {
        // Left behind by a phone that stopped waiting.
        unawaited(api!.delete('homes/$id/commands/${entry.key}').catchError((_) {}));
      }
    }
  }

  Future<void> _run(String home, String id, Map row) async {
    String? error;
    try {
      final c = DeviceCommand.fromJson(Map<String, dynamic>.from(jsonDecode(row['command'] as String) as Map));
      error = await store.runRemoteCommand(row['device'] as String, c);
    } catch (_) {
      error = 'That command could not be read.';
    }
    try {
      await api!.patch('homes/$home/commands/$id', {'status': error == null ? 'done' : 'failed', 'error': error, 'command': null});
    } on CloudException catch (_) {}
  }

  // ---- Away from home ------------------------------------------------------------------

  Map<String, DeviceState> _hubStates = {};

  /// The device keeping the open home online, and when it last checked in.
  String? get hubName => (_live['hub'] as Map?)?['name'] as String?;
  DateTime? get hubSeen {
    final ms = ((_live['hub'] as Map?)?['seen'] as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  bool get online {
    final seen = hubSeen;
    return !isHub && _followKey != null && seen != null && DateTime.now().difference(seen) < hubTimeout;
  }

  /// Whether this device is reaching some devices through the device at home right now.
  bool get away => online && store.viaHub.isNotEmpty;

  void _onLive(DbEvent e) {
    _live = apply(_live, e);
    final states = _live['states'];
    _hubStates = {
      if (states is Map)
        for (final s in states.entries)
          if (s.value is String) FirebaseClient.unkey('${s.key}'): _state(s.value as String),
    };
    if (online) store.applyHubStates(_hubStates);
    _checkOnline(force: true);
  }

  static DeviceState _state(String raw) {
    try {
      return DeviceState.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return DeviceState.unreachable;
    }
  }

  void _checkOnline({bool force = false}) {
    final now = online;
    if (now == _wasOnline && !force) return;
    _wasOnline = now;
    if (!now) store.viaHub.clear();
    notifyListeners();
  }

  @override
  DeviceState? stateOf(String deviceId) => _hubStates[deviceId];

  @override
  Future<void> send(Device device, DeviceCommand command) async {
    final id = _cloudId;
    final api = this.api;
    if (id == null || api == null) throw const CloudException('Sign in to reach your home from here.');
    final key = await api.post('homes/$id/commands', {
      'device': device.id,
      'command': jsonEncode(command.toJson()),
      'by': deviceId,
      'at': FirebaseClient.serverTime,
      'status': 'new',
    });
    final path = 'homes/$id/commands/$key';
    try {
      final until = DateTime.now().add(delay * 6);
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(delay * 0.2);
        final row = await api.get(path);
        if (row is! Map) continue;
        if (row['status'] == 'done') return;
        if (row['status'] == 'failed') throw CloudException(row['error'] as String? ?? 'It did not work.');
      }
      throw CloudException('${hubName ?? 'Your home device'} did not answer.');
    } finally {
      unawaited(api.delete(path).catchError((_) {}));
    }
  }

  @override
  void dispose() {
    _unfollow();
    _tick?.cancel();
    store.removeListener(_storeChanged);
    super.dispose();
  }
}
