import 'dart:async';
import 'dart:math';

import '../../models/device.dart';
import '../integration.dart';
import 'clusters.dart';
import 'color.dart';
import 'commissioner.dart';
import 'controller.dart';
import 'crypto.dart';
import 'discovery.dart';
import 'fabric.dart';
import 'interaction.dart';
import 'node.dart';
import 'session.dart';
import 'tlv.dart';

/// The integration type for Matter devices on the home network.
const matterType = 'matter';

/// Matter devices that this app added itself (with their setup code), talked
/// to directly over the home network: no hub, no cloud.
///
/// Settings it keeps up to date in `config.settings`:
/// * `fabric`: the app's Matter keys and certificates (see [MatterFabric.toJson]),
/// * `nodes`: one entry per added device: `{id, address, port, vendor, product, label, endpoints}`.
///
/// Each Matter endpoint that does something (a light, a plug, a sensor...)
/// becomes one [Device] whose external id is `<node id hex>:<endpoint>`.
class MatterDriver extends IntegrationDriver {
  MatterDriver(super.config, super.client, {this.discovery});

  /// How devices are looked up on the network (by default on every interface).
  final MatterDiscovery? discovery;
  MatterController? _controller;

  /// The controller behind this driver, created from the saved settings (or
  /// with a new fabric, which is saved at once).
  MatterController get controller => _controller ??= _load();

  MatterController _load() {
    final saved = config.settings['fabric'];
    final MatterFabric fabric;
    if (saved is Map) {
      fabric = MatterFabric.fromJson(Map<String, dynamic>.from(saved));
    } else {
      fabric = MatterFabric.create();
      config.settings['fabric'] = fabric.toJson();
    }
    final nodes = <MatterNode>[];
    for (final n in (config.settings['nodes'] as List? ?? const [])) {
      try {
        nodes.add(MatterNode.fromJson(Map<String, dynamic>.from(n as Map)));
      } catch (_) {
        // Skip a damaged entry rather than losing the others.
      }
    }
    final c = MatterController(fabric, nodes: nodes, discovery: discovery);
    c.onChanged = () => _save(c);
    return c;
  }

  void _save(MatterController c) {
    config.settings['fabric'] = c.fabric.toJson();
    config.settings['nodes'] = [for (final n in c.nodes.values) n.toJson()];
    onSettings?.call();
  }

  /// Whether a device announcing itself as `<fabric>-<node>` (operational
  /// mDNS name) is one this app added.
  bool owns(String instanceName) {
    final name = instanceName.toUpperCase();
    return controller.nodes.keys.any((n) => controller.fabric.instanceName(n) == name);
  }

  /// Adds the device with setup [code] (11 digits or "MT:..."). [address]
  /// skips the network search. [onProgress] gets the steps in
  /// [CommissioningStep]. Returns the new devices; throws
  /// [IntegrationException] with a message to show when it fails.
  Future<List<Device>> commission(String code, {String? address, void Function(String step)? onProgress}) async {
    final c = controller;
    final MatterNode node;
    try {
      node = await c.commission(code, address: address, onProgress: onProgress);
    } on MatterException catch (e) {
      throw IntegrationException(e.message);
    } finally {
      _save(c);
    }
    final devices = _devicesOf(node);
    final states = await refreshAll(devices);
    for (final d in devices) {
      d.state = states[d.id] ?? d.state;
    }
    return devices;
  }

  /// Takes the device off SmartMenuKJ's fabric and forgets it.
  Future<void> removeNode(int nodeId) async {
    final c = controller;
    try {
      await c.removeNode(nodeId);
    } on MatterException catch (e) {
      throw IntegrationException(e.message);
    } finally {
      _save(c);
    }
  }

  @override
  Future<void> stop() async {
    final c = _controller;
    _controller = null;
    await c?.close();
  }

  @override
  Future<List<Device>> discover() async {
    final c = controller;
    final out = <Device>[];
    await Future.wait([
      for (final node in c.nodes.values.toList())
        () async {
          try {
            await c.updateNode(node.nodeId);
          } on MatterException {
            // Not reachable now: use what was read last time.
          }
          out.addAll(_devicesOf(node));
        }(),
    ]);
    _save(c);
    return out;
  }

