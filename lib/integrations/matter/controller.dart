import 'dart:async';
import 'dart:io';

import 'case.dart';
import 'clusters.dart';
import 'commissioner.dart';
import 'crypto.dart';
import 'discovery.dart';
import 'fabric.dart';
import 'interaction.dart';
import 'node.dart';
import 'onboarding.dart';
import 'session.dart';
import 'tlv.dart';

/// The app's Matter controller: adds devices to our fabric and talks to them,
/// keeping one encrypted (CASE) session per device and opening a new one
/// when the old one drops or the device moved to another address.
///
/// ```dart
/// final c = MatterController(MatterFabric.create());
/// final node = await c.commission('34970112332', onProgress: print);
/// await c.setOnOff(node.nodeId, 1, true);
/// save(c.toJson()); // fabric keys and nodes, plain JSON
/// ```
class MatterController {
  MatterController(this.fabric, {Iterable<MatterNode> nodes = const [], MatterDiscovery? discovery})
      : discovery = discovery ?? MatterDiscovery(),
        nodes = {for (final n in nodes) n.nodeId: n};

  /// Restores a controller saved with [toJson].
  factory MatterController.fromJson(Map<String, dynamic> j, {MatterDiscovery? discovery}) => MatterController(
        MatterFabric.fromJson(Map<String, dynamic>.from(j['fabric'] as Map)),
        nodes: [
          for (final n in (j['nodes'] as List? ?? const [])) MatterNode.fromJson(Map<String, dynamic>.from(n as Map)),
        ],
        discovery: discovery,
      );

  final MatterFabric fabric;
  final MatterDiscovery discovery;

  /// The devices on our fabric, by node id.
  final Map<int, MatterNode> nodes;

  /// Called when something that should be saved changed (a new device, a new
  /// address, the fabric's next node id).
  void Function()? onChanged;

  MatterTransport? _transport;
  Future<MatterTransport>? _opening;
  final _sessions = <int, SecureSession>{};
  final _connecting = <int, Future<SecureSession>>{};
  bool _closed = false;

  Map<String, dynamic> toJson() => {
        'fabric': fabric.toJson(),
        'nodes': [for (final n in nodes.values) n.toJson()],
      };

  Future<MatterTransport> _net() async {
    if (_closed) throw MatterException('Matter is shut down.');
    final t = _transport;
    if (t != null) return t;
    return _opening ??= MatterTransport.open().then((t) {
      _transport = t;
      return t;
    }).whenComplete(() {
      _opening = null;
    });
  }

  /// Adds a device in pairing mode. [code] is the 11-digit code or the
  /// "MT:..." QR text. [address] ("192.168.1.40", "[fe80::1%wlan0]:5540")
  /// skips the search; otherwise the device is found with mDNS.
  /// Throws [CommissioningException] with a message to show the user.
  Future<MatterNode> commission(String code,
      {String? address, int? port, void Function(String step)? onProgress}) async {
    final SetupCode setup;
    try {
      setup = parseSetupCode(code);
    } on SetupCodeException catch (e) {
      throw CommissioningException(CommissioningFailure.wrongCode, e.message);
    }
    InternetAddress? ip;
    var p = port ?? 5540;
    if (address != null && address.trim().isNotEmpty) {
      final parsed = parseHostPort(address.trim());
      if (parsed == null) throw CommissioningException(CommissioningFailure.notFound, 'That is not an IP address.');
      ip = parsed.$1;
      p = port ?? parsed.$2 ?? 5540;
    }
    final t = await _net();
    final (node, session) = await Commissioner(t, fabric, discovery: discovery)
        .commission(setup, address: ip, port: p, onProgress: onProgress);
    nodes[node.nodeId] = node;
    _sessions[node.nodeId] = session;
    _watch(node.nodeId, session);
    onChanged?.call();
    onProgress?.call(CommissioningStep.reading);
    try {
      final d = await describe(node.nodeId);
      node.label = d.label;
      node.vendorId ??= d.vendorId;
      node.productId ??= d.productId;
      node.endpoints = d.endpoints;
      onChanged?.call();
    } on MatterException {
      // The device is added; its details can be read later.
    }
    return node;
  }

