import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/device.dart';
import 'mac_vendor.dart';
import 'mdns.dart';
import 'net.dart';
import 'sweep.dart';
import 'wol.dart';

/// What the router (or this computer) knows about an address on the network.
class Neighbor {
  const Neighbor({this.mac, this.name});
  final String? mac;

  /// The name the device gave itself when it asked for its address, or one set on the router.
  final String? name;

  Neighbor merge(Neighbor other) => Neighbor(mac: mac ?? other.mac, name: name ?? other.name);
}

/// Everything found out about one address.
class WhoIs {
  const WhoIs({required this.host, this.name, this.mac, this.vendor, this.guess});
  final String host;

  /// The device's own name (from the router, DNS, Bonjour, Windows or its web page).
  final String? name;
  final String? mac;

  /// Who made it, from its MAC address.
  final String? vendor;
  final DeviceGuess? guess;

  /// What to call it in a list: its name, else what it probably is, else its maker.
  String? get label => name ?? guess?.what ?? (vendor == null ? null : '$vendor device');

  /// What it probably is, for under its name.
  String? get what => guess?.what;

  /// For the Network devices connection.
  Map<String, String> get hints => {
        'name': ?label,
        if (name == null && label != null) 'guessed': '1',
        'mac': ?mac,
        'vendor': ?vendor,
        'what': ?what,
        if (guess != null && guess!.kind != DeviceKind.other) 'kind': guess!.kind.name,
      };
}

/// Names that say nothing: a device that sent none, or the chip's default.
String? usefulName(String? raw) {
  final n = raw?.trim().replaceFirst(RegExp(r'\.(local|lan|home|localdomain|home\.arpa|fritz\.box|domain)\.?$', caseSensitive: false), '');
  if (n == null || n.isEmpty || n == '*' || RegExp(r'^[\d.]+$').hasMatch(n)) return null;
  final low = n.toLowerCase();
  if (const {'localhost', 'unknown', 'none', 'android', 'espressif', 'esp32', 'esp8266', 'lwip0', 'default'}.contains(low)) return null;
  // "android-1a2b3c4d5e6f", "ESP_3A2B1C", "ESP-3A2B1C": made up from the MAC.
  if (RegExp(r'^(android|esp|wlan|dhcp|host|client)[-_][0-9a-f]{6,}$', caseSensitive: false).hasMatch(n)) return null;
  return n;
}

/// Finds out what is at [host]: its name from the router ([known]), DNS, Bonjour,
/// Windows file sharing (NetBIOS) or its web page, and its maker from its MAC.
/// [open] are the ports it listens on, when the caller knocked already.
Future<WhoIs> whoIs(
  String host, {
  Set<int>? open,
  Neighbor? known,
  Map<int, int> portMap = const {},
  Future<Map<String, String>> Function()? arp,
  Duration within = const Duration(milliseconds: 1500),
}) async {
  if (open == null) {
    SweepHit? hit;
    await sweepHosts([host], (h) => hit = h, portMap: portMap, parallelHosts: 1);
    open = hit?.openPorts ?? const {};
  }
  final ports = open;
  int port(int p) => portMap[p] ?? p;
  final web = ports.contains(80)
      ? Uri.parse('http://$host:${port(80)}/')
      : ports.contains(8080)
          ? Uri.parse('http://$host:${port(8080)}/')
          : ports.contains(443)
              ? Uri.parse('https://$host:${port(443)}/')
              : null;
  final results = await Future.wait<Object?>([
    reverseName(host),
    mdnsHostName(host, port: port(5353), within: within),
    netbiosStatus(host, port: port(137), within: within),
    if (web != null) webTitle(web, within: within * 2) else Future.value(),
    (arp ?? arpTable)().then((t) => t[host], onError: (_) => null),
  ]);
  final nb = results[2] as NetbiosInfo?;
  final mac = normalizeMac(known?.mac) ?? normalizeMac(results[4] as String?) ?? normalizeMac(nb?.mac);
  final vendor = (await MacVendors.load())?.vendorOf(mac);
  final name = usefulName(known?.name) ??
      usefulName(results[0] as String?) ??
      usefulName(results[1] as String?) ??
      usefulName(nb?.name) ??
      results[3] as String?;
  final androidName = RegExp(r'^android[-_]', caseSensitive: false).hasMatch(known?.name ?? '');
  return WhoIs(
    host: host,
    name: name,
    mac: mac,
    vendor: vendor,
    guess: androidName ? const DeviceGuess('Android phone') : guessDevice(vendor: vendor, mac: mac, ports: ports),
  );
}

