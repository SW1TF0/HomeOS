import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/integration.dart';
import 'package:smartmenukj/integrations/lan/lan_driver.dart';
import 'package:smartmenukj/integrations/lan/lan_protocol.dart';
import 'package:smartmenukj/integrations/lan/mac_vendor.dart';
import 'package:smartmenukj/integrations/lan/roomba.dart';
import 'package:smartmenukj/integrations/lan/routeros.dart';
import 'package:smartmenukj/integrations/lan/sweep.dart';
import 'package:smartmenukj/integrations/lan/upnp.dart';
import 'package:smartmenukj/integrations/network_scan.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:provider/provider.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/theme/app_theme.dart';
import 'package:smartmenukj/ui/screens/router_screen.dart';

/// A robot answering "irobotmcs" on a local UDP port, as a Roomba does on 5678.
Future<RawDatagramSocket> fakeRobotUdp(Map<String, Object?> answer) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = s.receive();
    if (d != null && utf8.decode(d.data) == 'irobotmcs') s.send(utf8.encode(jsonEncode(answer)), d.address, d.port);
  });
  return s;
}

/// The robot's password service on 8883: answers the magic packet in two parts, as older robots do.
Future<ServerSocket> fakePasswordServer(String? password) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((c) {
    c.listen((data) async {
      if (password == null) {
        await c.close();
        return;
      }
      final body = [0xef, 0xcc, 0x3b, 0x29, 0x00, ...utf8.encode(password), 0];
      c.add([0xf0, body.length]);
      await c.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      c.add(body);
      await c.flush();
    });
  });
  return server;
}

/// Just enough of an MQTT 3.1.1 broker to stand in for a Roomba.
class FakeRobotBroker {
  FakeRobotBroker._(this.server, this.password);
  final ServerSocket server;
  final String password;
  final commands = <Map<String, dynamic>>[];
  final logins = <(String?, String?, String?)>[];
  final _clients = <Socket>[];
  Map<String, dynamic> state = {
    'name': 'Downstairs',
    'batPct': 87,
    'bin': {'present': true, 'full': false},
    'cleanMissionStatus': {'cycle': 'none', 'phase': 'charge', 'error': 0},
  };

  static Future<FakeRobotBroker> start(String password) async {
    final b = FakeRobotBroker._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), password);
    b.server.listen(b._serve);
    return b;
  }

  int get port => server.port;

  static List<int> _len(int n) {
    final out = <int>[];
    do {
      var b = n % 128;
      n ~/= 128;
      if (n > 0) b |= 0x80;
      out.add(b);
    } while (n > 0);
    return out;
  }

  static List<int> _str(String s) => [utf8.encode(s).length >> 8, utf8.encode(s).length & 0xff, ...utf8.encode(s)];

  void publish(String topic, Object json) {
    final body = [..._str(topic), ...utf8.encode(jsonEncode(json))];
    for (final c in _clients) {
      c.add([0x30, ..._len(body.length), ...body]);
    }
  }

  void report(Map<String, dynamic> reported) => publish(r'$aws/things/BLID123/shadow/update', {
        'state': {'reported': reported},
      });

  void _serve(Socket c) {
    var buf = <int>[];
    c.listen((data) {
      buf = [...buf, ...data];
      while (buf.length >= 2) {
        var mult = 1, len = 0, i = 1;
        int b;
        do {
          if (i >= buf.length) return;
          b = buf[i++];
          len += (b & 0x7f) * mult;
          mult *= 128;
        } while (b & 0x80 != 0);
        if (buf.length < i + len) return;
        final type = buf[0] >> 4;
        final body = buf.sublist(i, i + len);
        buf = buf.sublist(i + len);
        _handle(c, type, body);
      }
    }, onDone: () => _clients.remove(c), onError: (_) => _clients.remove(c));
  }

  void _handle(Socket c, int type, List<int> body) {
    String readStr(int at) => utf8.decode(body.sublist(at + 2, at + 2 + (body[at] << 8 | body[at + 1])));
    switch (type) {
      case 1: // CONNECT
        final flags = body[7];
        var at = 10;
        final clientId = readStr(at);
        at += 2 + utf8.encode(clientId).length;
        String? user, pass;
        if (flags & 0x80 != 0) {
          user = readStr(at);
          at += 2 + utf8.encode(user).length;
        }
        if (flags & 0x40 != 0) pass = readStr(at);
        logins.add((clientId, user, pass));
        final ok = pass == password;
        c.add([0x20, 0x02, 0x00, ok ? 0 : 4]);
        if (!ok) {
          c.close();
          return;
        }
        _clients.add(c);
        // A robot tells everything it knows right after a client connects, in pieces.
        Timer(const Duration(milliseconds: 20), () {
          report({'name': state['name'], 'batPct': state['batPct']});
          report({'bin': state['bin'], 'cleanMissionStatus': state['cleanMissionStatus']});
        });
      case 8: // SUBSCRIBE
        c.add([0x90, 0x03, body[0], body[1], 0x00]);
      case 3: // PUBLISH
        final topicLen = body[0] << 8 | body[1];
        final topic = utf8.decode(body.sublist(2, 2 + topicLen));
        if (topic == 'cmd') commands.add(jsonDecode(utf8.decode(body.sublist(2 + topicLen))) as Map<String, dynamic>);
      case 12: // PINGREQ
        c.add([0xd0, 0x00]);
      case 14: // DISCONNECT
        c.close();
    }
  }

  Future<void> close() async {
    for (final c in [..._clients]) {
      c.destroy();
    }
    await server.close();
  }
}

