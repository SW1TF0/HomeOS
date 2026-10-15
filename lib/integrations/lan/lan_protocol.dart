import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/device.dart';
import '../integration.dart';

/// Builds a [Device] that belongs to the network-devices connection.
typedef DeviceFactory = Device Function({
  required String externalId,
  required String name,
  required DeviceKind kind,
  Set<Capability>? capabilities,
  Map<String, dynamic>? props,
  DeviceState state,
});

/// What a protocol needs to reach the network. Tests swap ports and turn TLS off.
class LanContext {
  LanContext({
    required this.client,
    required this.make,
    this.portMap = const {},
    this.allowTls = true,
    this.timeout = const Duration(seconds: 3),
  });

  final http.Client client;
  final DeviceFactory make;

  /// Replaces standard ports (tests run fake devices on free local ports).
  final Map<int, int> portMap;

  /// Whether to use the encrypted variants of protocols (wss, TLS). Self-signed
  /// certificates are accepted, since every TV ships its own.
  final bool allowTls;
  final Duration timeout;

  int port(int standard) => portMap[standard] ?? standard;

  Uri url(String host, int port, String path, [String scheme = 'http']) =>
      Uri.parse('$scheme://$host:${this.port(port)}$path');

  Future<http.Response> get(Uri uri, {Map<String, String>? headers}) async {
    final res = await client.get(uri, headers: headers).timeout(timeout);
    return res;
  }

  Future<http.Response> post(Uri uri, String body, {Map<String, String>? headers}) async {
    final res = await client.post(uri, body: body, headers: headers).timeout(timeout);
    return res;
  }

  Future<dynamic> getJson(Uri uri) async {
    final res = await get(uri);
    if (res.statusCode >= 400) throw IntegrationException('${uri.host} answered HTTP ${res.statusCode}.');
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<Socket> connect(String host, int port, {bool tls = false}) {
    final p = this.port(port);
    if (tls && allowTls) {
      return SecureSocket.connect(host, p, timeout: timeout, onBadCertificate: (_) => true);
    }
    return Socket.connect(host, p, timeout: timeout);
  }

  Future<WebSocket> webSocket(Uri uri) {
    final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
    final fixed = uri.replace(port: port(uri.port));
    return WebSocket.connect(fixed.toString(), customClient: client).timeout(timeout);
  }

  /// Whether something listens on [port] of [host].
  Future<bool> tcpOpen(String host, int port, {Duration? within}) async {
    try {
      final s = await Socket.connect(host, this.port(port), timeout: within ?? const Duration(milliseconds: 1200));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// One way of talking to devices on the local network (a TV brand, a plug family...).
abstract class LanProtocol {
  const LanProtocol();

  String get id;

  /// Shown to the user, e.g. "Samsung TV".
  String get label;

  /// Returns the devices at [host] if they speak this protocol, otherwise null.
  /// [hints] carry what discovery already learned (name, maker, UPnP location...).
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints);

  Future<DeviceState?> read(LanContext ctx, Device device);

  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command);

  /// Runs once after the device is added (opens the pairing prompt on a TV).
  /// Returns a message for the user, or null.
  Future<String?> setUp(LanContext ctx, Device device) async => null;

  /// Extra settings shown on the device (a TV's pre-shared key...).
  List<SettingField> fields(Device device) => const [];

  Future<void> close() async {}
}

/// Thrown for remote keys a device cannot press.
IntegrationException unsupported(Device d, Object what) =>
    IntegrationException('${d.name} has no "$what" over the network.');

/// First text between `<tag>` and `</tag>`, namespace prefixes allowed.
String? xmlTag(String xml, String tag) {
  final m = RegExp('<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w-]+:)?$tag>').firstMatch(xml);
  return m == null ? null : xmlUnescape(m.group(1)!.trim());
}

String xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String xmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Sends a UPnP SOAP action and returns the response body.
Future<String> soap(LanContext ctx, Uri controlUrl, String serviceType, String action,
    {Map<String, String> args = const {}}) async {
  final body = '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$serviceType">'
      '${args.entries.map((e) => '<${e.key}>${xmlEscape(e.value)}</${e.key}>').join()}'
      '</u:$action></s:Body></s:Envelope>';
  final res = await ctx.post(controlUrl, body, headers: {
    'Content-Type': 'text/xml; charset="utf-8"',
    'SOAPACTION': '"$serviceType#$action"',
  });
  if (res.statusCode >= 400) {
    throw IntegrationException('${controlUrl.host} refused $action (HTTP ${res.statusCode}).');
  }
  return res.body;
}

/// Remote keys every TV protocol here understands, used to describe a device.
List<String> keyNames(Iterable<RemoteKey> keys) => keys.map((k) => k.name).toList();

/// TVs that do not answer are usually switched off, not broken.
const offTv = DeviceState(on: false);

/// Builds the standard device for a TV or streamer.
Device tvDevice(
  LanContext ctx, {
  required String protocol,
  required String host,
  required String name,
  required Iterable<RemoteKey> keys,
  bool power = true,
  bool volume = false,
  Map<String, dynamic> props = const {},
  DeviceState state = const DeviceState(),
}) =>
    ctx.make(
      externalId: '$protocol:$host',
      name: name,
      kind: DeviceKind.media,
      capabilities: {
        if (power) Capability.onOff,
        if (volume) Capability.volume,
        Capability.remote,
      },
      props: {'host': host, 'protocol': protocol, 'keys': keyNames(keys), ...props},
      state: state,
    );
