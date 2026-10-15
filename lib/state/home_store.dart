import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../integrations/catalog.dart';
import '../integrations/integration.dart';
import '../integrations/lan/lan_driver.dart';
import '../models/device.dart';
import '../models/home.dart';
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
  HomeStore({required this.repository, http.Client? client, this.pollInterval = const Duration(seconds: 10)})
      : client = client ?? http.Client();

  final HomeRepository repository;
  final http.Client client;
  final Duration pollInterval;

  HomeData data = HomeData();
  bool loaded = false;
  final Map<String, IntegrationDriver> _drivers = {};
  final Map<String, IntegrationStatus> status = {};

  /// Short messages for the user (errors, confirmations), shown as toasts.
  final ValueNotifier<String?> message = ValueNotifier(null);

  Timer? _saveTimer;
  Timer? _pollTimer;
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
    final f = Floor(id: newId('floor'), name: name);
    data.floors.add(f);
    _changed();
    return f;
  }

  void renameFloor(Floor f, String name) {
    f.name = name;
    _changed();
  }

  void removeFloor(Floor f) {
    if (data.floors.length <= 1) return;
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
    final r = Room(
      id: newId('room'),
      floorId: floorId,
      name: name ?? 'Room ${data.rooms.where((r) => r.floorId == floorId).length + 1}',
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
    _changed();
  }

  void renameRoom(Room r, String name) {
    r.name = name;
    _changed();
  }

  void removeRoom(Room r) {
    data.rooms.remove(r);
    for (final d in data.devices) {
      if (d.roomId == r.id) d.roomId = null;
    }
    _changed();
  }

  // ---- Devices -------------------------------------------------------------------

  /// Puts a device on the map. It joins whichever room it lands in.
  void placeDevice(Device d, String floorId, Offset pos) {
    d.floorId = floorId;
    d.mapPos = pos;
    final inside = data.rooms.where((r) => r.floorId == floorId && r.contains(pos)).toList()
      ..sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
    d.roomId = inside.isEmpty ? null : inside.first.id;
    _changed();
  }

  void unplaceDevice(Device d) {
    d.mapPos = null;
    d.floorId = null;
    _changed();
  }

  void updateDevice(Device d, {String? name, DeviceKind? kind, String? roomId, bool clearRoom = false, bool? favorite}) {
    if (name != null && name.trim().isNotEmpty) d.name = name.trim();
    if (kind != null) d.kind = kind;
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

  void removeDevice(Device d) {
    data.devices.remove(d);
    _changed();
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
    driver.start().then((_) {
      status[cfg.id] = IntegrationStatus(ok: true, lastSync: status[cfg.id]?.lastSync);
      _changed(save: false);
    }, onError: (Object e) {
      status[cfg.id] = IntegrationStatus(ok: false, message: '$e');
      _changed(save: false);
    });
  }

  Future<void> _stopDriver(String id) async {
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
    _saveTimer?.cancel();
    for (final d in _drivers.values) {
      d.stop();
    }
    message.dispose();
    super.dispose();
  }
}
