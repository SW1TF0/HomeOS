import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// Samsung Tizen TVs (2016 and newer) over their local remote-control websocket.
/// The first time, the TV asks whether to allow SmartHomeKJ; the token it hands
/// out is saved on the device.
class SamsungProtocol extends LanProtocol {
  SamsungProtocol();

  @override
  String get id => 'samsung';
  @override
  String get label => 'Samsung TV';

  static const keys = {
    RemoteKey.power: 'KEY_POWER',
    RemoteKey.volumeUp: 'KEY_VOLUP',
    RemoteKey.volumeDown: 'KEY_VOLDOWN',
    RemoteKey.mute: 'KEY_MUTE',
    RemoteKey.channelUp: 'KEY_CHUP',
    RemoteKey.channelDown: 'KEY_CHDOWN',
    RemoteKey.up: 'KEY_UP',
    RemoteKey.down: 'KEY_DOWN',
    RemoteKey.left: 'KEY_LEFT',
    RemoteKey.right: 'KEY_RIGHT',
    RemoteKey.ok: 'KEY_ENTER',
    RemoteKey.back: 'KEY_RETURN',
    RemoteKey.home: 'KEY_HOME',
    RemoteKey.menu: 'KEY_MENU',
    RemoteKey.playPause: 'KEY_PLAY',
    RemoteKey.stop: 'KEY_STOP',
    RemoteKey.rewind: 'KEY_REWIND',
    RemoteKey.forward: 'KEY_FF',
    RemoteKey.source: 'KEY_SOURCE',
  };

  static const appName = 'SmartHomeKJ';

  final Map<String, _Session> _sessions = {};

  Future<Map<String, dynamic>> _info(LanContext ctx, String host) async {
    final j = await ctx.getJson(ctx.url(host, 8001, '/api/v2/'));
    if (j is! Map || j['device'] is! Map) throw IntegrationException('$host is not a Samsung TV.');
    return Map<String, dynamic>.from(j);
  }

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final Map<String, dynamic> info;
    try {
      info = await _info(ctx, host);
    } catch (_) {
      return null;
    }
    final dev = Map<String, dynamic>.from(info['device'] as Map);
    final name = (dev['name'] ?? info['name'] ?? 'Samsung TV').toString().replaceAll('&quot;', '"');
    return [
      tvDevice(
        ctx,
        protocol: id,
        host: host,
        name: name,
        keys: keys.keys,
        props: {
          'model': '${dev['modelName'] ?? ''}',
          if (dev['wifiMac'] != null) 'mac': '${dev['wifiMac']}',
          'tokenAuth': '${dev['TokenAuthSupport']}' == 'true',
        },
        state: _stateFrom(dev),
      ),
    ];
  }

  DeviceState _stateFrom(Map dev) {
    final power = dev['PowerState'] as String?;
    return DeviceState(on: power == null ? true : power == 'on');
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    try {
      final info = await _info(ctx, device.props['host'] as String);
      return _stateFrom(info['device'] as Map);
    } catch (_) {
      return offTv;
    }
  }

  Uri _wsUrl(LanContext ctx, Device d) {
    final host = d.props['host'];
    final name = base64.encode(utf8.encode(appName));
    final token = d.props['token'] as String?;
    final secure = (d.props['tokenAuth'] == true) && ctx.allowTls;
    return Uri.parse(secure
        ? 'wss://$host:8002/api/v2/channels/samsung.remote.control?name=$name${token != null ? '&token=$token' : ''}'
        : 'ws://$host:8001/api/v2/channels/samsung.remote.control?name=$name');
  }

  Future<_Session> _session(LanContext ctx, Device d) async {
    final open = _sessions[d.id];
    if (open != null && !open.closed) return open;
    final ws = await ctx.webSocket(_wsUrl(ctx, d));
    final s = _Session(ws);
    // The first message says whether the TV let us in.
    final first = await s.next.timeout(const Duration(seconds: 30), onTimeout: () {
      ws.close();
      throw IntegrationException('${d.name} did not answer. Allow SmartHomeKJ on the TV screen and try again.');
    });
    final event = first['event'];
    if (event == 'ms.channel.unauthorized') {
      await ws.close();
      throw IntegrationException('${d.name} said no. On the TV open Settings > General > External Device Manager > '
          'Device Connection Manager, allow SmartHomeKJ, then try again.');
    }
    if (event != 'ms.channel.connect') {
      await ws.close();
      throw IntegrationException('${d.name} answered something unexpected ($event).');
    }
    final token = (first['data'] is Map) ? first['data']['token'] : null;
    if (token != null) d.props['token'] = '$token';
    _sessions[d.id] = s;
    return s;
  }

  Future<void> _press(LanContext ctx, Device d, String key) async {
    final s = await _session(ctx, d);
    s.ws.add(jsonEncode({
      'method': 'ms.remote.control',
      'params': {'Cmd': 'Click', 'DataOfCmd': key, 'Option': 'false', 'TypeOfRemote': 'SendRemoteKey'},
    }));
    s.touch();
  }

  @override
  Future<String?> setUp(LanContext ctx, Device device) async {
    try {
      await _session(ctx, device);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    if (command.on != null) {
      // On: wake-on-LAN is handled by the driver; a TV in standby also takes KEY_POWER.
      final current = await read(ctx, device);
      if (command.on == true && current?.on == true) return const DeviceState(on: true);
      if (command.on == false && current?.on == false) return const DeviceState(on: false);
      await _press(ctx, device, 'KEY_POWER');
      return DeviceState(on: command.on);
    }
    if (command.key != null) {
      final k = keys[command.key];
      if (k == null) throw unsupported(device, command.key!.name);
      await _press(ctx, device, k);
      return null;
    }
    if (command.volume != null) throw unsupported(device, 'volume level');
    return null;
  }

  @override
  Future<void> close() async {
    for (final s in _sessions.values) {
      await s.ws.close();
    }
    _sessions.clear();
  }
}

/// An open websocket, closed after a minute without key presses.
class _Session {
  _Session(this.ws) {
    ws.listen((m) {
      if (m is String) {
        try {
          final j = jsonDecode(m);
          if (j is Map<String, dynamic>) _incoming.add(j);
        } catch (_) {}
      }
    }, onDone: () => closed = true, onError: (_) => closed = true);
    touch();
  }

  final WebSocket ws;
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  bool closed = false;
  Timer? _idle;

  Future<Map<String, dynamic>> get next => _incoming.stream.first;

  void touch() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 60), () {
      closed = true;
      ws.close();
    });
  }
}
