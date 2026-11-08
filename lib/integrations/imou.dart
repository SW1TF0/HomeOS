import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../models/device.dart';
import '../util/digest_auth.dart';
import 'integration.dart';
import 'matter/crypto.dart';

/// The Imou Open Platform's data centres, Europe first.
const imouEndpoints = {
  'eu': 'https://openapi-fk.easy4ip.com',
  'global': 'https://openapi.easy4ip.com',
  'sg': 'https://openapi-sg.easy4ip.com',
  'us': 'https://openapi-or.easy4ip.com',
};

/// Imou's cloud (open.imoulife.com), with the App ID and App Secret of a free developer account made with the same
/// login as the Imou Life app. Reaches the account's cameras from anywhere.
class ImouCloud {
  ImouCloud(this.client, {required this.appId, required this.secret, String region = ''})
      : _endpoint = _pick(region);

  final http.Client client;
  final String appId;
  final String secret;

  /// The data centre in use; found by trying each when none is set.
  String? get endpoint => _endpoint;
  String? _endpoint;

  /// Called when the data centre was found, so it is kept.
  void Function(String endpoint)? onEndpoint;

  static String? _pick(String region) {
    final r = region.trim().toLowerCase();
    if (r.isEmpty || r == 'auto') return null;
    if (r.startsWith('https://')) return r.replaceAll(RegExp(r'/+$'), '');
    if (r.contains('eu') || r.contains('fk')) return imouEndpoints['eu'];
    if (r.contains('us') || r.contains('america') || r.contains('or')) return imouEndpoints['us'];
    if (r.contains('sg') || r.contains('asia')) return imouEndpoints['sg'];
    return imouEndpoints['global'];
  }

  static const timeout = Duration(seconds: 12);

  String? _token;
  DateTime? _expires;
  Future<String>? _getting;

  /// Older accounts sign with MD5, the current documents with HMAC-SHA256; whichever Imou accepts is kept.
  bool _hmac = false;

  final _rand = Random.secure();

  /// The MD5 signature the Imou SDKs have used: of `time:…,nonce:…,appSecret:…`, in small hex.
  static String signMd5(int time, String nonce, String secret) => md5Hex('time:$time,nonce:$nonce,appSecret:$secret');

  /// The signature in Imou's current documents: Base64 of HMAC-SHA256 of the same text, keyed with the secret's
  /// SHA-256 in small hex.
  static String signHmac(int time, String nonce, String secret) => base64.encode(
      hmacSha256(utf8.encode(hexOf(sha256(utf8.encode(secret)))), utf8.encode('time:$time,nonce:$nonce,appSecret:$secret')));

  String _nonce() => List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<String> _accessToken() {
    final t = _token;
    if (t != null && _expires != null && clock.now().isBefore(_expires!)) return Future.value(t);
    return _getting ??= () async {
      try {
        final data = await _connect();
        final secs = (data['expireTime'] as num?)?.toInt() ?? 259200;
        _expires = clock.now().add(Duration(seconds: (secs - 600).clamp(60, 259200)));
        return _token = '${data['accessToken']}';
      } finally {
        _getting = null;
      }
    }();
  }

  /// Gets a token, trying each data centre when none is known.
  Future<Map<String, dynamic>> _connect() async {
    final known = _endpoint;
    if (known != null) return _post(known, 'accessToken', {});
    Object? first;
    for (final e in imouEndpoints.values) {
      try {
        final data = await _post(e, 'accessToken', {});
        _endpoint = e;
        onEndpoint?.call(e);
        return data;
      } on ImouError catch (err) {
        first ??= err;
      } catch (err) {
        first ??= err;
      }
    }
    throw first ?? IntegrationException('Imou did not answer.');
  }

