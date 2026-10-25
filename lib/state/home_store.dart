import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset, Rect;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../integrations/camera/camera_setup.dart';
import '../integrations/catalog.dart';
import '../integrations/integration.dart';
import '../integrations/lan/lan_driver.dart';
import '../integrations/lan/mac_vendor.dart';
import '../integrations/lan/routeros.dart';
import '../integrations/lan/whois.dart';
import '../integrations/matter/matter_driver.dart';
import '../models/automation.dart';
import '../models/device.dart';
import '../models/home.dart';
import '../models/scene.dart';
import 'repository.dart';
import 'seed.dart';

/// Connection status of one integration, shown on the Connect screen.
class IntegrationStatus {
  const IntegrationStatus({this.ok = true, this.message, this.lastSync});
  final bool ok;
  final String? message;
  final DateTime? lastSync;
}

/// A way to reach this home's devices from anywhere: through the device
/// that stays at home (see CloudSync).
abstract class RemoteControl {
  /// Whether the device at home is online right now.
  bool get online;

  /// The state of a device as the device at home sees it.
  DeviceState? stateOf(String deviceId);

  /// Has the device at home carry out [command]. Throws with a message for the user when it cannot.
  Future<void> send(Device device, DeviceCommand command);
}

/// Holds the whole home and is the only place that changes it.
class HomeStore extends ChangeNotifier {
  HomeStore({
    required this.repository,
    http.Client? client,
    this._pollInterval = const Duration(seconds: 10),
    this.claimRun,
    this.onHomeNetwork,
    this.automate = true,
  }) : client = client ?? http.Client();

  final HomeRepository repository;
  final http.Client client;

  /// How often devices are asked what they are doing while the app is open.
  Duration get pollInterval => _pollInterval;
  Duration _pollInterval;
  set pollInterval(Duration v) {
    if (v == _pollInterval) return;
    _pollInterval = v;
    if (_pollTimer == null) return;
    _pollTimer!.cancel();
    _pollTimer = Timer.periodic(v, (_) => refreshAll());
  }

  /// Asked before a timed scene runs, with the scene and its time slot. When
  /// something else (an Android alarm) already ran that slot, it answers false.
  final Future<bool> Function(String sceneId, String slot)? claimRun;

  /// Whether this device is on a Wi-Fi or wired network right now (the app
  /// passes hasHomeNetwork from lan/net.dart). Without it the device is taken to be at home.
  final Future<bool> Function()? onHomeNetwork;

  /// Whether automations run here. Off for the short background runs of timed scenes and widget taps, which would
  /// otherwise see every change as new.
  final bool automate;

  HomeData data = HomeData();
  bool loaded = false;
  final Map<String, IntegrationDriver> _drivers = {};
  final Map<String, Future<void>> _starting = {};
  final Map<String, IntegrationStatus> status = {};

  /// Short messages for the user (errors, confirmations), shown as toasts.
  final ValueNotifier<String?> message = ValueNotifier(null);

  Timer? _saveTimer;
  Timer? _pollTimer;
  Timer? _sceneTimer;
  String? _lastScheduledMinute;
  bool _refreshing = false;
  bool _disposed = false;
  final _rand = Random();

  // ---- Loading and saving ------------------------------------------------

  Future<void> load() async {
    homeList = await repository.homes();
    data = await repository.load(homeId) ?? (homeId == firstHomeId ? seedHome() : emptyHome());
    await _loadOtherScenes();
    loaded = true;
    _startDrivers();
    notifyListeners();
  }

