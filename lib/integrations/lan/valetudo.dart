import 'dart:convert';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// Robot vacuums running Valetudo (the local, cloud-free firmware for Roborock, Dreame, Viomi and other
/// robots), over its REST API on port 80. They announce themselves as `_valetudo._tcp`.
class ValetudoProtocol extends LanProtocol {
  const ValetudoProtocol();

  @override
  String get id => 'valetudo';
  @override
  String get label => 'Valetudo robot';

  static int _port(Map<String, dynamic> props) => int.tryParse('${props['port']}') ?? 80;

  Uri _url(LanContext ctx, Device d, String path) =>
      ctx.url(d.props['host'] as String, _port(d.props), '/api/v2/robot$path');

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final port = _port(hints);
    final Map robot;
    final List capabilities;
    try {
      robot = await ctx.getJson(ctx.url(host, port, '/api/v2/robot')) as Map;
      capabilities = await ctx.getJson(ctx.url(host, port, '/api/v2/robot/capabilities')) as List;
    } catch (_) {
      return null;
    }
    if (robot['implementation'] == null && robot['modelName'] == null) return null;
    final speeds = <String>[];
    if (capabilities.contains('FanSpeedControlCapability')) {
      try {
        final list = await ctx.getJson(ctx.url(host, port, '/api/v2/robot/capabilities/FanSpeedControlCapability/presets'));
        speeds.addAll([for (final s in list as List) '$s']);
      } catch (_) {}
    }
    final model = [robot['manufacturer'], robot['modelName']].whereType<String>().join(' ');
    final hinted = hints['name'];
    final device = ctx.make(
      externalId: 'valetudo:$host',
      // Valetudo names itself "Valetudo <model> <random words>"; a name the user gave it is kept.
      name: hinted != null && hinted.isNotEmpty && !hinted.toLowerCase().startsWith('valetudo')
          ? hinted
          : (model.isEmpty ? 'Robot vacuum' : model),
      kind: DeviceKind.vacuum,
      capabilities: {
        if (capabilities.contains('BasicControlCapability')) ...{Capability.run, Capability.dock},
        if (capabilities.contains('LocateCapability')) Capability.locate,
        if (speeds.isNotEmpty) Capability.mode,
      },
      props: {
        'host': host,
        'protocol': id,
        if (port != 80) 'port': '$port',
        'model': model,
        if (speeds.isNotEmpty) 'modes': speeds,
      },
    );
    device.state = device.state.merge(await read(ctx, device) ?? const DeviceState());
    return [device];
  }

  /// What Valetudo calls what the robot is doing.
  static String? _activity(Object? status) => switch (status) {
        'cleaning' || 'moving' || 'manual_control' => Activity.running,
        'paused' => Activity.paused,
        'returning' => Activity.returning,
        'docked' => Activity.docked,
        'idle' => Activity.idle,
        'error' => Activity.error,
        _ => null,
      };

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final List attributes;
    try {
      attributes = await ctx.getJson(_url(ctx, device, '/state/attributes')) as List;
    } catch (_) {
      return DeviceState.unreachable;
    }
    Map? find(String type, [String? kind]) => attributes
        .whereType<Map>()
        .where((a) => a['__class'] == type && (kind == null || a['type'] == kind))
        .firstOrNull;
    final status = find('StatusStateAttribute');
    final battery = find('BatteryStateAttribute')?['level'];
    final activity = _activity(status?['value']);
    final error = status?['error'] is Map ? (status!['error'] as Map)['message'] : status?['metaData']?['error_description'];
    return DeviceState(
      activity: activity == Activity.docked && find('BatteryStateAttribute')?['flag'] == 'charging'
          ? Activity.charging
          : activity,
      battery: battery is num ? battery.clamp(0, 100) / 100 : null,
      mode: find('PresetSelectionStateAttribute', 'fan_speed')?['value'] as String?,
      readings: {'Error': activity == Activity.error && error is String ? error : ''},
    );
  }

  Future<void> _put(LanContext ctx, Device d, String path, Map<String, dynamic> body) async {
    final res = await ctx.put(_url(ctx, d, path), jsonEncode(body), headers: {'Content-Type': 'application/json'});
    if (res.statusCode >= 400) throw IntegrationException('${d.name} refused that (HTTP ${res.statusCode}).');
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    if (command.mode != null) {
      await _put(ctx, device, '/capabilities/FanSpeedControlCapability/preset', {'name': command.mode});
    }
    final action = switch (command.action) {
      DeviceAction.start => 'start',
      DeviceAction.pause => 'pause',
      DeviceAction.stop => 'stop',
      DeviceAction.dock => 'home',
      _ => null,
    };
    if (action != null) await _put(ctx, device, '/capabilities/BasicControlCapability', {'action': action});
    if (command.action == DeviceAction.locate) {
      await _put(ctx, device, '/capabilities/LocateCapability', {'action': 'locate'});
    }
    return null;
  }
}