  /// Calls [method] with [params] and the account's token. Returns the answer's data.
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> params) async {
    final token = await _accessToken();
    try {
      return await _post(_endpoint!, method, {...params, 'token': token});
    } on ImouError catch (e) {
      if (e.code != 'TK1002' && e.code != 'TK1003') rethrow;
      _token = null;
      return _post(_endpoint!, method, {...params, 'token': await _accessToken()});
    }
  }

  Future<Map<String, dynamic>> _post(String endpoint, String method, Map<String, dynamic> params, {bool again = true}) async {
    final time = clock.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = _nonce();
    final body = jsonEncode({
      'system': {
        'ver': '1.0',
        'sign': _hmac ? signHmac(time, nonce, secret) : signMd5(time, nonce, secret),
        'appId': appId,
        'time': time,
        'nonce': nonce,
      },
      'id': '${_rand.nextInt(1 << 30)}',
      'params': params,
    });
    final res = await client
        .post(Uri.parse('$endpoint/openapi/$method'), headers: {'Content-Type': 'application/json;charset=UTF-8'}, body: body)
        .timeout(timeout);
    if (res.statusCode >= 400) throw IntegrationException('Imou answered HTTP ${res.statusCode}.');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    final result = j is Map ? j['result'] as Map? : null;
    if (result == null) throw IntegrationException('Imou sent an answer the app does not understand.');
    final code = '${result['code']}';
    if (code == '0') return Map<String, dynamic>.from(result['data'] as Map? ?? const {});
    if (code == 'SN1001' && again) {
      _hmac = !_hmac;
      return _post(endpoint, method, params, again: false);
    }
    throw ImouError(code, '${result['msg'] ?? ''}');
  }

  /// Every camera and device on the account: deviceId, name, model, whether it is online.
  Future<List<Map<String, dynamic>>> devices() async {
    final out = <Map<String, dynamic>>[];
    final list = await call('deviceBaseList', {'bindId': -1, 'limit': 50, 'type': 'bindAndShare', 'needApInfo': false});
    final ids = [for (final d in (list['deviceList'] as List? ?? const [])) if (d is Map) '${d['deviceId']}'];
    for (var i = 0; i < ids.length; i += 10) {
      Map<String, dynamic> details = const {};
      try {
        details = await call('deviceBaseDetailList', {
          'deviceList': [for (final id in ids.sublist(i, min(i + 10, ids.length))) {'deviceId': id, 'channelList': '0'}],
        });
      } catch (_) {}
      final byId = {
        for (final d in (details['deviceList'] as List? ?? const []))
          if (d is Map) '${d['deviceId']}': Map<String, dynamic>.from(d),
      };
      for (final id in ids.sublist(i, min(i + 10, ids.length))) {
        out.add({'deviceId': id, ...?byId[id]});
      }
    }
    return out;
  }

  /// "1" online, "0" offline, "4" asleep (a battery camera).
  Future<String> online(String id) async => '${(await call('deviceOnline', {'deviceId': id}))['onLine']}';

  /// The address of a new picture from the camera. It takes a moment to be ready.
  Future<String> snapshotUrl(String id) async {
    final data = await call('setDeviceSnapEnhanced', {'deviceId': id, 'channelId': '0'});
    final url = data['url'] as String?;
    if (url == null || url.isEmpty) throw IntegrationException('Imou did not send a picture.');
    return url;
  }

  /// The camera's live video (HLS) addresses: HD and SD. Creates them the first time.
  Future<({String? hd, String? sd})> liveAddresses(String id) async {
    Future<List> streams() async {
      try {
        return (await call('getLiveStreamInfo', {'deviceId': id, 'channelId': '0'}))['streams'] as List? ?? const [];
      } on ImouError catch (e) {
        if (e.code == 'LV1002') return const [];
        rethrow;
      }
    }

    var list = await streams();
    if (list.isEmpty) {
      for (final stream in [0, 1]) {
        try {
          await call('bindDeviceLive', {'deviceId': id, 'channelId': '0', 'streamId': stream});
        } on ImouError catch (e) {
          if (e.code != 'LV1001') rethrow;
        }
      }
      list = await streams();
    }
    String? pick(int stream) {
      final mine = [for (final s in list) if (s is Map && '${s['streamId']}' == '$stream' && s['hls'] is String) '${s['hls']}'];
      return mine.where((u) => u.startsWith('https://')).firstOrNull ?? mine.firstOrNull;
    }

    return (hd: pick(0), sd: pick(1));
  }
}

/// An error code from Imou's cloud.
class ImouError extends IntegrationException {
  ImouError(this.code, String msg) : super(_explain(code, msg));
  final String code;

