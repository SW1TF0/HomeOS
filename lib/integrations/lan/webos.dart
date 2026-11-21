import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// LG webOS TVs over their local "SSAP" websocket (ports 3000 / 3001).
/// The first connection shows a prompt on the TV; the key it hands out is saved.
class WebOsProtocol extends LanProtocol {
  WebOsProtocol();

  @override
  String get id => 'webos';
  @override
  String get label => 'LG TV';

  /// Keys sent as button presses on the TV's pointer socket.
  static const buttons = {
    RemoteKey.up: 'UP',
    RemoteKey.down: 'DOWN',
    RemoteKey.left: 'LEFT',
    RemoteKey.right: 'RIGHT',
    RemoteKey.ok: 'ENTER',
    RemoteKey.back: 'BACK',
    RemoteKey.home: 'HOME',
    RemoteKey.menu: 'MENU',
    RemoteKey.rewind: 'REWIND',
    RemoteKey.forward: 'FASTFORWARD',
  };

  /// Keys sent as SSAP requests.
  static const requests = {
    RemoteKey.volumeUp: 'ssap://audio/volumeUp',
    RemoteKey.volumeDown: 'ssap://audio/volumeDown',
    RemoteKey.channelUp: 'ssap://tv/channelUp',
    RemoteKey.channelDown: 'ssap://tv/channelDown',
    RemoteKey.stop: 'ssap://media.controls/stop',
  };

  static final allKeys = {
    RemoteKey.power,
    RemoteKey.mute,
    RemoteKey.playPause,
    ...buttons.keys,
    ...requests.keys,
  };

