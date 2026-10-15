import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// Google Cast devices: Chromecast, Google TV, Android TVs with Chromecast built-in,
/// Nest speakers and many soundbars. Volume, mute and play/pause of what is
/// casting. Cast cannot switch a TV on or off.
class CastProtocol extends LanProtocol {
  const CastProtocol();

  @override
  String get id => 'cast';
  @override
  String get label => 'Google Cast';

  static const keys = [
    RemoteKey.volumeUp,
    RemoteKey.volumeDown,
    RemoteKey.mute,
    RemoteKey.playPause,
    RemoteKey.stop,
  ];

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    String? name;
    String? model;
    try {
      final info = await ctx.getJson(ctx.url(host, 8008, '/setup/eureka_info?params=name,device_info'));
      if (info is! Map) return null;
      name = info['name'] as String?;
      final di = info['device_info'];
      if (di is Map) model = di['model_name'] as String?;
    } catch (_) {
      // Newer firmware closes 8008; the mDNS hint still tells us it is a Cast device.
      if (hints['protocol'] != id) return null;
    }
    return [
      tvDevice(
        ctx,
        protocol: id,
        host: host,
        name: name ?? hints['name'] ?? 'Cast device',
        keys: keys,
        power: false,
        volume: true,
        props: {'model': model ?? hints['model'] ?? ''},
      ),
    ];
  }

  Future<T> _with<T>(LanContext ctx, Device d, Future<T> Function(CastChannel c) run) async {
    final socket = await ctx.connect(d.props['host'] as String, 8009, tls: true);
    final c = CastChannel(socket);
    try {
      c.connect(CastChannel.receiver);
      return await run(c);
    } finally {
      c.close();
    }
  }

  static Map _status(Map<String, dynamic> m) => m['status'] is Map ? m['status'] as Map : const {};

  static DeviceState _stateFrom(Map status) {
    final vol = status['volume'] is Map ? status['volume'] as Map : const {};
    final apps = (status['applications'] as List? ?? const []).whereType<Map>().toList();
    final app = apps.where((a) => a['isIdleScreen'] != true).firstOrNull;
    return DeviceState(
      volume: (vol['level'] as num?)?.toDouble(),
      muted: vol['muted'] as bool?,
      readings: {'Playing': app == null ? 'Nothing' : '${app['displayName'] ?? 'An app'}'},
    );
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async =>
      _with(ctx, device, (c) async => _stateFrom(_status(await c.request(CastChannel.receiverNs, {'type': 'GET_STATUS'}))));

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) => _with(ctx, device, (c) async {
        Future<DeviceState> setVolume(Map<String, dynamic> v) async => _stateFrom(
            _status(await c.request(CastChannel.receiverNs, {'type': 'SET_VOLUME', 'volume': v})));
        if (command.on != null) throw unsupported(device, 'power (Cast cannot switch a TV on or off)');
        if (command.volume != null) return setVolume({'level': command.volume!.clamp(0.0, 1.0)});
        if (command.muted != null) return setVolume({'muted': command.muted});
        final key = command.key;
        if (key == null) return null;
        final status = _status(await c.request(CastChannel.receiverNs, {'type': 'GET_STATUS'}));
        final now = _stateFrom(status);
        switch (key) {
          case RemoteKey.volumeUp || RemoteKey.volumeDown:
            final level = ((now.volume ?? 0.3) + (key == RemoteKey.volumeUp ? 0.05 : -0.05)).clamp(0.0, 1.0);
            return setVolume({'level': level});
          case RemoteKey.mute:
            return setVolume({'muted': !(now.muted ?? false)});
          case RemoteKey.playPause || RemoteKey.stop:
            final apps = (status['applications'] as List? ?? const []).whereType<Map>();
            final app = apps.where((a) => a['isIdleScreen'] != true).firstOrNull;
            if (app == null) throw IntegrationException('Nothing is casting on ${device.name}.');
            if (key == RemoteKey.stop) {
              await c.request(CastChannel.receiverNs, {'type': 'STOP', 'sessionId': app['sessionId']});
              return const DeviceState(readings: {'Playing': 'Nothing'});
            }
            final transport = app['transportId'] as String;
            c.connect(transport);
            final media = await c.request(CastChannel.mediaNs, {'type': 'GET_STATUS'}, destination: transport);
            final list = (media['status'] as List? ?? const []).whereType<Map>().toList();
            if (list.isEmpty) throw IntegrationException('${app['displayName']} is not playing anything.');
            final playing = list.first['playerState'] == 'PLAYING';
            await c.request(CastChannel.mediaNs, {'type': playing ? 'PAUSE' : 'PLAY', 'mediaSessionId': list.first['mediaSessionId']},
                destination: transport);
            return null;
          default:
            throw unsupported(device, key.name);
        }
      });
}