  void _changed({bool save = true}) {
    if (_disposed) return;
    notifyListeners();
    _watchAutomations();
    if (save) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
    }
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    await repository.save(homeId, data);
  }

  String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 20).toRadixString(36)}';

  void toast(String text) {
    _lastToast = text;
    message.value = text;
  }

  String? _lastToast;

  // ---- Queries --------------------------------------------------------------

  List<Floor> get floors => data.floors;
  List<Device> get devices => data.devices;
  List<IntegrationConfig> get integrations => data.integrations;

  List<Room> roomsOn(String floorId) => data.rooms.where((r) => r.floorId == floorId).toList();
  List<Room> get rooms => data.rooms;

  Room? room(String? id) => id == null ? null : data.rooms.where((r) => r.id == id).firstOrNull;
  Device? device(String id) => data.devices.where((d) => d.id == id).firstOrNull;
  IntegrationConfig? integration(String id) => data.integrations.where((i) => i.id == id).firstOrNull;

  List<Device> devicesIn(String roomId) => data.devices.where((d) => d.roomId == roomId).toList();
  List<Device> placedOn(String floorId) =>
      data.devices.where((d) => d.floorId == floorId && d.mapPos != null).toList();
  List<Device> get unplaced => data.devices.where((d) => d.mapPos == null).toList();
  List<Device> get favorites => data.devices.where((d) => d.favorite).toList();

  int get activeCount => data.devices.where((d) => d.countsAsOn).length;

  // ---- Homes --------------------------------------------------------------------

  /// Every home on this device, and the one that is open. Each home has its
  /// own floors, rooms, devices, connections and scenes.
  HomeList homeList = HomeList(homes: [HomeEntry(id: firstHomeId, name: defaultHomeName)], current: firstHomeId);
  List<HomeEntry> get homes => homeList.homes;
  String get homeId => homeList.current;
  String get homeName => homes.where((h) => h.id == homeId).firstOrNull?.name ?? defaultHomeName;

  /// The scenes of the homes that are not open, so their timers can be booked too.
  final Map<String, List<Scene>> otherScenes = {};
  List<Scene> get allScenes => [...data.scenes, for (final list in otherScenes.values) ...list];

  Future<void> _loadOtherScenes() async {
    otherScenes.clear();
    for (final h in homes) {
      if (h.id == homeId) continue;
      final d = await repository.load(h.id);
      if (d != null && d.scenes.isNotEmpty) otherScenes[h.id] = d.scenes;
    }
  }

  /// Closes the open home and opens another one.
  Future<void> openHome(String id) async {
    if (id == homeId || !homes.any((h) => h.id == id)) return;
    await saveNow();
    await _stopDrivers();
    viaHub.clear();
    final next = await repository.load(id) ?? emptyHome();
    if (data.scenes.isNotEmpty) otherScenes[homeId] = data.scenes;
    otherScenes.remove(id);
    // The theme belongs to the app, not to a home.
    next.themeMode = data.themeMode;
    homeList.current = id;
    data = next;
    _forgetAutomationState();
    _undo.clear();
    _startDrivers();
    _changed();
    await repository.saveHomes(homeList);
    if (_pollTimer != null) unawaited(refreshAll());
  }

  /// Adds an empty home and opens it.
  Future<HomeEntry> addHome(String name) async {
    final home = HomeEntry(id: newId('home'), name: name.trim().isEmpty ? defaultHomeName : name.trim());
    await repository.save(home.id, emptyHome()..themeMode = data.themeMode);
    homes.add(home);
    await repository.saveHomes(homeList);
    await openHome(home.id);
    return home;
  }

  Future<void> renameHome(HomeEntry home, String name) async {
    if (name.trim().isEmpty) return;
    home.name = name.trim();
    _changed(save: false);
    await repository.saveHomes(homeList);
  }

  /// Deletes a home with everything in it. The last home cannot be deleted.
  Future<bool> removeHome(HomeEntry home) async {
    if (homes.length <= 1 || !homes.contains(home)) return false;
    if (home.id == homeId) await openHome(homes.firstWhere((h) => h.id != home.id).id);
    homes.remove(home);
    otherScenes.remove(home.id);
    await repository.saveHomes(homeList);
    await repository.remove(home.id);
    _changed(save: false);
    return true;
  }

  void moveHome(int from, int to) {
    if (from < 0 || from >= homes.length) return;
    final h = homes.removeAt(from);
    homes.insert(to.clamp(0, homes.length), h);
    _changed(save: false);
    repository.saveHomes(homeList);
  }

  /// Saves the list of homes after their details changed (names, account links).
  Future<void> saveHomeList() async {
    _changed(save: false);
    await repository.saveHomes(homeList);
  }

  HomeEntry? homeEntry(String id) => homes.where((h) => h.id == id).firstOrNull;
  HomeEntry get openHomeEntry => homeEntry(homeId) ?? homes.first;

  /// A home's saved data, whether or not it is open.
  Future<HomeData?> homeData(String id) async {
    if (id == homeId) return data;
    return repository.load(id);
  }

  /// Adds a home that came from the account, without opening it.
  Future<void> addSavedHome(HomeEntry home, HomeData d) async {
    await repository.save(home.id, d..themeMode = data.themeMode);
    homes.add(home);
    if (d.scenes.isNotEmpty) otherScenes[home.id] = d.scenes;
    await saveHomeList();
  }

  /// Takes in a newer copy of a home, saved on another device. The states this
  /// device already knows stay, and connections keep running when they did not change.
  Future<void> replaceHome(String id, HomeData next) async {
    if (id != homeId) {
      next.themeMode = data.themeMode;
      await repository.save(id, next);
      if (next.scenes.isNotEmpty) {
        otherScenes[id] = next.scenes;
      } else {
        otherScenes.remove(id);
      }
      _changed(save: false);
      return;
    }
    final states = {for (final d in data.devices) d.id: d.state};
    for (final d in next.devices) {
      if (states[d.id] case final s?) d.state = s;
    }
    next.themeMode = data.themeMode;
    String connections(HomeData h) => jsonEncode([for (final i in h.integrations) i.toJson()]);
    if (connections(next) == connections(data)) {
      data = next;
      for (final cfg in data.integrations) {
        _drivers[cfg.id]?.attach(data.devices.where((d) => d.integrationId == cfg.id));
      }
    } else {
      await _stopDrivers();
      data = next;
      _startDrivers();
    }
    _undo.clear();
    _changed();
  }

  // ---- Theme ------------------------------------------------------------------

  String get themeMode => data.themeMode;
  set themeMode(String v) {
    data.themeMode = v;
    _changed();
  }

  // ---- Floors and rooms ---------------------------------------------------------

  Floor addFloor(String name) {
    _checkpoint();
    final f = Floor(id: newId('floor'), name: name);
    data.floors.add(f);
    _changed();
    return f;
  }

  void renameFloor(Floor f, String name) {
    _checkpoint();
    f.name = name;
    _changed();
  }

  void removeFloor(Floor f) {
    if (data.floors.length <= 1) return;
    _checkpoint();
    final roomIds = data.rooms.where((r) => r.floorId == f.id).map((r) => r.id).toSet();
    data.rooms.removeWhere((r) => r.floorId == f.id);
    for (final d in data.devices) {
      if (d.floorId == f.id || roomIds.contains(d.roomId)) {
        d.floorId = null;
        d.mapPos = null;
        d.roomId = null;
      }
    }
    data.floors.remove(f);
    _changed();
  }

  Room addRoom(String floorId, {String? name, double x = 2, double y = 2, double width = 8, double height = 6}) {
    _checkpoint();
    final r = Room(
      id: newId('room'),
      floorId: floorId,
      name: uniqueRoomName(name ?? 'Room'),
      x: x,
      y: y,
      width: width,
      height: height,
    );
    data.rooms.add(r);
    _changed();
    return r;
  }

  static const minRoomSize = 2.0;

  /// Moves or resizes a room. Devices inside a moved room travel with it.
  void setRoomRect(Room r, {double? x, double? y, double? width, double? height, bool moveDevices = true}) {
    _checkpoint();
    final dx = (x ?? r.x) - r.x;
    final dy = (y ?? r.y) - r.y;
    r.x = x ?? r.x;
    r.y = y ?? r.y;
    r.width = max(minRoomSize, width ?? r.width);
    r.height = max(minRoomSize, height ?? r.height);
    if (moveDevices && (dx != 0 || dy != 0)) {
      for (final d in data.devices) {
        if (d.roomId == r.id && d.mapPos != null) d.mapPos = d.mapPos!.translate(dx, dy);
      }
    }
    _reassignRooms(r.floorId);
    _changed();
  }

  /// After rooms change shape: devices left outside their room join the room
  /// they now stand in (or none), and devices without a room join the one around them.
  void _reassignRooms(String floorId) {
    final rooms = roomsOn(floorId)..sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
    for (final d in data.devices) {
      final pos = d.mapPos;
      if (pos == null || d.floorId != floorId) continue;
      final current = room(d.roomId);
      if (current != null && current.floorId == floorId && current.contains(pos)) continue;
      d.roomId = rooms.where((r) => r.contains(pos)).firstOrNull?.id;
    }
  }

  void renameRoom(Room r, String name) {
    _checkpoint();
    r.name = name;
    _changed();
  }

  void removeRoom(Room r) {
    _checkpoint();
    data.rooms.remove(r);
    for (final d in data.devices) {
      if (d.roomId == r.id) d.roomId = null;
    }
    _reassignRooms(r.floorId);
    _changed();
  }

  /// [base], or "[base] 2", "[base] 3"... so no two rooms share a name.
  String uniqueRoomName(String base) {
    final taken = data.rooms.map((r) => r.name.toLowerCase()).toSet();
    if (!taken.contains(base.toLowerCase())) return base;
    var n = 2;
    while (taken.contains('${base.toLowerCase()} $n')) {
      n++;
    }
    return '$base $n';
  }

  /// Top-left corner of an empty [width] × [height] spot on a floor, as close
  /// to [near] (the spot's wanted centre) as the other rooms allow.
  Offset freeSpot(String floorId, double width, double height, {Offset? near}) {
    final taken = roomsOn(floorId).map((r) => r.rect).toList();
    final want = near ?? Offset(width / 2, height / 2);
    var right = want.dx + width, bottom = want.dy + height;
    for (final r in taken) {
      right = max(right, r.right);
      bottom = max(bottom, r.bottom);
    }
    Offset? best;
    var bestDist = double.infinity;
    for (var y = 0.0; y <= bottom + 1; y++) {
      for (var x = 0.0; x <= right + 1; x++) {
        final spot = Rect.fromLTWH(x, y, width, height);
        if (taken.any((r) => r.overlaps(spot))) continue;
        final dist = (spot.center - want).distanceSquared;
        if (dist < bestDist) {
          bestDist = dist;
          best = Offset(x, y);
        }
      }
    }
    return best ?? Offset(0, bottom + 1);
  }

  /// Adds a room of the same size (without its devices) in the nearest free spot.
  Room duplicateRoom(Room r) {
    final at = freeSpot(r.floorId, r.width, r.height, near: r.rect.center.translate(r.width, 0));
    return addRoom(r.floorId, name: r.name, x: at.dx, y: at.dy, width: r.width, height: r.height);
  }

  /// Changes the order rooms are listed in on the home screen.
  void moveRoom(int from, int to) {
    final r = data.rooms.removeAt(from);
    data.rooms.insert(to.clamp(0, data.rooms.length), r);
    _changed();
  }

  // ---- Undo for the floor plan ---------------------------------------------------

  final List<_Layout> _undo = [];

  void _checkpoint() {
    _undo.add(_Layout.of(data));
    if (_undo.length > 50) _undo.removeAt(0);
  }

  bool get canUndoLayout => _undo.isNotEmpty;

  /// Puts floors, rooms and device spots back the way they were before the last change.
  void undoLayout() {
    if (_undo.isEmpty) return;
    _undo.removeLast().restore(data);
    _changed();
  }

  void clearLayoutUndo() {
    if (_undo.isEmpty) return;
    _undo.clear();
    notifyListeners();
  }

  // ---- Devices -------------------------------------------------------------------

  /// Puts a device on the map. It joins whichever room it lands in.
  void placeDevice(Device d, String floorId, Offset pos) {
    _checkpoint();
    d.floorId = floorId;
    d.mapPos = pos;
    final inside = data.rooms.where((r) => r.floorId == floorId && r.contains(pos)).toList()
      ..sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
    d.roomId = inside.isEmpty ? null : inside.first.id;
    _changed();
  }

  void unplaceDevice(Device d) {
    _checkpoint();
    d.mapPos = null;
    d.floorId = null;
    _changed();
  }

  void updateDevice(Device d, {String? name, DeviceKind? kind, String? roomId, bool clearRoom = false, bool? favorite}) {
    if (name != null && name.trim().isNotEmpty) d.name = name.trim();
    if (kind != null && kind != d.kind && integration(d.integrationId)?.type == 'demo') {
      // A virtual device becomes a believable one of its new kind.
      d.capabilities = defaultCapabilities(kind);
      d.state = _initialState(kind);
      d.props = _virtualProps(kind);
    }
    if (kind != null) d.kind = kind;
    if (clearRoom || roomId != null) _checkpoint();
    if (clearRoom) {
      d.roomId = null;
    } else if (roomId != null) {
      d.roomId = roomId;
      final r = room(roomId);
      // Keep the map honest: a device assigned to a room on another spot moves into it.
      if (r != null && (d.mapPos == null || d.floorId != r.floorId || !r.contains(d.mapPos!))) {
        d.floorId = r.floorId;
        d.mapPos = r.rect.center;
      }
    }
    if (favorite != null) d.favorite = favorite;
    _changed();
  }

  /// Makes exactly [picked] the favourites.
  void setFavorites(Iterable<Device> picked) {
    final ids = picked.map((d) => d.id).toSet();
    for (final d in data.devices) {
      d.favorite = ids.contains(d.id);
    }
    _changed();
  }

  /// Changes the order of the favourites on the home screen. Other devices keep their place.
  void moveFavorite(int from, int to) {
    final favs = favorites;
    final slots = [for (var i = 0; i < data.devices.length; i++) if (data.devices[i].favorite) i];
    final d = favs.removeAt(from);
    favs.insert(to.clamp(0, favs.length), d);
    for (var k = 0; k < slots.length; k++) {
      data.devices[slots[k]] = favs[k];
    }
    _changed();
  }

  void removeDevice(Device d) {
    data.devices.remove(d);
    for (final s in data.scenes) {
      s.actions.removeWhere((a) => a.deviceId == d.id);
    }
    data.automations.removeWhere((a) => a.trigger.deviceId == d.id || a.then.deviceId == d.id);
    _changed();
    _forgetMatter(d);
  }

  // ---- Sample home ---------------------------------------------------------------------

  /// Devices from the sample home shown on first launch.
  List<Device> get sampleDevices =>
      data.devices.where((d) => d.integrationId == demoIntegrationId && d.externalId.startsWith('manual:') && _seedIds.contains(d.id)).toList();

  static final Set<String> _seedIds = seedHome().devices.map((d) => d.id).toSet();

  /// Whether real devices have joined while the sample ones are still around.
  bool get showSampleCleanup => sampleDevices.isNotEmpty && data.devices.any((d) => d.integrationId != demoIntegrationId);

  /// Removes the sample devices, and the sample rooms if nothing real is in them.
  void removeSampleHome({bool rooms = true}) {
    final ids = sampleDevices.map((d) => d.id).toSet();
    _undo.clear();
    data.devices.removeWhere((d) => ids.contains(d.id));
    for (final s in data.scenes) {
      s.actions.removeWhere((a) => ids.contains(a.deviceId));
    }
    data.automations.removeWhere((a) => ids.contains(a.trigger.deviceId) || ids.contains(a.then.deviceId));
    if (rooms) {
      final seedRooms = seedHome().rooms.map((r) => r.id).toSet();
      data.rooms.removeWhere((r) => seedRooms.contains(r.id) && !data.devices.any((d) => d.roomId == r.id));
    }
    _changed();
  }

  // ---- Scenes --------------------------------------------------------------------------

  List<Scene> get scenes => data.scenes;
  Scene? scene(String id) => data.scenes.where((s) => s.id == id).firstOrNull;

  /// Creates a scene that remembers what [devices] are doing right now, or that turns them all off or on.
  Scene addScene(String name, Iterable<Device> devices, {String icon = 'auto', bool? turnOn}) {
    SceneAction make(Device d) => (turnOn == null ? null : SceneAction.turn(d, turnOn)) ?? SceneAction.capture(d);
    final s = Scene(id: newId('scene'), name: name, icon: icon, actions: devices.map(make).toList());
    data.scenes.add(s);
    _changed();
    return s;
  }

  void updateScene(Scene s, {String? name, String? icon, Iterable<Device>? capture, SceneSchedule? schedule, bool clearSchedule = false}) {
    if (name != null && name.trim().isNotEmpty) s.name = name.trim();
    if (icon != null) s.icon = icon;
    if (capture != null) s.actions = capture.map(SceneAction.capture).toList();
    if (clearSchedule) {
      s.schedule = null;
    } else if (schedule != null) {
      s.schedule = schedule;
    }
    _changed();
  }

  /// Sets what [s] does to one device, adding the device when it was not in the scene.
  void setSceneStep(Scene s, SceneAction a) {
    final i = s.actions.indexWhere((x) => x.deviceId == a.deviceId);
    i < 0 ? s.actions.add(a) : s.actions[i] = a;
    _changed();
  }

  void removeSceneStep(Scene s, String deviceId) {
    s.actions.removeWhere((x) => x.deviceId == deviceId);
    _changed();
  }

  void removeScene(Scene s) {
    data.scenes.remove(s);
    data.automations.removeWhere((a) => a.then.sceneId == s.id);
    _changed();
  }

  void moveScene(int from, int to) {
    final s = data.scenes.removeAt(from);
    data.scenes.insert(to.clamp(0, data.scenes.length), s);
    _changed();
  }

  /// Puts every device of [s] in its saved state. Returns how many answered.
  Future<int> runScene(Scene s, {bool quiet = false}) async {
    final jobs = <Future<bool>>[];
    for (final a in s.actions) {
      final d = device(a.deviceId);
      if (d == null) continue;
      jobs.add(command(d, a.command));
    }
    final ok = (await Future.wait(jobs)).where((r) => r).length;
    if (!quiet || ok < jobs.length) {
      toast(ok == jobs.length ? '${s.name}: done.' : '${s.name}: ${jobs.length - ok} of ${jobs.length} devices did not answer.');
    }
    return ok;
  }

  /// Runs scheduled scenes whose time has come. Called every few seconds.
  void runDueScenes([DateTime? now]) {
    final t = now ?? DateTime.now();
    final key = SceneSchedule.slot(t);
    if (key == _lastScheduledMinute) return;
    _lastScheduledMinute = key;
    for (final s in data.scenes) {
      if (s.schedule?.matches(t) ?? false) _runTimed(s, key);
    }
  }

  Future<void> _runTimed(Scene s, String slot) async {
    if (claimRun != null && !await claimRun!(s.id, slot)) return;
    await runScene(s);
  }

  // ---- Automations ----------------------------------------------------------------------

  List<Automation> get automations => data.automations;

  /// When each automation last ran here, to show in the list.
  final Map<String, DateTime> automationRuns = {};

  /// Each device's state when automations last looked, to see what changed since.
  final Map<String, DeviceState> _seen = {};
  final Map<String, Timer> _offTimers = {};
  bool _watching = false;

  void addAutomation(Automation a) {
    data.automations.add(a);
    _changed();
  }

  /// Saves a change made to [a] in place.
  void automationChanged(Automation a) => _changed();

  void removeAutomation(Automation a) {
    data.automations.remove(a);
    _offTimers.remove(a.id)?.cancel();
    _changed();
  }

  void _forgetAutomationState() {
    _seen.clear();
    for (final t in _offTimers.values) {
      t.cancel();
    }
    _offTimers.clear();
  }

  /// Runs every automation whose change has just happened. Called after every change to the home.
  void _watchAutomations() {
    if (!automate || !loaded || _watching) return;
    _watching = true;
    try {
      final now = clock.now();
      final due = <Automation>[];
      for (final a in data.automations) {
        if (!a.enabled) continue;
        final before = _seen[a.trigger.deviceId];
        final after = device(a.trigger.deviceId)?.state;
        if (before == null || after == null || identical(before, after)) continue;
        if (!a.trigger.fired(before, after) || !a.allowedAt(now)) continue;
        // One that sets itself off again (a lamp that turns itself off when on) waits a moment between runs.
        final last = automationRuns[a.id];
        if (last != null && now.difference(last) < const Duration(seconds: 3)) continue;
        automationRuns[a.id] = now;
        due.add(a);
      }
      _seen
        ..clear()
        ..addAll({for (final d in data.devices) d.id: d.state});
      for (final a in due) {
        unawaited(runAutomation(a));
      }
    } finally {
      _watching = false;
    }
  }

  /// Does what [a] does, whatever happened.
  Future<void> runAutomation(Automation a) async {
    final step = a.then;
    if (step.sceneId case final id?) {
      final s = scene(id);
      if (s != null) await runScene(s, quiet: true);
      return;
    }
    final d = device(step.deviceId ?? '');
    final turn = d == null ? null : SceneAction.turn(d, step.on);
    if (d == null || turn == null) return;
    _offTimers.remove(a.id)?.cancel();
    await command(d, turn.command);
    if (step.on && step.offAfter != null) {
      _offTimers[a.id] = Timer(Duration(minutes: step.offAfter!), () {
        _offTimers.remove(a.id);
        final still = device(d.id);
        final off = still == null ? null : SceneAction.turn(still, false);
        if (still != null && off != null) unawaited(command(still, off.command));
      });
    }
  }

  Device addVirtualDevice(String integrationId, String name, DeviceKind kind, {Map<String, dynamic>? props}) {
    final ext = 'manual:${newId('dev')}';
    final d = Device(
      id: Device.idFor(integrationId, ext),
      name: name,
      kind: kind,
      integrationId: integrationId,
      externalId: ext,
      props: props ?? (integration(integrationId)?.type == 'demo' ? _virtualProps(kind) : null),
      // Virtual devices start with a believable state; real ones wait for theirs.
      state: props?['component'] != null ? const DeviceState() : _initialState(kind),
    );
    if (props?['component'] != null) d.capabilities = _mqttCaps(props!);
    data.devices.add(d);
    _drivers[integrationId]?.attach([d]);
    _changed();
    return d;
  }

  static Set<Capability> _mqttCaps(Map<String, dynamic> props) => switch (props['component']) {
        'light' => {Capability.onOff, if (props['brightness_command_topic'] != null) Capability.brightness},
        'sensor' || 'binary_sensor' => {Capability.readings},
        'cover' => {Capability.position},
        'lock' => {Capability.lock},
        _ => {Capability.onOff},
      };

  static DeviceState _initialState(DeviceKind kind) => switch (kind) {
        DeviceKind.light => const DeviceState(on: false, brightness: 0.8, colorTempK: 3000),
        DeviceKind.climate => const DeviceState(on: true, targetTemp: 21, currentTemp: 20.5),
        DeviceKind.cover || DeviceKind.garage => const DeviceState(position: 0),
        DeviceKind.lock => const DeviceState(locked: true),
        DeviceKind.sensor => const DeviceState(readings: {'Temperature': '21.0 °C', 'Humidity': '45 %'}),
        DeviceKind.vacuum => const DeviceState(activity: Activity.docked, battery: 1, mode: 'Balanced'),
        DeviceKind.mower => const DeviceState(activity: Activity.docked, battery: 1),
        DeviceKind.appliance => const DeviceState(activity: Activity.idle),
        DeviceKind.alarm => const DeviceState(activity: Activity.disarmed),
        DeviceKind.purifier => const DeviceState(on: false, speed: 0.5, mode: 'Auto'),
        DeviceKind.humidifier => const DeviceState(on: false, targetHumidity: 50, currentHumidity: 42),
        DeviceKind.button || DeviceKind.camera => const DeviceState(),
        _ => const DeviceState(on: false),
      };

  /// What a virtual device of [kind] offers to choose from.
  static Map<String, dynamic> _virtualProps(DeviceKind kind) => switch (kind) {
        DeviceKind.vacuum => {'modes': ['Quiet', 'Balanced', 'Turbo', 'Max']},
        DeviceKind.purifier => {'modes': ['Auto', 'Sleep', 'Turbo']},
        DeviceKind.alarm => {'arms': ['home', 'away', 'night']},
        _ => {},
      };

  // ---- Control ----------------------------------------------------------------------

  /// Reaches the devices through the device at home, when this device is away.
  RemoteControl? remote;

  /// Devices shown as the device at home sees them, because this device cannot reach them itself.
  final Set<String> viaHub = {};

  RemoteControl? get _hub => remote != null && remote!.online ? remote : null;

  /// On mobile data only, with no Wi-Fi: devices at home cannot hear this device, so commands go
  /// through the device at home straight away. Checked with every refresh and before commands.
  bool get offHomeNetwork => _offHomeNetwork;
  bool _offHomeNetwork = false;

  Future<bool> checkHomeNetwork() async {
    final check = onHomeNetwork;
    if (check == null) return !_offHomeNetwork;
    bool on;
    try {
      on = await check();
    } catch (_) {
      on = true;
    }
    if (on == _offHomeNetwork) {
      _offHomeNetwork = !on;
      for (final driver in _drivers.values) {
        driver.away = _offHomeNetwork;
      }
      _changed(save: false);
    }
    return on;
  }

  /// Whether [d] is reached over the network, rather than living only in the app.
  bool networked(Device d) => integration(d.integrationId)?.type != 'demo';

  /// Whether [d] can be switched from anywhere with nothing left at home: through its maker's cloud (Shelly, Tuya,
  /// Imou) or Home Assistant's outside address. Everything else needs a device at home to pass commands on.
  bool worksAnywhere(Device d) => !networked(d) || (_drivers[d.integrationId]?.reachesAnywhere(d) ?? false);

  /// New states from the device at home. They show for the devices this device cannot reach itself.
  void applyHubStates(Map<String, DeviceState> states) {
    var changed = false;
    for (final d in data.devices) {
      final s = states[d.id];
      if (s == null) continue;
      if (viaHub.contains(d.id) || _drivers[d.integrationId] == null || !d.state.reachable) {
        d.state = s;
        viaHub.add(d.id);
        changed = true;
      }
    }
    if (changed) _changed(save: false);
  }

  /// Carries out a command sent from another device. Returns what went wrong, or null.
  Future<String?> runRemoteCommand(String deviceId, DeviceCommand c) async {
    final d = device(deviceId);
    if (d == null) return 'That device is not in this home any more.';
    _lastToast = null;
    if (await command(d, c)) return null;
    return _lastToast ?? '${d.name} did not answer.';
  }

  final Map<String, int> _commandTurn = {};

  /// Changes a device. The screen updates at once; if the device refuses,
  /// the old state comes back and the user is told why. Away from home, the
  /// device at home passes the change on.
  Future<bool> command(Device d, DeviceCommand c) async {
    final before = d.state;
    // A newer command to the same device (a second tap, an automation) wins over this one's late answer.
    final turn = _commandTurn[d.id] = (_commandTurn[d.id] ?? 0) + 1;
    bool overtaken() => _commandTurn[d.id] != turn;
    d.state = d.state.applyCommand(c);
    _changed();
    final driver = _drivers[d.integrationId];
    final hub = _hub;
    final anywhere = driver != null && driver.reachesAnywhere(d);
    if (hub != null && (driver == null || (viaHub.contains(d.id) && !anywhere))) return _sendViaHub(hub, d, c, before);
    if ((hub != null || anywhere) && networked(d)) {
      // Off the home Wi-Fi, a device with its own way in from outside is reached that way, the others through home.
      final atHome = await checkHomeNetwork();
      if (!atHome && !anywhere) return _sendViaHub(hub!, d, c, before);
    }
    if (driver == null) {
      d.state = before;
      _changed(save: false);
      toast('${d.name}: its connection is missing.');
      return false;
    }
    try {
      final confirmed = await driver.send(d, c);
      if (overtaken()) return true;
      if (confirmed != null) d.state = d.state.merge(confirmed);
      if (!d.state.reachable) d.state = d.state.merge(const DeviceState(reachable: true));
      _changed();
      return true;
    } catch (e) {
      if (hub != null) return _sendViaHub(hub, d, c, before);
      if (overtaken()) return false;
      d.state = before.merge(DeviceState.unreachable);
      _changed(save: false);
      toast(_offHomeNetwork && networked(d) && !anywhere
          ? '${d.name} only answers on your home Wi-Fi. To switch it from anywhere, see Connect, then Control from '
              'anywhere.'
          : '${d.name}: $e');
      return false;
    }
  }

  Future<bool> _sendViaHub(RemoteControl hub, Device d, DeviceCommand c, DeviceState before) async {
    try {
      await hub.send(d, c);
      viaHub.add(d.id);
      _changed();
      return true;
    } catch (e) {
      d.state = before;
      _changed(save: false);
      toast('${d.name}: $e');
      return false;
    }
  }

  /// Whether a tap on [d] does something by itself (switches, opens, starts, presses). Other devices open their
  /// controls instead: alarms want a choice and maybe a code, cameras show a picture.
  static bool tapControls(Device d) =>
      d.has(Capability.lock) ||
      d.has(Capability.onOff) ||
      d.has(Capability.position) ||
      d.has(Capability.press) ||
      (d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower));

  Future<void> toggle(Device d) {
    if (d.has(Capability.lock)) return command(d, DeviceCommand(locked: !(d.state.locked ?? false)));
    if (d.has(Capability.onOff)) return command(d, DeviceCommand(on: !(d.state.on ?? false)));
    if (d.has(Capability.position)) {
      return command(d, DeviceCommand(position: (d.state.position ?? 0) > 0.5 ? 0 : 1));
    }
    if (d.has(Capability.press)) return press(d);
    if (d.has(Capability.run)) {
      return command(d, DeviceCommand(action: d.state.activity == Activity.running ? DeviceAction.pause : DeviceAction.start));
    }
    return Future.value();
  }

  /// Presses a button or runs a scene or script, and says so: nothing else shows that it worked.
  Future<void> press(Device d) async {
    if (await command(d, const DeviceCommand(action: DeviceAction.press))) toast('${d.name}: done.');
  }

  /// Where to watch [d] live, or null when it has no video set up.
  CameraStream? liveStream(Device d) => _drivers[d.integrationId]?.liveStream(d) ?? CameraStream.fromProps(d.props);

  /// Finds where the camera at [host] streams its video, with its login, and saves that on [device]. Without a
  /// device the camera is added to Network devices. Throws [CameraSetupException] with a message to show.
  Future<Device> setUpCamera({
    Device? device,
    required String host,
    required String user,
    required String pass,
    String brand = 'other',
    String? link,
    int rtspPort = 554,
    List<int>? onvifPorts,
  }) async {
    final address = LanDriver.cleanHost(host);
    if (address.isEmpty && (link ?? '').trim().isEmpty) {
      throw const CameraSetupException('Type the camera\'s address, such as 192.168.1.30.');
    }
    final onvif = Uri.tryParse(device?.props['onvif'] as String? ?? '');
    final links = await findCameraLinks(
      host: address,
      user: user.trim(),
      pass: pass,
      brand: brand,
      link: link,
      onvifUrl: onvif == null || onvif.host.isEmpty ? null : onvif,
      client: client,
      rtspPort: rtspPort,
      onvifPorts: onvifPorts,
    );
    var d = device;
    if (d == null) {
      final cfg = lanIntegration;
      final where = address.isEmpty ? Uri.parse(link!.trim()).host : address;
      final id = Device.idFor(cfg.id, 'camera:$where');
      d = this.device(id);
      if (d == null) {
        d = Device(
          id: id,
          name: links.name ?? 'Camera',
          kind: DeviceKind.camera,
          integrationId: cfg.id,
          externalId: 'camera:$where',
          props: {'host': where, 'protocol': 'camera'},
        );
        data.devices.add(d);
      }
      final hosts = parseHosts(cfg.setting('hosts'));
      if (!hosts.contains(where)) cfg.settings['hosts'] = [...hosts, where].join('\n');
      _drivers[cfg.id]?.attach(data.devices.where((x) => x.integrationId == cfg.id));
    }
    for (final (key, value) in [('streamUrl', links.stream), ('streamUrlLow', links.streamLow), ('mjpegUrl', links.mjpeg)]) {
      value == null ? d.props.remove(key) : d.props[key] = value;
    }
    d.props['cameraBrand'] = brand;
    if (links.snapshot != null) {
      d.props['snapshotUrl'] = links.snapshot;
      d.capabilities = {...d.capabilities, Capability.snapshot};
    }
    d.state = d.state.merge(const DeviceState(reachable: true));
    _changed();
    return d;
  }

  /// Forgets where [d]'s video is (and its login, which is part of each address).
  void clearCamera(Device d) {
    for (final key in const ['streamUrl', 'streamUrlLow', 'mjpegUrl', 'cameraBrand']) {
      d.props.remove(key);
    }
    _changed();
  }

  static Set<Capability> _keepSnapshot(Device d, Set<Capability> found) =>
      d.props['snapshotUrl'] is String ? {...found, Capability.snapshot} : found;

  /// A still picture from a camera, or null when it cannot take one.
  Future<Uint8List?> snapshot(Device d) async {
    final driver = _drivers[d.integrationId];
    if (driver == null) return null;
    final picture = await driver.snapshot(d);
    if (picture != null && !d.state.reachable) {
      d.state = d.state.merge(const DeviceState(reachable: true));
      _changed(save: false);
    }
    return picture;
  }

  /// Whether [d] is switched with everything else by "All off" and a room's power button. Heating, doors, blinds
  /// and water valves are left alone: they move or matter on their own.
  static bool switchedTogether(Device d) =>
      d.has(Capability.onOff) && !const {DeviceKind.climate, DeviceKind.cover, DeviceKind.garage, DeviceKind.valve}.contains(d.kind);

  Future<void> setPower(Iterable<Device> devices, bool on) => Future.wait(
      devices.where((d) => d.has(Capability.onOff) && d.state.on != on).map((d) => command(d, DeviceCommand(on: on))));

  /// Sets every dimmable light in [devices] to [level] (0 switches them off).
  Future<void> setBrightness(Iterable<Device> devices, double level) => Future.wait(devices
      .where((d) => d.has(Capability.brightness))
      .map((d) => command(d, level <= 0.01 ? const DeviceCommand(on: false) : DeviceCommand(brightness: level))));

  /// What a room's power button switches: everything with on/off except heating, blinds, doors and valves.
  List<Device> switchablesIn(String roomId) => devicesIn(roomId).where(switchedTogether).toList();

  /// Room power: off when anything is on, otherwise the lights come on.
  Future<void> toggleRoom(String roomId) {
    final all = switchablesIn(roomId);
    if (all.any((d) => d.state.on == true)) return setPower(all, false);
    final lights = all.where((d) => d.kind == DeviceKind.light);
    return setPower(lights.isEmpty ? all : lights, true);
  }

  Future<void> allOff() => setPower(data.devices.where(switchedTogether), false);

  // ---- Integrations -------------------------------------------------------------------

  IntegrationDriver? driverFor(String integrationId) => _drivers[integrationId];

  void _startDrivers() {
    for (final cfg in data.integrations) {
      _startDriver(cfg);
    }
  }

  Future<void> _stopDrivers() async {
    for (final id in _drivers.keys.toList()) {
      await _stopDriver(id);
    }
    status.clear();
  }

  void _startDriver(IntegrationConfig cfg) {
    final spec = specFor(cfg.type);
    if (spec == null || !cfg.enabled) return;
    final driver = spec.create(cfg, client);
    driver.onPush = (externalId, st) {
      final d = device(Device.idFor(cfg.id, externalId));
      if (d == null) return;
      if (st.reachable) viaHub.remove(d.id);
      d.state = d.state.merge(st);
      _changed(save: false);
    };
    driver.onSettings = _changed;
    driver.away = _offHomeNetwork;
    _drivers[cfg.id] = driver;
    driver.attach(data.devices.where((d) => d.integrationId == cfg.id));
    _starting[cfg.id] = driver.start().then((_) {
      status[cfg.id] = IntegrationStatus(ok: true, lastSync: status[cfg.id]?.lastSync);
      _changed(save: false);
    }, onError: (Object e) {
      status[cfg.id] = IntegrationStatus(ok: false, message: '$e');
      _changed(save: false);
    });
  }

  /// Waits until every connection has started (or failed to), at most [timeout].
  Future<void> whenStarted({Duration timeout = const Duration(seconds: 4)}) =>
      Future.wait(_starting.values).timeout(timeout, onTimeout: () => const []);

  Future<void> _stopDriver(String id) async {
    _starting.remove(id);
    await _drivers.remove(id)?.stop();
  }

  IntegrationConfig addIntegration(String type, {String? name, Map<String, dynamic>? settings}) {
    final spec = specFor(type)!;
    final cfg = IntegrationConfig(
      id: newId(type),
      type: type,
      name: name ?? spec.name,
      settings: {
        for (final f in spec.fields)
          if (f.defaultValue != null) f.key: f.defaultValue,
        ...?settings,
      },
    );
    data.integrations.add(cfg);
    _startDriver(cfg);
    _changed();
    return cfg;
  }

  Future<void> updateIntegration(IntegrationConfig cfg, {String? name, Map<String, dynamic>? settings}) async {
    if (name != null && name.trim().isNotEmpty) cfg.name = name.trim();
    if (settings != null) cfg.settings = {...cfg.settings, ...settings};
    await _stopDriver(cfg.id);
    status.remove(cfg.id);
    _startDriver(cfg);
    _changed();
  }

  Future<void> removeIntegration(IntegrationConfig cfg) async {
    final driver = _drivers[cfg.id];
    // Matter devices forget the app's keys, which are deleted with the connection.
    if (driver is MatterDriver) {
      await Future.wait([
        for (final node in driver.controller.nodes.keys.toList())
          driver.removeNode(node).catchError((Object e) => debugPrint('Matter: $e')),
      ]).timeout(const Duration(seconds: 15), onTimeout: () => const []);
    }
    await _stopDriver(cfg.id);
    data.integrations.remove(cfg);
    data.devices.removeWhere((d) => d.integrationId == cfg.id);
    status.remove(cfg.id);
    _changed();
  }

  /// Pairs with a hub that needs it (Hue). Saves the key it hands out.
  Future<bool> pair(IntegrationConfig cfg) async {
    final driver = _drivers[cfg.id];
    if (driver == null) return false;
    try {
      final settings = await driver.pair();
      await updateIntegration(cfg, settings: settings);
      toast('Paired with ${cfg.name}.');
      return true;
    } catch (e) {
      toast('$e');
      return false;
    }
  }

  /// Imports devices from an integration. Known devices keep their name,
  /// room and map spot; new ones are added unplaced.
  Future<int> sync(IntegrationConfig cfg) async {
    final driver = _drivers[cfg.id];
    if (driver == null) return 0;
    try {
      final found = await driver.discover();
      var added = 0;
      for (final f in found) {
        final existing = device(f.id);
        if (existing == null) {
          data.devices.add(f);
          added++;
        } else {
          // Keep what was learned later (pairing tokens, MAC addresses, keys, a camera's picture).
          existing.props = {...existing.props, ...f.props};
          existing.capabilities = _keepSnapshot(existing, f.capabilities);
          existing.state = existing.state.merge(f.state);
        }
      }
      driver.attach(data.devices.where((d) => d.integrationId == cfg.id));
      status[cfg.id] = IntegrationStatus(ok: true, lastSync: DateTime.now(), message: '${found.length} devices');
      _changed();
      toast(added == 0 ? '${cfg.name}: ${found.length} devices, nothing new.' : '${cfg.name}: added $added new devices.');
      return added;
    } catch (e) {
      status[cfg.id] = IntegrationStatus(ok: false, message: '$e');
      _changed(save: false);
      toast('${cfg.name}: $e');
      return 0;
    }
  }

  // ---- Matter ---------------------------------------------------------------------------

  /// The Matter connection, created the first time it is needed.
  IntegrationConfig get matterIntegration =>
      data.integrations.where((i) => i.type == matterType).firstOrNull ?? addIntegration(matterType);

  /// Adds a Matter device in pairing mode with its pairing code, then shows
  /// its lights, plugs and sensors. Throws an error with a message to show.
  Future<List<Device>> pairMatter(String code, {String? address, void Function(String step)? onProgress}) async {
    final cfg = matterIntegration;
    final driver = _drivers[cfg.id];
    if (driver is! MatterDriver) throw IntegrationException('Matter is turned off.');
    final List<Device> found;
    try {
      found = await driver.commission(code, address: address, onProgress: onProgress);
    } finally {
      // The app's Matter keys are kept even when adding fails.
      _changed();
    }
    final added = [
      for (final f in found)
        if (device(f.id) == null) f,
    ];
    data.devices.addAll(added);
    driver.attach(data.devices.where((d) => d.integrationId == cfg.id));
    status[cfg.id] = IntegrationStatus(ok: true, lastSync: DateTime.now());
    _changed();
    return added;
  }

  /// When the last part of a Matter device leaves the app, the device forgets
  /// SmartHomeKJ too, so it is not added back on sync and frees its place.
  void _forgetMatter(Device d) {
    final driver = _drivers[d.integrationId];
    final node = matterNodeIdOf(d);
    if (driver is! MatterDriver || node == null) return;
    if (data.devices.any((o) => o.integrationId == d.integrationId && matterNodeIdOf(o) == node)) return;
    driver.removeNode(node).catchError((Object e) => debugPrint('Matter: $e')).whenComplete(_changed);
  }

  // ---- Network devices ------------------------------------------------------------------

  /// The Network devices connection, created the first time it is needed.
  IntegrationConfig get lanIntegration =>
      data.integrations.where((i) => i.type == lanType).firstOrNull ?? addIntegration(lanType);

  /// Adds whatever answers at [address]: a TV, a plug, a speaker, or any other
  /// device. Devices with their own connection (Shelly, WLED...) go there.
  Future<List<Device>> addNetworkDevice(String address, {Map<String, String> hints = const {}}) async {
    final host = LanDriver.cleanHost(address);
    if (host.isEmpty) {
      toast('Type an address such as 192.168.1.50.');
      return const [];
    }
    final cfg = lanIntegration;
    final driver = _drivers[cfg.id];
    if (driver is! LanDriver) return const [];
    if (hints.isEmpty) {
      // Typed in by hand: find out what it is first, as a scan would.
      hints = (await whoIs(host, known: (await routerNeighbors())[host])).hints;
    } else if (hints['mac'] != null && hints['vendor'] == null) {
      final vendor = (await MacVendors.load())?.vendorOf(hints['mac']);
      final guess = guessDevice(vendor: vendor, mac: hints['mac']);
      hints = {...hints, 'vendor': ?vendor, 'what': ?guess?.what, if (guess != null) 'kind': guess.kind.name};
    }
    final match = await driver.identify(host, hints: hints);
    if (match.family != null) {
      await addToFamily(match.family!, host);
      return const [];
    }
    final added = <Device>[];
    for (final f in match.devices) {
      final existing = device(f.id);
      if (existing == null) {
        data.devices.add(f);
        added.add(f);
      } else {
        existing.props = {...existing.props, ...f.props};
        existing.capabilities = _keepSnapshot(existing, f.capabilities);
        existing.state = existing.state.merge(f.state);
        if (existing.name == host) existing.name = f.name;
        if (existing.kind == DeviceKind.other) existing.kind = f.kind;
      }
    }
    final hosts = parseHosts(cfg.setting('hosts'));
    if (!hosts.contains(host)) cfg.settings['hosts'] = [...hosts, host].join('\n');
    driver.attach(data.devices.where((d) => d.integrationId == cfg.id));
    status[cfg.id] = IntegrationStatus(ok: true, lastSync: DateTime.now());
    _changed();
    if (match.devices.isEmpty) {
      toast('Nothing answered at $host.');
      return const [];
    }
    final pairs = added.where((d) => const {'samsung', 'webos'}.contains(d.props['protocol'])).toList();
    final cameras = added.where((d) => d.kind == DeviceKind.camera).toList();
    final robots = added.where((d) => d.props['protocol'] == 'roomba' && d.props['password'] == null).toList();
    final routers = added.where((d) => d.props['protocol'] == 'mikrotik' && d.state.readings['Status'] != 'Online').toList();
    if (added.isEmpty) {
      toast('${match.devices.first.name} is already added.');
    } else if (cameras.length == added.length) {
      toast('Added ${cameras.first.name}. Open it and enter its login to watch it live.');
    } else if (pairs.isNotEmpty) {
      toast('Added ${pairs.first.name}. Look at the TV and allow SmartHomeKJ.');
    } else if (robots.isNotEmpty) {
      toast('Added ${robots.first.name}. Open it and tap Get password to control it.');
    } else if (routers.isNotEmpty) {
      toast('Added ${routers.first.name}. Open it and enter the router\'s login to see and change its settings.');
    } else {
      toast('Added ${added.map((d) => d.name).join(', ')}.');
    }
    // A robot whose HOME button was just held hands out its password right away.
    for (final d in robots) {
      driver.setUp(d).then((problem) {
        if (problem == null) toast('${d.name} is ready.');
        _changed();
      });
    }
    for (final d in pairs) {
      driver.setUp(d).then((problem) {
        if (problem != null) toast(problem);
        _changed(); // saves the key the TV handed out
      });
    }
    return added;
  }

  /// Adds [address] to the connection for its device family, creating it if needed.
  Future<void> addToFamily(String type, String address) async {
    final spec = specFor(type);
    if (spec == null) return;
    final existing = data.integrations.where((i) => i.type == type).firstOrNull;
    if (spec.fields.any((f) => f.key == 'hosts')) {
      if (existing != null) {
        final hosts = parseHosts(existing.setting('hosts'));
        if (!hosts.contains(address)) {
          await updateIntegration(existing, settings: {'hosts': [...hosts, address].join('\n')});
        }
        await sync(existing);
      } else {
        await sync(addIntegration(type, settings: {'hosts': address}));
      }
      return;
    }
    if (type == 'hue') {
      if (existing == null) {
        addIntegration('hue', settings: {'host': address});
      } else {
        await updateIntegration(existing, settings: {'host': address});
      }
      toast('Found a Hue bridge. Press its round button, then tap Pair under Connect > Philips Hue.');
    }
  }

  /// Sends a Wake-on-LAN packet to a network device.
  Future<void> wake(Device d) async {
    final driver = _drivers[d.integrationId];
    if (driver is! LanDriver) return;
    try {
      await driver.wake(d);
      toast('Wake-up sent to ${d.name}.');
    } catch (e) {
      toast('$e');
    }
  }

  /// Forgets a TV's pairing and asks it again (the TV shows a prompt).
  Future<void> pairNetworkDevice(Device d) async {
    final driver = _drivers[d.integrationId];
    if (driver is! LanDriver) return;
    d.props
      ..remove('token')
      ..remove('clientKey');
    await driver.protocolOf(d).close();
    toast('Look at ${d.name} and allow SmartHomeKJ.');
    final problem = await driver.setUp(d);
    toast(problem ?? 'Paired with ${d.name}.');
    _changed();
  }

  /// Sets one of a device's own settings (MAC address, TV key...).
  /// Sets the address a camera's picture is fetched from (any integration); empty removes it.
  void setSnapshotUrl(Device d, String url) {
    final u = url.trim();
    if (u.isEmpty) {
      d.props.remove('snapshotUrl');
      d.capabilities = {...d.capabilities}..remove(Capability.snapshot);
    } else {
      d.props['snapshotUrl'] = u;
      d.capabilities = {...d.capabilities, Capability.snapshot};
    }
    _changed();
  }

  void setDeviceProp(Device d, String key, String? value) {
    if (value == null || value.trim().isEmpty) {
      d.props.remove(key);
    } else {
      d.props[key] = value.trim();
    }
    _changed();
    // A new login or password shows at once whether it works.
    if (const {'password', 'username', 'blid'}.contains(key)) refreshDevice(d);
  }

  /// Asks [d] what it is doing now.
  Future<void> refreshDevice(Device d) async {
    final driver = _drivers[d.integrationId];
    if (driver == null) return;
    try {
      d.state = d.state.merge(await driver.refresh(d) ?? const DeviceState());
    } catch (_) {
      d.state = d.state.merge(DeviceState.unreachable);
    }
    _changed(save: false);
  }

  /// Gets what a network device needs before it can be controlled (a Roomba's password).
  Future<void> setUpNetworkDevice(Device d) async {
    final driver = _drivers[d.integrationId];
    if (driver is! LanDriver) return;
    final problem = await driver.setUp(d);
    toast(problem ?? '${d.name} is ready.');
    _changed();
  }

  /// Who has which address, from every MikroTik in this home that has its login. Empty without one.
  Future<Map<String, Neighbor>> routerNeighbors() async {
    final out = <String, Neighbor>{};
    final routers = devices.where((d) => d.props['protocol'] == 'mikrotik' && d.state.readings['Status'] != 'Needs its login');
    await Future.wait(routers.map((d) async {
      try {
        final r = await openRouter(d).timeout(const Duration(seconds: 5));
        try {
          out.addAll(await r.neighbors().timeout(const Duration(seconds: 6)));
        } finally {
          await r.os.close();
        }
      } catch (_) {}
    }));
    return out;
  }

  /// Gives a device that was added by its bare address the name, maker and kind a scan found for it.
  void learnFromScan(String host, String name, Map<String, String> hints) {
    var changed = false;
    for (final d in devices.where((d) => d.props['host'] == host && integration(d.integrationId)?.type == lanType)) {
      if (d.name == host && name != host) {
        d.name = name;
        changed = true;
      }
      for (final k in const ['mac', 'vendor', 'what']) {
        if (d.props[k] == null && hints[k] != null) {
          d.props[k] = hints[k];
          changed = true;
        }
      }
      final kind = DeviceKind.values.asNameMap()[hints['kind']];
      if (d.kind == DeviceKind.other && kind != null) {
        d.kind = kind;
        changed = true;
      }
    }
    if (changed) _changed();
  }

  /// Logs in to a MikroTik router, for its settings screen.
  Future<MikroTik> openRouter(Device d) async {
    final driver = _drivers[d.integrationId];
    if (driver is! LanDriver) throw IntegrationException('${d.name} is not a network device.');
    return openMikroTik(driver.ctx, d);
  }

  /// Stores a router's login once it worked.
  void setRouterLogin(Device d, String user, String password) {
    d.props['username'] = user.trim().isEmpty ? 'admin' : user.trim();
    password.isEmpty ? d.props.remove('password') : d.props['password'] = password;
    _changed();
  }

  /// Reads the state of every device from its integration.
  Future<void> refreshAll() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await checkHomeNetwork();
      await Future.wait(data.integrations.map((cfg) async {
        final driver = _drivers[cfg.id];
        final spec = specFor(cfg.type);
        if (driver == null || spec == null) return;
        final mine = data.devices.where((d) => d.integrationId == cfg.id).toList();
        if (mine.isEmpty) return;
        final states = await driver.refreshAll(mine);
        final hub = _hub;
        for (final d in mine) {
          final s = states[d.id];
          if (s == null) continue;
          // Out of reach from here, but the device at home sees it.
          final far = s.reachable ? null : hub?.stateOf(d.id);
          if (far != null) {
            d.state = far;
            viaHub.add(d.id);
          } else {
            d.state = s;
            viaHub.remove(d.id);
          }
        }
        final reachable = mine.where((d) => d.state.reachable).length;
        if (spec.polls) {
          status[cfg.id] = IntegrationStatus(
            ok: reachable > 0,
            lastSync: status[cfg.id]?.lastSync,
            message: reachable == mine.length ? null : '$reachable of ${mine.length} devices answering',
          );
        }
      }));
      _changed(save: false);
    } finally {
      _refreshing = false;
    }
  }

  void startPolling() {
    _sceneTimer ??= Timer.periodic(const Duration(seconds: 15), (_) => runDueScenes());
    _pollTimer?.cancel();
    refreshAll();
    _pollTimer = Timer.periodic(pollInterval, (_) => refreshAll());
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ---- Backup ---------------------------------------------------------------------------

  String exportJson() => const JsonEncoder.withIndent('  ').convert(data.toJson());

  Future<void> importJson(String raw) async {
    final next = HomeData.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    if (next.floors.isEmpty) throw const FormatException('That backup has no floors.');
    await _stopDrivers();
    _undo.clear();
    // The theme belongs to the app, not to a backup.
    next.themeMode = data.themeMode;
    data = next;
    _forgetAutomationState();
    _startDrivers();
    _changed();
    await saveNow();
  }

  /// Every home on this device as one backup, the one kept in the backup file. Device states are left out: they come
  /// from the devices, and without them the backup only changes when the homes do. Account links stay out too, since a
  /// new install signs in again.
  Future<Map<String, dynamic>> exportAll() async {
    final list = <Map<String, dynamic>>[];
    for (final h in homes) {
      final d = h.id == homeId ? data : await repository.load(h.id);
      if (d == null) continue;
      final j = d.toJson();
      for (final device in j['devices'] as List) {
        (device as Map).remove('state');
      }
      list.add({'id': h.id, 'name': h.name, 'home': j});
    }
    return {'app': 'SmartHomeKJ', 'backup': 'homes', 'current': homeId, 'homes': list};
  }

  /// Whether [raw] is a backup of every home ([exportAll]) rather than of one home ([exportJson]).
  static bool isAllHomes(String raw) {
    try {
      final j = jsonDecode(raw);
      return j is Map && j['backup'] == 'homes' && j['homes'] is List;
    } catch (_) {
      return false;
    }
  }

  /// Takes back the homes in a backup: every home on this device is replaced by the ones in a backup of every home,
  /// and a backup of one home replaces the open home. Returns how many homes came back.
  Future<int> importAll(String raw) async {
    if (!isAllHomes(raw)) {
      await importJson(raw);
      return 1;
    }
    final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final next = <(HomeEntry, HomeData)>[];
    for (final h in j['homes'] as List) {
      if (h is! Map || h['id'] is! String || h['home'] is! Map) continue;
      final d = HomeData.fromJson(Map<String, dynamic>.from(h['home'] as Map));
      if (d.floors.isEmpty || next.any((e) => e.$1.id == h['id'])) continue;
      next.add((HomeEntry(id: h['id'] as String, name: h['name'] as String? ?? defaultHomeName), d));
    }
    if (next.isEmpty) throw const FormatException('That backup has no homes.');
    _saveTimer?.cancel();
    await _stopDrivers();
    for (final old in homes) {
      if (!next.any((e) => e.$1.id == old.id)) await repository.remove(old.id);
    }
    for (final (entry, d) in next) {
      await repository.save(entry.id, d);
    }
    final current = next.where((e) => e.$1.id == j['current']).firstOrNull ?? next.first;
    homeList = HomeList(homes: [for (final e in next) e.$1], current: current.$1.id);
    await repository.saveHomes(homeList);
    data = current.$2..themeMode = data.themeMode;
    viaHub.clear();
    _undo.clear();
    _forgetAutomationState();
    await _loadOtherScenes();
    _startDrivers();
    _changed(save: false);
    return next.length;
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _sceneTimer?.cancel();
    _saveTimer?.cancel();
    _forgetAutomationState();
    for (final d in _drivers.values) {
      d.stop();
    }
    message.dispose();
    super.dispose();
  }
}

