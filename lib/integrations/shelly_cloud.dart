import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import 'integration.dart';

/// The Shelly cloud (Cloud Control API), with the key and server from the Shelly app's
/// User settings > Authorization cloud key. Reaches every Shelly on the account from anywhere.
class ShellyCloud {
  ShellyCloud(this.client, {required String server, required this.key}) : base = _base(server);

  final http.Client client;
  final String key;
  final Uri base;

  static Uri _base(String server) {
    var s = server.trim().replaceAll(RegExp(r'/+$'), '');
    if (s.isEmpty) return Uri();
    if (!s.startsWith('http')) s = 'https://$s';
    return Uri.parse(s);
  }

  bool get usable => key.trim().isNotEmpty && base.host.isNotEmpty;

  static const timeout = Duration(seconds: 10);

  /// Shelly allows one request a second. Tests make it shorter.
  static Duration gap = const Duration(milliseconds: 1050);
  Future<void> _queue = Future.value();
  DateTime? _last;

  Future<T> _paced<T>(Future<T> Function() call) {
    final turn = _queue.then((_) async {
      final wait = _last == null ? Duration.zero : gap - clock.now().difference(_last!);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      try {
        return await call();
      } finally {
        _last = clock.now();
      }
    });
    _queue = turn.then((_) {}, onError: (_) {});
    return turn;
  }

  /// The old form-encoded calls, which still list the whole account.
  Future<Map<String, dynamic>> _v1(String path) => _paced(() async {
        final res = await client
            .post(base.replace(path: path), body: {'auth_key': key})
            .timeout(timeout);
        _check(res);
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is! Map || body['isok'] != true) {
          final errors = body is Map ? body['errors'] : null;
          final first = errors is Map && errors.isNotEmpty ? '${errors.keys.first}' : '$errors';
          throw IntegrationException(first.contains('auth') || first.contains('key')
              ? 'Shelly Cloud refused the key. Copy it again from the Shelly app: it changes when the password does.'
              : 'Shelly Cloud: ${first == 'null' ? 'it said no' : first.replaceAll('_', ' ')}.');
        }
        return Map<String, dynamic>.from(body['data'] as Map? ?? const {});
      });

  Future<dynamic> _v2(String path, Map<String, dynamic> body) => _paced(() async {
        final res = await client
            .post(base.replace(path: path, queryParameters: {'auth_key': key}),
                headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
            .timeout(timeout);
        _check(res);
        return res.body.trim().isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
      });

  void _check(http.Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw IntegrationException('Shelly Cloud refused the key. Copy it again from the Shelly app: it changes '
          'when the password does.');
    }
    if (res.statusCode < 400) return;
    String? error;
    try {
      error = (jsonDecode(res.body) as Map)['error'] as String?;
    } catch (_) {}
    throw IntegrationException(switch (error) {
      'DEVICE_OFFLINE' => 'it is offline in the Shelly cloud',
      'DEVICE_NOT_FOUND' => 'the Shelly cloud does not know it. Add it to the Shelly app with this account',
      null => 'Shelly Cloud answered HTTP ${res.statusCode}',
      _ => 'Shelly Cloud: $error',
    });
  }

  /// Every device on the account with what it last reported, keyed by its id. Each status also has `_dev_info`
  /// (id, gen, code, online) and the device's MAC.
  Future<Map<String, Map<String, dynamic>>> allStatus() async {
    final data = await _v1('/device/all_status');
    final all = data['devices_status'] as Map? ?? const {};
    return {for (final e in all.entries) '${e.key}': Map<String, dynamic>.from(e.value as Map? ?? const {})};
  }

  /// The names given in the Shelly app, keyed by device id. Empty when the cloud does not say.
  Future<Map<String, String>> names() async {
    try {
      final data = await _v1('/interface/device/get_all_lists');
      final devices = data['devices'] as Map? ?? const {};
      return {
        for (final e in devices.entries)
          if (e.value is Map && ((e.value as Map)['name'] as String? ?? '').trim().isNotEmpty)
            '${e.key}': ((e.value as Map)['name'] as String).trim(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// The status of [ids] now: id -> (online, status).
  Future<Map<String, ({bool online, Map<String, dynamic> status})>> statusOf(Iterable<String> ids) async {
    final out = <String, ({bool online, Map<String, dynamic> status})>{};
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 10) {
      final res = await _v2('/v2/devices/api/get', {
        'ids': list.sublist(i, (i + 10).clamp(0, list.length)),
        'select': ['status'],
      });
      for (final d in (res as List? ?? const [])) {
        if (d is! Map) continue;
        out['${d['id']}'] = (
          online: d['online'] == 1 || d['online'] == true,
          status: Map<String, dynamic>.from(d['status'] as Map? ?? const {}),
        );
      }
    }
    return out;
  }

  Future<void> setSwitch(String id, int channel, bool on) =>
      _v2('/v2/devices/api/set/switch', {'id': id, 'channel': channel, 'on': on});

  Future<void> setLight(String id, int channel, {bool? on, int? brightness}) => _v2('/v2/devices/api/set/light', {
        'id': id,
        'channel': channel,
        'on': ?on,
        if (brightness != null) ...{'on': true, 'brightness': brightness},
      });

  Future<void> setCover(String id, int channel, int position) =>
      _v2('/v2/devices/api/set/cover', {'id': id, 'channel': channel, 'position': position});

  /// The id the cloud gives a device with [mac]: its MAC in small letters without colons.
  static String? idForMac(String? mac) {
    final hex = (mac ?? '').replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toLowerCase();
    return hex.length == 12 ? hex : null;
  }

  /// The MAC a status from the cloud reports (Gen1 at the top, Gen2 and later under `sys`).
  static String? macOf(Map status) =>
      idForMac(status['mac'] as String? ?? (status['sys'] as Map?)?['mac'] as String? ?? (status['getinfo'] as Map?)?['mac'] as String?);

  /// Whether [status] came from a Gen1 device, which reports relays and lights as lists.
  static bool isGen1(Map status) {
    final info = status['_dev_info'];
    if (info is Map && info['gen'] != null) return '${info['gen']}'.toUpperCase() == 'G1';
    return !status.keys.any((k) => '$k'.contains(':')) && status['sys'] == null;
  }
}
