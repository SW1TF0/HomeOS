import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device.dart';
import '../models/home.dart';

/// A field on an integration's settings form.
class SettingField {
  const SettingField(
    this.key,
    this.label, {
    this.hint = '',
    this.secret = false,
    this.multiline = false,
    this.required = false,
    this.defaultValue,
  });

  final String key;
  final String label;
  final String hint;
  final bool secret;
  final bool multiline;
  final bool required;
  final String? defaultValue;
}

class IntegrationException implements Exception {
  IntegrationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Called by a driver when a device reports a new state on its own (MQTT pushes).
typedef StatePush = void Function(String externalId, DeviceState state);

/// Talks to one configured integration. One instance exists per [IntegrationConfig].
abstract class IntegrationDriver {
  IntegrationDriver(this.config, this.client);

  final IntegrationConfig config;
  final http.Client client;
  StatePush? onPush;

  /// Called when the driver changed [config]'s settings itself (keys it was given), so they get saved.
  void Function()? onSettings;

  /// Opens long-lived connections, if the integration has any.
  Future<void> start() async {}

  Future<void> stop() async {}

  /// Tells the driver which saved devices belong to it (after load or sync).
  void attach(Iterable<Device> devices) {}

  /// Finds the devices this integration can control.
  Future<List<Device>> discover();

  /// Reads the current state of every device in [devices], keyed by device id.
  /// Devices that could not be read are reported as unreachable.
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    final out = <String, DeviceState>{};
    for (final d in devices) {
      try {
        out[d.id] = await refresh(d) ?? d.state;
      } catch (_) {
        out[d.id] = d.state.merge(DeviceState.unreachable);
      }
    }
    return out;
  }

  Future<DeviceState?> refresh(Device device);

  /// Sends [command]. Returns the confirmed state if the device reports one.
  Future<DeviceState?> send(Device device, DeviceCommand command);

  /// For integrations that pair (Hue): returns settings to store on success.
  Future<Map<String, dynamic>> pair() =>
      throw IntegrationException('${config.name} does not need pairing.');

  Device makeDevice({
    required String externalId,
    required String name,
    required DeviceKind kind,
    Set<Capability>? capabilities,
    Map<String, dynamic>? props,
    DeviceState state = const DeviceState(),
  }) =>
      Device(
        id: Device.idFor(config.id, externalId),
        name: name,
        kind: kind,
        integrationId: config.id,
        externalId: externalId,
        capabilities: capabilities,
        props: props,
        state: state,
      );

  // HTTP helpers with sensible timeouts for devices on the local network.

  static const timeout = Duration(seconds: 6);

  Future<dynamic> getJson(Uri uri, {Map<String, String>? headers}) async {
    final res = await client.get(uri, headers: headers).timeout(timeout);
    return _decode(uri, res);
  }

  Future<dynamic> sendJson(String method, Uri uri, Object? body, {Map<String, String>? headers}) async {
    final req = http.Request(method, uri)
      ..headers.addAll({'Content-Type': 'application/json', ...?headers});
    if (body != null) req.body = jsonEncode(body);
    final streamed = await client.send(req).timeout(timeout);
    final res = await http.Response.fromStream(streamed).timeout(timeout);
    return _decode(uri, res);
  }

  dynamic _decode(Uri uri, http.Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw IntegrationException('${uri.host} refused access (HTTP ${res.statusCode}). Check the token or password.');
    }
    if (res.statusCode >= 400) {
      throw IntegrationException('${uri.host} answered HTTP ${res.statusCode}.');
    }
    if (res.body.trim().isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      return res.body;
    }
  }
}

/// Splits a "hosts" setting (one per line or comma separated) into hosts.
List<String> parseHosts(String raw) => raw
    .split(RegExp(r'[\s,;]+'))
    .map((h) => h.trim().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), ''))
    .where((h) => h.isNotEmpty)
    .toSet()
    .toList();

/// Base for devices that are each reached at their own LAN address
/// (Shelly, Tasmota, WLED, ESPHome). Reads each host at most once per refresh.
abstract class HostListDriver extends IntegrationDriver {
  HostListDriver(super.config, super.client);

  List<String> get hosts => parseHosts(config.setting('hosts'));

  Future<List<Device>> probe(String host);

  /// Reads everything a host reports, shared by all devices on that host.
  Future<dynamic> readHost(String host);

  DeviceState? stateFrom(Device device, dynamic hostData);

  @override
  Future<List<Device>> discover() async {
    if (hosts.isEmpty) {
      throw IntegrationException('Add at least one device address (for example 192.168.1.40).');
    }
    final out = <Device>[];
    final errors = <String>[];
    for (final host in hosts) {
      try {
        out.addAll(await probe(host));
      } catch (e) {
        errors.add('$host: $e');
      }
    }
    if (out.isEmpty && errors.isNotEmpty) {
      throw IntegrationException('Could not reach ${errors.join('; ')}');
    }
    return out;
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    final cache = <String, Future<dynamic>>{};
    final out = <String, DeviceState>{};
    for (final d in devices) {
      final host = d.props['host'] as String? ?? '';
      try {
        final data = await cache.putIfAbsent(host, () => readHost(host));
        out[d.id] = d.state.merge(stateFrom(d, data) ?? const DeviceState());
      } catch (_) {
        out[d.id] = d.state.merge(DeviceState.unreachable);
      }
    }
    return out;
  }

  @override
  Future<DeviceState?> refresh(Device device) async {
    final data = await readHost(device.props['host'] as String);
    return stateFrom(device, data);
  }
}