  final Map<String, _SsapSession> _sessions = {};
  final Map<String, bool> _playing = {};

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final maker = '${hints['manufacturer']} ${hints['server']} ${hints['model']}'.toLowerCase();
    final looksLg = hints['protocol'] == id || maker.contains('lg ') || maker.contains('webos') || maker.contains('lge');
    if (!looksLg) {
      // Another protocol already claimed it.
      if (hints['protocol'] != null && hints['protocol'] != 'generic' && hints['protocol'] != 'upnp') return null;
      // Without a hint, an open SSAP port is a strong sign.
      if (!await ctx.tcpOpen(host, 3001) && !await ctx.tcpOpen(host, 3000)) return null;
    }
    final name = hints['name'] ?? 'LG TV';
    return [
      tvDevice(ctx, protocol: id, host: host, name: name, keys: allKeys, volume: true, props: {
        if (hints['model'] != null) 'model': hints['model'],
      }),
    ];
  }

  Future<_SsapSession> _session(LanContext ctx, Device d) async {
    final open = _sessions[d.id];
    if (open != null && !open.closed) return open;
    final host = d.props['host'];
    WebSocket ws;
    try {
      ws = await ctx.webSocket(Uri.parse(ctx.allowTls ? 'wss://$host:3001' : 'ws://$host:3000'));
    } catch (_) {
      ws = await ctx.webSocket(Uri.parse('ws://$host:3000'));
    }
    var s = _SsapSession(ws);
    final key = d.props['clientKey'] as String?;
    Map<String, dynamic> reg;
    try {
      reg = await s.register(_registration(key, signed: true), key == null);
    } on IntegrationException catch (e) {
      if (!e.message.startsWith('The TV said')) rethrow;
      // Some firmware rejects the signed manifest; ask with a plain one.
      await s.close();
      s = _SsapSession(await ctx.webSocket(Uri.parse('ws://$host:3000')));
      reg = await s.register(_registration(key, signed: false), key == null);
    }
    final newKey = reg['client-key'];
    if (newKey != null) d.props['clientKey'] = '$newKey';
    _sessions[d.id] = s;
    // Remember the MAC so the TV can be woken later.
    if (d.props['mac'] == null) {
      unawaited(s.request('ssap://com.webos.service.connectionmanager/getinfo').then((info) {
        final mac = (info['wiredInfo'] is Map ? info['wiredInfo']['macAddress'] : null) ??
            (info['wifiInfo'] is Map ? info['wifiInfo']['macAddress'] : null);
        if (mac != null) d.props['mac'] = '$mac';
      }, onError: (_) {}));
    }
    return s;
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
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    if (device.props['clientKey'] == null) {
      // Not paired yet: only check that it is there.
      return await ctx.tcpOpen(device.props['host'] as String, 3000) ? const DeviceState(on: true) : offTv;
    }
    try {
      final s = await _session(ctx, device);
      final v = await s.request('ssap://audio/getVolume');
      final status = v['volumeStatus'] is Map ? v['volumeStatus'] as Map : v;
      final vol = status['volume'] as num?;
      final muted = status['muted'] ?? status['muteStatus'];
      return DeviceState(on: true, volume: vol == null ? null : vol / 100, muted: muted is bool ? muted : null);
    } catch (_) {
      return offTv;
    }
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    // The power key only arrives here when the state is unknown; a TV that answers is on.
    if (command.on == false || command.key == RemoteKey.power) {
      final s = await _session(ctx, device);
      await s.request('ssap://system/turnOff');
      return const DeviceState(on: false);
    }
    if (command.on == true) return null; // turning on is Wake-on-LAN, sent by the driver
    final s = await _session(ctx, device);
    if (command.volume != null) {
      await s.request('ssap://audio/setVolume', {'volume': (command.volume! * 100).round()});
      return DeviceState(volume: command.volume);
    }
    if (command.muted != null) {
      await s.request('ssap://audio/setMute', {'mute': command.muted});
      return DeviceState(muted: command.muted);
    }
    final key = command.key;
    if (key == null) return null;
    if (key == RemoteKey.mute) {
      final mute = !(device.state.muted ?? false);
      await s.request('ssap://audio/setMute', {'mute': mute});
      return DeviceState(muted: mute);
    }
    if (key == RemoteKey.playPause) {
      final playing = _playing[device.id] ?? false;
      await s.request(playing ? 'ssap://media.controls/pause' : 'ssap://media.controls/play');
      _playing[device.id] = !playing;
      return null;
    }
    final uri = requests[key];
    if (uri != null) {
      await s.request(uri);
      return null;
    }
    final button = buttons[key];
    if (button == null) throw unsupported(device, key.name);
    await s.button(ctx, button);
    return null;
  }

  @override
  Future<void> close() async {
    for (final s in _sessions.values) {
      await s.close();
    }
    _sessions.clear();
  }

  static Map<String, dynamic> _registration(String? clientKey, {required bool signed}) => {
        'forcePairing': false,
        'pairingType': 'PROMPT',
        'client-key': ?clientKey,
        'manifest': {
          'manifestVersion': 1,
          'appVersion': '1.1',
          if (signed) 'signed': _signed,
          'permissions': _permissions,
          if (signed) 'signatures': _signatures,
        },
      };

  static const _permissions = [
    'LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'TEST_OPEN', 'TEST_PROTECTED', 'CONTROL_AUDIO', //
    'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK', 'CONTROL_INPUT_MEDIA_RECORDING', 'CONTROL_INPUT_MEDIA_PLAYBACK',
    'CONTROL_INPUT_TV', 'CONTROL_POWER', 'READ_APP_STATUS', 'READ_CURRENT_CHANNEL', 'READ_INPUT_DEVICE_LIST',
    'READ_NETWORK_STATE', 'READ_RUNNING_APPS', 'READ_TV_CHANNEL_LIST', 'WRITE_NOTIFICATION_TOAST',
    'READ_POWER_STATE', 'READ_COUNTRY_INFO',
  ];

  // The manifest LG's own remote app uses; webOS accepts it from any client.
  static const _signed = {
    'created': '20140509',
    'appId': 'com.lge.test',
    'vendorId': 'com.lge',
    'localizedAppNames': {'': 'LG Remote App', 'ko-KR': '리모컨 앱', 'zxx-XX': 'ЛГ Rэмotэ AПП'},
    'localizedVendorNames': {'': 'LG Electronics'},
    'permissions': [
      'TEST_SECURE', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD', 'READ_INSTALLED_APPS', 'READ_LGE_SDX', //
      'READ_NOTIFICATIONS', 'SEARCH', 'WRITE_SETTINGS', 'WRITE_NOTIFICATION_ALERT', 'CONTROL_POWER',
      'READ_CURRENT_CHANNEL', 'READ_RUNNING_APPS', 'READ_UPDATE_INFO', 'UPDATE_FROM_REMOTE_APP',
      'READ_LGE_TV_INPUT_EVENTS', 'READ_TV_CURRENT_TIME',
    ],
    'serial': '2f930e2d2cfe083771f68e4fe7bb07',
  };

  static const _signatures = [
    {
      'signatureVersion': 1,
      'signature': 'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.'
          'hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/'
          'FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5'
          'NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==',
    },
  ];
}