/// A RouterOS API on a local port, with a handful of menus.
class FakeRouterApi {
  FakeRouterApi._(this.server, {required this.challenge});
  final ServerSocket server;
  final bool challenge;
  final sent = <List<String>>[];
  final Map<String, List<Map<String, String>>> menus = {
    '/system/resource': [
      {'uptime': '2w1d3h5m', 'cpu-load': '4', 'board-name': 'hAP ac2', 'version': '6.49.10 (long-term)', 'free-memory': '96', 'total-memory': '128'},
    ],
    '/system/identity': [
      {'name': 'Home router'},
    ],
    '/interface': [
      {'.id': '*1', 'name': 'ether1', 'type': 'ether', 'running': 'true', 'disabled': 'false'},
      {'.id': '*5', 'name': 'bridge', 'type': 'bridge', 'running': 'true', 'disabled': 'false'},
    ],
    '/interface/wireless': [
      {'.id': '*3', 'name': 'wlan1', 'ssid': 'Krasi-2G', 'band': '2ghz-b/g/n', 'disabled': 'false', 'running': 'true', 'security-profile': 'home'},
    ],
    '/interface/wireless/security-profiles': [
      {'.id': '*0', 'name': 'default'},
      {'.id': '*2', 'name': 'home'},
    ],
    '/ip/dhcp-server/lease': [
      {'.id': '*a', 'address': '192.168.88.20', 'mac-address': 'AA:BB:CC:00:11:22', 'host-name': 'Roomba-BLID', 'status': 'bound', 'dynamic': 'true'},
      {'.id': '*b', 'address': '192.168.88.30', 'mac-address': 'AA:BB:CC:00:11:33', 'comment': 'TV', 'status': 'waiting', 'dynamic': 'false'},
    ],
  };

