import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartmenukj/integrations/lan/mdns.dart';
import 'package:smartmenukj/integrations/lan/sweep.dart';

/// Builds an mDNS answer packet (no name compression, like a simple responder).
Uint8List mdnsAnswer(List<(String name, int type, List<int> rdata)> records) {
  final b = BytesBuilder();
  void u16(int v) => b.add([(v >> 8) & 0xff, v & 0xff]);
  List<int> name(String n) => [
        for (final l in n.split('.')) ...[utf8.encode(l).length, ...utf8.encode(l)],
        0,
      ];
  u16(0);
  u16(0x8400);
  u16(0);
  u16(records.length);
  u16(0);
  u16(0);
  for (final (n, type, data) in records) {
    b.add(name(n));
    u16(type);
    u16(1);
    b.add([0, 0, 0, 120]);
    u16(data.length);
    b.add(data);
  }
  return b.toBytes();
}

List<int> dnsName(String n) => [
      for (final l in n.split('.')) ...[utf8.encode(l).length, ...utf8.encode(l)],
      0,
    ];

void main() {
  test('mDNS queries round trip through the decoder', () {
    final q = encodeMdnsQuery(['_googlecast._tcp.local']);
    expect(q.sublist(4, 6), [0, 1], reason: 'one question');
    expect(decodeDnsRecords(q), isEmpty);
  });

  test('finds a Cast device that answers the phone directly (Android-safe mDNS)', () async {
    final responder = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final questions = <String>[];
    responder.listen((e) {
      final d = responder.receive();
      if (d == null) return;
      questions.add(utf8.decode(d.data, allowMalformed: true));
      final txt = utf8.encode('fn=Living Room TV');
      final reply = mdnsAnswer([
        ('_services._dns-sd._udp.local', DnsRecord.ptr, dnsName('_googlecast._tcp.local')),
        ('_googlecast._tcp.local', DnsRecord.ptr, dnsName('Chromecast-abc._googlecast._tcp.local')),
        ('Chromecast-abc._googlecast._tcp.local', DnsRecord.srv, [0, 0, 0, 0, 0x1f, 0x49, ...dnsName('abc.local')]),
        ('Chromecast-abc._googlecast._tcp.local', DnsRecord.txt, [txt.length, ...txt]),
        ('abc.local', DnsRecord.a, [127, 0, 0, 1]),
      ]);
      responder.send(reply, d.address, d.port);
    });
    final found = <MdnsService>[];
    await mdnsBrowse(['_googlecast._tcp'], found.add,
        target: InternetAddress.loopbackIPv4, port: responder.port, timeout: const Duration(milliseconds: 300));
    responder.close();
    expect(questions, isNotEmpty);
    final cast = found.firstWhere((s) => s.type == '_googlecast._tcp');
    expect(cast.instance, 'Chromecast-abc');
    expect(cast.host, '127.0.0.1');
    expect(cast.port, 8009);
    expect(cast.txt['fn'], 'Living Room TV');
  });

  test('the sweep finds devices that accept or refuse, and skips empty addresses', () async {
    final open = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    open.listen((c) => c.destroy());
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final hits = <SweepHit>[];
    await sweepHosts(['127.0.0.1'], hits.add, ports: [8060, 22], portMap: {8060: open.port, 22: closedPort});
    expect(hits.single.host, '127.0.0.1');
    expect(hits.single.openPorts, {8060});
    expect(guessFromPorts(hits.single.openPorts), 'roku');

    hits.clear();
    await sweepHosts(['127.0.0.1'], hits.add, ports: [22], portMap: {22: closedPort});
    expect(hits.single.openPorts, isEmpty, reason: 'a refusal still proves the device is there');
    await open.close();
  });

  test('labels devices from their ports', () {
    expect(labelFromPorts({53, 80}), 'Wi-Fi router');
    expect(labelFromPorts({62078}), 'iPhone or iPad');
    expect(labelFromPorts({9100}), 'Printer');
    expect(labelFromPorts({}), 'Device');
  });
}
