import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/lan/lan_driver.dart';
import 'package:smartmenukj/integrations/lan/lan_protocol.dart';
import 'package:smartmenukj/integrations/lan/mac_vendor.dart';
import 'package:smartmenukj/integrations/lan/routeros.dart';
import 'package:smartmenukj/integrations/lan/whois.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

/// Real sockets, not the test binding's HTTP client that answers 400 to everything.
class _RealHttp extends HttpOverrides {}

/// DNS name as length-prefixed labels.
List<int> dnsName(String name) => [
      for (final l in name.split('.')) ...[l.length, ...utf8.encode(l)],
      0,
    ];

/// Answers a reverse lookup sent to its port with [name], as a phone's Bonjour does.
Future<RawDatagramSocket> fakeBonjour(String name) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((e) {
    final d = s.receive();
    if (d == null) return;
    // The question's name starts after the 12-byte header and ends at its zero byte.
    final end = d.data.indexOf(0, 12);
    final question = d.data.sublist(12, end + 1);
    final rdata = dnsName(name);
    s.send([
      0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, //
      ...question, 0, 12, 0, 1, 0, 0, 0, 120, rdata.length >> 8, rdata.length & 0xff, ...rdata,
    ], d.address, d.port);
  });
  return s;
}

/// Answers a NetBIOS node status question like a Windows computer.
Future<RawDatagramSocket> fakeWindows(String name, List<int> mac) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  List<int> entry(String n, int flags) => [...latin1.encode(n.padRight(15)), 0, flags >> 8, flags & 0xff];
  s.listen((e) {
    final d = s.receive();
    if (d == null) return;
    final names = [...entry('WORKGROUP', 0x8400), ...entry(name, 0x0400)];
    final rdata = [2, ...names, ...mac, for (var i = 0; i < 40; i++) 0];
    s.send([
      d.data[0], d.data[1], 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, //
      ...d.data.sublist(12, 12 + 34), 0, 0x21, 0, 1, 0, 0, 0, 0, rdata.length >> 8, rdata.length & 0xff, ...rdata,
    ], d.address, d.port);
  });
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Makers', () {
    test('come from the first half of the MAC', () async {
      final v = (await MacVendors.load())!;
      expect(v.vendorOf('b8:27:eb:12:34:56'), 'Raspberry Pi');
      expect(v.vendorOf('F0-F5-BD-01-02-03'), 'Espressif');
      expect(v.vendorOf('10cee9aabbcc'), 'Apple');
      expect(v.vendorOf('48:a9:8a:01:02:03'), 'MikroTik');
      expect(v.vendorOf('70:b3:d5:b9:91:23'), 'DomoSafety', reason: 'a small block inside a shared one');
      expect(v.vendorOf('da:a1:19:00:00:01'), isNull, reason: 'a private address says nothing about its maker');
      expect(isPrivateMac('da:a1:19:00:00:01'), isTrue);
      expect(isPrivateMac('b8:27:eb:12:34:56'), isFalse);
    });

    test('and with the open ports say what a device probably is', () {
      expect(guessDevice(vendor: 'Apple', ports: {62078})?.what, 'iPhone or iPad');
      expect(guessDevice(vendor: 'Apple', ports: {7000})?.kind, DeviceKind.media);
      expect(guessDevice(vendor: 'Samsung', ports: {8001})?.what, 'Samsung TV');
      expect(guessDevice(vendor: 'Espressif')?.what, 'Smart plug, bulb or sensor');
      expect(guessDevice(vendor: 'Dahua / Imou')?.kind, DeviceKind.camera);
      expect(guessDevice(vendor: 'iRobot')?.kind, DeviceKind.vacuum);
      expect(guessDevice(vendor: 'Intel')?.what, 'Computer or laptop');
      expect(guessDevice(vendor: 'Xiaomi')?.what, 'Xiaomi phone or smart device');
      expect(guessDevice(mac: 'da:a1:19:00:00:01')?.what, 'Phone, tablet or laptop');
      expect(guessDevice(vendor: 'Some Small Company'), isNull);
    });
  });

  test('ARP tables are read from Linux, Android, macOS and Windows', () {
    expect(parseArpTable('''
IP address       HW type     Flags       HW address            Mask     Device
192.168.88.1     0x1         0x2         48:a9:8a:01:02:03     *        wlan0
192.168.88.9     0x1         0x0         00:00:00:00:00:00     *        wlan0
'''), {'192.168.88.1': '48:a9:8a:01:02:03'});
    expect(parseArpTable('192.168.88.20 dev wlan0 lladdr DC:A6:32:AA:BB:CC REACHABLE\nfe80::1 dev wlan0 lladdr 11:22:33:44:55:66 STALE'),
        {'192.168.88.20': 'dc:a6:32:aa:bb:cc'});
    expect(parseArpTable('? (192.168.88.30) at 0:11:2:a:b:c on en0 ifscope [ethernet]\n? (192.168.88.31) at (incomplete) on en0'),
        {'192.168.88.30': '00:11:02:0a:0b:0c'});
    expect(parseArpTable('''
Interface: 192.168.88.5 --- 0xb
  Internet Address      Physical Address      Type
  192.168.88.40         f0-f5-bd-01-02-03     dynamic
  192.168.88.255        ff-ff-ff-ff-ff-ff     static
  224.0.0.251           01-00-5e-00-00-fb     static
'''), {'192.168.88.40': 'f0:f5:bd:01:02:03'});
  });

  test('names made up from the MAC and empty page titles are left out', () {
    expect(usefulName('Krasimirs-iPhone.local'), 'Krasimirs-iPhone');
    expect(usefulName('android-1a2b3c4d5e6f7a8b'), isNull);
    expect(usefulName('ESP_3A2B1C'), isNull);
    expect(usefulName('localhost'), isNull);
    expect(usefulName('192.168.1.5'), isNull);
    expect(usefulName('Galaxy-S23'), 'Galaxy-S23');
    expect(cleanTitle('Login - Synology DiskStation'), 'Synology DiskStation');
    expect(cleanTitle('FRITZ!Box'), 'FRITZ!Box');
    expect(cleanTitle('  Index of / '), isNull);
    expect(cleanTitle('Welcome to nginx!'), isNull);
    expect(cleanTitle('404 Not Found'), isNull);
    expect(cleanTitle('Tom &amp; Jerry&#39;s NAS'), "Tom & Jerry's NAS");
  });

  test('NetBIOS gives a Windows computer\'s name and MAC', () async {
    expect(netbiosQuery().length, 50);
    final pc = await fakeWindows('DESKTOP-KJ', [0x00, 0x1b, 0x21, 0x0a, 0x0b, 0x0c]);
    final info = await netbiosStatus('127.0.0.1', port: pc.port);
    expect(info?.name, 'DESKTOP-KJ');
    expect(info?.mac, '00:1b:21:0a:0b:0c');
    pc.close();
  });

  test('Bonjour gives a phone\'s own name', () async {
    final phone = await fakeBonjour('Krasimirs-iPhone.local');
    expect(await mdnsHostName('127.0.0.1', port: phone.port), 'Krasimirs-iPhone.local');
    phone.close();
  });

  test('a web page\'s title or login box says what a device is', () => HttpOverrides.runWithHttpOverrides(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      if (req.uri.path == '/auth') {
        req.response
          ..statusCode = 401
          ..headers.set('WWW-Authenticate', 'Basic realm="TL-WR841N"');
      } else {
        req.response.write('<html><head><TITLE>Login - Synology DiskStation</TITLE></head></html>');
      }
      req.response.close();
    });
    expect(await webTitle(Uri.parse('http://127.0.0.1:${server.port}/')), 'Synology DiskStation');
    expect(await webTitle(Uri.parse('http://127.0.0.1:${server.port}/auth')), 'TL-WR841N');
    await server.close(force: true);
  }, _RealHttp()));

  test('whoIs puts it together', () async {
    final phone = await fakeBonjour('Krasimirs-iPhone.local');
    final closed = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final free = closed.port;
    closed.close();
    final who = await whoIs(
      '127.0.0.1',
      open: {62078},
      portMap: {5353: phone.port, 137: free},
      arp: () async => {'127.0.0.1': '10:ce:e9:12:34:56'},
      within: const Duration(milliseconds: 500),
    );
    expect(who.name, 'Krasimirs-iPhone');
    expect(who.vendor, 'Apple');
    expect(who.what, 'iPhone or iPad');
    expect(who.hints, {'name': 'Krasimirs-iPhone', 'mac': '10:ce:e9:12:34:56', 'vendor': 'Apple', 'what': 'iPhone or iPad'});
    phone.close();

    // Known only to the router, by a name Android made up and a private MAC.
    final quiet = await whoIs(
      '127.0.0.1',
      open: const {},
      known: const Neighbor(name: 'android-1a2b3c4d5e6f7a8b', mac: 'DA:A1:19:00:00:01'),
      portMap: {5353: free, 137: free},
      arp: () async => const {},
      within: const Duration(milliseconds: 300),
    );
    expect(quiet.name, isNull);
    expect(quiet.label, 'Android phone');
    expect(quiet.hints['guessed'], '1');
    expect(quiet.mac, 'da:a1:19:00:00:01');
  });

  test('a MikroTik says who has which address', () async {
    final ctx = LanContext(
      client: MockClient((req) async => switch (req.url.path) {
            '/rest/ip/dhcp-server/lease' => http.Response(
                jsonEncode([
                  {'.id': '*1', 'address': '192.168.88.21', 'mac-address': 'DA:A1:19:00:00:01', 'host-name': 'Galaxy-S23', 'status': 'bound'},
                  {'.id': '*2', 'address': '192.168.88.22', 'mac-address': '10:CE:E9:00:00:02', 'host-name': 'x', 'comment': 'Krasi Mac', 'status': 'bound'},
                  {'.id': '*3', 'address': '192.168.88.23', 'mac-address': 'B8:27:EB:00:00:03', 'status': 'waiting'},
                ]),
                200),
            '/rest/ip/arp' => http.Response(
                jsonEncode([
                  {'.id': '*a', 'address': '192.168.88.21', 'mac-address': 'DA:A1:19:00:00:01', 'complete': 'true'},
                  {'.id': '*b', 'address': '192.168.88.30', 'mac-address': 'F0:F5:BD:01:02:03', 'complete': 'true'},
                  {'.id': '*c', 'address': '192.168.88.31', 'complete': 'false'},
                ]),
                200),
            _ => http.Response('[]', 200),
          }),
      make: LanDriver(IntegrationConfig(id: 'lan', type: 'lan', name: 'Network devices'), http.Client()).makeDevice,
    );
    final n = await MikroTik(RouterOsRest(ctx, '10.0.0.1', 'admin', 'pw')).neighbors();
    expect(n.keys, unorderedEquals(['192.168.88.21', '192.168.88.22', '192.168.88.30']));
    expect(n['192.168.88.21']?.name, 'Galaxy-S23');
    expect(n['192.168.88.22']?.name, 'Krasi Mac', reason: 'a name set on the router wins');
    expect(n['192.168.88.30']?.mac, 'F0:F5:BD:01:02:03');
    expect(n['192.168.88.30']?.name, isNull);
  });

  test('a device added by its address learns its name and maker from a later scan', () async {
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 404)));
    await store.load();
    await store.addNetworkDevice('127.0.0.1', hints: {'protocol': 'generic', 'mac': 'B8:27:EB:00:00:03'});
    final d = store.devices.singleWhere((d) => d.props['host'] == '127.0.0.1');
    expect(d.name, '127.0.0.1');
    expect(d.props['vendor'], 'Raspberry Pi', reason: 'the maker comes from the MAC it was added with');
    expect(d.state.readings['Maker'], 'Raspberry Pi');

    store.learnFromScan('127.0.0.1', 'Pi-hole', {'mac': 'b8:27:eb:00:00:03', 'what': 'Raspberry Pi', 'kind': 'router'});
    expect(d.name, 'Pi-hole');
    expect(d.props['what'], 'Raspberry Pi');
    expect(d.kind, DeviceKind.router);

    store.learnFromScan('127.0.0.1', 'Something else', const {});
    expect(d.name, 'Pi-hole', reason: 'a name the device already has is kept');
    store.dispose();
  });
}
