import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device.dart';
import 'integration.dart';

/// ESPHome nodes with the `web_server:` component enabled. Entities are read
/// from the node's event stream and controlled through its REST endpoints.
class EspHomeDriver extends HostListDriver {
  EspHomeDriver(super.config, super.client);

  static const _listen = Duration(milliseconds: 2500);

  /// Reads the "state" events a node sends right after connecting.
  /// Returns entity key ("domain/object") to the event's JSON.
  @override
  Future<Map<String, Map<String, dynamic>>> readHost(String host) async {
    final req = http.Request('GET', Uri.parse('http://$host/events'))
      ..headers['Accept'] = 'text/event-stream';
    final res = await client.send(req).timeout(IntegrationDriver.timeout);
    if (res.statusCode != 200) {
      throw IntegrationException('$host answered HTTP ${res.statusCode}. Is web_server enabled?');
    }
    final out = <String, Map<String, dynamic>>{};
    final done = Completer<void>();
    String event = '';
    late final StreamSubscription<String> sub;
    sub = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:') && event == 'state') {
        try {
          final j = Map<String, dynamic>.from(jsonDecode(line.substring(5).trim()) as Map);
          final key = entityKey('${j['id']}');
          if (key != null) out[key] = j;
        } catch (_) {}
      }
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (_) {
      if (!done.isCompleted) done.complete();
    });
    await Future.any([done.future, Future.delayed(_listen)]);
    await sub.cancel();
    return out;
  }

  /// "light-desk_lamp" (web_server v1/v2) or "light/Desk Lamp" (v3) to "light/desk_lamp".
  static String? entityKey(String id) {
    final m = RegExp(r'^([a-z_]+)[-/](.+)$').firstMatch(id);
    if (m == null) return null;
    return '${m.group(1)}/${m.group(2)}';
  }

  static const _sensorDomains = {'sensor', 'binary_sensor', 'text_sensor'};

  @override
  Future<List<Device>> probe(String host) async {
    final entities = await readHost(host);
    if (entities.isEmpty) {
      throw IntegrationException('$host sent no entities. Add `web_server:` to its ESPHome config.');
    }
    final node = host.split('.').first;
    final out = <Device>[];
    final readings = <String, String>{};
    entities.forEach((key, j) {
      final domain = key.split('/').first;
      final name = '${j['name'] ?? key.split('/').last.replaceAll('_', ' ')}';
      if (_sensorDomains.contains(domain)) {
        readings[name] = '${j['state'] ?? j['value']}';
        return;
      }
      final kind = switch (domain) {
        'light' => DeviceKind.light,
        'switch' => DeviceKind.toggle,
        'fan' => DeviceKind.fan,
        'cover' => DeviceKind.cover,
        'lock' => DeviceKind.lock,
        _ => null,
      };
      if (kind == null) return;
      final d = makeDevice(
        externalId: '$host#$key',
        name: name,
        kind: kind,
        capabilities: kind == DeviceKind.light
            ? {Capability.onOff, if (j.containsKey('brightness')) Capability.brightness}
            : null,
        props: {'host': host, 'entity': key},
      );
      d.state = stateFrom(d, entities) ?? const DeviceState();
      out.add(d);
    });
    if (readings.isNotEmpty) {
      out.add(makeDevice(
        externalId: '$host#sensors',
        name: '$node sensors',
        kind: DeviceKind.sensor,
        props: {'host': host, 'entity': 'sensors'},
        state: DeviceState(readings: readings),
      ));
    }
    return out;
  }

  @override
  DeviceState? stateFrom(Device d, dynamic data) {
    final entities = data as Map<String, Map<String, dynamic>>;
    final key = d.props['entity'] as String;
    if (key == 'sensors') {
      final readings = <String, String>{};
      entities.forEach((k, j) {
        if (_sensorDomains.contains(k.split('/').first)) {
          readings['${j['name'] ?? k.split('/').last.replaceAll('_', ' ')}'] = '${j['state'] ?? j['value']}';
        }
      });
      return DeviceState(readings: readings);
    }
    final j = entities[key];
    if (j == null) return DeviceState.unreachable;
    final state = '${j['state']}'.toUpperCase();
    return DeviceState(
      on: j['value'] is bool ? j['value'] as bool : (state == 'ON' || state == 'OPEN'),
      brightness: j['brightness'] is num ? (j['brightness'] as num) / 255 : null,
      position: d.kind == DeviceKind.cover && j['position'] is num ? (j['position'] as num).toDouble() : null,
      locked: d.kind == DeviceKind.lock ? state == 'LOCKED' : null,
    );
  }

  @override
  Future<DeviceState?> send(Device d, DeviceCommand c) async {
    final host = d.props['host'] as String;
    final parts = (d.props['entity'] as String).split('/');
    Future<void> post(String action, [Map<String, String>? q]) async {
      final uri = Uri(scheme: 'http', host: host.split(':').first,
          port: host.contains(':') ? int.parse(host.split(':').last) : null,
          pathSegments: [parts[0], parts.sublist(1).join('/'), action], queryParameters: q);
      final res = await client.post(uri).timeout(IntegrationDriver.timeout);
      if (res.statusCode >= 400) throw IntegrationException('$host answered HTTP ${res.statusCode}.');
    }

    if (c.position != null) {
      await post('set', {'position': c.position!.toStringAsFixed(2)});
    } else if (c.locked != null) {
      await post(c.locked! ? 'lock' : 'unlock');
    } else if (c.brightness != null) {
      await post('turn_on', {'brightness': '${(c.brightness! * 255).round()}'});
    } else if (c.on != null) {
      await post(c.on! ? 'turn_on' : 'turn_off');
    }
    return null;
  }
}
