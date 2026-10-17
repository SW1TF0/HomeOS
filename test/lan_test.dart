import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/lan/cast.dart';
import 'package:smartmenukj/integrations/lan/lan_driver.dart';
import 'package:smartmenukj/integrations/lan/lan_protocol.dart';
import 'package:smartmenukj/integrations/lan/plugs.dart';
import 'package:smartmenukj/integrations/lan/upnp.dart';
import 'package:smartmenukj/integrations/lan/wol.dart';
import 'package:smartmenukj/integrations/network_scan.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

/// A fake device on this machine: an HTTP server whose handler sees every request.
Future<HttpServer> fakeHttp(FutureOr<void> Function(HttpRequest req, String body) handle) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await utf8.decodeStream(req);
    await handle(req, body);
    await req.response.close();
  });
  return server;
}

LanDriver lanDriver(Map<int, int> ports, {http.Client? client}) => LanDriver(
      IntegrationConfig(id: 'lan', type: 'lan', name: 'Network devices'),
      client ?? http.Client(),
      portMap: ports,
      allowTls: false,
    );

/// Ports that nothing listens on, so protocols that are not under test fail fast.
Future<Map<int, int>> closedPorts(Iterable<int> standard) async {
  final out = <int, int>{};
  for (final p in standard) {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    out[p] = s.port;
    await s.close();
  }
  return out;
}

const _allPorts = [80, 443, 8080, 22, 445, 139, 554, 631, 9100, 5000, 8443, 62078, 7000, 1400, 8008, 8009, 8001, 8060, 3000, 3001, 9999, 55443, 49151, 49152, 49153, 49154, 49155];