/// One registered SSAP connection.
class _SsapSession {
  _SsapSession(this.ws) {
    ws.listen(_onMessage, onDone: () => closed = true, onError: (_) => closed = true);
    _idle();
  }

  final WebSocket ws;
  bool closed = false;
  int _next = 0;
  final Map<String, Completer<Map<String, dynamic>>> _waiting = {};
  Completer<Map<String, dynamic>>? _registered;
  WebSocket? _pointer;
  Timer? _timer;

  void _idle() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 90), close);
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> m;
    try {
      m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return;
    }
    final payload = m['payload'] is Map ? Map<String, dynamic>.from(m['payload'] as Map) : <String, dynamic>{};
    if (m['type'] == 'registered') {
      _registered?.complete(payload);
      return;
    }
    final c = _waiting.remove(m['id']);
    if (m['type'] == 'error') {
      final e = IntegrationException('The TV said: ${m['error'] ?? 'error'}');
      if (m['id'] == 'register_0' && _registered != null && !_registered!.isCompleted) {
        _registered!.completeError(e);
      }
      c?.completeError(e);
      return;
    }
    // "response" to register only means the prompt is showing; keep waiting.
    if (m['id'] == 'register_0') return;
    c?.complete(payload);
  }

  Future<Map<String, dynamic>> register(Map<String, dynamic> payload, bool firstTime) {
    _registered = Completer();
    ws.add(jsonEncode({'type': 'register', 'id': 'register_0', 'payload': payload}));
    return _registered!.future.timeout(Duration(seconds: firstTime ? 60 : 10), onTimeout: () {
      close();
      throw IntegrationException(firstTime
          ? 'The LG TV did not confirm. Accept SmartHomeKJ on the TV screen and try again.'
          : 'The LG TV did not answer.');
    });
  }

  Future<Map<String, dynamic>> request(String uri, [Map<String, dynamic>? payload]) {
    _idle();
    final id = 'req_${_next++}';
    final c = Completer<Map<String, dynamic>>();
    _waiting[id] = c;
    ws.add(jsonEncode({'type': 'request', 'id': id, 'uri': uri, 'payload': ?payload}));
    return c.future.timeout(const Duration(seconds: 6), onTimeout: () {
      _waiting.remove(id);
      throw IntegrationException('The LG TV did not answer $uri.');
    });
  }

  Future<void> button(LanContext ctx, String name) async {
    if (_pointer == null || _pointer!.closeCode != null) {
      final r = await request('ssap://com.webos.service.networkinput/getPointerInputSocket');
      final path = r['socketPath'] as String?;
      if (path == null) throw IntegrationException('The LG TV did not open its remote socket.');
      _pointer = await ctx.webSocket(Uri.parse(path));
    }
    _pointer!.add('type:button\nname:$name\n\n');
  }

  Future<void> close() async {
    _timer?.cancel();
    closed = true;
    await _pointer?.close();
    await ws.close();
  }
}
