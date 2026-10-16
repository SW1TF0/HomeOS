import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../integrations/catalog.dart';
import '../integrations/integration.dart';
import '../integrations/lan/lan_driver.dart';
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

/// Holds the whole home and is the only place that changes it.
class HomeStore extends ChangeNotifier {
  HomeStore({
    required this.repository,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 10),
    this.claimRun,
  }) : client = client ?? http.Client();

  final HomeRepository repository;
  final http.Client client;
  final Duration pollInterval;

  /// Asked before a timed scene runs, with the scene and its time slot. When
  /// something else (an Android alarm) already ran that slot, it answers false.
  final Future<bool> Function(String sceneId, String slot)? claimRun;

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
    data = await repository.load() ?? seedHome();
    loaded = true;
    for (final cfg in data.integrations) {
      _startDriver(cfg);
    }
    notifyListeners();
  }

  void _changed({bool save = true}) {
    if (_disposed) return;
    notifyListeners();
    if (save) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
    }
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    await repository.save(data);
  }

  String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 20).toRadixString(36)}';

  void toast(String text) => message.value = text;

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

  int get activeCount => data.devices.where((d) => d.state.isActive && d.kind != DeviceKind.lock).length;

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
    _changed();
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
    if (rooms) {
      final seedRooms = seedHome().rooms.map((r) => r.id).toSet();
      data.rooms.removeWhere((r) => seedRooms.contains(r.id) && !data.devices.any((d) => d.roomId == r.id));
    }
    _changed();
  }

  // ---- Scenes --------------------------------------------------------------------------

  List<Scene> get scenes => data.scenes;
  Scene? scene(String id) => data.scenes.where((s) => s.id == id).firstOrNull;

  /// Creates a scene that remembers what [devices] are doing right now.
  Scene addScene(String name, Iterable<Device> devices, {String icon = 'auto'}) {
    final s = Scene(id: newId('scene'), name: name, icon: icon, actions: devices.map(SceneAction.capture).toList());
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

  void removeScene(Scene s) {
    data.scenes.remove(s);
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

  Device addVirtualDevice(String integrationId, String name, DeviceKind kind, {Map<String, dynamic>? props}) {
    final ext = 'manual:${newId('dev')}';
    final d = Device(
      id: Device.idFor(integrationId, ext),
      name: name,
      kind: kind,
      integrationId: integrationId,
      externalId: ext,
      props: props,
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
        DeviceKind.cover => const DeviceState(position: 0),
        DeviceKind.lock => const DeviceState(locked: true),
        DeviceKind.sensor => const DeviceState(readings: {'Temperature': '21.0 °C', 'Humidity': '45 %'}),
        _ => const DeviceState(on: false),
      };

  // ---- Control ----------------------------------------------------------------------

  /// Changes a device. The screen updates at once; if the device refuses,
  /// the old state comes back and the user is told why.
  Future<bool> command(Device d, DeviceCommand c) async {
    final before = d.state;
    d.state = d.state.applyCommand(c);
    _changed();
    final driver = _drivers[d.integrationId];
    if (driver == null) {
      d.state = before;
      _changed(save: false);
      toast('${d.name}: its connection is missing.');
      return false;
    }
    try {
      final confirmed = await driver.send(d, c);
      if (confirmed != null) d.state = d.state.merge(confirmed);
      if (!d.state.reachable) d.state = d.state.merge(const DeviceState(reachable: true));
      _changed();
      return true;
    } catch (e) {
      d.state = before.merge(DeviceState.unreachable);
      _changed(save: false);
      toast('${d.name}: $e');
      return false;
    }
  }

  Future<void> toggle(Device d) {
    if (d.has(Capability.lock)) return command(d, DeviceCommand(locked: !(d.state.locked ?? false)));
    if (d.has(Capability.onOff)) return command(d, DeviceCommand(on: !(d.state.on ?? false)));
    if (d.has(Capability.position)) {
      return command(d, DeviceCommand(position: (d.state.position ?? 0) > 0.5 ? 0 : 1));
    }
    return Future.value();
  }

  Future<void> setPower(Iterable<Device> devices, bool on) => Future.wait(
      devices.where((d) => d.has(Capability.onOff) && d.state.on != on).map((d) => command(d, DeviceCommand(on: on))));

  /// Sets every dimmable light in [devices] to [level] (0 switches them off).
  Future<void> setBrightness(Iterable<Device> devices, double level) => Future.wait(devices
      .where((d) => d.has(Capability.brightness))
      .map((d) => command(d, level <= 0.01 ? const DeviceCommand(on: false) : DeviceCommand(brightness: level))));

  /// What a room's power button switches: everything with on/off except heating.
  List<Device> switchablesIn(String roomId) =>
      devicesIn(roomId).where((d) => d.has(Capability.onOff) && d.kind != DeviceKind.climate).toList();

  /// Room power: off when anything is on, otherwise the lights come on.
  Future<void> toggleRoom(String roomId) {
    final all = switchablesIn(roomId);
    if (all.any((d) => d.state.on == true)) return setPower(all, false);
    final lights = all.where((d) => d.kind == DeviceKind.light);
    return setPower(lights.isEmpty ? all : lights, true);
  }

  Future<void> allOff() => setPower(data.devices.where((d) => d.kind != DeviceKind.climate), false);

  // ---- Integrations -------------------------------------------------------------------

  IntegrationDriver? driverFor(String integrationId) => _drivers[integrationId];

  void _startDriver(IntegrationConfig cfg) {
    final spec = specFor(cfg.type);
    if (spec == null || !cfg.enabled) return;
    final driver = spec.create(cfg, client);
    driver.onPush = (externalId, st) {
      final d = device(Device.idFor(cfg.id, externalId));
      if (d == null) return;
      d.state = d.state.merge(st);
      _changed(save: false);
    };
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
          existing.capabilities = f.capabilities;
          // Keep what was learned later (pairing tokens, MAC addresses, keys).
          existing.props = {...existing.props, ...f.props};
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
        existing.capabilities = f.capabilities;
        existing.props = {...existing.props, ...f.props};
        existing.state = existing.state.merge(f.state);
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
    if (added.isEmpty) {
      toast('${match.devices.first.name} is already added.');
    } else if (pairs.isNotEmpty) {
      toast('Added ${pairs.first.name}. Look at the TV and allow SmartMenuKJ.');
    } else {
      toast('Added ${added.map((d) => d.name).join(', ')}.');
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
    toast('Look at ${d.name} and allow SmartMenuKJ.');
    final problem = await driver.setUp(d);
    toast(problem ?? 'Paired with ${d.name}.');
    _changed();
  }

  /// Sets one of a device's own settings (MAC address, TV key...).
  void setDeviceProp(Device d, String key, String? value) {
    if (value == null || value.trim().isEmpty) {
      d.props.remove(key);
    } else {
      d.props[key] = value.trim();
    }
    _changed();
  }

  /// Reads the state of every device from its integration.
  Future<void> refreshAll() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await Future.wait(data.integrations.map((cfg) async {
        final driver = _drivers[cfg.id];
        final spec = specFor(cfg.type);
        if (driver == null || spec == null) return;
        final mine = data.devices.where((d) => d.integrationId == cfg.id).toList();
        if (mine.isEmpty) return;
        final states = await driver.refreshAll(mine);
        for (final d in mine) {
          final s = states[d.id];
          if (s != null) d.state = s;
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
    for (final id in _drivers.keys.toList()) {
      await _stopDriver(id);
    }
    status.clear();
    _undo.clear();
    data = next;
    for (final cfg in data.integrations) {
      _startDriver(cfg);
    }
    _changed();
    await saveNow();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _sceneTimer?.cancel();
    _saveTimer?.cancel();
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
