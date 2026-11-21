import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'onboarding.dart';
import 'session.dart';

/// Finding Matter devices with mDNS / DNS-SD (Core spec 4.3): devices in
/// pairing mode advertise `_matterc._udp`, devices on a fabric advertise
/// `<compressed fabric id>-<node id>._matter._tcp`.

/// A DNS resource record, the parts mDNS needs.
class DnsRecord {
  DnsRecord(this.name, this.type, this.ttl, this.data);
  final String name;
  final int type;
  final int ttl;

  /// PTR: the target name. SRV: (priority, weight, port, target). TXT: list of
  /// strings. A / AAAA: an [InternetAddress]. Other types: the raw bytes.
  final Object data;

  @override
  String toString() => '$name ${DnsType.name(type)} $data';
}

class DnsType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const aaaa = 28;
  static const srv = 33;
  static const any = 255;

  static String name(int t) =>
      const {1: 'A', 12: 'PTR', 16: 'TXT', 28: 'AAAA', 33: 'SRV', 47: 'NSEC', 255: 'ANY'}[t] ?? 'TYPE$t';
}

/// Builds an mDNS query. [unicastResponse] sets the QU bit.
Uint8List encodeDnsQuery(List<(String, int)> questions, {bool unicastResponse = false}) {
  final b = BytesBuilder();
  b.add([0, 0, 0, 0, 0, questions.length, 0, 0, 0, 0, 0, 0]);
  for (final (name, type) in questions) {
    _writeName(b, name);
    b.add([type >> 8, type & 0xff, unicastResponse ? 0x80 : 0x00, 0x01]);
  }
  return b.toBytes();
}

void _writeName(BytesBuilder b, String name) {
  for (final label in name.split('.')) {
    if (label.isEmpty) continue;
    final bytes = utf8.encode(label);
    b.addByte(bytes.length);
    b.add(bytes);
  }
  b.addByte(0);
}

