import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'net.dart';

/// A service instance announced over mDNS (Bonjour).
class MdnsService {
  MdnsService({required this.type, required this.instance, required this.host});

  /// e.g. `_googlecast._tcp`
  final String type;

  /// e.g. `Living Room TV`
  String instance;

  /// IP address of the device that answered.
  final String host;
  int? port;
  final Map<String, String> txt = {};
}

/// One DNS resource record.
class DnsRecord {
  DnsRecord(this.name, this.type, this.data);
  final String name;
  final int type;
  final Object data;

  static const a = 1, ptr = 12, txt = 16, srv = 33;
}

/// Builds a DNS query for PTR records of [names].
Uint8List encodeMdnsQuery(List<String> names) {
  final b = BytesBuilder();
  void u16(int v) => b.add([(v >> 8) & 0xff, v & 0xff]);
  u16(0); // id
  u16(0); // flags: standard query
  u16(names.length);
  u16(0);
  u16(0);
  u16(0);
  for (final n in names) {
    for (final label in n.split('.').where((l) => l.isNotEmpty)) {
      final bytes = utf8.encode(label);
      b.addByte(bytes.length);
      b.add(bytes);
    }
    b.addByte(0);
    u16(DnsRecord.ptr);
    u16(0x8001); // class IN, "unicast response" bit
  }
  return b.toBytes();
}

/// Reads every record (answers, authority, additional) from a DNS packet.
List<DnsRecord> decodeDnsRecords(Uint8List p) {
  var i = 0;
  int u16() {
    final v = (p[i] << 8) | p[i + 1];
    i += 2;
    return v;
  }

  String name(int at, [int depth = 0]) {
    final labels = <String>[];
    var j = at;
    while (j < p.length && depth < 20) {
      final len = p[j];
      if (len == 0) break;
      if (len & 0xc0 == 0xc0) {
        labels.add(name(((len & 0x3f) << 8) | p[j + 1], depth + 1));
        break;
      }
      labels.add(utf8.decode(p.sublist(j + 1, j + 1 + len), allowMalformed: true));
      j += 1 + len;
    }
    return labels.where((l) => l.isNotEmpty).join('.');
  }

  int skipName(int at) {
    var j = at;
    while (j < p.length) {
      final len = p[j];
      if (len == 0) return j + 1;
      if (len & 0xc0 == 0xc0) return j + 2;
      j += 1 + len;
    }
    return j;
  }

  final out = <DnsRecord>[];
  if (p.length < 12) return out;
  i = 4;
  final qd = u16(), an = u16(), ns = u16(), ar = u16();
  for (var q = 0; q < qd; q++) {
    i = skipName(i) + 4;
  }
  for (var r = 0; r < an + ns + ar && i + 10 <= p.length; r++) {
    final n = name(i);
    i = skipName(i);
    final type = u16();
    u16(); // class
    i += 4; // ttl
    final len = u16();
    final start = i;
    if (start + len > p.length) break;
    switch (type) {
      case DnsRecord.ptr:
        out.add(DnsRecord(n, type, name(start)));
      case DnsRecord.srv:
        final port = (p[start + 4] << 8) | p[start + 5];
        out.add(DnsRecord(n, type, (port, name(start + 6))));
      case DnsRecord.txt:
        final entries = <String>[];
        var j = start;
        while (j < start + len) {
          final l = p[j];
          entries.add(utf8.decode(p.sublist(j + 1, j + 1 + l), allowMalformed: true));
          j += 1 + l;
        }
        out.add(DnsRecord(n, type, entries));
      case DnsRecord.a when len == 4:
        out.add(DnsRecord(n, type, p.sublist(start, start + 4).join('.')));
    }
    i = start + len;
  }
  return out;
}

/// Asks the network which devices offer the given service [types] and calls
/// [found] for every service instance that answers.
///
/// Queries go out from a random port ("legacy unicast", RFC 6762 6.7), so
/// devices answer this socket directly. That works on Android, where the
/// system already holds the mDNS port 5353 and multicast replies are dropped.
Future<void> mdnsBrowse(
  Iterable<String> types,
  void Function(MdnsService s) found, {
  Duration timeout = const Duration(seconds: 3),
  bool enumerate = true,
  InternetAddress? target,
  int port = 5353,
}) async {
  RawDatagramSocket socket;
  try {
    socket = await lanUdpSocket();
  } catch (_) {
    return;
  }
  final dest = target ?? InternetAddress('224.0.0.251');
  final services = <String, MdnsService>{};
  final asked = <String>{...types};
  final more = StreamController<String>();

  void handle(Datagram d) {
    final List<DnsRecord> records;
    try {
      records = decodeDnsRecords(d.data);
    } catch (_) {
      return;
    }
    final host = d.address.address;
    final addresses = {for (final r in records.where((r) => r.type == DnsRecord.a)) r.name: r.data as String};
    for (final r in records) {
      if (r.type != DnsRecord.ptr) continue;
      final target = r.data as String;
      if (r.name.startsWith('_services._dns-sd._udp')) {
        final t = target.replaceFirst(RegExp(r'\.local$'), '');
        if (enumerate && asked.length < 60 && asked.add(t)) more.add(t);
        continue;
      }
      final type = r.name.replaceFirst(RegExp(r'\.local$'), '');
      if (!asked.contains(type)) continue;
      final instance = target.endsWith('.$type.local') ? target.substring(0, target.length - type.length - 7) : target;
      final s = services.putIfAbsent('$type|$target', () => MdnsService(type: type, instance: instance, host: host));
      for (final x in records) {
        if (x.name != target) continue;
        if (x.type == DnsRecord.srv) {
          final (p, srvHost) = x.data as (int, String);
          s.port = p;
          // Answers relayed by another device (a sleep proxy) carry the real address.
          final ip = addresses[srvHost];
          if (ip != null && ip != host) {
            services['$type|$target'] = MdnsService(type: type, instance: instance, host: ip)..port = p;
          }
        }
        if (x.type == DnsRecord.txt) {
          for (final e in x.data as List<String>) {
            final k = e.indexOf('=');
            if (k > 0) s.txt[e.substring(0, k)] = e.substring(k + 1);
          }
        }
      }
      found(services['$type|$target']!);
    }
  }

  final sub = socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d != null) handle(d);
  });

  void ask(List<String> names) {
    // A few questions per packet keeps it under every device's size limit.
    for (var k = 0; k < names.length; k += 8) {
      final chunk = names.sublist(k, (k + 8).clamp(0, names.length)).map((t) => '$t.local').toList();
      trySend(socket, encodeMdnsQuery(chunk), dest, port);
    }
  }

  final moreSub = more.stream.listen((t) => ask([t]));
  final first = [if (enumerate) '_services._dns-sd._udp', ...types];
  ask(first);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  ask(first); // UDP gets lost; ask twice
  await Future<void>.delayed(timeout);
  await moreSub.cancel();
  await more.close();
  await sub.cancel();
  socket.close();
}