  void _watch(int nodeId, SecureSession s) {
    s.addCloseListener(() {
      if (identical(_sessions[nodeId], s)) _sessions.remove(nodeId);
    });
  }

  /// An open session with [nodeId], connecting if needed.
  Future<SecureSession> session(int nodeId, {bool reconnect = false}) {
    final s = _sessions[nodeId];
    if (s != null && !s.isClosed && !reconnect) return Future.value(s);
    if (reconnect && s != null) {
      _sessions.remove(nodeId);
      s.close();
    }
    // (A block body: returning the removed future from whenComplete would make it wait for itself.)
    return _connecting[nodeId] ??= _connect(nodeId).whenComplete(() {
      _connecting.remove(nodeId);
    });
  }

  Future<SecureSession> _connect(int nodeId) async {
    final node = nodes[nodeId];
    if (node == null) throw MatterException('This device is not part of SmartMenuKJ.');
    final t = await _net();
    final tried = <String>{};
    Object? lastError;

    Future<SecureSession?> attempt(InternetAddress a, int port) async {
      if (!t.supports(a) || !tried.add('${a.address}:$port')) return null;
      try {
        matterLog?.call('connect: CASE with ${a.address}:$port');
        final s = await establishCase(t, fabric, nodeId, a, port);
        _sessions[nodeId] = s;
        _watch(nodeId, s);
        if (node.address != a.address || node.port != port) {
          node.address = a.address;
          node.port = port;
          onChanged?.call();
        }
        return s;
      } on NotOnFabricException {
        rethrow;
      } on MatterException catch (e) {
        matterLog?.call('connect: CASE failed: $e');
        lastError = e;
        return null;
      }
    }

    final known = node.address == null ? null : InternetAddress.tryParse(node.address!);
    if (known != null) {
      final s = await attempt(known, node.port);
      if (s != null) return s;
    }
    // Ask the network where the device is now.
    MdnsService? found;
    try {
      found = await discovery.resolveOperational(fabric.instanceName(nodeId));
    } catch (_) {}
    if (found != null) {
      for (final a in found.sortedAddresses) {
        final s = await attempt(a, found.port ?? node.port);
        if (s != null) return s;
      }
    }
    if (lastError is MatterException && lastError is! MatterTimeoutException) throw lastError!;
    throw MatterTimeoutException('${node.label.isEmpty ? 'The device' : node.label} is not answering.');
  }

  /// Runs [op] on a session with [nodeId], reconnecting once if the session
  /// turns out to be dead.
  Future<T> run<T>(int nodeId, Future<T> Function(InteractionClient im) op) async {
    for (var attempt = 0;; attempt++) {
      final s = await session(nodeId, reconnect: attempt > 0);
      try {
        return await op(InteractionClient(s));
      } on MatterTimeoutException {
        if (attempt > 0) rethrow;
      } on SessionClosedException {
        if (attempt > 0) rethrow;
      }
    }
  }

  Future<ReadResult> read(int nodeId, List<AttributePath> paths) => run(nodeId, (im) => im.read(paths));

  Future<CommandResponse> invoke(int nodeId, int endpoint, int cluster, int command,
          {void Function(TlvWriter w)? fields, Duration? timed}) =>
      run(nodeId, (im) => im.invoke(endpoint, cluster, command, fields: fields, timed: timed));

  Future<void> write(int nodeId, int endpoint, int cluster, int attribute, void Function(TlvWriter w, int tag) value,
          {Duration? timed}) =>
      run(nodeId, (im) => im.write(endpoint, cluster, attribute, value, timed: timed));

