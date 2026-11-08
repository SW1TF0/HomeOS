import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../util/digest_auth.dart';
import '../lan/lan_protocol.dart';
import '../lan/net.dart';

/// A camera that answered an ONVIF search.
class OnvifCamera {
  const OnvifCamera({required this.host, required this.deviceUrl, this.name});
  final String host;

  /// Its ONVIF device service, e.g. `http://192.168.1.30:2020/onvif/device_service`.
  final Uri deviceUrl;
  final String? name;
}

/// Looks for ONVIF cameras with WS-Discovery (what camera apps use). Most cameras sold since 2015 answer:
/// Tapo, Reolink, Hikvision, Dahua, Imou, Amcrest, Annke, Foscam and unbranded ones.
Future<List<OnvifCamera>> onvifProbe(
    {Duration timeout = const Duration(seconds: 3), InternetAddress? to, int port = 3702}) async {
  final found = <String, OnvifCamera>{};
  RawDatagramSocket socket;
  try {
    socket = to == null ? await lanUdpSocket() : await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  } catch (_) {
    return const [];
  }
  final sub = socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    final cam = parseProbeMatch(utf8.decode(d.data, allowMalformed: true), from: d.address.address);
    if (cam != null) found[cam.host] = cam;
  });
  final probe = utf8.encode('<?xml version="1.0" encoding="UTF-8"?>'
      '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
      'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
      'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
      '<e:Header><w:MessageID>uuid:${_uuid()}</w:MessageID>'
      '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
      '<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>'
      '<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>');
  for (var i = 0; i < 2; i++) {
    trySend(socket, probe, to ?? InternetAddress('239.255.255.250'), port);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  await Future<void>.delayed(timeout);
  await sub.cancel();
  socket.close();
  return found.values.toList();
}

/// Reads a WS-Discovery answer: where the camera's ONVIF service is and what it calls itself.
OnvifCamera? parseProbeMatch(String xml, {required String from}) {
  if (!xml.contains('ProbeMatch')) return null;
  final addrs = (xmlTag(xml, 'XAddrs') ?? '').split(RegExp(r'\s+')).map(Uri.tryParse).whereType<Uri>().toList();
  if (addrs.isEmpty) return null;
  // Some cameras list an IPv6 or old address too: prefer the one that answered.
  final url = addrs.where((u) => u.host == from).firstOrNull ??
      addrs.where((u) => InternetAddress.tryParse(u.host)?.type == InternetAddressType.IPv4).firstOrNull ??
      addrs.first;
  String? scope(String key) {
    final m = RegExp('onvif://www\\.onvif\\.org/$key/([^\\s<]+)').firstMatch(xml);
    if (m == null) return null;
    try {
      return Uri.decodeComponent(m.group(1)!).replaceAll('_', ' ').trim();
    } catch (_) {
      return m.group(1);
    }
  }

  final name = scope('name');
  final hardware = scope('hardware');
  final label = name == null
      ? hardware
      : hardware == null || name.toLowerCase().contains(hardware.toLowerCase())
          ? name
          : '$name $hardware';
  return OnvifCamera(host: from, deviceUrl: url, name: label);
}

String _uuid() {
  final b = randomBytes(16).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-${b.substring(16, 20)}-${b.substring(20)}';
}

class OnvifException implements Exception {
  const OnvifException(this.message, {this.login = false});
  final String message;

  /// The camera refused the user and password.
  final bool login;

  @override
  String toString() => message;
}

/// Video addresses an ONVIF camera gave.
class OnvifStreams {
  const OnvifStreams({this.name, this.main, this.sub, this.snapshot});
  final String? name;
  final Uri? main;
  final Uri? sub;
  final Uri? snapshot;
}

/// Asks an ONVIF camera for its video addresses. The login is sent as a WS-Security password digest, and as HTTP
/// Digest for cameras that want that instead.
class OnvifClient {
  OnvifClient(this.deviceUrl,
      {required this.user, required this.pass, required this.client, this.timeout = const Duration(seconds: 4)});

  final Uri deviceUrl;
  final String user;
  final String pass;
  final http.Client client;
  final Duration timeout;

  /// How far the camera's clock is from ours. A password digest from the wrong time is refused.
  Duration _skew = Duration.zero;

  static const _device = 'http://www.onvif.org/ver10/device/wsdl';
  static const _media = 'http://www.onvif.org/ver10/media/wsdl';

