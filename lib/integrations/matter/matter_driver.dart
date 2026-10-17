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
    final byNode = <int, List<Device>>{};
    final out = <String, DeviceState>{};
    for (final d in devices) {
      final ref = _ref(d);
      if (ref == null) {
        out[d.id] = d.state.merge(DeviceState.unreachable);
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
              out[d.id] = d.state.merge(_stateFrom(d, r));
            }
          } catch (_) {
            for (final d in list) {
              out[d.id] = d.state.merge(DeviceState.unreachable);
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
    } on MatterException catch (err) {
      throw IntegrationException('${device.name}: ${err.message}');
    }
    return (await refreshAll([device]))[device.id];
  }

  Future<void> _power(Device d, bool on) async {
    final (nodeId, ep) = _ref(d)!;
    final e = _endpoint(d);
    final hasOnOff = e?.has(Cluster.onOff) ?? true;
    if (d.kind == DeviceKind.climate && !(e?.has(Cluster.onOff) ?? false)) {
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
          },
        ),
    ];
  }

  static String _name(MatterNode n) => n.label.isEmpty ? 'Matter device' : n.label;

  static const _sensorClusters = {
    Cluster.temperatureMeasurement,
    Cluster.relativeHumidityMeasurement,
    Cluster.illuminanceMeasurement,
    Cluster.occupancySensing,
    Cluster.booleanState,
    Cluster.pressureMeasurement,
  };

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
              DeviceType.waterLeakDetector:
          return DeviceKind.sensor;
        case DeviceType.windowCovering:
          return DeviceKind.cover;
        case DeviceType.doorLock:
          return DeviceKind.lock;
        case DeviceType.thermostat || DeviceType.roomAirConditioner:
          return DeviceKind.climate;
        case DeviceType.fan || DeviceType.airPurifier:
          return DeviceKind.fan;
        case DeviceType.speaker || DeviceType.basicVideoPlayer:
          return DeviceKind.media;
      }
    }
    // An unknown device type: go by what it can do.
    if (e.has(Cluster.onOff)) return DeviceKind.toggle;
    if (e.clusters.any(_sensorClusters.contains)) return DeviceKind.sensor;
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
      case DeviceKind.fan || DeviceKind.media:
        return {Capability.onOff};
      case DeviceKind.camera || DeviceKind.other:
        return {};
      default:
        return defaultCapabilities(kind);
    }
  }

  /// The attributes that make up [d]'s state.
  List<AttributePath> _paths(Device d) {
    final (_, ep) = _ref(d)!;
    final e = _endpoint(d);
    bool has(int cluster) => e == null || e.has(cluster);
    AttributePath p(int cluster, int attribute) => AttributePath(endpoint: ep, cluster: cluster, attribute: attribute);
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
      if (d.kind == DeviceKind.sensor)
        for (final c in _sensorClusters)
          if (e?.has(c) ?? false) p(c, measuredValue),
      if (d.kind == DeviceKind.cover) p(Cluster.windowCovering, WindowCovering.currentPositionLiftPercent100ths),
      if (d.kind == DeviceKind.lock) p(Cluster.doorLock, DoorLock.lockState),
      if (d.kind == DeviceKind.climate) ...[
        p(Cluster.thermostat, Thermostat.localTemperature),
        p(Cluster.thermostat, Thermostat.systemMode),
        p(Cluster.thermostat, Thermostat.occupiedHeatingSetpoint),
        if (e?.has(Cluster.onOff) ?? false) p(Cluster.onOff, OnOff.onOff),
      ],
      if (d.kind == DeviceKind.fan && !(e?.has(Cluster.onOff) ?? true)) p(Cluster.fanControl, FanControl.fanMode),
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
    double? currentTemp, targetTemp, position;
    bool? locked;
    if (d.kind == DeviceKind.sensor) {
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
    if (d.kind == DeviceKind.fan && on == null) {
      final m = i(Cluster.fanControl, FanControl.fanMode);
      if (m != null) on = m != 0;
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