  /// Reads the device's endpoints, their device types and clusters, and its names.
  Future<NodeDescription> describe(int nodeId) async {
    final r = await read(nodeId, const [
      AttributePath(cluster: Cluster.descriptor, attribute: DescriptorAttr.deviceTypeList),
      AttributePath(cluster: Cluster.descriptor, attribute: DescriptorAttr.serverList),
      AttributePath(cluster: Cluster.descriptor, attribute: DescriptorAttr.partsList),
      AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.vendorName),
      AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.vendorId),
      AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.productName),
      AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.productId),
      AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.nodeLabel),
      AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.uniqueId),
      AttributePath(cluster: Cluster.bridgedDeviceBasicInformation, attribute: BasicInfoAttr.nodeLabel),
      AttributePath(cluster: Cluster.bridgedDeviceBasicInformation, attribute: BasicInfoAttr.productName),
      AttributePath(cluster: Cluster.bridgedDeviceBasicInformation, attribute: BasicInfoAttr.reachable),
      AttributePath(cluster: Cluster.bridgedDeviceBasicInformation, attribute: BasicInfoAttr.uniqueId),
      AttributePath(cluster: Cluster.colorControl, attribute: GlobalAttr.featureMap),
    ]);
    final endpoints = <int, MatterEndpoint>{};
    MatterEndpoint ep(int id) => endpoints.putIfAbsent(id, () => MatterEndpoint(id));
    for (final v in r.where(cluster: Cluster.descriptor)) {
      final list = v.value is List ? v.value as List : const [];
      switch (v.attribute) {
        case DescriptorAttr.deviceTypeList:
          ep(v.endpoint).deviceTypes.addAll([
            for (final d in list)
              if (d is TlvStruct && d.integer(0) != null) d.integer(0)!,
          ]);
        case DescriptorAttr.serverList:
          ep(v.endpoint).clusters.addAll(list.whereType<int>());
        case DescriptorAttr.partsList:
          ep(v.endpoint).parts.addAll(list.whereType<int>());
      }
    }
    for (final v in r.where(cluster: Cluster.bridgedDeviceBasicInformation)) {
      final e = ep(v.endpoint);
      switch (v.attribute) {
        case BasicInfoAttr.nodeLabel:
          if (v.value is String && (v.value as String).isNotEmpty) e.label = v.value as String;
        case BasicInfoAttr.productName:
          if (v.value is String && (v.value as String).isNotEmpty) e.label ??= v.value as String;
        case BasicInfoAttr.reachable:
          if (v.value is bool) e.reachable = v.value as bool;
        case BasicInfoAttr.uniqueId:
          if (v.value is String) e.uniqueId = v.value as String;
      }
    }
    for (final v in r.where(cluster: Cluster.colorControl, attribute: GlobalAttr.featureMap)) {
      if (v.value is int) ep(v.endpoint).colorFeatures = v.value as int;
    }
    String? str(int attr) {
      final v = r.get(0, Cluster.basicInformation, attr);
      return v is String && v.isNotEmpty ? v : null;
    }

    final list = endpoints.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return NodeDescription(
      nodeId: nodeId,
      vendorName: str(BasicInfoAttr.vendorName),
      vendorId: r.get(0, Cluster.basicInformation, BasicInfoAttr.vendorId) as int?,
      productName: str(BasicInfoAttr.productName),
      productId: r.get(0, Cluster.basicInformation, BasicInfoAttr.productId) as int?,
      nodeLabel: str(BasicInfoAttr.nodeLabel),
      uniqueId: str(BasicInfoAttr.uniqueId),
      endpoints: list,
    );
  }

  /// Reads the device's description again and remembers its endpoints and name.
  Future<MatterNode> updateNode(int nodeId) async {
    final node = nodes[nodeId];
    if (node == null) throw MatterException('This device is not part of SmartMenuKJ.');
    final d = await describe(nodeId);
    node.label = d.label;
    node.vendorId ??= d.vendorId;
    node.productId ??= d.productId;
    node.endpoints = d.endpoints;
    onChanged?.call();
    return node;
  }

  // ---- lights and switches -----------------------------------------------------

  Future<void> setOnOff(int nodeId, int endpoint, bool on) =>
      invoke(nodeId, endpoint, Cluster.onOff, on ? OnOff.on : OnOff.off);

  /// [level] is 1..254. With [withOnOff] the light also turns on (or off at the lowest level).
  Future<void> setLevel(int nodeId, int endpoint, int level,
          {Duration transition = Duration.zero, bool withOnOff = true}) =>
      invoke(nodeId, endpoint, Cluster.levelControl,
          withOnOff ? LevelControl.moveToLevelWithOnOff : LevelControl.moveToLevel, fields: (w) {
        w.uint(0, level.clamp(1, 254));
        w.uint(1, _tenths(transition));
        w.uint(2, 0);
        w.uint(3, 0);
      });

  /// Colour temperature in mireds (1,000,000 / kelvin).
  Future<void> setColorTemperature(int nodeId, int endpoint, int mireds, {Duration transition = Duration.zero}) =>
      invoke(nodeId, endpoint, Cluster.colorControl, ColorControl.moveToColorTemperature, fields: (w) {
        w.uint(0, mireds.clamp(1, 0xfeff));
        w.uint(1, _tenths(transition));
        // Apply even while the light is off, so it comes on in the new colour.
        w.uint(2, 1);
        w.uint(3, 1);
      });

  /// [hue] and [saturation] are 0..254 (Matter's scale for 0..360° and 0..100 %).
  Future<void> setHueSaturation(int nodeId, int endpoint, int hue, int saturation,
          {Duration transition = Duration.zero}) =>
      invoke(nodeId, endpoint, Cluster.colorControl, ColorControl.moveToHueAndSaturation, fields: (w) {
        w.uint(0, hue.clamp(0, 254));
        w.uint(1, saturation.clamp(0, 254));
        w.uint(2, _tenths(transition));
        w.uint(3, 1);
        w.uint(4, 1);
      });

  /// CIE 1931 x and y, each as value * 65536 (0..65279).
  Future<void> setColorXy(int nodeId, int endpoint, int x, int y, {Duration transition = Duration.zero}) =>
      invoke(nodeId, endpoint, Cluster.colorControl, ColorControl.moveToColor, fields: (w) {
        w.uint(0, x.clamp(0, 0xfeff));
        w.uint(1, y.clamp(0, 0xfeff));
        w.uint(2, _tenths(transition));
        w.uint(3, 1);
        w.uint(4, 1);
      });

  static int _tenths(Duration d) => (d.inMilliseconds ~/ 100).clamp(0, 0xfffe);

  /// The attributes a light reports: on/off, level and colour, plus what its
  /// colour control supports.
  Future<LightState> readLight(int nodeId, int endpoint) async {
    final r = await read(nodeId, [
      AttributePath(endpoint: endpoint, cluster: Cluster.onOff, attribute: OnOff.onOff),
      AttributePath(endpoint: endpoint, cluster: Cluster.levelControl, attribute: LevelControl.currentLevel),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: ColorControl.colorMode),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: ColorControl.currentHue),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: ColorControl.currentSaturation),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: ColorControl.currentX),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: ColorControl.currentY),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: ColorControl.colorTemperatureMireds),
      AttributePath(endpoint: endpoint, cluster: Cluster.colorControl, attribute: GlobalAttr.featureMap),
    ]);
    return LightState.fromRead(r, endpoint);
  }

  /// Takes the device off our fabric (it forgets SmartMenuKJ) and forgets it here.
  Future<void> removeNode(int nodeId) async {
    try {
      await run(nodeId, (im) async {
        final index = await im.readAttribute(0, Cluster.operationalCredentials, OperationalCredentials.currentFabricIndex);
        if (index is! int) throw MatterException('The device did not say which fabric this is.');
        final r = await im.invoke(0, Cluster.operationalCredentials, OperationalCredentials.removeFabric,
            fields: (w) => w.uint(0, index));
        final status = r?.fields.integer(0) ?? 0;
        if (status != 0) throw MatterException('The device refused to remove SmartMenuKJ (error $status).');
      });
    } on SessionClosedException {
      // The device drops the session as soon as the fabric is gone.
    } on MatterTimeoutException {
      // Same: the answer may never come once the fabric is removed.
    } finally {
      _sessions.remove(nodeId)?.close();
      if (nodes.remove(nodeId) != null) onChanged?.call();
    }
  }

  /// Closes every session and the network sockets.
  Future<void> close() async {
    _closed = true;
    for (final s in _sessions.values.toList()) {
      s.close(notifyPeer: true);
    }
    _sessions.clear();
    // Let the CloseSession messages leave before the sockets close.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _transport?.close();
    _transport = null;
  }
}