  Future<OnvifStreams> streams() async {
    try {
      final t = await _call(deviceUrl, '<tds:GetSystemDateAndTime xmlns:tds="$_device"/>', auth: false);
      final at = parseOnvifTime(t);
      if (at != null) _skew = at.difference(DateTime.now().toUtc());
    } catch (_) {}
    String? name;
    var media = deviceUrl;
    try {
      final info = await _call(deviceUrl, '<tds:GetDeviceInformation xmlns:tds="$_device"/>');
      final parts = [xmlTag(info, 'Manufacturer'), xmlTag(info, 'Model')].whereType<String>().where((s) => s.isNotEmpty);
      if (parts.isNotEmpty) name = parts.toSet().join(' ');
    } on OnvifException catch (e) {
      if (e.login) rethrow;
    }
    try {
      final caps = await _call(
          deviceUrl, '<tds:GetCapabilities xmlns:tds="$_device"><tds:Category>Media</tds:Category></tds:GetCapabilities>');
      final block = xmlTag(caps, 'Media');
      final x = block == null ? null : Uri.tryParse(xmlTag(block, 'XAddr') ?? '');
      if (x != null && x.host.isNotEmpty) media = x.replace(host: deviceUrl.host);
    } on OnvifException catch (e) {
      if (e.login) rethrow;
    }
    final profiles = await _call(media, '<trt:GetProfiles xmlns:trt="$_media"/>');
    final tokens = [
      for (final m in RegExp(r'<(?:[\w-]+:)?Profiles\b[^>]*\btoken="([^"]+)"').allMatches(profiles)) m.group(1)!,
    ];
    if (tokens.isEmpty) throw const OnvifException('The camera has no video profiles.');
    Future<Uri?> uri(String action, String token, [String setup = '']) async {
      try {
        final r = await _call(media,
            '<trt:$action xmlns:trt="$_media" xmlns:tt="http://www.onvif.org/ver10/schema">$setup<trt:ProfileToken>$token</trt:ProfileToken></trt:$action>');
        return Uri.tryParse(xmlTag(r, 'Uri') ?? '');
      } on OnvifException catch (e) {
        if (e.login) rethrow;
        return null;
      }
    }

    const rtsp = '<trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>'
        '<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>';
    final main = await uri('GetStreamUri', tokens.first, rtsp);
    final sub = tokens.length > 1 ? await uri('GetStreamUri', tokens[1], rtsp) : null;
    final snapshot = await uri('GetSnapshotUri', tokens.first);
    return OnvifStreams(name: name, main: main, sub: sub == main ? null : sub, snapshot: snapshot);
  }

  Future<String> _call(Uri url, String body, {bool auth = true}) async {
    final envelope = '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
        '${auth && user.isNotEmpty ? '<s:Header>${_security()}</s:Header>' : ''}<s:Body>$body</s:Body></s:Envelope>';
    const type = {'Content-Type': 'application/soap+xml; charset=utf-8'};
    var res = await client.post(url, headers: type, body: envelope).timeout(timeout);
    if (res.statusCode == 401 && auth && user.isNotEmpty) {
      final challenge = AuthChallenge.pick([res.headers['www-authenticate'] ?? '']);
      final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
      res = await client
          .post(url,
              headers: {...type, 'Authorization': authorization(challenge, user, pass, 'POST', path.isEmpty ? '/' : path)},
              body: envelope)
          .timeout(timeout);
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode == 401 || res.statusCode == 403 || text.contains('NotAuthorized') || text.contains('FailedAuthentication')) {
      throw const OnvifException('The camera refused the user and password.', login: true);
    }
    if (res.statusCode >= 400 || !text.contains('Envelope')) {
      throw OnvifException('The camera answered HTTP ${res.statusCode}.');
    }
    return text;
  }

  String _security() {
    final nonce = randomBytes(16);
    final created = '${DateTime.now().toUtc().add(_skew).toIso8601String().split('.').first}Z';
    final digest = base64.encode(sha1Bytes([...nonce, ...utf8.encode(created), ...utf8.encode(pass)]));
    return '<Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
        '<UsernameToken><Username>${xmlEscape(user)}</Username>'
        '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
        '$digest</Password>'
        '<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">'
        '${base64.encode(nonce)}</Nonce>'
        '<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">$created</Created>'
        '</UsernameToken></Security>';
  }
}

/// The camera's clock, from a GetSystemDateAndTime answer.
DateTime? parseOnvifTime(String xml) {
  final utc = xmlTag(xml, 'UTCDateTime');
  if (utc == null) return null;
  int? n(String tag) => int.tryParse(xmlTag(utc, tag) ?? '');
  final (y, mo, d, h, mi, s) = (n('Year'), n('Month'), n('Day'), n('Hour'), n('Minute'), n('Second'));
  if (y == null || mo == null || d == null || h == null || mi == null) return null;
  return DateTime.utc(y, mo, d, h, mi, s ?? 0);
}
