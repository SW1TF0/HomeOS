import 'dart:convert';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// Sony Bravia TVs (2013 and newer) over their REST API and IRCC remote codes.
/// The TV needs "Remote start" and a pre-shared key: Settings > Network >
/// Home network > IP control > Authentication > Normal and Pre-Shared Key.
class SonyProtocol extends LanProtocol {
  SonyProtocol();

  @override
  String get id => 'sony';
  @override
  String get label => 'Sony Bravia';

  static const ircc = {
    RemoteKey.power: 'AAAAAQAAAAEAAAAVAw==',
    RemoteKey.volumeUp: 'AAAAAQAAAAEAAAASAw==',
    RemoteKey.volumeDown: 'AAAAAQAAAAEAAAATAw==',
    RemoteKey.mute: 'AAAAAQAAAAEAAAAUAw==',
    RemoteKey.channelUp: 'AAAAAQAAAAEAAAAQAw==',
    RemoteKey.channelDown: 'AAAAAQAAAAEAAAARAw==',
    RemoteKey.up: 'AAAAAQAAAAEAAAB0Aw==',
    RemoteKey.down: 'AAAAAQAAAAEAAAB1Aw==',
    RemoteKey.left: 'AAAAAQAAAAEAAAA0Aw==',
    RemoteKey.right: 'AAAAAQAAAAEAAAAzAw==',
    RemoteKey.ok: 'AAAAAQAAAAEAAABlAw==',
    RemoteKey.back: 'AAAAAgAAAJcAAAAjAw==',
    RemoteKey.home: 'AAAAAQAAAAEAAABgAw==',
    RemoteKey.menu: 'AAAAAgAAAJcAAAA2Aw==',
    RemoteKey.playPause: 'AAAAAgAAAJcAAAAaAw==',
    RemoteKey.stop: 'AAAAAgAAAJcAAAAYAw==',
    RemoteKey.rewind: 'AAAAAgAAAJcAAAAbAw==',
    RemoteKey.forward: 'AAAAAgAAAJcAAAAcAw==',
    RemoteKey.source: 'AAAAAQAAAAEAAAAlAw==',
  };

  static const _pause = 'AAAAAgAAAJcAAAAZAw==';

  String _psk(Device d) {
    final k = '${d.props['psk'] ?? ''}'.trim();
    return k.isEmpty ? '0000' : k;
  }

  Future<dynamic> _call(LanContext ctx, String host, String service, String method,
      {List<dynamic> params = const [], String version = '1.0', String? psk}) async {
    final res = await ctx.post(
      ctx.url(host, 80, '/sony/$service'),
      jsonEncode({'method': method, 'params': params, 'id': 1, 'version': version}),
      headers: {'Content-Type': 'application/json', 'X-Auth-PSK': ?psk},
    );
    if (res.statusCode == 403 || res.statusCode == 401) {
      throw IntegrationException('The Sony TV refused the pre-shared key. Set the same key on the TV and on this device.');
    }
    if (res.statusCode >= 400) throw IntegrationException('The Sony TV answered HTTP ${res.statusCode}.');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    if (j is Map && j['error'] != null) {
      final err = j['error'];
      if (err is List && err.isNotEmpty && (err[0] == 403 || err[0] == 401)) {
        throw IntegrationException('The Sony TV refused the pre-shared key. Set the same key on the TV and on this device.');
      }
      throw IntegrationException('The Sony TV said: $err');
    }
    final result = j is Map ? j['result'] : null;
    return result is List && result.isNotEmpty ? result.first : result;
  }

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    Map info;
    try {
      final r = await _call(ctx, host, 'system', 'getInterfaceInformation');
      if (r is! Map) return null;
      info = r;
    } catch (_) {
      return null;
    }
    String? mac;
    try {
      final sys = await _call(ctx, host, 'system', 'getSystemInformation', psk: '0000');
      if (sys is Map) mac = sys['macAddr'] as String?;
    } catch (_) {}
    final model = '${info['modelName'] ?? ''}';
    return [
      tvDevice(
        ctx,
        protocol: id,
        host: host,
        name: hints['name'] ?? (model.isEmpty ? 'Sony TV' : 'Sony $model'),
        keys: ircc.keys,
        volume: true,
        props: {'model': model, 'mac': ?mac},
      ),
    ];
  }

  @override
  List<SettingField> fields(Device device) => const [
        SettingField('psk', 'Pre-shared key', hint: 'Set on the TV under IP control', secret: true, defaultValue: '0000'),
      ];

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final host = device.props['host'] as String;
    final dynamic power;
    try {
      power = await _call(ctx, host, 'system', 'getPowerStatus');
    } catch (_) {
      return offTv;
    }
    final on = power is Map && power['status'] == 'active';
    if (!on) return const DeviceState(on: false);
    try {
      final vol = await _call(ctx, host, 'audio', 'getVolumeInformation', psk: _psk(device));
      final list = vol is List ? vol : [vol];
      final speaker = list.whereType<Map>().firstWhere((v) => v['target'] == 'speaker', orElse: () => list.first as Map);
      final max = (speaker['maxVolume'] as num?) ?? 100;
      return DeviceState(
        on: true,
        volume: (speaker['volume'] as num?) == null ? null : (speaker['volume'] as num) / max,
        muted: speaker['mute'] as bool?,
      );
    } catch (_) {
      return const DeviceState(on: true);
    }
  }

  Future<void> _ircc(LanContext ctx, Device d, String code) async {
    final res = await ctx.post(
      ctx.url(d.props['host'] as String, 80, '/sony/IRCC'),
      '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      '<u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>$code</IRCCCode></u:X_SendIRCC>'
      '</s:Body></s:Envelope>',
      headers: {
        'Content-Type': 'text/xml; charset=UTF-8',
        'SOAPACTION': '"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"',
        'X-Auth-PSK': _psk(d),
      },
    );
    if (res.statusCode == 403 || res.statusCode == 401) {
      throw IntegrationException('The Sony TV refused the pre-shared key. Set the same key on the TV and on this device.');
    }
    if (res.statusCode >= 400) throw IntegrationException('The Sony TV answered HTTP ${res.statusCode}.');
  }

  final Map<String, bool> _playing = {};

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    final host = device.props['host'] as String;
    final psk = _psk(device);
    if (command.on != null) {
      await _call(ctx, host, 'system', 'setPowerStatus', params: [
        {'status': command.on}
      ], psk: psk);
      return DeviceState(on: command.on);
    }
    if (command.volume != null) {
      await _call(ctx, host, 'audio', 'setAudioVolume', params: [
        {'target': 'speaker', 'volume': '${(command.volume! * 100).round()}'}
      ], psk: psk);
      return DeviceState(volume: command.volume);
    }
    if (command.muted != null) {
      await _call(ctx, host, 'audio', 'setAudioMute', params: [
        {'status': command.muted}
      ], psk: psk);
      return DeviceState(muted: command.muted);
    }
    final key = command.key;
    if (key == null) return null;
    if (key == RemoteKey.playPause) {
      await _ircc(ctx, device, (_playing[device.id] ?? false) ? _pause : ircc[key]!);
      _playing[device.id] = !(_playing[device.id] ?? false);
      return null;
    }
    await _ircc(ctx, device, ircc[key]!);
    return null;
  }
}