/// Splits "1.2.3.4", "1.2.3.4:5540", "fe80::1%wlan0", "[fe80::1%wlan0]:5540".
(InternetAddress, int?)? parseHostPort(String s) {
  final bracket = RegExp(r'^\[(.+)\](?::(\d+))?$').firstMatch(s);
  if (bracket != null) {
    final a = InternetAddress.tryParse(bracket[1]!);
    return a == null ? null : (a, bracket[2] == null ? null : int.parse(bracket[2]!));
  }
  final direct = InternetAddress.tryParse(s);
  if (direct != null) return (direct, null);
  final colon = s.lastIndexOf(':');
  if (colon > 0) {
    final a = InternetAddress.tryParse(s.substring(0, colon));
    final p = int.tryParse(s.substring(colon + 1));
    if (a != null && a.type == InternetAddressType.IPv4 && p != null) return (a, p);
  }
  return null;
}

/// A light's state as the device reports it.
class LightState {
  LightState({this.on, this.level, this.colorMode, this.hue, this.saturation, this.x, this.y, this.mireds, this.colorFeatures});

  factory LightState.fromRead(ReadResult r, int endpoint) {
    int? i(int cluster, int attr) {
      final v = r.get(endpoint, cluster, attr);
      return v is int ? v : null;
    }

    final on = r.get(endpoint, Cluster.onOff, OnOff.onOff);
    return LightState(
      on: on is bool ? on : null,
      level: i(Cluster.levelControl, LevelControl.currentLevel),
      colorMode: i(Cluster.colorControl, ColorControl.colorMode),
      hue: i(Cluster.colorControl, ColorControl.currentHue),
      saturation: i(Cluster.colorControl, ColorControl.currentSaturation),
      x: i(Cluster.colorControl, ColorControl.currentX),
      y: i(Cluster.colorControl, ColorControl.currentY),
      mireds: i(Cluster.colorControl, ColorControl.colorTemperatureMireds),
      colorFeatures: i(Cluster.colorControl, GlobalAttr.featureMap),
    );
  }

  final bool? on;

  /// 1..254 (null when the device has no level control).
  final int? level;
  final int? colorMode;
  final int? hue;
  final int? saturation;
  final int? x;
  final int? y;
  final int? mireds;

  /// Colour control feature map: HS 0x01, XY 0x08, colour temperature 0x10.
  final int? colorFeatures;

  bool get supportsHueSaturation => (colorFeatures ?? 0) & ColorControl.featureHueSaturation != 0;
  bool get supportsXy => (colorFeatures ?? 0) & ColorControl.featureXy != 0;
  bool get supportsColorTemperature => (colorFeatures ?? 0) & ColorControl.featureColorTemperature != 0;

  @override
  String toString() =>
      'LightState(on: $on, level: $level, mode: $colorMode, hs: $hue/$saturation, xy: $x/$y, mireds: $mireds, features: $colorFeatures)';
}

/// Used by tests and tools: 64-bit ids as the app shows and saves them.
String nodeIdHex(int nodeId) => hex64(nodeId);