/// A copy of the floor plan: floors, rooms and where each device sits.
class _Layout {
  _Layout(this.floors, this.rooms, this.spots);

  factory _Layout.of(HomeData data) => _Layout(
        [for (final f in data.floors) (f.id, f.name)],
        [for (final r in data.rooms) r.toJson()],
        {for (final d in data.devices) d.id: (d.floorId, d.roomId, d.mapPos)},
      );

  final List<(String, String)> floors;
  final List<Map<String, dynamic>> rooms;
  final Map<String, (String?, String?, Offset?)> spots;

  /// Keeps the same Room objects alive, so screens holding one stay valid.
  static Room _copyRoom(Room from, Room to) => to
    ..floorId = from.floorId
    ..name = from.name
    ..x = from.x
    ..y = from.y
    ..width = from.width
    ..height = from.height;

  void restore(HomeData data) {
    final floorsById = {for (final f in data.floors) f.id: f};
    data.floors
      ..clear()
      ..addAll([for (final (id, name) in floors) (floorsById[id] ?? Floor(id: id, name: name))..name = name]);
    final roomsById = {for (final r in data.rooms) r.id: r};
    data.rooms
      ..clear()
      ..addAll([
        for (final j in rooms)
          if (roomsById[j['id']] case final r?) _copyRoom(Room.fromJson(j), r) else Room.fromJson(j),
      ]);
    for (final d in data.devices) {
      final spot = spots[d.id];
      if (spot == null) continue;
      d.floorId = spot.$1;
      d.roomId = spot.$2;
      d.mapPos = spot.$3;
    }
  }
}
