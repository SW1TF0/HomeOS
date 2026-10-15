import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/device.dart';
import 'integration.dart';
import 'mqtt_model.dart';

/// Any MQTT broker (Mosquitto, the Home Assistant add-on, EMQX...). Imports
/// Zigbee2MQTT and Home Assistant MQTT discovery devices and accepts devices
/// with hand-typed topics. Updates arrive live, no polling.
class MqttDriver extends IntegrationDriver {
  MqttDriver(super.config, super.client)
      : model = MqttModel(
          z2mBase: config.setting('z2m_base', 'zigbee2mqtt'),
          discoveryPrefix: config.setting('discovery_prefix', 'homeassistant'),
        );

  final MqttModel model;
  MqttServerClient? _mqtt;
  StreamSubscription? _sub;
  final _subscribed = <String>{};
  Future<void>? _starting;

  bool get connected => _mqtt?.connectionStatus?.state == MqttConnectionState.connected;

  @override
  Future<void> start() {
    if (connected) return Future.value();
    return _starting ??= _connect().whenComplete(() => _starting = null);
  }

  Future<void> _connect() async {
    final host = config.setting('host');
    if (host.isEmpty) throw IntegrationException('Enter the broker address (for example 192.168.1.10).');
    final port = int.tryParse(config.setting('port', '1883')) ?? 1883;
    final id = 'smartmenukj-${Random().nextInt(1 << 32).toRadixString(16)}';
    final c = MqttServerClient.withPort(host, id, port)
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..connectTimeoutPeriod = 6000
      ..logging(on: false)
      ..connectionMessage = MqttConnectMessage().withClientIdentifier(id).startClean();
    try {
      final user = config.setting('username');
      final pass = config.setting('password');
      await c.connect(user.isEmpty ? null : user, pass.isEmpty ? null : pass);
    } catch (e) {
      c.disconnect();
      throw IntegrationException('Could not connect to $host:$port ($e).');
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      c.disconnect();
      throw IntegrationException('Broker $host:$port refused the connection (${c.connectionStatus?.returnCode}).');
    }
    _mqtt = c;
    _subscribed.clear();
    _sub = c.updates?.listen(_onMessages);
    _subscribeAll(model.subscriptions);
  }

  void _subscribeAll(Iterable<String> topics) {
    for (final t in topics) {
      if (_subscribed.add(t)) _mqtt?.subscribe(t, MqttQos.atMostOnce);
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage?>> messages) {
    for (final m in messages) {
      final msg = m.payload;
      if (msg is! MqttPublishMessage) continue;
      final payload = utf8.decode(msg.payload.message.toList(), allowMalformed: true);
      final (changed, newTopics) = model.handle(m.topic, payload);
      _subscribeAll(newTopics);
      changed.forEach((id, st) => onPush?.call(id, st));
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _mqtt?.disconnect();
    _mqtt = null;
  }

  /// Registers hand-made devices so their state topics are followed.
  @override
  void attach(Iterable<Device> devices) {
    for (final d in devices) {
      if (d.externalId.startsWith('manual:')) {
        _subscribeAll(model.register(d.externalId, Map<String, dynamic>.from(d.props)));
      }
    }
  }

  @override
  Future<List<Device>> discover() async {
    await start();
    // Retained messages (device lists, discovery configs, states) arrive right after subscribing.
    await Future.delayed(const Duration(seconds: 3));
    for (final name in model.z2mDevices.keys) {
      _publish(MqttOut('${model.z2mBase}/$name/get', jsonEncode({'state': ''})));
    }
    return model.devices((externalId, name, kind, caps, props, state) => makeDevice(
          externalId: externalId,
          name: name,
          kind: kind,
          capabilities: caps,
          props: props,
          state: state,
        ));
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    try {
      await start();
      attach(devices);
    } catch (_) {
      return {for (final d in devices) d.id: d.state.merge(DeviceState.unreachable)};
    }
    return {
      for (final d in devices)
        if (model.states[d.externalId] != null) d.id: d.state.merge(model.states[d.externalId]!),
    };
  }

  @override
  Future<DeviceState?> refresh(Device device) async => model.states[device.externalId];

  void _publish(MqttOut out) {
    final b = MqttClientPayloadBuilder()..addUTF8String(out.payload);
    _mqtt?.publishMessage(out.topic, MqttQos.atLeastOnce, b.payload!, retain: out.retain);
  }

  @override
  Future<DeviceState?> send(Device device, DeviceCommand command) async {
    await start();
    final msgs = model.commandsFor(device, command);
    if (msgs.isEmpty) throw IntegrationException('${device.name} has no command topic for that.');
    msgs.forEach(_publish);
    return null;
  }
}