/// A Cast v2 channel: length-prefixed protobuf `CastMessage`s carrying JSON.
class CastChannel {
  CastChannel(this.socket) {
    _sub = socket.listen(_onData, onError: (_) => _fail(), onDone: _fail);
  }

  static const sender = 'sender-0';
  static const receiver = 'receiver-0';
  static const connectionNs = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeatNs = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiverNs = 'urn:x-cast:com.google.cast.receiver';
  static const mediaNs = 'urn:x-cast:com.google.cast.media';

  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder();
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _waiting = {};

  void connect(String destination) => _send(connectionNs, {'type': 'CONNECT'}, destination);

  Future<Map<String, dynamic>> request(String ns, Map<String, dynamic> payload, {String destination = receiver}) {
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _waiting[id] = c;
    _send(ns, {...payload, 'requestId': id}, destination);
    return c.future.timeout(const Duration(seconds: 6), onTimeout: () {
      _waiting.remove(id);
      throw IntegrationException('The Cast device did not answer.');
    });
  }

  void _send(String ns, Map<String, dynamic> payload, String destination) {
    final msg = encodeCastMessage(sender, destination, ns, jsonEncode(payload));
    final len = ByteData(4)..setUint32(0, msg.length);
    socket.add([...len.buffer.asUint8List(), ...msg]);
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    var bytes = _buffer.toBytes();
    while (bytes.length >= 4) {
      final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (bytes.length < 4 + len) break;
      final msg = decodeCastMessage(bytes.sublist(4, 4 + len));
      bytes = bytes.sublist(4 + len);
      _handle(msg);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  void _handle(CastMessage m) {
    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(jsonDecode(m.payload) as Map);
    } catch (_) {
      return;
    }
    if (m.namespace == heartbeatNs && payload['type'] == 'PING') {
      _send(heartbeatNs, {'type': 'PONG'}, m.source);
      return;
    }
    final id = payload['requestId'];
    if (id is int) {
      final c = _waiting.remove(id);
      if (c == null) return;
      if (payload['type'] == 'INVALID_REQUEST' || payload['type'] == 'LOAD_FAILED') {
        c.completeError(IntegrationException('The Cast device said: ${payload['reason'] ?? payload['type']}'));
      } else {
        c.complete(payload);
      }
    }
  }

  void _fail() {
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError(IntegrationException('The Cast device closed the connection.'));
    }
    _waiting.clear();
  }

  void close() {
    _sub.cancel();
    socket.destroy();
  }
}

class CastMessage {
  const CastMessage(this.source, this.destination, this.namespace, this.payload);
  final String source;
  final String destination;
  final String namespace;
  final String payload;
}

void _varint(BytesBuilder b, int v) {
  while (v >= 0x80) {
    b.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  b.addByte(v);
}

void _string(BytesBuilder b, int field, String s) {
  final bytes = utf8.encode(s);
  _varint(b, (field << 3) | 2);
  _varint(b, bytes.length);
  b.add(bytes);
}

Uint8List encodeCastMessage(String source, String destination, String namespace, String payload) {
  final b = BytesBuilder();
  _varint(b, (1 << 3) | 0); // protocol_version = CASTV2_1_0
  _varint(b, 0);
  _string(b, 2, source);
  _string(b, 3, destination);
  _string(b, 4, namespace);
  _varint(b, (5 << 3) | 0); // payload_type = STRING
  _varint(b, 0);
  _string(b, 6, payload);
  return b.toBytes();
}

CastMessage decodeCastMessage(List<int> bytes) {
  var i = 0;
  int varint() {
    var shift = 0;
    var result = 0;
    while (true) {
      final byte = bytes[i++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  final strings = <int, String>{};
  while (i < bytes.length) {
    final tag = varint();
    final field = tag >> 3;
    switch (tag & 7) {
      case 0:
        varint();
      case 2:
        final len = varint();
        if (field >= 2 && field <= 6) strings[field] = utf8.decode(bytes.sublist(i, i + len), allowMalformed: true);
        i += len;
      case 1:
        i += 8;
      case 5:
        i += 4;
      default:
        return CastMessage(strings[2] ?? '', strings[3] ?? '', strings[4] ?? '', strings[6] ?? '');
    }
  }
  return CastMessage(strings[2] ?? '', strings[3] ?? '', strings[4] ?? '', strings[6] ?? '');
}