  static Future<FakeRouterApi> start({bool challenge = false}) async {
    final f = FakeRouterApi._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), challenge: challenge);
    f.server.listen(f._serve);
    return f;
  }

  void _serve(Socket c) {
    var buf = <int>[];
    var loggedIn = false;
    void reply(List<List<String>> sentences) => c.add([for (final s in sentences) ...RouterOsApi.encodeSentence(s)]);
    c.listen((data) {
      buf = [...buf, ...data];
      while (true) {
        final words = <String>[];
        var i = 0;
        var done = false;
        while (true) {
          final l = RouterOsApi.decodeLength(buf, i);
          if (l == null) break;
          final (n, used) = l;
          if (n == 0) {
            i += used;
            done = true;
            break;
          }
          if (i + used + n > buf.length) break;
          words.add(utf8.decode(buf.sublist(i + used, i + used + n)));
          i += used + n;
        }
        if (!done) return;
        buf = buf.sublist(i);
        sent.add(words);
        final args = {for (final w in words.skip(1)) w.substring(1, w.indexOf('=', 1)): w.substring(w.indexOf('=', 1) + 1)};
        final cmd = words.first;
        if (cmd == '/login') {
          if (challenge && args['response'] == null) {
            reply([
              ['!done', '=ret=0123456789abcdef0123456789abcdef'],
            ]);
          } else if ((challenge && args['response']!.length == 34) || args['password'] == 'secret') {
            loggedIn = true;
            reply([
              ['!done'],
            ]);
          } else {
            reply([
              ['!trap', '=message=invalid user name or password (6)'],
              ['!done'],
            ]);
          }
          continue;
        }
        if (!loggedIn) {
          reply([
            ['!fatal', 'not logged in'],
          ]);
          c.destroy();
          return;
        }
        if (cmd.endsWith('/print')) {
          final menu = menus[cmd.substring(0, cmd.length - 6)];
          if (menu == null) {
            reply([
              ['!trap', '=message=no such command prefix'],
              ['!done'],
            ]);
          } else {
            reply([
              for (final e in menu) ['!re', for (final kv in e.entries) '=${kv.key}=${kv.value}'],
              ['!done'],
            ]);
          }
        } else {
          reply([
            ['!done'],
          ]);
        }
      }
    });
  }

  Future<void> close() => server.close();
}

LanContext lanContext(Map<int, int> ports, {http.Client? client}) => LanContext(
      client: client ?? MockClient((_) async => http.Response('', 404)),
      make: LanDriver(IntegrationConfig(id: 'lan', type: 'lan', name: 'Network devices'), http.Client()).makeDevice,
      portMap: ports,
      allowTls: false,
    );