/// The answers of an mDNS response (answer, authority and additional sections),
/// or null if [d] is not a response.
/// Link-local IPv6 addresses get [zone] (the interface name) so they can be used.
List<DnsRecord>? decodeDnsResponse(Uint8List d, {String? zone}) {
  try {
    if (d.length < 12 || d[2] & 0x80 == 0) return null;
    final qd = (d[4] << 8) | d[5];
    final rr = ((d[6] << 8) | d[7]) + ((d[8] << 8) | d[9]) + ((d[10] << 8) | d[11]);
    var at = 12;
    for (var i = 0; i < qd; i++) {
      at = _readName(d, at).$2 + 4;
    }
    final out = <DnsRecord>[];
    for (var i = 0; i < rr; i++) {
      final (name, next) = _readName(d, at);
      at = next;
      final type = (d[at] << 8) | d[at + 1];
      final ttl = (d[at + 4] << 24) | (d[at + 5] << 16) | (d[at + 6] << 8) | d[at + 7];
      final len = (d[at + 8] << 8) | d[at + 9];
      at += 10;
      if (at + len > d.length) break;
      final rdata = Uint8List.sublistView(d, at, at + len);
      final Object data = switch (type) {
        DnsType.ptr => _readName(d, at).$1,
        DnsType.srv => (
            priority: (rdata[0] << 8) | rdata[1],
            weight: (rdata[2] << 8) | rdata[3],
            port: (rdata[4] << 8) | rdata[5],
            target: _readName(d, at + 6).$1,
          ),
        DnsType.txt => _readTxt(rdata),
        DnsType.a when len == 4 => InternetAddress.fromRawAddress(Uint8List.fromList(rdata)),
        DnsType.aaaa when len == 16 => _withZone(InternetAddress.fromRawAddress(Uint8List.fromList(rdata)), zone),
        _ => Uint8List.fromList(rdata),
      };
      out.add(DnsRecord(name, type, ttl, data));
      at += len;
    }
    return out;
  } on RangeError {
    return null;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

InternetAddress _withZone(InternetAddress a, String? zone) {
  if (!a.isLinkLocal || zone == null) return a;
  return InternetAddress.tryParse('${a.address}%$zone') ?? a;
}

(String, int) _readName(Uint8List d, int at) {
  final labels = <String>[];
  var pos = at;
  int? end;
  for (var jumps = 0; jumps < 64; jumps++) {
    final len = d[pos];
    if (len == 0) {
      return (labels.join('.'), end ?? pos + 1);
    }
    if (len & 0xc0 == 0xc0) {
      end ??= pos + 2;
      pos = ((len & 0x3f) << 8) | d[pos + 1];
      continue;
    }
    labels.add(utf8.decode(d.sublist(pos + 1, pos + 1 + len), allowMalformed: true));
    pos += 1 + len;
  }
  throw const FormatException('DNS name loops');
}

List<String> _readTxt(Uint8List d) {
  final out = <String>[];
  var at = 0;
  while (at < d.length) {
    final len = d[at];
    if (at + 1 + len > d.length) break;
    if (len > 0) out.add(utf8.decode(d.sublist(at + 1, at + 1 + len), allowMalformed: true));
    at += 1 + len;
  }
  return out;
}

/// What a DNS-SD service instance advertises.
class MdnsService {
  MdnsService(this.instance);

  /// Full instance name, for example `ABCD-1234._matter._tcp.local`.
  final String instance;
  String? host;
  int? port;
  final txt = <String, String>{};
  final addresses = <InternetAddress>[];

  bool get complete => host != null && port != null && addresses.isNotEmpty;

  /// Addresses in the order to try: IPv4, then routable IPv6, then link-local.
  List<InternetAddress> get sortedAddresses => sortAddresses(addresses);
}

/// Sorts addresses the way they should be tried.
List<InternetAddress> sortAddresses(Iterable<InternetAddress> addresses) {
  int rank(InternetAddress a) {
    if (a.type == InternetAddressType.IPv4) return a.isLinkLocal ? 1 : 0;
    if (a.isLinkLocal) return 3;
    return 2;
  }

  final list = addresses.toSet().toList();
  list.sort((a, b) => rank(a).compareTo(rank(b)));
  return list;
}

/// A device that is in pairing mode.
class CommissionableDevice {
  CommissionableDevice(this.service);
  final MdnsService service;

  int? get discriminator => int.tryParse(service.txt['D'] ?? '');
  int? get vendorId => int.tryParse((service.txt['VP'] ?? '').split('+').first);
  int? get productId {
    final vp = (service.txt['VP'] ?? '').split('+');
    return vp.length > 1 ? int.tryParse(vp[1]) : null;
  }

  /// Commissioning mode: 1 pairing window opened by the device, 2 by another app.
  int? get commissioningMode => int.tryParse(service.txt['CM'] ?? '');
  int? get deviceType => int.tryParse(service.txt['DT'] ?? '');
  String? get name => service.txt['DN'];
  MrpParams get mrp => MrpParams.fromTxt(service.txt);
  List<InternetAddress> get addresses => service.sortedAddresses;
  int get port => service.port ?? 5540;

  @override
  String toString() => 'CommissionableDevice(${name ?? service.instance}, D=$discriminator, $addresses:$port)';
}

/// The interfaces that lead to the home network, best first: Wi-Fi and
/// Ethernet, then the rest. Mobile data, VPNs and containers are left out
/// (unless nothing else is there).
List<NetworkInterface> homeInterfaces(List<NetworkInterface> all) {
  int score(String name) {
    final n = name.toLowerCase();
    if (n.startsWith('wlan') || n.startsWith('wl') || n.startsWith('en') || n.startsWith('eth') || n.contains('wi-fi')) {
      return 0;
    }
    if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('tun') || n.startsWith('ppp') ||
        n.startsWith('utun') || n.startsWith('docker') || n.startsWith('veth') || n.startsWith('br-') ||
        n.startsWith('dummy') || n.startsWith('p2p') || n == 'lo') {
      return 9;
    }
    return 5;
  }

  final home = all.where((i) => score(i.name) < 9).toList()..sort((a, b) => score(a.name).compareTo(score(b.name)));
  return home.isEmpty ? all : home;
}

/// mDNS queries over the local network.
class MatterDiscovery {
  /// [interface] pins queries to one network interface (the Wi-Fi one on a
  /// phone; tests pass the loopback interface). By default every interface
  /// that has an address is used.
  MatterDiscovery({this.interface});

  final NetworkInterface? interface;

  static final _group4 = InternetAddress('224.0.0.251');
  static final _group6 = InternetAddress('ff02::fb');

  /// Devices in pairing mode. With [code], only those whose discriminator matches.
  Future<List<CommissionableDevice>> commissionable({
    SetupCode? code,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final service = code == null
        ? '_matterc._udp.local'
        : code.isShort
            ? '_S${code.shortDiscriminator}._sub._matterc._udp.local'
            : '_L${code.discriminator}._sub._matterc._udp.local';
    final found = await _browse(service, '._matterc._udp.local', timeout,
        accept: (s) {
      if (code == null) return true;
      final d = CommissionableDevice(s).discriminator;
      return d != null && code.matches(d);
    });
    return [for (final s in found) CommissionableDevice(s)];
  }

  /// Looks up the current address of an operational node by its instance name
  /// (see `MatterFabric.instanceName`). Returns null when nothing answers.
  Future<MdnsService?> resolveOperational(String instanceName, {Duration timeout = const Duration(seconds: 5)}) async {
    final full = '$instanceName._matter._tcp.local';
    final found = await _resolve([full], timeout);
    return found.isEmpty ? null : found.first;
  }

  Future<List<MdnsService>> _browse(String query, String suffix, Duration timeout,
      {required bool Function(MdnsService) accept}) async {
    final q = await _MdnsSocket.open(interface);
    if (q.isEmpty) return const [];
    final services = <String, MdnsService>{};
    final hosts = <String, Set<InternetAddress>>{};
    final done = Completer<void>();
    var quietUntilDone = false;
    void absorb(List<DnsRecord> records) {
      _merge(records, services, hosts, (n) => n.toLowerCase().endsWith(suffix.toLowerCase()));
      final ready = services.values.where((s) => s.complete && accept(s)).toList();
      if (ready.isNotEmpty && !quietUntilDone) {
        quietUntilDone = true;
        // Give other devices a moment to answer too, then stop.
        Timer(const Duration(milliseconds: 600), () {
          if (!done.isCompleted) done.complete();
        });
      }
    }

    q.onRecords = absorb;
    try {
      final deadline = DateTime.now().add(timeout);
      var wait = const Duration(milliseconds: 250);
      while (!done.isCompleted && DateTime.now().isBefore(deadline)) {
        final questions = <(String, int)>[(query, DnsType.ptr)];
        for (final s in services.values) {
          if (s.host == null || s.port == null) questions.add((s.instance, DnsType.srv));
          if (s.txt.isEmpty) questions.add((s.instance, DnsType.txt));
          if (s.host != null && s.addresses.isEmpty) {
            questions.add((s.host!, DnsType.a));
            if (q.hasIpv6) questions.add((s.host!, DnsType.aaaa));
          }
        }
        q.send(questions);
        final left = deadline.difference(DateTime.now());
        await Future.any([done.future, Future<void>.delayed(left < wait ? left : wait)]);
        if (wait < const Duration(seconds: 2)) wait *= 2;
      }
    } finally {
      q.close();
    }
    return services.values.where((s) => s.complete && accept(s)).toList();
  }

  Future<List<MdnsService>> _resolve(List<String> instances, Duration timeout) async {
    final q = await _MdnsSocket.open(interface);
    if (q.isEmpty) return const [];
    final services = <String, MdnsService>{for (final i in instances) i.toLowerCase(): MdnsService(i)};
    final hosts = <String, Set<InternetAddress>>{};
    final done = Completer<void>();
    q.onRecords = (records) {
      _merge(records, services, hosts, (n) => services.containsKey(n.toLowerCase()));
      if (services.values.every((s) => s.complete) && !done.isCompleted) done.complete();
    };
    try {
      final deadline = DateTime.now().add(timeout);
      var wait = const Duration(milliseconds: 250);
      while (!done.isCompleted && DateTime.now().isBefore(deadline)) {
        final questions = <(String, int)>[];
        for (final s in services.values) {
          if (s.host == null || s.port == null) questions.add((s.instance, DnsType.srv));
          if (s.host != null && s.addresses.isEmpty) {
            questions.add((s.host!, DnsType.a));
            if (q.hasIpv6) questions.add((s.host!, DnsType.aaaa));
          }
        }
        q.send(questions);
        final left = deadline.difference(DateTime.now());
        await Future.any([done.future, Future<void>.delayed(left < wait ? left : wait)]);
        if (wait < const Duration(seconds: 2)) wait *= 2;
      }
    } finally {
      q.close();
    }
    return services.values.where((s) => s.complete).toList();
  }

  static void _merge(List<DnsRecord> records, Map<String, MdnsService> services, Map<String, Set<InternetAddress>> hosts,
      bool Function(String instance) wanted) {
    for (final r in records) {
      if (r.type == DnsType.ptr && r.ttl > 0) {
        final target = r.data as String;
        if (wanted(target)) services.putIfAbsent(target.toLowerCase(), () => MdnsService(target));
      }
    }
    for (final r in records) {
      final key = r.name.toLowerCase();
      switch (r.type) {
        case DnsType.srv:
          if (!wanted(r.name)) continue;
          final s = services.putIfAbsent(key, () => MdnsService(r.name));
          final srv = r.data as ({int priority, int weight, int port, String target});
          s.host = srv.target;
          s.port = srv.port;
        case DnsType.txt:
          if (!wanted(r.name)) continue;
          final s = services.putIfAbsent(key, () => MdnsService(r.name));
          for (final entry in r.data as List<String>) {
            final eq = entry.indexOf('=');
            if (eq > 0) s.txt[entry.substring(0, eq)] = entry.substring(eq + 1);
          }
        case DnsType.a || DnsType.aaaa:
          hosts.putIfAbsent(key, () => {}).add(r.data as InternetAddress);
      }
    }
    for (final s in services.values) {
      final h = s.host?.toLowerCase();
      if (h == null) continue;
      for (final a in hosts[h] ?? const <InternetAddress>{}) {
        if (!s.addresses.contains(a)) s.addresses.add(a);
      }
    }
  }
}

/// The sockets of one mDNS query: bound to port 5353 (shared with any other
/// mDNS software) and joined to the mDNS groups, so multicast answers arrive.
/// When 5353 cannot be shared, a socket on a random port asks "legacy"
/// questions, which responders answer directly.
class _MdnsSocket {
  _MdnsSocket._(this._sockets, this.zone);

  final List<(RawDatagramSocket, bool)> _sockets; // socket, is IPv6

  /// The interface link-local IPv6 answers belong to, when there is only one.
  final String? zone;
  void Function(List<DnsRecord> records)? onRecords;

  bool get hasIpv6 => _sockets.any((s) => s.$2);

  bool get isEmpty => _sockets.isEmpty;

  static Future<_MdnsSocket> open(NetworkInterface? pinned) async {
    final interfaces = pinned != null
        ? [pinned]
        : homeInterfaces((await NetworkInterface.list(includeLinkLocal: true, type: InternetAddressType.any))
            .where((i) => i.addresses.isNotEmpty)
            .toList());
    // Multicast leaves through the home network, not mobile data.
    final out = pinned ?? interfaces.firstOrNull;
    final sockets = <(RawDatagramSocket, bool)>[];
    for (final v6 in [false, true]) {
      final hasFamily = interfaces.any((i) => i.addresses.any((a) => (a.type == InternetAddressType.IPv6) == v6));
      if (!hasFamily) continue;
      final s = await _bind(v6);
      if (s == null) continue;
      for (final i in interfaces) {
        if (!i.addresses.any((a) => (a.type == InternetAddressType.IPv6) == v6)) continue;
        try {
          s.joinMulticast(v6 ? MatterDiscovery._group6 : MatterDiscovery._group4, i);
        } catch (_) {}
      }
      if (out != null) {
        try {
          if (v6) {
            s.setRawOption(
                RawSocketOption.fromInt(RawSocketOption.levelIPv6, RawSocketOption.IPv6MulticastInterface, out.index));
          } else if (out.addresses.where((a) => a.type == InternetAddressType.IPv4).firstOrNull case final a?) {
            s.setRawOption(RawSocketOption(
                RawSocketOption.levelIPv4, RawSocketOption.IPv4MulticastInterface, Uint8List.fromList(a.rawAddress)));
          }
        } catch (_) {}
      }
      s.multicastLoopback = true;
      sockets.add((s, v6));
    }
    final v6Interfaces = interfaces.where((i) => i.addresses.any((a) => a.type == InternetAddressType.IPv6)).toList();
    final m = _MdnsSocket._(sockets, v6Interfaces.length == 1 ? v6Interfaces.single.name : out?.name);
    for (final (s, _) in sockets) {
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        for (var d = s.receive(); d != null; d = s.receive()) {
          final records = decodeDnsResponse(d.data, zone: m.zone);
          if (records != null && records.isNotEmpty) m.onRecords?.call(records);
        }
      });
    }
    return m;
  }

  static Future<RawDatagramSocket?> _bind(bool v6) async {
    final any = v6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4;
    for (final reusePort in [true, false]) {
      try {
        return await RawDatagramSocket.bind(any, 5353, reuseAddress: true, reusePort: reusePort);
      } catch (_) {}
    }
    try {
      return await RawDatagramSocket.bind(any, 0);
    } catch (_) {
      return null;
    }
  }

  void send(List<(String, int)> questions) {
    if (questions.isEmpty) return;
    for (final (s, v6) in _sockets) {
      final legacy = s.port != 5353;
      final data = encodeDnsQuery(questions, unicastResponse: legacy);
      try {
        s.send(data, v6 ? MatterDiscovery._group6 : MatterDiscovery._group4, 5353);
      } catch (_) {}
    }
  }

  void close() {
    for (final (s, _) in _sockets) {
      s.close();
    }
  }
}