// ---------------------------------------------------------------------------
// This computer's list of who has which address.

Map<String, String>? _arp;
DateTime _arpAt = DateTime(0);
Future<Map<String, String>>? _arpReading;
bool _noArp = false;

/// Addresses and MACs this device talked to lately (the ARP table). Android
/// keeps it to itself since version 10, so there it is usually empty and the
/// router's list ([Neighbor]) has to do.
Future<Map<String, String>> arpTable() {
  if (_noArp) return Future.value(const {});
  if (_arp != null && DateTime.now().difference(_arpAt) < const Duration(seconds: 2)) return Future.value(_arp);
  return _arpReading ??= _readArp().then((t) {
    _arp = t;
    _arpAt = DateTime.now();
    _arpReading = null;
    return t;
  });
}

Future<Map<String, String>> _readArp() async {
  try {
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        final t = parseArpTable(await File('/proc/net/arp').readAsString());
        if (t.isNotEmpty || !Platform.isAndroid) return t;
      } on FileSystemException {
        // Android 10 and later.
      }
      final r = await Process.run('ip', ['neigh', 'show']).timeout(const Duration(seconds: 2));
      final t = parseArpTable('${r.stdout}');
      if (t.isEmpty) _noArp = true;
      return t;
    }
    if (Platform.isMacOS || Platform.isWindows) {
      final r = await Process.run('arp', [if (Platform.isMacOS) '-an' else '-a']).timeout(const Duration(seconds: 3));
      return parseArpTable('${r.stdout}');
    }
  } catch (_) {
    _noArp = true;
  }
  return const {};
}

/// Reads `/proc/net/arp`, `ip neigh`, macOS `arp -an` and Windows `arp -a`.
Map<String, String> parseArpTable(String text) {
  final out = <String, String>{};
  final ip = RegExp(r'(\d{1,3}(?:\.\d{1,3}){3})');
  final mac = RegExp(r'(?<![0-9a-fA-F:-])([0-9a-fA-F]{1,2}(?:[:-][0-9a-fA-F]{1,2}){5})(?![0-9a-fA-F:-])');
  for (final line in const LineSplitter().convert(text)) {
    final a = ip.firstMatch(line)?.group(1);
    final m = mac.firstMatch(line)?.group(1);
    if (a == null || m == null) continue;
    // macOS writes 0:1:2:a:b:c without the leading zeros.
    final full = normalizeMac(m.split(RegExp('[:-]')).map((p) => p.padLeft(2, '0')).join(':'));
    if (full != null && full != 'ff:ff:ff:ff:ff:ff' && !full.startsWith('01:00:5e')) out[a] = full;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Bonjour: phones, Macs, Linux and many gadgets answer to their own name.

/// Asks [host] itself for its Bonjour name (a reverse lookup sent straight to
/// its mDNS port), e.g. `Krasimirs-iPhone.local`.
Future<String?> mdnsHostName(String host, {int port = 5353, Duration within = const Duration(milliseconds: 1500)}) async {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return null;
  final reverse = '${host.split('.').reversed.join('.')}.in-addr.arpa';
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final done = Completer<String?>();
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket!.receive();
      if (d == null) return;
      for (final r in decodeDnsRecords(d.data)) {
        if (r.type == DnsRecord.ptr && r.name.toLowerCase() == reverse && !done.isCompleted) done.complete(r.data as String);
      }
    });
    final query = encodeMdnsQuery([reverse]);
    trySend(socket, query, ip, port);
    Future<void>.delayed(within ~/ 3, () => trySend(socket!, query, ip, port));
    return await done.future.timeout(within, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    socket?.close();
  }
}

// ---------------------------------------------------------------------------
// NetBIOS: Windows computers, NAS boxes and Samba say their name and MAC.

class NetbiosInfo {
  const NetbiosInfo(this.name, this.mac);
  final String? name;
  final String? mac;
}

/// A NetBIOS "node status" question for every name ("*").
Uint8List netbiosQuery([int id = 0x4b4a]) {
  final name = [0x2a, for (var i = 0; i < 15; i++) 0];
  return Uint8List.fromList([
    id >> 8, id & 0xff, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, //
    0x20,
    for (final b in name) ...[0x41 + (b >> 4), 0x41 + (b & 0x0f)],
    0, 0, 0x21, 0, 1,
  ]);
}