  static String _explain(String code, String msg) => switch (code) {
        'OP1008' || 'SN1001' => 'Imou did not accept the App ID and App Secret. Copy them again from '
            'open.imoulife.com > My App.',
        'OP1009' => 'Imou: no permission ($msg). The developer account must use the same login as the Imou Life app.',
        'DV1007' || 'DV1020' => 'the camera is offline',
        'OP1011' || 'OP1013' || 'OP1014' => 'Imou\'s free plan has run out of calls for now',
        _ => 'Imou: ${msg.isEmpty ? code : msg}',
      };
}

/// Imou (and Dahua consumer) cameras through Imou's cloud: online status, pictures and live video from anywhere.
class ImouDriver extends IntegrationDriver {
  ImouDriver(super.config, super.client);

  ImouCloud? _api;

  ImouCloud get api {
    final id = config.setting('app_id'), secret = config.setting('app_secret');
    if (id.isEmpty || secret.isEmpty) {
      throw IntegrationException('Enter the App ID and App Secret from open.imoulife.com > My App.');
    }
    final a = _api;
    if (a != null && a.appId == id && a.secret == secret) return a;
    return _api = ImouCloud(client, appId: id, secret: secret, region: config.setting('region'))
      ..onEndpoint = (e) {
        config.settings['region'] = e;
        onSettings?.call();
      };
  }

  @override
  bool reachesAnywhere(Device device) => true;

  /// When each camera was last asked whether it is online, and the answer. Imou's free plan counts calls.
  final Map<String, (DateTime, DeviceState)> _seen = {};
  static const poll = Duration(minutes: 1);

  /// How long Imou needs to put a new picture online.
  static Duration pictureDelay = const Duration(seconds: 2);

  @override
  Future<List<Device>> discover() async {
    final list = await api.devices();
    if (list.isEmpty) {
      throw IntegrationException('Imou lists no cameras. The developer account must use the same login as the Imou '
          'Life app the cameras are in.');
    }
    final out = <Device>[];
    for (final dev in list) {
      final id = '${dev['deviceId']}';
      final status = '${dev['status'] ?? dev['deviceStatus'] ?? ''}';
      final d = makeDevice(
        externalId: id,
        name: '${dev['name'] ?? dev['deviceName'] ?? 'Imou camera'}'.trim(),
        kind: DeviceKind.camera,
        capabilities: {Capability.snapshot},
        props: {
          'imouId': id,
          'cameraBrand': 'imou',
          'model': ?dev['deviceModel'] as String?,
        },
        state: status == 'offline' || status == '0' ? DeviceState.unreachable : const DeviceState(),
      );
      await _addLive(d);
      out.add(d);
    }
    return out;
  }

  /// Puts the camera's live video addresses on it. Imou's free plan may not include live video; then it shows pictures.
  Future<void> _addLive(Device d) async {
    try {
      final live = await api.liveAddresses('${d.props['imouId']}');
      if (live.hd != null) d.props['streamUrl'] = live.hd;
      if (live.sd != null) d.props['streamUrlLow'] = live.sd;
      if (live.hd == null && live.sd != null) d.props['streamUrl'] = live.sd;
    } catch (_) {}
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    final out = <String, DeviceState>{};
    for (final d in devices) {
      try {
        out[d.id] = d.state.merge(await refresh(d) ?? const DeviceState());
      } catch (_) {
        out[d.id] = d.state.merge(DeviceState.unreachable);
      }
    }
    return out;
  }

  @override
  Future<DeviceState?> refresh(Device device) async {
    final seen = _seen[device.id];
    if (seen != null && clock.now().difference(seen.$1) < poll) return seen.$2;
    final on = await api.online('${device.props['imouId']}');
    final s = on == '0' ? DeviceState.unreachable : const DeviceState();
    _seen[device.id] = (clock.now(), s);
    if (s.reachable && device.props['streamUrl'] == null) await _addLive(device);
    return s;
  }

  @override
  Future<Uint8List?> snapshot(Device device) async {
    final url = Uri.parse(await api.snapshotUrl('${device.props['imouId']}'));
    Object? error;
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future<void>.delayed(attempt == 0 ? pictureDelay : const Duration(milliseconds: 1500));
      try {
        return await getImage(url);
      } catch (e) {
        error = e;
      }
    }
    throw error ?? IntegrationException('${device.name} sent no picture.');
  }

  @override
  Future<DeviceState?> send(Device device, DeviceCommand command) =>
      throw IntegrationException('${device.name} is watched, not switched, through Imou.');
}