void main() {
  group('Wake-on-LAN', () {
    test('builds the magic packet', () {
      expect(normalizeMac('AA-BB-CC-dd-ee-ff'), 'aa:bb:cc:dd:ee:ff');
      expect(normalizeMac('nope'), isNull);
      final p = magicPacket('aa:bb:cc:dd:ee:ff');
      expect(p.length, 102);
      expect(p.sublist(0, 6), List.filled(6, 0xff));
      expect(p.sublist(96), [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    });
  });

  group('Valetudo', () {
    test('finds a robot vacuum, reads it and sends it cleaning, beeping and home', () async {
      final puts = <String>[];
      var status = 'docked';
      final server = await fakeHttp((req, body) {
        final path = req.uri.path;
        if (req.method == 'PUT') {
          puts.add('${path.split('/').last} $body');
          if (body.contains('start')) status = 'cleaning';
          return;
        }
        final reply = switch (path) {
          '/api/v2/robot' => {'manufacturer': 'Roborock', 'modelName': 'S5 Max', 'implementation': 'RoborockS5MaxValetudoRobot'},
          '/api/v2/robot/capabilities' => ['BasicControlCapability', 'FanSpeedControlCapability', 'LocateCapability'],
          '/api/v2/robot/capabilities/FanSpeedControlCapability/presets' => ['low', 'medium', 'high', 'max'],
          '/api/v2/robot/state/attributes' => [
            {'__class': 'StatusStateAttribute', 'value': status, 'flag': 'none'},
            {'__class': 'BatteryStateAttribute', 'level': 87, 'flag': status == 'docked' ? 'charging' : 'discharging'},
            {'__class': 'PresetSelectionStateAttribute', 'type': 'fan_speed', 'value': 'high'},
          ],
          _ => null,
        };
        if (reply == null) {
          req.response.statusCode = 404;
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(reply));
        }
      });
      final driver = lanDriver({...await closedPorts(_allPorts), 80: server.port});
      final found = await driver.identify('127.0.0.1', hints: {'protocol': 'valetudo', 'name': 'Valetudo RoborockS5Max QuietBlueFox'});
      final robot = found.devices.single;
      expect(robot.name, 'Roborock S5 Max');
      expect(robot.kind, DeviceKind.vacuum);
      expect(robot.capabilities, {Capability.run, Capability.dock, Capability.locate, Capability.mode});
      expect(robot.modes, ['low', 'medium', 'high', 'max']);
      expect((robot.state.activity, robot.state.battery, robot.state.mode), (Activity.charging, 0.87, 'high'));
      expect(robot.state.readings, isEmpty);
      expect((await driver.identify('127.0.0.1')).devices.single.props['protocol'], 'valetudo', reason: 'found without a hint too');

      await driver.send(robot, const DeviceCommand(mode: 'max', action: DeviceAction.start));
      await driver.send(robot, const DeviceCommand(action: DeviceAction.locate));
      await driver.send(robot, const DeviceCommand(action: DeviceAction.dock));
      expect(puts, [
        'preset {"name":"max"}',
        'BasicControlCapability {"action":"start"}',
        'LocateCapability {"action":"locate"}',
        'BasicControlCapability {"action":"home"}',
      ]);
      expect((await driver.refreshAll([robot]))[robot.id]!.activity, Activity.running);
      await server.close(force: true);
    });
  });

  group('Roku', () {
    test('identifies a Roku TV and presses keys', () async {
      final presses = <String>[];
      final server = await fakeHttp((req, body) {
        if (req.uri.path == '/query/device-info') {
          req.response.write('<device-info><user-device-name>Living room Roku</user-device-name>'
              '<model-name>TCL 55S</model-name><is-tv>true</is-tv><power-mode>PowerOn</power-mode></device-info>');
        } else if (req.uri.path.startsWith('/keypress/')) {
          presses.add(req.uri.pathSegments.last);
        }
      });
      final ports = {...await closedPorts(_allPorts), 8060: server.port};
      final driver = lanDriver(ports);
      final match = await driver.identify('127.0.0.1');
      final tv = match.devices.single;
      expect(tv.name, 'Living room Roku');
      expect(tv.kind, DeviceKind.media);
      expect(tv.has(Capability.remote), isTrue);
      expect(tv.state.on, isTrue);
      await driver.send(tv, const DeviceCommand(key: RemoteKey.volumeUp));
      await driver.send(tv, const DeviceCommand(key: RemoteKey.ok));
      await driver.send(tv, const DeviceCommand(on: false));
      expect(presses, ['VolumeUp', 'Select', 'PowerOff']);
      await server.close(force: true);
    });
  });

  group('Samsung', () {
    test('pairs over the websocket, keeps the token and sends keys', () async {
      final keys = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/api/v2/') {
          req.response
            ..write(jsonEncode({
              'device': {'name': '[TV] Samsung Q60', 'modelName': 'QE55Q60', 'wifiMac': 'aa:bb:cc:00:11:22', 'PowerState': 'on'},
            }))
            ..close();
        } else if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.add(jsonEncode({
            'event': 'ms.channel.connect',
            'data': {'token': '12345678'}
          }));
          ws.listen((m) => keys.add((jsonDecode(m as String) as Map)['params']['DataOfCmd'] as String));
        } else {
          req.response
            ..statusCode = 404
            ..close();
        }
      });
      final driver = lanDriver({...await closedPorts(_allPorts), 8001: server.port});
      final tv = (await driver.identify('127.0.0.1', hints: {'protocol': 'samsung'})).devices.single;
      expect(tv.name, '[TV] Samsung Q60');
      expect(tv.props['mac'], 'aa:bb:cc:00:11:22');
      expect(await driver.setUp(tv), isNull);
      expect(tv.props['token'], '12345678');
      await driver.send(tv, const DeviceCommand(key: RemoteKey.volumeUp));
      await driver.send(tv, const DeviceCommand(key: RemoteKey.back));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(keys, ['KEY_VOLUP', 'KEY_RETURN']);
      await driver.stop();
      await server.close(force: true);
    });
  });

  group('Sony', () {
    test('reads power and volume, sends the pre-shared key and IRCC codes', () async {
      final calls = <String>[];
      final server = await fakeHttp((req, body) {
        final psk = req.headers.value('X-Auth-PSK');
        if (req.uri.path == '/sony/IRCC') {
          calls.add('ircc ${RegExp(r'<IRCCCode>(.*)</IRCCCode>').firstMatch(body)!.group(1)} $psk');
          return;
        }
        final j = jsonDecode(body) as Map;
        calls.add('${j['method']} $psk');
        final result = switch (j['method']) {
          'getInterfaceInformation' => [
              {'productCategory': 'tv', 'modelName': 'KD-55X85J'}
            ],
          'getPowerStatus' => [
              {'status': 'active'}
            ],
          'getVolumeInformation' => [
              [
                {'target': 'speaker', 'volume': 25, 'mute': false, 'maxVolume': 100}
              ]
            ],
          _ => [],
        };
        req.response.write(jsonEncode({'result': result, 'id': 1}));
      });
      final driver = lanDriver({...await closedPorts(_allPorts), 80: server.port});
      final tv = (await driver.identify('127.0.0.1', hints: {'protocol': 'sony'})).devices.single;
      expect(tv.name, 'Sony KD-55X85J');
      expect(tv.has(Capability.volume), isTrue);
      tv.props['psk'] = '4321';
      final st = await driver.refresh(tv);
      expect(st!.on, isTrue);
      expect(st.volume, closeTo(0.25, 0.001));
      await driver.send(tv, const DeviceCommand(key: RemoteKey.home));
      await driver.send(tv, const DeviceCommand(volume: 0.4));
      expect(calls, contains('ircc AAAAAQAAAAEAAABgAw== 4321'));
      expect(calls.last, 'setAudioVolume 4321');
      await server.close(force: true);
    });
  });

  group('Google Cast', () {
    test('protobuf messages round trip', () {
      final bytes = encodeCastMessage('sender-0', 'receiver-0', CastChannel.receiverNs, '{"type":"GET_STATUS"}');
      final m = decodeCastMessage(bytes);
      expect(m.source, 'sender-0');
      expect(m.destination, 'receiver-0');
      expect(m.namespace, CastChannel.receiverNs);
      expect(m.payload, '{"type":"GET_STATUS"}');
    });

    test('reads and sets the volume', () async {
      var level = 0.3;
      final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sock.listen((client) {
        final buf = BytesBuilder();
        client.listen((data) {
          buf.add(data);
          var b = buf.toBytes();
          while (b.length >= 4) {
            final len = ByteData.sublistView(b, 0, 4).getUint32(0);
            if (b.length < 4 + len) break;
            final m = decodeCastMessage(b.sublist(4, 4 + len));
            b = b.sublist(4 + len);
            final p = jsonDecode(m.payload) as Map;
            if (m.namespace != CastChannel.receiverNs) continue;
            if (p['type'] == 'SET_VOLUME') level = (p['volume']['level'] as num).toDouble();
            final reply = encodeCastMessage('receiver-0', m.source, m.namespace, jsonEncode({
              'type': 'RECEIVER_STATUS',
              'requestId': p['requestId'],
              'status': {
                'volume': {'level': level, 'muted': false},
                'applications': [
                  {'displayName': 'YouTube', 'isIdleScreen': false, 'transportId': 't1', 'sessionId': 's1'}
                ],
              },
            }));
            final len4 = ByteData(4)..setUint32(0, reply.length);
            client.add([...len4.buffer.asUint8List(), ...reply]);
          }
          buf.clear();
          buf.add(b);
        });
      });
      final eureka = await fakeHttp((req, _) => req.response.write(jsonEncode({
            'name': 'Bedroom TV',
            'device_info': {'model_name': 'Chromecast'}
          })));
      final driver = lanDriver({...await closedPorts(_allPorts), 8008: eureka.port, 8009: sock.port});
      final cast = (await driver.identify('127.0.0.1', hints: {'protocol': 'cast'})).devices.single;
      expect(cast.name, 'Bedroom TV');
      expect(cast.has(Capability.onOff), isFalse, reason: 'Cast cannot switch a TV on');
      final st = await driver.refresh(cast);
      expect(st!.volume, closeTo(0.3, 0.001));
      expect(st.readings['Playing'], 'YouTube');
      final after = await driver.send(cast, const DeviceCommand(volume: 0.6));
      expect(after!.volume, closeTo(0.6, 0.001));
      expect(level, closeTo(0.6, 0.001));
      await sock.close();
      await eureka.close(force: true);
    });
  });

  group('Kasa', () {
    test('cipher round trips', () {
      const json = '{"system":{"get_sysinfo":{}}}';
      expect(kasaDecrypt(kasaEncrypt(json)), json);
    });

    test('imports each outlet of a power strip and switches one', () async {
      final requests = <Map>[];
      final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sock.listen((client) {
        final buf = BytesBuilder();
        client.listen((data) {
          buf.add(data);
          final b = buf.toBytes();
          if (b.length < 4) return;
          final len = ByteData.sublistView(b, 0, 4).getUint32(0);
          if (b.length < 4 + len) return;
          final req = jsonDecode(kasaDecrypt(b.sublist(4, 4 + len))) as Map;
          requests.add(req);
          final reply = req['system']?['get_sysinfo'] != null
              ? {
                  'system': {
                    'get_sysinfo': {
                      'alias': 'Strip',
                      'model': 'HS300',
                      'mic_type': 'IOT.SMARTPLUGSWITCH',
                      'mac': '11:22:33:44:55:66',
                      'children': [
                        {'id': 'ABC00', 'alias': 'Lamp', 'state': 1},
                        {'id': 'ABC01', 'alias': 'Fan', 'state': 0},
                      ],
                    }
                  }
                }
              : {
                  'system': {
                    'set_relay_state': {'err_code': 0}
                  }
                };
          final enc = kasaEncrypt(jsonEncode(reply));
          final l = ByteData(4)..setUint32(0, enc.length);
          client.add([...l.buffer.asUint8List(), ...enc]);
        });
      });
      final driver = lanDriver({...await closedPorts(_allPorts), 9999: sock.port});
      final outlets = (await driver.identify('127.0.0.1', hints: {'protocol': 'kasa'})).devices;
      expect(outlets.map((d) => d.name), ['Lamp', 'Fan']);
      expect(outlets.first.state.on, isTrue);
      await driver.send(outlets[1], const DeviceCommand(on: true));
      expect(requests.last['context']['child_ids'], ['ABC01']);
      expect(requests.last['system']['set_relay_state']['state'], 1);
      expect((await driver.refresh(outlets[1]))!.on, isFalse);
      await sock.close();
    });
  });

  group('Yeelight', () {
    test('reads a bulb and switches it', () async {
      final calls = <String>[];
      final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sock.listen((client) {
        client.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          final j = jsonDecode(line) as Map;
          calls.add('${j['method']} ${j['params']}');
          final result = j['method'] == 'get_prop' ? ['on', '50', '4000', '0', '2', 'Desk'] : ['ok'];
          client.write('${jsonEncode({'id': j['id'], 'result': result})}\r\n');
        });
      });
      final driver = lanDriver({...await closedPorts(_allPorts), 55443: sock.port});
      final bulb = (await driver.identify('127.0.0.1', hints: {'protocol': 'yeelight'})).devices.single;
      expect(bulb.name, 'Desk');
      expect(bulb.state.brightness, 0.5);
      expect(bulb.state.colorTempK, 4000);
      await driver.send(bulb, const DeviceCommand(on: false));
      expect(calls.last, 'set_power [off, smooth, 300]');
      await sock.close();
    });
  });

  group('UPnP', () {
    test('reads SSDP replies and device descriptions', () {
      final h = parseSsdpHeaders('HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: http://192.168.1.30:7676/smp_15_\r\nSERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\nST: upnp:rootdevice\r\n\r\n');
      expect(h['location'], 'http://192.168.1.30:7676/smp_15_');
      final desc = UpnpDescription.parse('''
<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>[TV] Living room</friendlyName><manufacturer>Samsung Electronics</manufacturer><modelName>QE55</modelName>
<serviceList><service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/RenderingControl1</controlURL></service></serviceList>
</device></root>''', Uri.parse(h['location']!));
      expect(desc.friendlyName, '[TV] Living room');
      expect(desc.protocolGuess(server: h['server']!), 'samsung');
      expect(desc.serviceUrl('RenderingControl'), 'http://192.168.1.30:7676/upnp/control/RenderingControl1');
    });

    test('sets the volume of a media renderer', () async {
      final actions = <String>[];
      var volume = 12;
      final server = await fakeHttp((req, body) {
        final action = req.headers.value('SOAPACTION')!.split('#').last.replaceAll('"', '');
        actions.add(action);
        if (action == 'SetVolume') volume = int.parse(RegExp(r'<DesiredVolume>(\d+)').firstMatch(body)!.group(1)!);
        req.response.write('<s:Envelope><s:Body><u:${action}Response>'
            '<CurrentVolume>$volume</CurrentVolume><CurrentMute>0</CurrentMute></u:${action}Response></s:Body></s:Envelope>');
      });
      final rc = 'http://127.0.0.1:${server.port}/rc';
      final driver = lanDriver(await closedPorts(_allPorts));
      final speaker = (await driver.identify('127.0.0.1', hints: {'protocol': 'upnp', 'rendering': rc, 'name': 'Kitchen speaker'}))
          .devices
          .single;
      expect(speaker.name, 'Kitchen speaker');
      expect((await driver.refresh(speaker))!.volume, 0.12);
      await driver.send(speaker, const DeviceCommand(key: RemoteKey.volumeUp));
      expect(volume, 14);
      await server.close(force: true);
    });
  });

  test('anything else becomes an online / offline device', () async {
    final open = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    open.listen((c) => c.destroy());
    final driver = lanDriver({...await closedPorts(_allPorts), 631: open.port});
    final match = await driver.identify('127.0.0.1', hints: {'name': 'Office printer', 'service': '_ipp._tcp'});
    final d = match.devices.single;
    expect(d.name, 'Office printer');
    expect(d.props['protocol'], 'generic');
    expect(d.state.readings['Status'], 'Online');
    await expectLater(driver.send(d, const DeviceCommand(on: true)), throwsA(isA<Exception>()),
        reason: 'no MAC yet, so it cannot be woken');
    await open.close();
  });

  group('Store', () {
    test('adds a TV by address and its power key turns it off', () async {
      final calls = <String>[];
      final store = HomeStore(
        repository: MemoryHomeRepository(),
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          if (req.url.path == '/query/device-info') {
            return http.Response('<device-info><user-device-name>Roku TV</user-device-name><is-tv>true</is-tv>'
                '<power-mode>PowerOn</power-mode></device-info>', 200);
          }
          return http.Response('', 200);
        }),
      );
      await store.load();
      final added = await store.addNetworkDevice('http://10.9.9.8/', hints: {'protocol': 'roku'});
      final tv = added.single;
      expect(tv.name, 'Roku TV');
      expect(store.lanIntegration.setting('hosts'), '10.9.9.8');
      await store.command(tv, const DeviceCommand(key: RemoteKey.power));
      expect(tv.state.on, isFalse);
      expect(calls.last, 'POST /keypress/PowerOff');
      expect(await store.addNetworkDevice('10.9.9.8', hints: {'protocol': 'roku'}), isEmpty, reason: 'already added');
      store.dispose();
    });

    test('a Shelly typed in by address goes to the Shelly connection', () async {
      final store = HomeStore(
        repository: MemoryHomeRepository(),
        client: MockClient((req) async => req.url.path == '/shelly'
            ? http.Response(jsonEncode({'type': 'SHSW-1', 'mac': 'AABBCC'}), 200)
            : http.Response('nope', 404)),
      );
      await store.load();
      await store.addNetworkDevice('10.9.9.7');
      final shelly = store.integrations.where((i) => i.type == 'shelly').single;
      expect(shelly.setting('hosts'), '10.9.9.7');
      store.dispose();
    });
  });

  test('scan results keep the best guess for each address', () {
    const generic = FoundService(name: '10.0.0.5', host: '10.0.0.5', port: 8001, service: 'port', integrationType: 'lan');
    const tv = FoundService(
        name: '[TV] Samsung', host: '10.0.0.5', port: 7676, service: 'UPnP', integrationType: 'lan', hints: {'protocol': 'samsung'});
    expect(tv.key, generic.key);
    expect(tv.rank, greaterThan(generic.rank));
    expect(tv.address, '10.0.0.5');
  });

  test('LanContext maps ports', () {
    final ctx = LanContext(client: http.Client(), make: lanDriver(const {}).makeDevice, portMap: {80: 8080});
    expect(ctx.url('h', 80, '/x').toString(), 'http://h:8080/x');
  });
}