  @override
  Future<DeviceState?> refresh(Device device) async => (await refreshAll([device]))[device.id];

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    final now = await _read(devices);
    return {for (final d in devices) d.id: d.state.merge(now[d.id]!)};
  }

  /// What [devices] report now, not yet merged with what was known before (so that a mode or a problem
  /// that is gone can be cleared by the one merge), and unreachable ones as such.
  Future<Map<String, DeviceState>> _read(List<Device> devices) async {
    final byNode = <int, List<Device>>{};
    final out = <String, DeviceState>{};
    for (final d in devices) {
      final ref = _ref(d);
      if (ref == null) {
        out[d.id] = DeviceState.unreachable;
      } else {
        byNode.putIfAbsent(ref.$1, () => []).add(d);
      }
    }
    await Future.wait([
      for (final MapEntry(key: nodeId, value: list) in byNode.entries)
        () async {
          try {
            final paths = [for (final d in list) ..._paths(d)];
            final r = await controller.read(nodeId, paths);
            for (final d in list) {
              out[d.id] = _stateFrom(d, r);
            }
          } catch (_) {
            for (final d in list) {
              out[d.id] = DeviceState.unreachable;
            }
          }
        }(),
    ]);
    return out;
  }

  @override
  Future<DeviceState?> send(Device device, DeviceCommand command) async {
    final ref = _ref(device);
    if (ref == null) throw IntegrationException('${device.name} is not a Matter device of this app.');
    final (nodeId, ep) = ref;
    final c = controller;
    final e = _endpoint(device);
    final fan = device.kind == DeviceKind.fan || device.kind == DeviceKind.purifier;
    try {
      final b = command.brightness;
      if (b != null && b <= 0) {
        await _power(device, false);
      } else if (b != null) {
        await c.setLevel(nodeId, ep, (b * 254).round().clamp(1, 254));
        if (command.on == false) await _power(device, false);
      } else if (command.on != null) {
        await _power(device, command.on!);
      }
      if (command.colorTempK != null && command.colorTempK! > 0) {
        await c.setColorTemperature(nodeId, ep, (1000000 / command.colorTempK!).round());
      }
      if (command.color != null) {
        final features = e?.colorFeatures ?? (device.props['colorFeatures'] as int?) ?? 0;
        if (features & ColorControl.featureHueSaturation != 0 || features & ColorControl.featureXy == 0) {
          final (h, s) = rgbToHueSat(command.color!);
          await c.setHueSaturation(nodeId, ep, h, s);
        } else {
          final (x, y) = rgbToXy(command.color!);
          await c.setColorXy(nodeId, ep, x, y);
        }
      }
      if (command.position != null) {
        await c.invoke(nodeId, ep, Cluster.windowCovering, WindowCovering.goToLiftPercentage,
            fields: (w) => w.uint(0, ((1 - command.position!.clamp(0.0, 1.0)) * 10000).round()));
      }
      if (command.targetTemp != null) {
        final attr = _systemMode(device) == Thermostat.modeCool
            ? Thermostat.occupiedCoolingSetpoint
            : Thermostat.occupiedHeatingSetpoint;
        await c.write(nodeId, ep, Cluster.thermostat, attr, (w, tag) => w.int_(tag, (command.targetTemp! * 100).round()));
      }
      if (command.locked != null) {
        // Door locks only take commands inside a timed interaction.
        await c.invoke(nodeId, ep, Cluster.doorLock, command.locked! ? DoorLock.lockDoor : DoorLock.unlockDoor,
            timed: const Duration(seconds: 10));
      }
      if (command.speed != null && fan) {
        if (e?.has(Cluster.onOff) ?? false) await c.setOnOff(nodeId, ep, true);
        await c.write(nodeId, ep, Cluster.fanControl, FanControl.percentSetting,
            (w, tag) => w.uint(tag, (command.speed!.clamp(0.0, 1.0) * 100).round().clamp(1, 100)));
      }
      if (command.mode != null && fan) {
        await c.write(nodeId, ep, Cluster.fanControl, FanControl.fanMode,
            (w, tag) => w.uint(tag, command.mode == 'Auto' ? FanControl.modeAuto : FanControl.modeOn));
      } else if (command.mode != null) {
        final cluster = e == null ? null : _modeCluster(e);
        final mode = _modeId(device, command.mode!);
        if (cluster == null || mode == null) throw MatterException('It has no mode called ${command.mode}.');
        await _changeMode(device, cluster, mode);
      }
      if (command.action != null) await _act(device, command.action!);
    } on MatterException catch (err) {
      throw IntegrationException('${device.name}: ${err.message}');
    }
    return (await _read([device]))[device.id];
  }

  /// Starts, pauses, stops or sends home a robot or an appliance, or has a robot show where it is.
  Future<void> _act(Device d, DeviceAction action) async {
    final (nodeId, ep) = _ref(d)!;
    if (action == DeviceAction.locate) {
      await controller.invoke(nodeId, ep, Cluster.identify, Identify.identify, fields: (w) => w.uint(0, 10));
      return;
    }
    final e = _endpoint(d);
    final op = _opCluster(e, d.kind);
    if (op == null) return;
    // What it was doing before this command (its state already shows the command's outcome).
    final paused = d.props['opState'] == OperationalState.paused;
    if (d.kind != DeviceKind.vacuum) {
      final command = switch (action) {
        DeviceAction.start => paused ? OperationalState.resume : OperationalState.start,
        DeviceAction.pause => OperationalState.pause,
        DeviceAction.stop => OperationalState.stop,
        _ => null,
      };
      if (command != null) await _operate(d, op, command);
      return;
    }
    switch (action) {
      case DeviceAction.start when paused:
        await _operate(d, op, OperationalState.resume);
      case DeviceAction.start:
        await _changeMode(d, Cluster.rvcRunMode, await _runMode(d, ModeBase.tagCleaning));
      case DeviceAction.pause:
        await _operate(d, op, OperationalState.pause);
      case DeviceAction.stop:
        await _changeMode(d, Cluster.rvcRunMode, await _runMode(d, ModeBase.tagIdle));
      case DeviceAction.dock:
        // Matter 1.4 robots have a "go home" command; older ones go home when they stop cleaning.
        if (e?.opCommands?.contains(OperationalState.goHome) ?? true) {
          try {
            await _operate(d, op, OperationalState.goHome);
            return;
          } on ImStatusException catch (x) {
            if (x.status != ImStatus.unsupportedCommand) rethrow;
          }
        }
        await _changeMode(d, Cluster.rvcRunMode, await _runMode(d, ModeBase.tagIdle));
      default:
        break;
    }
  }

  /// Sends an operational state command, failing with the device's reason when it refuses.
  Future<void> _operate(Device d, int cluster, int command) async {
    final (nodeId, ep) = _ref(d)!;
    final r = await controller.invoke(nodeId, ep, cluster, command);
    final result = r?.fields.struct(0);
    final error = result?.integer(0);
    if (error != null && error != 0) {
      throw MatterException('${_problem(error, result!.string(1), robot: d.kind == DeviceKind.vacuum)}.');
    }
  }

  /// Switches a mode cluster to [mode], failing with the device's reason when it refuses.
  Future<void> _changeMode(Device d, int cluster, int mode) async {
    final (nodeId, ep) = _ref(d)!;
    final r = await controller.invoke(nodeId, ep, cluster, ModeBase.changeToMode, fields: (w) => w.uint(0, mode));
    final status = r?.fields.integer(0);
    if (status != null && status != 0) {
      final text = r!.fields.string(1)?.trim();
      throw MatterException(text != null && text.isNotEmpty ? text : _modeProblem(cluster, status));
    }
  }

  static String _modeProblem(int cluster, int status) => switch (status) {
        1 => 'It does not have that mode.',
        0x40 when cluster == Cluster.rvcCleanMode => 'It cannot change that while cleaning.',
        0x40 when cluster == Cluster.rvcRunMode => 'It is stuck.',
        0x41 when cluster == Cluster.rvcRunMode => 'Its dust bin is missing.',
        0x42 when cluster == Cluster.rvcRunMode => 'Its dust bin is full.',
        0x43 when cluster == Cluster.rvcRunMode => 'Its water tank is empty.',
        0x44 when cluster == Cluster.rvcRunMode => 'Its water tank is missing.',
        0x45 when cluster == Cluster.rvcRunMode => 'Its water tank lid is open.',
        0x46 when cluster == Cluster.rvcRunMode => 'Its mop pad is missing.',
        0x47 when cluster == Cluster.rvcRunMode => 'Its battery is too low.',
        _ => 'It cannot do that right now.',
      };

  /// The robot's run mode with [tag] (idle or cleaning), asked from the robot if it is not known yet.
  Future<int> _runMode(Device d, int tag) async {
    final key = tag == ModeBase.tagIdle ? 'idleMode' : 'cleanMode';
    if (d.props[key] is! int) {
      final (nodeId, ep) = _ref(d)!;
      final r = await controller.read(
          nodeId, [AttributePath(endpoint: ep, cluster: Cluster.rvcRunMode, attribute: ModeBase.supportedModes)]);
      _learnRunModes(d, r.get(ep, Cluster.rvcRunMode, ModeBase.supportedModes));
    }
    final mode = d.props[key];
    if (mode is! int) throw MatterException(tag == ModeBase.tagIdle ? 'It has no way to stop.' : 'It has no cleaning mode.');
    return mode;
  }

  static void _learnRunModes(Device d, Object? supported) {
    final modes = _modes(supported);
    final idle = modes.where((m) => m.tags.contains(ModeBase.tagIdle)).firstOrNull;
    final cleaning = modes.where((m) => m.tags.contains(ModeBase.tagCleaning)).firstOrNull;
    if (idle != null) d.props['idleMode'] = idle.id;
    if (cleaning != null) d.props['cleanMode'] = cleaning.id;
  }

  /// The modes a mode cluster offers: name, number and tags.
  static List<({String label, int id, List<int> tags})> _modes(Object? supported) => [
        if (supported is List)
          for (final m in supported.whereType<TlvStruct>())
            if (m.integer(1) case final id?)
              (
                label: m.string(0)?.trim().isNotEmpty ?? false ? m.string(0)!.trim() : 'Mode $id',
                id: id,
                tags: [
                  for (final t in m.array(2) ?? const [])
                    if (t is TlvStruct && t.integer(1) != null) t.integer(1)!,
                ],
              ),
      ];

  /// The number of the mode called [label], from the modes last read.
  static int? _modeId(Device d, String label) {
    final labels = d.props['modes'], ids = d.props['modeIds'];
    if (labels is! List || ids is! List) return null;
    final at = labels.indexOf(label);
    return at >= 0 && at < ids.length ? (ids[at] as num).toInt() : null;
  }

  Future<void> _power(Device d, bool on) async {
    final (nodeId, ep) = _ref(d)!;
    final e = _endpoint(d);
    final hasOnOff = e?.has(Cluster.onOff) ?? true;
    if (d.kind == DeviceKind.valve) {
      await controller.invoke(nodeId, ep, Cluster.valveConfigurationAndControl, on ? Valve.open : Valve.close);
    } else if (d.kind == DeviceKind.climate && !(e?.has(Cluster.onOff) ?? false)) {
      // Thermostats are switched with their system mode.
      await controller.write(nodeId, ep, Cluster.thermostat, Thermostat.systemMode,
          (w, tag) => w.uint(tag, on ? Thermostat.modeHeat : Thermostat.modeOff));
    } else if (!hasOnOff && (e?.has(Cluster.fanControl) ?? false)) {
      // Fans without on/off: fan mode 4 is "on", 0 is "off".
      await controller.write(nodeId, ep, Cluster.fanControl, FanControl.fanMode, (w, tag) => w.uint(tag, on ? 4 : 0));
    } else {
      await controller.setOnOff(nodeId, ep, on);
    }
  }

  int? _systemMode(Device d) => d.props['systemMode'] as int?;

  // ---- mapping ------------------------------------------------------------------

  static (int, int)? _ref(Device d) {
    final parts = d.externalId.split(':');
    if (parts.length != 2) return null;
    try {
      return (parseHex64(parts[0]), int.parse(parts[1]));
    } on FormatException {
      return null;
    }
  }

  MatterEndpoint? _endpoint(Device d) {
    final ref = _ref(d);
    if (ref == null) return null;
    return controller.nodes[ref.$1]?.endpoints.where((e) => e.id == ref.$2).firstOrNull;
  }

  List<Device> _devicesOf(MatterNode node) {
    final useful = [
      for (final e in node.endpoints)
        if (_kindOf(e) != null && (e.id != 0 || node.endpoints.length == 1)) e,
    ];
    return [
      for (final e in useful)
        makeDevice(
          externalId: '${hex64(node.nodeId)}:${e.id}',
          name: e.label ?? (useful.length > 1 ? '${_name(node)} ${e.id}' : _name(node)),
          kind: _kindOf(e)!,
          capabilities: _capabilities(e, _kindOf(e)!),
          props: {
            'node': hex64(node.nodeId),
            'endpoint': e.id,
            if (e.deviceTypes.isNotEmpty) 'deviceType': e.deviceTypes.first,
            if (e.colorFeatures != null) 'colorFeatures': e.colorFeatures,
            if (node.vendorId != null) 'vendorId': node.vendorId,
            if (node.productId != null) 'productId': node.productId,
            ..._kindProps(e, _kindOf(e)!),
          },
        ),
    ];
  }

  /// What the controls need to know: what the modes are called and which buttons make sense.
  static Map<String, dynamic> _kindProps(MatterEndpoint e, DeviceKind kind) {
    final commands = e.opCommands;
    return switch (kind) {
      DeviceKind.vacuum => {
          'modeTitle': 'Cleaning',
          // Without "go home", stopping is how a robot goes home, so one of the two buttons is enough.
          'noStop': commands != null && !commands.contains(OperationalState.goHome),
        },
      DeviceKind.appliance => {'noStop': commands != null && !commands.contains(OperationalState.stop)},
      DeviceKind.fan || DeviceKind.purifier when (e.fanFeatures ?? 0) & FanControl.featureAuto != 0 => {
          'modes': ['Auto'],
        },
      _ => const {},
    };
  }

  static String _name(MatterNode n) => n.label.isEmpty ? 'Matter device' : n.label;

  /// Sensor clusters whose attribute 0 is the reading.
  static const _sensorClusters = {
    Cluster.temperatureMeasurement,
    Cluster.relativeHumidityMeasurement,
    Cluster.illuminanceMeasurement,
    Cluster.occupancySensing,
    Cluster.booleanState,
    Cluster.pressureMeasurement,
    Cluster.airQuality,
  };

  static const _concentrations = {
    Cluster.carbonDioxideConcentration: 'CO2',
    Cluster.carbonMonoxideConcentration: 'CO',
    Cluster.pm25Concentration: 'PM2.5',
    Cluster.pm10Concentration: 'PM10',
    Cluster.tvocConcentration: 'VOC',
  };

  static const _units = ['ppm', 'ppb', 'ppt', 'mg/m³', 'µg/m³', 'ng/m³', 'particles/m³', 'Bq/m³'];

  static const _airQuality = ['', 'Good', 'Fair', 'Moderate', 'Poor', 'Very poor', 'Extremely poor'];

  /// Every cluster that gives a reading.
  static final _readingClusters = {..._sensorClusters, ..._concentrations.keys, Cluster.smokeCoAlarm};

  /// The operational state cluster of a robot or an appliance.
  static int? _opCluster(MatterEndpoint? e, DeviceKind kind) {
    if (kind == DeviceKind.vacuum) return Cluster.rvcOperationalState;
    if (kind != DeviceKind.appliance) return null;
    if (e == null || e.has(Cluster.operationalState)) return Cluster.operationalState;
    return e.has(Cluster.ovenCavityOperationalState) ? Cluster.ovenCavityOperationalState : null;
  }

  /// Where a robot's cleaning modes or an appliance's programs are, in the order looked for.
  static const _modeClusters = [
    Cluster.rvcCleanMode,
    Cluster.laundryWasherMode,
    Cluster.dishwasherMode,
    Cluster.microwaveOvenMode,
    Cluster.ovenMode,
  ];

  static int? _modeCluster(MatterEndpoint e) => _modeClusters.where(e.has).firstOrNull;

  /// The mode cluster [d]'s modes come from (fans have theirs in fan control).
  static int? _modeClusterOf(Device d, MatterEndpoint? e) =>
      d.has(Capability.mode) && e != null && d.kind != DeviceKind.fan && d.kind != DeviceKind.purifier
          ? _modeCluster(e)
          : null;

  /// The endpoints that may know a robot's battery level: its own, else the other power sources of the same
  /// device (never those of other devices behind the same bridge).
  List<int> _powerSources(Device d) {
    final (nodeId, ep) = _ref(d)!;
    final node = controller.nodes[nodeId];
    final e = _endpoint(d);
    if (node == null || e == null) return [ep];
    if (e.has(Cluster.powerSource)) return [ep];
    if (e.has(Cluster.bridgedDeviceBasicInformation)) return const [];
    return [
      for (final x in node.endpoints)
        if (x.has(Cluster.powerSource) && !x.has(Cluster.bridgedDeviceBasicInformation)) x.id,
    ];
  }

  static String? _activity(int state) => switch (state) {
        OperationalState.stopped => Activity.idle,
        OperationalState.running => Activity.running,
        OperationalState.paused => Activity.paused,
        OperationalState.error => Activity.error,
        OperationalState.seekingCharger => Activity.returning,
        OperationalState.charging => Activity.charging,
        OperationalState.docked => Activity.docked,
        0x43 => 'emptying_dust_bin',
        0x44 => 'cleaning_mop',
        0x45 => 'filling_water_tank',
        0x46 => 'updating_maps',
        _ => null,
      };

  /// An operational error in a few words, or null for none.
  static String? _problem(int id, String? label, {required bool robot}) => switch (id) {
        0 => null,
        1 => 'Cannot start',
        2 => 'Could not finish',
        3 => 'Cannot do that now',
        0x40 when robot => 'Cannot find its dock',
        0x41 when robot => 'Stuck',
        0x42 when robot => 'Dust bin missing',
        0x43 when robot => 'Dust bin full',
        0x44 when robot => 'Water tank empty',
        0x45 when robot => 'Water tank missing',
        0x46 when robot => 'Water tank lid open',
        0x47 when robot => 'Mop pad missing',
        0x48 when robot => 'Battery low',
        0x49 when robot => 'Cannot reach the area',
        0x4a when robot => 'Dirty water tank full',
        0x4b when robot => 'Dirty water tank missing',
        0x4c when robot => 'Wheels jammed',
        0x4d when robot => 'Brush jammed',
        0x4e when robot => 'Sensors blocked',
        _ => label != null && label.trim().isNotEmpty ? label.trim() : 'Error $id',
      };

  /// "45 min", "1 h 05 min".
  static String _duration(int seconds) {
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
  }

  static DeviceKind? _kindOf(MatterEndpoint e) {
    for (final t in e.deviceTypes) {
      switch (t) {
        case DeviceType.onOffLight ||
              DeviceType.dimmableLight ||
              DeviceType.colorTemperatureLight ||
              DeviceType.extendedColorLight:
          return DeviceKind.light;
        case DeviceType.onOffPlugInUnit || DeviceType.dimmablePlugInUnit:
          return DeviceKind.outlet;
        case DeviceType.mountedOnOffControl || DeviceType.mountedDimmableLoadControl:
          return DeviceKind.toggle;
        case DeviceType.temperatureSensor ||
              DeviceType.humiditySensor ||
              DeviceType.lightSensor ||
              DeviceType.occupancySensor ||
              DeviceType.contactSensor ||
              DeviceType.pressureSensor ||
              DeviceType.waterLeakDetector ||
              DeviceType.smokeCoAlarm ||
              DeviceType.airQualitySensor:
          return DeviceKind.sensor;
        case DeviceType.windowCovering:
          return DeviceKind.cover;
        case DeviceType.doorLock:
          return DeviceKind.lock;
        case DeviceType.thermostat || DeviceType.roomAirConditioner:
          return DeviceKind.climate;
        case DeviceType.fan:
          return DeviceKind.fan;
        case DeviceType.airPurifier:
          return DeviceKind.purifier;
        case DeviceType.roboticVacuumCleaner:
          return DeviceKind.vacuum;
        case DeviceType.waterValve:
          return DeviceKind.valve;
        case DeviceType.laundryWasher || DeviceType.laundryDryer || DeviceType.dishwasher || DeviceType.microwaveOven:
          return DeviceKind.appliance;
        case DeviceType.speaker || DeviceType.basicVideoPlayer:
          return DeviceKind.media;
      }
    }
    // An unknown device type (an oven's cavity, say): go by what it can do.
    if (e.has(Cluster.operationalState) || e.has(Cluster.ovenCavityOperationalState)) return DeviceKind.appliance;
    if (e.has(Cluster.onOff)) return DeviceKind.toggle;
    if (e.clusters.any(_readingClusters.contains)) return DeviceKind.sensor;
    return null;
  }

  static Set<Capability> _capabilities(MatterEndpoint e, DeviceKind kind) {
    switch (kind) {
      case DeviceKind.light || DeviceKind.outlet || DeviceKind.toggle:
        final f = e.colorFeatures;
        final hasColor = e.has(Cluster.colorControl);
        final ct = hasColor &&
            (f != null
                ? f & ColorControl.featureColorTemperature != 0
                : e.isA(DeviceType.colorTemperatureLight) || e.isA(DeviceType.extendedColorLight));
        final color = hasColor &&
            (f != null
                ? f & (ColorControl.featureHueSaturation | ColorControl.featureXy) != 0
                : e.isA(DeviceType.extendedColorLight));
        return {
          if (e.has(Cluster.onOff)) Capability.onOff,
          if (e.has(Cluster.levelControl)) Capability.brightness,
          if (ct) Capability.colorTemp,
          if (color) Capability.color,
        };
      case DeviceKind.sensor:
        return {Capability.readings};
      case DeviceKind.cover:
        return {Capability.position};
      case DeviceKind.lock:
        return {Capability.lock};
      case DeviceKind.climate:
        return {Capability.onOff, Capability.targetTemp};
      case DeviceKind.fan || DeviceKind.purifier:
        return {
          Capability.onOff,
          if (e.has(Cluster.fanControl)) Capability.speed,
          if ((e.fanFeatures ?? 0) & FanControl.featureAuto != 0) Capability.mode,
        };
      case DeviceKind.vacuum:
        return {
          Capability.run,
          Capability.dock,
          if (e.has(Cluster.identify)) Capability.locate,
          if (e.has(Cluster.rvcCleanMode)) Capability.mode,
        };
      case DeviceKind.appliance:
        final commands = e.opCommands;
        const control = [OperationalState.pause, OperationalState.stop, OperationalState.start, OperationalState.resume];
        return {
          if (_opCluster(e, kind) != null && (commands == null || commands.any(control.contains))) Capability.run,
          if (_modeCluster(e) != null) Capability.mode,
        };
      case DeviceKind.valve || DeviceKind.media:
        return {Capability.onOff};
      case DeviceKind.camera || DeviceKind.other:
        return {};
      default: // kinds no Matter device type maps to
        return defaultCapabilities(kind);
    }
  }

  /// The attributes that make up [d]'s state.
  List<AttributePath> _paths(Device d) {
    final (_, ep) = _ref(d)!;
    final e = _endpoint(d);
    bool has(int cluster) => e == null || e.has(cluster);
    AttributePath p(int cluster, int attribute) => AttributePath(endpoint: ep, cluster: cluster, attribute: attribute);
    final op = _opCluster(e, d.kind);
    final modes = _modeClusterOf(d, e);
    return [
      if (d.has(Capability.onOff) && has(Cluster.onOff) && d.kind != DeviceKind.climate) p(Cluster.onOff, OnOff.onOff),
      if (d.has(Capability.brightness)) p(Cluster.levelControl, LevelControl.currentLevel),
      if (d.has(Capability.colorTemp) || d.has(Capability.color)) ...[
        p(Cluster.colorControl, ColorControl.colorMode),
        if (d.has(Capability.colorTemp)) p(Cluster.colorControl, ColorControl.colorTemperatureMireds),
        if (d.has(Capability.color)) ...[
          if ((e?.colorFeatures ?? ColorControl.featureHueSaturation) & ColorControl.featureHueSaturation != 0) ...[
            p(Cluster.colorControl, ColorControl.currentHue),
            p(Cluster.colorControl, ColorControl.currentSaturation),
          ],
          if ((e?.colorFeatures ?? 0) & ColorControl.featureXy != 0) ...[
            p(Cluster.colorControl, ColorControl.currentX),
            p(Cluster.colorControl, ColorControl.currentY),
          ],
        ],
      ],
      if (d.kind == DeviceKind.sensor || d.kind == DeviceKind.purifier) ...[
        for (final c in _sensorClusters)
          if (e?.has(c) ?? false) p(c, measuredValue),
        for (final c in _concentrations.keys)
          if (e?.has(c) ?? false) ...[p(c, Concentration.measuredValue), p(c, Concentration.measurementUnit)],
        if (e?.has(Cluster.smokeCoAlarm) ?? false) ...[
          p(Cluster.smokeCoAlarm, SmokeCoAlarm.smokeState),
          p(Cluster.smokeCoAlarm, SmokeCoAlarm.coState),
        ],
      ],
      if (d.kind == DeviceKind.cover) p(Cluster.windowCovering, WindowCovering.currentPositionLiftPercent100ths),
      if (d.kind == DeviceKind.lock) p(Cluster.doorLock, DoorLock.lockState),
      if (d.kind == DeviceKind.climate) ...[
        p(Cluster.thermostat, Thermostat.localTemperature),
        p(Cluster.thermostat, Thermostat.systemMode),
        p(Cluster.thermostat, Thermostat.occupiedHeatingSetpoint),
        if (e?.has(Cluster.onOff) ?? false) p(Cluster.onOff, OnOff.onOff),
      ],
      if ((d.kind == DeviceKind.fan || d.kind == DeviceKind.purifier) && has(Cluster.fanControl)) ...[
        p(Cluster.fanControl, FanControl.fanMode),
        if (d.has(Capability.speed)) ...[
          p(Cluster.fanControl, FanControl.percentSetting),
          p(Cluster.fanControl, FanControl.percentCurrent),
        ],
      ],
      if (d.kind == DeviceKind.valve) ...[
        p(Cluster.valveConfigurationAndControl, Valve.currentState),
        p(Cluster.valveConfigurationAndControl, Valve.targetState),
      ],
      if (op != null) ...[
        p(op, OperationalState.operationalState),
        p(op, OperationalState.operationalError),
        if (d.kind == DeviceKind.appliance) p(op, OperationalState.countdownTime),
      ],
      if (d.kind == DeviceKind.vacuum) p(Cluster.rvcRunMode, ModeBase.supportedModes),
      if (modes != null) ...[p(modes, ModeBase.supportedModes), p(modes, ModeBase.currentMode)],
      if (d.kind == DeviceKind.vacuum)
        for (final b in _powerSources(d))
          AttributePath(endpoint: b, cluster: Cluster.powerSource, attribute: PowerSource.batPercentRemaining),
      if (e?.has(Cluster.bridgedDeviceBasicInformation) ?? false)
        p(Cluster.bridgedDeviceBasicInformation, BasicInfoAttr.reachable),
    ];
  }

  DeviceState _stateFrom(Device d, ReadResult r) {
    final (_, ep) = _ref(d)!;
    final e = _endpoint(d);
    Object? v(int cluster, int attribute) => r.get(ep, cluster, attribute);
    int? i(int cluster, int attribute) {
      final x = v(cluster, attribute);
      return x is int ? x : null;
    }

    final onOff = v(Cluster.onOff, OnOff.onOff);
    bool? on = onOff is bool ? onOff : null;
    final level = i(Cluster.levelControl, LevelControl.currentLevel);
    int? colorTempK, color;
    final mode = i(Cluster.colorControl, ColorControl.colorMode);
    final mireds = i(Cluster.colorControl, ColorControl.colorTemperatureMireds);
    if (mode == ColorControl.modeColorTemperature && mireds != null && mireds > 0) {
      colorTempK = (1000000 / mireds).round();
    } else if (mode == ColorControl.modeHueSaturation) {
      final h = i(Cluster.colorControl, ColorControl.currentHue), s = i(Cluster.colorControl, ColorControl.currentSaturation);
      if (h != null && s != null) color = hueSatToRgb(h, s);
    } else if (mode == ColorControl.modeXy) {
      final x = i(Cluster.colorControl, ColorControl.currentX), y = i(Cluster.colorControl, ColorControl.currentY);
      if (x != null && y != null) color = xyToRgb(x, y);
    }

    final readings = <String, String>{};
    double? currentTemp, targetTemp, position, speed, battery;
    bool? locked;
    String? activity, modeName;
    if (d.kind == DeviceKind.sensor || d.kind == DeviceKind.purifier) {
      final t = i(Cluster.temperatureMeasurement, measuredValue);
      if (t != null) {
        currentTemp = t / 100;
        readings['Temperature'] = '${currentTemp.toStringAsFixed(1)} °C';
      }
      final h = i(Cluster.relativeHumidityMeasurement, measuredValue);
      if (h != null) readings['Humidity'] = '${(h / 100).round()} %';
      final lux = i(Cluster.illuminanceMeasurement, measuredValue);
      if (lux != null) readings['Light'] = '${(lux == 0 ? 0 : pow(10, (lux - 1) / 10000)).round()} lx';
      final occ = i(Cluster.occupancySensing, measuredValue);
      if (occ != null) readings['Motion'] = occ & 1 != 0 ? 'Detected' : 'Clear';
      final state = v(Cluster.booleanState, measuredValue);
      if (state is bool) {
        readings[e?.isA(DeviceType.waterLeakDetector) ?? false ? 'Leak' : 'Contact'] =
            e?.isA(DeviceType.waterLeakDetector) ?? false ? (state ? 'Leak!' : 'Dry') : (state ? 'Closed' : 'Open');
      }
      final pressure = i(Cluster.pressureMeasurement, measuredValue);
      if (pressure != null) readings['Pressure'] = '$pressure hPa';
      final quality = i(Cluster.airQuality, measuredValue);
      if (quality != null && quality > 0 && quality < _airQuality.length) readings['Air quality'] = _airQuality[quality];
      for (final MapEntry(key: c, value: label) in _concentrations.entries) {
        final x = v(c, Concentration.measuredValue);
        final unit = i(c, Concentration.measurementUnit);
        if (x is num) readings[label] = '${x.round()}${unit != null && unit < _units.length ? ' ${_units[unit]}' : ''}';
      }
      final smoke = i(Cluster.smokeCoAlarm, SmokeCoAlarm.smokeState);
      if (smoke != null) readings['Smoke'] = const ['Clear', 'Warning', 'Smoke!'][smoke.clamp(0, 2)];
      final co = i(Cluster.smokeCoAlarm, SmokeCoAlarm.coState);
      if (co != null) readings['Carbon monoxide'] = const ['Clear', 'Warning', 'CO!'][co.clamp(0, 2)];
    }
    if (d.kind == DeviceKind.cover) {
      final lift = i(Cluster.windowCovering, WindowCovering.currentPositionLiftPercent100ths);
      if (lift != null) position = 1 - lift / 10000;
    }
    if (d.kind == DeviceKind.lock) {
      final s = i(Cluster.doorLock, DoorLock.lockState);
      if (s != null) locked = s == 1;
    }
    if (d.kind == DeviceKind.climate) {
      final t = i(Cluster.thermostat, Thermostat.localTemperature);
      if (t != null) currentTemp = t / 100;
      final m = i(Cluster.thermostat, Thermostat.systemMode);
      if (m != null) {
        on ??= m != Thermostat.modeOff;
        d.props['systemMode'] = m;
      }
      final sp = i(Cluster.thermostat, Thermostat.occupiedHeatingSetpoint);
      if (sp != null) targetTemp = sp / 100;
    }
    if (d.kind == DeviceKind.fan || d.kind == DeviceKind.purifier) {
      final m = i(Cluster.fanControl, FanControl.fanMode);
      if (m != null) {
        on ??= m != FanControl.modeOff;
        if (d.has(Capability.mode)) modeName = m == FanControl.modeAuto ? 'Auto' : '';
      }
      final pct = i(Cluster.fanControl, FanControl.percentSetting) ?? i(Cluster.fanControl, FanControl.percentCurrent);
      if (pct != null && pct > 0) speed = pct / 100;
    }
    if (d.kind == DeviceKind.valve) {
      final now = i(Cluster.valveConfigurationAndControl, Valve.currentState);
      final where = now == Valve.moving ? i(Cluster.valveConfigurationAndControl, Valve.targetState) : now;
      if (where != null) on = where == Valve.opened;
    }
    final op = _opCluster(e, d.kind);
    if (op != null) {
      final s = i(op, OperationalState.operationalState);
      if (s != null) {
        activity = _activity(s);
        d.props['opState'] = s;
      }
      final error = v(op, OperationalState.operationalError);
      if (error is TlvStruct) {
        readings['Error'] = _problem(error.integer(0) ?? 0, error.string(1), robot: d.kind == DeviceKind.vacuum) ?? '';
      }
      if (d.kind == DeviceKind.appliance) {
        final left = i(op, OperationalState.countdownTime);
        readings['Left'] = left != null && left > 0 ? _duration(left) : '';
      }
    }
    if (d.kind == DeviceKind.vacuum) {
      _learnRunModes(d, v(Cluster.rvcRunMode, ModeBase.supportedModes));
      for (final b in _powerSources(d)) {
        final level = r.get(b, Cluster.powerSource, PowerSource.batPercentRemaining);
        if (level is int) {
          battery = (level / 200).clamp(0.0, 1.0);
          break;
        }
      }
    }
    final modes = _modeClusterOf(d, e);
    if (modes != null) {
      final list = _modes(v(modes, ModeBase.supportedModes));
      if (list.isNotEmpty) {
        d.props['modes'] = [for (final m in list) m.label];
        d.props['modeIds'] = [for (final m in list) m.id];
      }
      final current = i(modes, ModeBase.currentMode);
      final ids = d.props['modeIds'], labels = d.props['modes'];
      if (current != null && ids is List && labels is List) {
        final at = ids.indexOf(current);
        modeName = at >= 0 && at < labels.length ? '${labels[at]}' : '';
      }
    }
    final reachable = v(Cluster.bridgedDeviceBasicInformation, BasicInfoAttr.reachable);
    return DeviceState(
      on: on,
      brightness: level == null ? null : level / 254,
      colorTempK: colorTempK,
      color: color,
      position: position,
      targetTemp: targetTemp,
      currentTemp: currentTemp,
      locked: locked,
      activity: activity,
      battery: battery,
      mode: modeName,
      speed: speed,
      readings: readings,
      reachable: reachable is bool ? reachable : true,
    );
  }
}

/// The progress steps [MatterDriver.commission] reports, in order.
const matterCommissioningSteps = [
  CommissioningStep.looking,
  CommissioningStep.checkingCode,
  CommissioningStep.securing,
  CommissioningStep.adding,
  CommissioningStep.reading,
];

/// Used by tests: the node id of a Matter device's external id.
int? matterNodeIdOf(Device d) => MatterDriver._ref(d)?.$1;