/// Reads the answer to [netbiosQuery]: the computer's name and its MAC.
NetbiosInfo? parseNetbiosStatus(Uint8List p) {
  try {
    var i = 12;
    i = p[i] & 0xc0 == 0xc0 ? i + 2 : i + 1 + p[i] + 1;
    i += 10; // type, class, ttl, length
    final count = p[i++];
    String? name;
    for (var n = 0; n < count; n++, i += 18) {
      final suffix = p[i + 15];
      final group = p[i + 16] & 0x80 != 0;
      if (name == null && suffix == 0 && !group) {
        name = latin1.decode(p.sublist(i, i + 15)).replaceAll('\u0000', '').trim();
      }
    }
    final mac = i + 6 <= p.length ? normalizeMac(p.sublist(i, i + 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')) : null;
    return name == null && mac == null ? null : NetbiosInfo(name, mac);
  } catch (_) {
    return null;
  }
}

Future<NetbiosInfo?> netbiosStatus(String host, {int port = 137, Duration within = const Duration(milliseconds: 1500)}) async {
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return null;
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final done = Completer<NetbiosInfo?>();
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket!.receive();
      if (d == null || done.isCompleted) return;
      final info = parseNetbiosStatus(d.data);
      if (info != null) done.complete(info);
    });
    trySend(socket, netbiosQuery(), ip, port);
    return await done.future.timeout(within, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    socket?.close();
  }
}

// ---------------------------------------------------------------------------
// The device's own web page often says what it is.

final _generic = RegExp(
    r'^(index of\b.*|log ?in|sign ?in|user login|web ?server|web ?ui|web client|document|untitled|home|home page|'
    r'welcome|loading\.*|please wait\.*|redirect(ing)?\.*|error|\d{3}( .*)?|not found|it works!?|default page|'
    r'test page|welcome to nginx!?|iis windows server|apache2 .*default page.*|management|login page|web)$',
    caseSensitive: false);

/// Tidies a page title: "Login - Synology DiskStation" becomes "Synology DiskStation". Null when it says nothing.
String? cleanTitle(String? raw) {
  if (raw == null) return null;
  var t = raw
      .replaceAll(RegExp(r'&amp;', caseSensitive: false), '&')
      .replaceAll(RegExp(r'&lt;', caseSensitive: false), '<')
      .replaceAll(RegExp(r'&gt;', caseSensitive: false), '>')
      .replaceAll(RegExp(r'&quot;', caseSensitive: false), '"')
      .replaceAll(RegExp(r'&#0*39;|&apos;', caseSensitive: false), "'")
      .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (_generic.hasMatch(t)) return null;
  t = t.replaceFirst(RegExp(r'^(log ?in|sign ?in|welcome( to)?)\s*[-|:–]?\s*', caseSensitive: false), '');
  t = t.replaceFirst(RegExp(r'\s*[-|:–]\s*(log ?in|sign ?in|login page|web ?ui|home)$', caseSensitive: false), '');
  t = t.trim();
  if (t.isEmpty || _generic.hasMatch(t)) return null;
  return t.length > 40 ? '${t.substring(0, 39).trimRight()}…' : t;
}

/// The title of the page at [uri], or the name a login box asks for.
Future<String?> webTitle(Uri uri, {Duration within = const Duration(seconds: 3)}) async {
  final client = HttpClient()
    ..connectionTimeout = within
    ..badCertificateCallback = (_, _, _) => true;
  try {
    final req = await client.getUrl(uri).timeout(within);
    req.headers.set(HttpHeaders.userAgentHeader, 'SmartHomeKJ');
    final res = await req.close().timeout(within);
    final realm = RegExp(r'realm="([^"]*)"').firstMatch(res.headers.value(HttpHeaders.wwwAuthenticateHeader) ?? '')?.group(1);
    final bytes = <int>[];
    await for (final chunk in res.timeout(within)) {
      bytes.addAll(chunk);
      if (bytes.length > 48 * 1024) break;
    }
    final html = utf8.decode(bytes, allowMalformed: true);
    final title = RegExp(r'<title[^>]*>([^<]*)</title', caseSensitive: false).firstMatch(html)?.group(1);
    return cleanTitle(title) ?? cleanTitle(realm);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