void main() {
  group('Roomba', () {
    test('is found by its answer on UDP 5678', () async {
      final udp = await fakeRobotUdp({
        'hostname': 'Roomba-BLID123',
        'robotname': 'Downstairs',
        'sku': 'R960020',
        'mac': '80:a5:89:00:00:01',
        'ip': '127.0.0.1',
      });
      final info = await roombaAt('127.0.0.1', port: udp.port);
      expect(info, isNotNull);
      expect(info!.blid, 'BLID123');
      expect(info.name, 'Downstairs');
      expect(info.hints, containsPair('protocol', 'roomba'));
      expect(RoombaInfo('h', const {'hostname': 'iRobot-ABC', 'sku': 'm611020'}).name, 'Braava');
      expect(RoombaInfo('h', const {'hostname': 'printer'}).isRobot, isFalse);
      udp.close();
    });

    test('reads the password the robot hands out, and says what to do when it does not', () async {
      expect(roombaPasswordFrom([0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x00]), isNull);
      expect(roombaPasswordFrom([0xf0, 0x09, 0xef, 0xcc, 0x3b, 0x29, 0x00, 0x3a, 0x31, 0x00]), ':1');

      final good = await fakePasswordServer(':1:1571234:AbCdEf');
      final roomba = RoombaProtocol();
      expect(await roomba.password(lanContext({8883: good.port}), '127.0.0.1'), ':1:1571234:AbCdEf');
      await good.close();

      final closed = await fakePasswordServer(null);
      final ctx = lanContext({8883: closed.port, roombaPort: closed.port});
      final robot = ctx.make(
          externalId: 'roomba:127.0.0.1',
          name: 'Roomba',
          kind: DeviceKind.vacuum,
          props: {'host': '127.0.0.1', 'protocol': 'roomba', 'blid': 'BLID123'});
      expect(await roomba.setUp(ctx, robot), contains('hold its HOME button'));
      expect(robot.props['password'], isNull);
      expect((await roomba.read(ctx, robot))!.readings['Status'], 'Needs its password');
      await closed.close();
    });

    test('gets its password, then shows its state and cleans, pauses, resumes and goes home', () async {
      final udp = await fakeRobotUdp({'hostname': 'Roomba-BLID123', 'robotname': 'Downstairs', 'sku': 'R960020'});
      final pw = await fakePasswordServer('robot-pass');
      final broker = await FakeRobotBroker.start('robot-pass');
      final pushes = <DeviceState>[];
      final ctx = lanContext({roombaPort: udp.port, 8883: pw.port})..push = (_, s) => pushes.add(s);
      final roomba = RoombaProtocol();

      final found = await roomba.identify(ctx, '127.0.0.1', const {});
      final robot = found!.single;
      expect(robot.kind, DeviceKind.vacuum);
      expect(robot.name, 'Downstairs');
      expect(robot.props['blid'], 'BLID123');
      expect(robot.props['model'], 'iRobot R960020');
      expect(robot.state.readings['Status'], 'Needs its password');

      // The password and the control both use port 8883 on a robot; here they are two fakes.
      robot.props['password'] = await roomba.password(ctx, '127.0.0.1');
      expect(robot.props['password'], 'robot-pass');

      final live = lanContext({roombaPort: udp.port, 8883: broker.port})..push = (_, s) => pushes.add(s);
      final state = (await roomba.read(live, robot))!;
      expect(broker.logins.single, ('BLID123', 'BLID123', 'robot-pass'));
      expect(state.battery, closeTo(0.87, 0.001));
      expect(state.activity, Activity.charging);
      expect(state.readings['Bin'], 'OK');
      expect(state.readings['Status'], '', reason: 'clears "Needs its password"');

      expect((await roomba.send(live, robot, const DeviceCommand(action: DeviceAction.start)))!.activity, Activity.running);
      broker.report({
        'cleanMissionStatus': {'cycle': 'clean', 'phase': 'stop', 'error': 0},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pushes.last.activity, Activity.paused, reason: 'stopped in the middle of a cleaning is paused');
      await roomba.send(live, robot, const DeviceCommand(action: DeviceAction.start));
      await roomba.send(live, robot, const DeviceCommand(action: DeviceAction.locate));
      broker.report({
        'cleanMissionStatus': {'cycle': 'clean', 'phase': 'run', 'error': 0},
        'bin': {'present': true, 'full': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pushes.last.readings['Bin'], 'Full');
      expect((await roomba.send(live, robot, const DeviceCommand(action: DeviceAction.dock)))!.activity, Activity.returning);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(broker.commands.map((c) => c['command']), ['start', 'resume', 'find', 'pause', 'dock']);
      expect(broker.commands.first['initiator'], 'localApp');
      expect(broker.commands.first['time'], isA<int>());

      broker.report({
        'cleanMissionStatus': {'cycle': 'none', 'phase': 'stuck', 'error': 17},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pushes.last.activity, Activity.error);
      expect(pushes.last.readings['Error'], 'The way is blocked');

      await roomba.close();
      await broker.close();
      await pw.close();
      udp.close();
    });

    test('a wrong password says to get it again', () async {
      final broker = await FakeRobotBroker.start('right');
      final ctx = lanContext({8883: broker.port});
      final robot = ctx.make(
          externalId: 'roomba:127.0.0.1',
          name: 'Roomba',
          kind: DeviceKind.vacuum,
          props: {'host': '127.0.0.1', 'protocol': 'roomba', 'blid': 'BLID123', 'password': 'wrong'});
      await expectLater(RoombaProtocol().read(ctx, robot),
          throwsA(isA<IntegrationException>().having((e) => e.message, 'message', contains('Get password'))));
      await broker.close();
    });
  });

  group('MikroTik', () {
    test('API words carry their length', () {
      for (final n in [0, 5, 0x7f, 0x80, 0x3fff, 0x4000, 0x1fffff, 0x200000, 0xfffffff, 0x10000000]) {
        final enc = RouterOsApi.encodeLength(n);
        expect(RouterOsApi.decodeLength([...enc, 1, 2], 0), (n, enc.length), reason: '$n');
      }
      expect(RouterOsApi.decodeLength([0x81], 0), isNull, reason: 'not all there yet');
    });

    test('over the API: logs in, shows the router and changes its Wi-Fi, ports and name', () async {
      final api = await FakeRouterApi.start();
      final ctx = lanContext({8728: api.server.port});
      await expectLater(MikroTikProtocol.openAt(ctx, '127.0.0.1', password: 'nope'), throwsA(isA<RouterLoginException>()));

      final router = MikroTik(await MikroTikProtocol.openAt(ctx, '127.0.0.1', password: 'secret'));
      final snap = await router.load();
      expect(snap.identity, 'Home router');
      expect(snap.model, 'hAP ac2');
      expect(snap.version, '6.49.10');
      expect(snap.uptime, '15 days 3 h');
      expect(snap.cpu, '4%');
      expect(snap.memory, '25%');
      expect(snap.wifi.single.ssid, 'Krasi-2G');
      expect(snap.wifi.single.modern, isFalse);
      expect(snap.clients.map((c) => c.name), ['Roomba-BLID', 'TV'], reason: 'online first');
      expect(snap.ports.map((p) => p['name']), ['ether1'], reason: 'the bridge is left alone');

      await router.setWifiName(snap.wifi.single, 'Krasi');
      await router.setWifiPassword(snap.wifi.single, 'longpassword');
      await expectLater(router.setWifiPassword(snap.wifi.single, 'short'), throwsA(isA<IntegrationException>()));
      await router.setEnabled('/interface', '*1', false);
      await router.rename('Krasi router');
      await router.keepAddress(snap.clients.first);
      await router.reboot();
      final changes = api.sent.where((s) => !s.first.endsWith('/print') && s.first != '/login').toList();
      expect(changes, [
        ['/interface/wireless/set', '=.id=*3', '=ssid=Krasi'],
        ['/interface/wireless/security-profiles/set', '=.id=*2', '=wpa2-pre-shared-key=longpassword', '=wpa-pre-shared-key=longpassword'],
        ['/interface/set', '=.id=*1', '=disabled=yes'],
        ['/system/identity/set', '=name=Krasi router'],
        ['/ip/dhcp-server/lease/make-static', '=.id=*a'],
        ['/system/reboot'],
      ]);
      await router.os.close();
      await api.close();
    });

    test('logs in to older routers that answer with a challenge', () async {
      final api = await FakeRouterApi.start(challenge: true);
      final os = await RouterOsApi.open(lanContext({8728: api.server.port}), '127.0.0.1', 'admin', 'pw');
      expect(api.sent[1].last, startsWith('=response=00'));
      expect(api.sent[1].last.length, '=response='.length + 34);
      await os.close();
      await api.close();
    });

    test('over REST: found by its web page, added without a login, then read with one', () async {
      final requests = <String>[];
      var authorised = false;
      final client = MockClient((req) async {
        requests.add('${req.method} ${req.url.path} ${req.body}');
        if (req.url.path == '/') return http.Response('<html><title>RouterOS router configuration page</title></html>', 200);
        if (!req.url.path.startsWith('/rest/')) return http.Response('', 404);
        authorised = req.headers['authorization'] == 'Basic ${base64.encode(utf8.encode('admin:pw'))}';
        if (!authorised) return http.Response('{"error":401,"message":"Unauthorized"}', 401);
        return switch (req.url.path) {
          '/rest/system/resource' => http.Response(
              jsonEncode({'uptime': '5h12m3s', 'cpu-load': '1', 'board-name': 'hAP ax2', 'version': '7.15.3 (stable)'}), 200),
          '/rest/system/identity' => http.Response(jsonEncode({'name': 'MikroTik'}), 200),
          '/rest/interface/wifi' => http.Response(
              jsonEncode([
                {'.id': '*1', 'name': 'wifi1', 'configuration.ssid': 'Home', 'channel.band': '5ghz-ax', 'disabled': 'false'},
                {'.id': '*2', 'name': 'wifi2', 'configuration': 'guest-cfg', 'disabled': 'true'},
              ]),
              200),
          '/rest/interface/wifi/configuration' => http.Response(jsonEncode([
                {'.id': '*9', 'name': 'guest-cfg', 'ssid': 'Guests'},
              ]), 200),
          '/rest/ip/dhcp-server/lease' => http.Response(jsonEncode([
                {'.id': '*1', 'address': '192.168.88.5', 'host-name': 'phone', 'status': 'bound', 'dynamic': 'true'},
              ]), 200),
          '/rest/interface' => http.Response(jsonEncode([]), 200),
          '/rest/interface/wifi/set' => http.Response('[]', 200),
          _ => http.Response('{"error":400,"message":"Bad Request","detail":"no such command"}', 400),
        };
      });
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final none = closed.port;
      await closed.close();
      final ctx = lanContext({8291: none, 8728: none}, client: client);
      final protocol = const MikroTikProtocol();

      final router = (await protocol.identify(ctx, '127.0.0.1', const {}))!.single;
      expect(router.kind, DeviceKind.router);
      expect(router.name, 'MikroTik router');
      expect(router.state.readings['Status'], 'Needs its login');

      router.props['password'] = 'pw';
      final state = (await protocol.read(ctx, router))!;
      expect(state.readings['Status'], 'Online');
      expect(state.readings['Uptime'], '5 h 12 min');
      expect(state.readings['Connected'], '1 device');
      expect(state.readings['Wi-Fi'], 'On');
      expect(state.readings['RouterOS'], '7.15.3');

      final again = (await protocol.identify(ctx, '127.0.0.1', {'protocol': 'mikrotik', 'password': 'pw'}))!.single;
      expect(again.name, 'MikroTik', reason: 'named after its identity once logged in');
      expect(again.props['model'], 'MikroTik hAP ax2');
      expect(again.props['api'], 'rest');

      final mt = MikroTik(await MikroTikProtocol.open(ctx, router));
      final wifi = await mt.wifi();
      expect(wifi.map((w) => (w.ssid, w.enabled, w.modern)), [('Home', true, true), ('Guests', false, true)]);
      await mt.setWifiName(wifi.first, 'Home 5G');
      await mt.setWifiPassword(wifi.first, '12345678');
      expect(requests.where((r) => r.startsWith('POST')).map((r) => r.split(' ').skip(1).join(' ')), [
        '/rest/interface/wifi/set {".id":"*1","configuration.ssid":"Home 5G"}',
        '/rest/interface/wifi/set {".id":"*1","security.passphrase":"12345678"}',
      ]);
      await expectLater(mt.os.run('/nope'), throwsA(isA<IntegrationException>().having((e) => e.message, 'message', contains('no such command'))));
    });
  });

  testWidgets('the router screen logs in, then switches Wi-Fi off and renames the router', (tester) async {
    tester.view.physicalSize = const Size(420, 1400) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final posts = <String>[];
    var wifiOn = true;
    final store = HomeStore(
      repository: MemoryHomeRepository(),
      client: MockClient((req) async {
        if (req.headers['authorization'] != 'Basic ${base64.encode(utf8.encode('admin:pw'))}') {
          return http.Response('{"error":401,"message":"Unauthorized"}', 401);
        }
        if (req.method == 'POST') {
          posts.add('${req.url.path} ${req.body}');
          if (req.body.contains('"disabled":"yes"')) wifiOn = false;
          return http.Response('[]', 200);
        }
        return switch (req.url.path) {
          '/rest/system/resource' => http.Response(jsonEncode({'uptime': '1d2h', 'cpu-load': '3', 'board-name': 'hAP ax3', 'version': '7.16'}), 200),
          '/rest/system/identity' => http.Response(jsonEncode({'name': 'Home'}), 200),
          '/rest/interface/wifi' => http.Response(jsonEncode([
                {'.id': '*1', 'name': 'wifi1', 'configuration.ssid': 'Krasi', 'channel.band': '5ghz-ax', 'disabled': '${!wifiOn}'},
              ]), 200),
          '/rest/ip/dhcp-server/lease' => http.Response(jsonEncode([
                {'.id': '*4', 'address': '192.168.88.7', 'host-name': 'Roomba', 'status': 'bound', 'dynamic': 'true'},
              ]), 200),
          '/rest/interface' => http.Response(jsonEncode([
                {'.id': '*2', 'name': 'ether1', 'type': 'ether', 'running': 'true', 'disabled': 'false', 'comment': 'Internet'},
              ]), 200),
          _ => http.Response('{"error":400,"message":"Bad Request","detail":"no such command"}', 400),
        };
      }),
    );
    await tester.runAsync(() async {
      await store.load();
      await store.addNetworkDevice('10.0.0.1', hints: {'protocol': 'mikrotik'});
    });
    final router = store.devices.firstWhere((d) => d.kind == DeviceKind.router);
    expect(router.state.readings['Status'], 'Needs its login');
    expect(store.message.value, contains('enter the router\'s login'));

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(theme: buildAppTheme(Brightness.light), home: RouterScreen(deviceId: router.id)),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byKey(const Key('router-login-form')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('router-password')), 'pw');
    await tester.tap(find.byKey(const Key('router-log-in')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(router.props['password'], 'pw');
    expect(find.byKey(const Key('router-status')), findsOneWidget);
    expect(find.text('Home'), findsNWidgets(2), reason: 'the title and the rename row');
    expect(find.text('Krasi'), findsOneWidget);
    expect(find.text('Roomba'), findsOneWidget);
    expect(find.text('ether1 · Internet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wifi-wifi1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch off'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(posts.last, '/rest/interface/wifi/set {".id":"*1","disabled":"yes"}');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('wifi-wifi1'))).value, isFalse);

    await tester.scrollUntilVisible(find.byKey(const Key('router-rename')), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const Key('router-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Krasi router');
    await tester.tap(find.text('Save'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(posts.last, '/rest/system/identity/set {"name":"Krasi router"}');
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  group('Scan', () {
    test('unknown web devices are kept, and router and robot ports are recognised', () {
      expect(NetworkScanner.guessFromName('Living room thing'), 'lan');
      expect(NetworkScanner.guessFromName('shellyplug-s-1234'), 'shelly');
      expect(guessFromPorts({80, 8291}), 'mikrotik');
      expect(guessDevice(ports: {53, 80, 8291})?.what, 'MikroTik router');
      expect(sweepPorts, containsAll([8883, 8291, 8728]));
      expect(FoundService.protocolLabels['roomba'], 'iRobot Roomba');
      expect(uptimeText('1w2d3h4m5s'), '9 days 3 h');
      expect(uptimeText('45m10s'), '45 min');
    });

    test('a device that only turns knocks down is online, and one with a web page can open it', () async {
      final closed = await closedPortsFor(GenericProtocol.ports);
      final ctx = lanContext(closed);
      final d = (await const GenericProtocol().identify(ctx, '127.0.0.1', {'name': 'Phone', 'mac': 'aa:bb:cc:dd:ee:ff'}))!.single;
      expect(d.state.readings['Status'], 'Online', reason: 'refused means it is there');
      expect(d.props['web'], isNull);
      expect(d.props['mac'], 'aa:bb:cc:dd:ee:ff');
      expect((await const GenericProtocol().read(ctx, d))!.readings['Status'], 'Online');

      final web = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      web.listen((c) => c.destroy());
      final withWeb = (await const GenericProtocol().identify(lanContext({...closed, 80: web.port}), '127.0.0.1', const {}))!.single;
      expect(withWeb.props['web'], 'http://127.0.0.1/');
      expect(GenericProtocol.webPage('10.0.0.2', [8443]), 'https://10.0.0.2:8443/');
      await web.close();
    });
  });
}

/// Local ports that refuse connections, standing in for [standard] ports.
Future<Map<int, int>> closedPortsFor(Iterable<int> standard) async {
  final out = <int, int>{};
  for (final p in standard) {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    out[p] = s.port;
    await s.close();
  }
  return out;
}
