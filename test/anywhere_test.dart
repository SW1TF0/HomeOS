import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/home_assistant.dart';
import 'package:smartmenukj/integrations/imou.dart';
import 'package:smartmenukj/integrations/integration.dart';
import 'package:smartmenukj/integrations/shelly.dart';
import 'package:smartmenukj/integrations/shelly_cloud.dart';
import 'package:smartmenukj/integrations/tuya.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

IntegrationConfig cfg(String type, Map<String, dynamic> settings) =>
    IntegrationConfig(id: type, type: type, name: type, settings: settings);

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// The device at home, for routing tests.
class FakeHub implements RemoteControl {
  final sent = <String>[];
  @override
  bool get online => true;
  @override
  DeviceState? stateOf(String deviceId) => null;
  @override
  Future<void> send(Device device, DeviceCommand command) async => sent.add(device.name);
}

void main() {
  setUp(() => ShellyCloud.gap = Duration.zero);

  group('Home Assistant outside address', () {
    test('uses the outside address when the home one does not answer, and goes there first while away', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add(req.url.host);
        if (req.url.host == '192.168.1.5') throw http.ClientException('no route');
        if (req.url.path == '/api/states') {
          return json([
            {'entity_id': 'light.porch', 'state': 'on', 'attributes': {'friendly_name': 'Porch', 'supported_color_modes': ['onoff']}},
          ]);
        }
        return json([]);
      });
      final ha = HomeAssistantDriver(
          cfg('homeassistant', {'url': 'http://192.168.1.5:8123', 'token': 't', 'remote_url': 'https://abc.ui.nabu.casa/'}),
          client);
      final devices = await ha.discover();
      expect(devices.single.name, 'Porch');
      expect(calls, ['192.168.1.5', 'abc.ui.nabu.casa']);
      expect(ha.baseUrl, 'https://abc.ui.nabu.casa');
      expect(ha.reachesAnywhere(devices.single), isTrue);

      calls.clear();
      await ha.send(devices.single, const DeviceCommand(on: false));
      expect(calls, ['abc.ui.nabu.casa'], reason: 'the address that answered goes first for a while');

      final away = HomeAssistantDriver(
          cfg('homeassistant', {'url': 'http://192.168.1.5:8123', 'token': 't', 'remote_url': 'https://abc.ui.nabu.casa'}),
          client)
        ..away = true;
      calls.clear();
      await away.refreshAll(devices);
      expect(calls, ['abc.ui.nabu.casa']);
    });

    test('a home address only answers at home, a public one anywhere', () {
      final d = Device(id: 'x', name: 'x', kind: DeviceKind.light, integrationId: 'ha', externalId: 'light.x');
      bool anywhere(String url) => HomeAssistantDriver(cfg('homeassistant', {'url': url, 'token': 't'}), MockClient((_) async => json([])))
          .reachesAnywhere(d);
      expect(anywhere('http://192.168.1.5:8123'), isFalse);
      expect(anywhere('homeassistant.local:8123'), isFalse);
      expect(anywhere('http://10.0.0.2'), isFalse);
      expect(anywhere('https://home.example.com'), isTrue);
      expect(anywhere('https://xyz.ui.nabu.casa'), isTrue);
    });
  });

  group('Shelly Cloud', () {
    /// A fake Shelly cloud plus, optionally, one Shelly Plus on the home network.
    ({http.Client client, List<String> calls, List<String> bodies}) fake({bool lanUp = true, bool cloudOn = true}) {
      final calls = <String>[];
      final bodies = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.host}${req.url.path}');
        if (req.body.isNotEmpty) bodies.add(req.body);
        if (req.url.host == '10.0.0.5') {
          if (!lanUp) throw http.ClientException('timed out');
          return switch (req.url.path) {
            '/shelly' => json({'name': 'Hall', 'gen': 2, 'mac': 'A8032AB12345'}),
            '/rpc/Shelly.GetStatus' => json({'switch:0': {'output': true}, 'sys': {'mac': 'A8032AB12345'}}),
            '/rpc/Shelly.GetConfig' => json({'switch:0': {'name': 'Hall light'}}),
            _ => json({}),
          };
        }
        if (req.url.host != 'shelly-49-eu.shelly.cloud') return http.Response('', 404);
        if (req.url.path.startsWith('/v2/') && req.url.queryParameters['auth_key'] != 'KEY') return http.Response('', 401);
        return switch (req.url.path) {
          '/device/all_status' => req.bodyFields['auth_key'] == 'KEY'
              ? json({
                  'isok': true,
                  'data': {
                    'devices_status': {
                      'a8032ab12345': {
                        '_dev_info': {'id': 'a8032ab12345', 'gen': 'G2', 'online': true},
                        'switch:0': {'output': true},
                        'sys': {'mac': 'A8032AB12345'},
                      },
                      'c45bbe6f00aa': {
                        '_dev_info': {'id': 'c45bbe6f00aa', 'gen': 'G2', 'online': true},
                        'switch:0': {'output': false, 'apower': 3.5},
                        'cover:0': {'current_pos': 20},
                        'sys': {'mac': 'C45BBE6F00AA'},
                      },
                      '98f4ab112233': {
                        '_dev_info': {'id': '98f4ab112233', 'gen': 'G1', 'code': 'SHSW-1', 'online': false},
                        'relays': [
                          {'ison': true}
                        ],
                        'mac': '98F4AB112233',
                      },
                    },
                  },
                })
              : json({'isok': false, 'errors': {'wrong_key': 'x'}}),
          '/interface/device/get_all_lists' => json({
              'isok': true,
              'data': {
                'devices': {
                  'c45bbe6f00aa': {'name': 'Garden'},
                },
              },
            }),
          '/v2/devices/api/get' => json([
              for (final id in (jsonDecode(req.body) as Map)['ids'] as List)
                {
                  'id': id,
                  'online': cloudOn ? 1 : 0,
                  'status': id == 'a8032ab12345'
                      ? {'switch:0': {'output': false}}
                      : {'switch:0': {'output': true}, 'cover:0': {'current_pos': 60}},
                },
            ]),
          '/v2/devices/api/set/switch' || '/v2/devices/api/set/cover' => http.Response('', 200),
          _ => http.Response('', 404),
        };
      });
      return (client: client, calls: calls, bodies: bodies);
    }

    test('adds the account\'s devices without addresses and links the ones on the home network', () async {
      final f = fake();
      final d = ShellyDriver(
          cfg('shelly', {'hosts': '10.0.0.5', 'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'KEY'}), f.client);
      final devices = await d.discover();
      final hall = devices.firstWhere((e) => e.name == 'Hall light');
      expect(hall.props['host'], '10.0.0.5');
      expect(hall.props['cloudId'], 'a8032ab12345', reason: 'the same Shelly in the cloud, not added twice');
      expect(devices.where((e) => e.props['cloudId'] == 'a8032ab12345'), hasLength(1));
      final garden = devices.firstWhere((e) => e.name == 'Garden');
      expect(garden.props['host'], isNull);
      expect(garden.state.on, isFalse);
      expect(devices.firstWhere((e) => e.kind == DeviceKind.cover).state.position, closeTo(0.2, 1e-9));
      final old = devices.firstWhere((e) => e.name == 'Shelly SHSW-1');
      expect(old.state.reachable, isFalse);
      expect(devices.every(d.reachesAnywhere), isTrue);

      // A device only in the cloud is always switched through it.
      await d.send(garden, const DeviceCommand(on: true));
      expect(f.calls.last, 'POST shelly-49-eu.shelly.cloud/v2/devices/api/set/switch');
      expect(jsonDecode(f.bodies.last), {'id': 'c45bbe6f00aa', 'channel': 0, 'on': true});
    });

    test('away from home every Shelly goes through the cloud, and back home through the Wi-Fi', () async {
      final f = fake();
      final d = ShellyDriver(
          cfg('shelly', {'hosts': '10.0.0.5', 'cloud_server': 'https://shelly-49-eu.shelly.cloud/', 'cloud_key': 'KEY'}),
          f.client);
      final devices = await d.discover();
      final hall = devices.firstWhere((e) => e.name == 'Hall light');
      final cover = devices.firstWhere((e) => e.kind == DeviceKind.cover);
      d.away = true;
      f.calls.clear();
      final states = await d.refreshAll([hall, cover]);
      expect(f.calls.where((c) => c.contains('10.0.0.5')), isEmpty);
      expect(states[hall.id]!.on, isFalse);
      expect(states[cover.id]!.position, closeTo(0.6, 1e-9));
      await d.send(hall, const DeviceCommand(on: true));
      await d.send(cover, const DeviceCommand(position: 0.3));
      expect(jsonDecode(f.bodies.last), {'id': 'c45bbe6f00aa', 'channel': 0, 'position': 30});
      expect(f.calls.where((c) => c.contains('10.0.0.5')), isEmpty);

      d.away = false;
      await d.send(hall, const DeviceCommand(on: false));
      expect(f.calls.last, 'GET 10.0.0.5/rpc/Switch.Set');
    });

    test('a Shelly that stops answering at home is switched through the cloud', () async {
      final up = fake();
      final d = ShellyDriver(
          cfg('shelly', {'hosts': '10.0.0.5', 'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'KEY'}), up.client);
      final hall = (await d.discover()).firstWhere((e) => e.name == 'Hall light');
      final down = fake(lanUp: false);
      final later = ShellyDriver(
          cfg('shelly', {'hosts': '10.0.0.5', 'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'KEY'}), down.client);
      await later.send(hall, const DeviceCommand(on: true));
      expect(down.calls, ['GET 10.0.0.5/rpc/Switch.Set', 'POST shelly-49-eu.shelly.cloud/v2/devices/api/set/switch']);
      await later.send(hall, const DeviceCommand(on: false));
      expect(down.calls.last, 'POST shelly-49-eu.shelly.cloud/v2/devices/api/set/switch');
      expect(down.calls.where((c) => c.contains('10.0.0.5')), hasLength(1), reason: 'it waits a while before trying home again');
    });

    test('without a cloud key, nothing changes', () async {
      final f = fake();
      final d = ShellyDriver(cfg('shelly', {'hosts': '10.0.0.5'}), f.client)..away = true;
      final devices = await d.discover();
      expect(devices.single.props['mac'], 'a8032ab12345');
      expect(d.reachesAnywhere(devices.single), isFalse);
      expect(f.calls.where((c) => c.contains('shelly.cloud')), isEmpty);
      expect(ShellyDriver(cfg('shelly', {}), f.client).discover(), throwsA(isA<IntegrationException>()));
    });

    test('a wrong key is explained', () async {
      final d = ShellyDriver(cfg('shelly', {'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'nope'}), fake().client);
      expect(d.discover(), throwsA(isA<IntegrationException>()));
    });
  });

  group('Tuya', () {
    test('signs requests the way Tuya documents', () {
      expect(
          TuyaCloud.sign(
              accessId: 'abc123', secret: 'secretXYZ', t: '1700000000000', method: 'GET', path: '/v1.0/token', query: {'grant_type': '1'}),
          '6EA0AEEDF9C3F5727DD63487BF07A009337F4423693E7FBA08C93DD1F4E7E4D9');
      expect(
          TuyaCloud.sign(
            accessId: 'abc123',
            secret: 'secretXYZ',
            token: 'tok456',
            t: '1700000000123',
            method: 'POST',
            path: '/v1.0/iot-03/devices/dev1/commands',
            body: '{"commands":[{"code":"switch_1","value":false}]}',
          ),
          '4DD91D338395C96E0E65455578F28200BC76298CB9182E47CE2E3914D3F8C07D');
      expect(
          TuyaCloud.sign(
            accessId: 'abc123',
            secret: 'secretXYZ',
            token: 'tok456',
            t: '1700000000123',
            method: 'GET',
            path: '/v1.0/iot-01/associated-users/devices',
            query: {'size': '50', 'last_row_key': 'k2'},
          ),
          'EE58EC09F942FDEDC417CD6133F39A88069AB49A385AA63BDBDCE5F18577A892');
      expect(tuyaEndpoint('Central Europe'), 'https://openapi.tuyaeu.com');
      expect(tuyaEndpoint('western europe'), 'https://openapi-weaz.tuyaeu.com');
      expect(tuyaEndpoint('us-e'), 'https://openapi-ueaz.tuyaus.com');
      expect(tuyaEndpoint(''), 'https://openapi.tuyaeu.com');
    });

    /// A fake Tuya cloud that checks every signature and keeps the commands it was sent.
    ({http.Client client, List<Map> commands, List<String> paths}) fake({List<int> expireTokens = const []}) {
      final commands = <Map>[];
      final paths = <String>[];
      var tokens = 0;
      final functions = {
        'plug1': [
          {'code': 'switch_1', 'type': 'Boolean', 'values': '{}'},
          {'code': 'switch_2', 'type': 'Boolean', 'values': '{}'},
          {'code': 'countdown_1', 'type': 'Integer', 'values': '{"min":0,"max":86400}'},
        ],
        'bulb1': [
          {'code': 'switch_led', 'type': 'Boolean', 'values': '{}'},
          {'code': 'work_mode', 'type': 'Enum', 'values': '{"range":["white","colour","scene","music"]}'},
          {'code': 'bright_value_v2', 'type': 'Integer', 'values': '{"min":10,"max":1000,"scale":0,"step":1}'},
          {'code': 'temp_value_v2', 'type': 'Integer', 'values': '{"min":0,"max":1000,"scale":0,"step":1}'},
          {'code': 'colour_data_v2', 'type': 'Json', 'values': '{"h":{"min":0,"max":360},"s":{"min":0,"max":1000}}'},
        ],
        'curtain1': [
          {'code': 'control', 'type': 'Enum', 'values': '{"range":["open","stop","close"]}'},
          {'code': 'percent_control', 'type': 'Integer', 'values': '{"min":0,"max":100}'},
        ],
        'thermo1': [
          {'code': 'switch', 'type': 'Boolean', 'values': '{}'},
          {'code': 'temp_set', 'type': 'Integer', 'values': '{"min":50,"max":350,"scale":1,"step":5}'},
          {'code': 'mode', 'type': 'Enum', 'values': '{"range":["auto","manual","holiday"]}'},
        ],
      };
      final devices = [
        {
          'id': 'plug1', 'name': 'Desk strip', 'category': 'pc', 'online': true,
          'status': [
            {'code': 'switch_1', 'value': true},
            {'code': 'switch_2', 'value': false},
            {'code': 'cur_power', 'value': 125},
          ],
        },
        {
          'id': 'bulb1', 'name': 'Bedroom bulb', 'category': 'dj', 'online': true,
          'status': [
            {'code': 'switch_led', 'value': true},
            {'code': 'work_mode', 'value': 'white'},
            {'code': 'bright_value_v2', 'value': 505},
            {'code': 'temp_value_v2', 'value': 0},
          ],
        },
        {
          'id': 'curtain1', 'name': 'Living curtain', 'category': 'cl', 'online': true,
          'status': [
            {'code': 'control', 'value': 'stop'},
            {'code': 'percent_control', 'value': 40},
          ],
        },
        {
          'id': 'thermo1', 'name': 'Radiator', 'category': 'wk', 'online': false,
          'status': [
            {'code': 'switch', 'value': true},
            {'code': 'temp_set', 'value': 215},
            {'code': 'temp_current', 'value': 198},
          ],
        },
        {
          'id': 'smoke1', 'name': 'Hall smoke alarm', 'category': 'ywbj', 'online': true,
          'status': [
            {'code': 'smoke_sensor_status', 'value': 'alarm'},
            {'code': 'battery_percentage', 'value': 80},
          ],
        },
        {
          'id': 'th1', 'name': 'Kids room', 'category': 'wsdcg', 'online': true,
          'status': [
            {'code': 'va_temperature', 'value': 224},
            {'code': 'va_humidity', 'value': 51},
          ],
        },
      ];
      final client = MockClient((req) async {
        expect(req.url.host, 'openapi.tuyaeu.com');
        final token = req.headers['access_token'] ?? '';
        final q = req.url.queryParameters;
        expect(
            req.headers['sign'],
            TuyaCloud.sign(
                accessId: 'AID', secret: 'SECRET', token: token, t: req.headers['t']!, method: req.method, path: req.url.path, query: q, body: req.body),
            reason: 'every request is signed');
        paths.add(req.url.path);
        if (req.url.path == '/v1.0/token') {
          tokens++;
          return json({'success': true, 'result': {'access_token': 'TOKEN$tokens', 'expire_time': 7200, 'uid': 'u1'}, 't': 1});
        }
        if (token != 'TOKEN$tokens' || expireTokens.contains(paths.length)) {
          return json({'success': false, 'code': 1010, 'msg': 'token invalid'});
        }
        if (req.url.path == '/v1.0/iot-01/associated-users/devices') {
          return json({'success': true, 'result': {'devices': devices, 'has_more': false, 'last_row_key': ''}});
        }
        final fn = RegExp(r'^/v1\.0/iot-03/devices/(\w+)/functions$').firstMatch(req.url.path);
        if (fn != null) {
          return json({'success': true, 'result': {'category': '', 'functions': functions[fn.group(1)] ?? []}});
        }
        final cmd = RegExp(r'^/v1\.0/iot-03/devices/(\w+)/commands$').firstMatch(req.url.path);
        if (cmd != null) {
          commands.add({'id': cmd.group(1), ...jsonDecode(req.body) as Map});
          return json({'success': true, 'result': true});
        }
        return json({'success': false, 'code': 1108, 'msg': 'uri path invalid'});
      });
      return (client: client, commands: commands, paths: paths);
    }

    TuyaDriver driver(http.Client client) =>
        TuyaDriver(cfg('tuya', {'access_id': 'AID', 'access_secret': 'SECRET', 'region': 'eu'}), client);

    test('lists plugs, lights, curtains, thermostats and sensors of the linked app', () async {
      final f = fake();
      final tuya = driver(f.client);
      final devices = await tuya.discover();
      Device named(String n) => devices.firstWhere((d) => d.name == n);
      expect(devices.map((d) => d.name), [
        'Desk strip 1', 'Desk strip 2', 'Bedroom bulb', 'Living curtain', 'Radiator', 'Hall smoke alarm', 'Kids room',
      ]);
      expect(named('Desk strip 1').kind, DeviceKind.outlet);
      expect(named('Desk strip 1').state.on, isTrue);
      expect(named('Desk strip 1').state.readings['Power'], '12.5 W');
      expect(named('Desk strip 2').state.on, isFalse);
      final bulb = named('Bedroom bulb');
      expect(bulb.capabilities, containsAll([Capability.brightness, Capability.colorTemp, Capability.color]));
      expect(bulb.state.brightness, closeTo(0.5, 0.01));
      expect(bulb.state.colorTempK, 2700);
      expect(named('Living curtain').state.position, closeTo(0.4, 1e-9));
      final radiator = named('Radiator');
      expect(radiator.kind, DeviceKind.climate);
      expect(radiator.state.reachable, isFalse);
      expect(named('Hall smoke alarm').state.readings['Smoke'], 'Smoke!');
      expect(named('Kids room').state.readings, {'Temperature': '22.4 °C', 'Humidity': '51 %'});
      expect(devices.every(tuya.reachesAnywhere), isTrue);
      expect(f.paths.where((p) => p == '/v1.0/token'), hasLength(1), reason: 'one token for every call');
    });

    test('switches, dims, colours, moves curtains and sets thermostats', () async {
      final f = fake();
      final tuya = driver(f.client);
      final devices = await tuya.discover();
      Device named(String n) => devices.firstWhere((d) => d.name == n);
      await tuya.send(named('Desk strip 2'), const DeviceCommand(on: true));
      await tuya.send(named('Bedroom bulb'), const DeviceCommand(brightness: 1));
      await tuya.send(named('Bedroom bulb'), const DeviceCommand(color: 0xFF0000));
      await tuya.send(named('Bedroom bulb'), const DeviceCommand(colorTempK: 6500));
      await tuya.send(named('Living curtain'), const DeviceCommand(position: 0.25));
      await tuya.send(named('Living curtain'), const DeviceCommand(position: 1));
      await tuya.send(named('Radiator'), const DeviceCommand(targetTemp: 22.5));
      expect(f.commands, [
        {'id': 'plug1', 'commands': [{'code': 'switch_2', 'value': true}]},
        {'id': 'bulb1', 'commands': [{'code': 'bright_value_v2', 'value': 1000}, {'code': 'switch_led', 'value': true}]},
        {
          'id': 'bulb1',
          'commands': [
            {'code': 'work_mode', 'value': 'colour'},
            {'code': 'colour_data_v2', 'value': {'h': 0, 's': 1000, 'v': 500}},
            {'code': 'switch_led', 'value': true},
          ],
        },
        {'id': 'bulb1', 'commands': [{'code': 'work_mode', 'value': 'white'}, {'code': 'temp_value_v2', 'value': 1000}]},
        {'id': 'curtain1', 'commands': [{'code': 'percent_control', 'value': 25}]},
        {'id': 'curtain1', 'commands': [{'code': 'control', 'value': 'open'}]},
        {'id': 'thermo1', 'commands': [{'code': 'temp_set', 'value': 225}]},
      ]);
      expect(tuya.send(named('Kids room'), const DeviceCommand(on: true)), throwsA(isA<IntegrationException>()));
    });

    test('gets a new token when Tuya says the old one ran out', () async {
      final f = fake(expireTokens: [3]);
      final tuya = driver(f.client);
      final devices = await tuya.discover();
      expect(devices, isNotEmpty);
      expect(f.paths.where((p) => p == '/v1.0/token'), hasLength(2));
    });

    test('a refresh right after a command keeps the new state on screen', () async {
      final f = fake();
      final tuya = driver(f.client);
      final devices = await tuya.discover();
      final strip = devices.firstWhere((d) => d.name == 'Desk strip 2');
      strip.state = strip.state.applyCommand(const DeviceCommand(on: true));
      await tuya.send(strip, const DeviceCommand(on: true));
      final states = await tuya.refreshAll([strip]);
      expect(states[strip.id]!.on, isTrue, reason: 'the cloud has not caught up yet');
    });
  });

  group('Imou', () {
    test('signs like the Imou documents and SDKs', () {
      expect(ImouCloud.signHmac(1706511734, 'f5a1ae2d-c09c-4d39-a744-83a5c2c653c2', 'test123456789test123456789'),
          'xjhCQBoJ9hRDsCjyDcHjtDNzRZ3ZJezcawsfWeiaoxU=');
      expect(ImouCloud.signMd5(1706511734, 'f5a1ae2d-c09c-4d39-a744-83a5c2c653c2', 'test123456789test123456789'),
          'fd37b62889e4757c58b8f3bf05fb9976');
    });

    test('finds the data centre, lists cameras with live video and takes pictures', () async {
      ImouDriver.pictureDelay = Duration.zero;
      final methods = <String>[];
      var bound = false;
      final client = MockClient((req) async {
        if (req.url.host == 'img.example.com') return http.Response.bytes([0xff, 0xd8, 0xff, 1, 2], 200, headers: {'content-type': 'image/jpeg'});
        final method = req.url.pathSegments.last;
        final body = jsonDecode(req.body) as Map;
        final system = body['system'] as Map;
        Map<String, dynamic> ok(Map<String, dynamic> data) => {'result': {'code': '0', 'msg': 'ok', 'data': data}, 'id': body['id']};
        Map<String, dynamic> fail(String code) => {'result': {'code': code, 'msg': code}, 'id': body['id']};
        methods.add('${req.url.host.split('.').first} $method');
        // This account is in Europe, and only takes the newer signature.
        if (req.url.host != 'openapi-fk.easy4ip.com') return json(fail('OP1008'));
        if (system['sign'] != ImouCloud.signHmac(system['time'] as int, system['nonce'] as String, 'SEC')) {
          return json(fail('SN1001'));
        }
        final params = body['params'] as Map;
        if (method != 'accessToken' && params['token'] != 'At_1') return json(fail('TK1002'));
        return json(switch (method) {
          'accessToken' => ok({'accessToken': 'At_1', 'expireTime': 259200}),
          'deviceBaseList' => ok({'count': 1, 'deviceList': [{'deviceId': '7F0A1B'}]}),
          'deviceBaseDetailList' => ok({
              'deviceList': [{'deviceId': '7F0A1B', 'name': 'Yard camera', 'deviceModel': 'IPC-F42', 'status': 'online'}],
            }),
          'getLiveStreamInfo' => bound
              ? ok({
                  'streams': [
                    {'streamId': 0, 'hls': 'http://cmgw.example.com/hd.m3u8', 'status': '1'},
                    {'streamId': 0, 'hls': 'https://cmgw.example.com/hd.m3u8', 'status': '1'},
                    {'streamId': 1, 'hls': 'https://cmgw.example.com/sd.m3u8', 'status': '1'},
                  ],
                })
              : fail('LV1002'),
          'bindDeviceLive' => () {
              bound = true;
              return ok({'liveToken': 'lt'});
            }(),
          'deviceOnline' => ok({'onLine': '1'}),
          'setDeviceSnapEnhanced' => ok({'url': 'https://img.example.com/snap.jpg'}),
          _ => fail('OP1002'),
        });
      });
      final config = cfg('imou', {'app_id': 'APP', 'app_secret': 'SEC'});
      var saved = 0;
      final imou = ImouDriver(config, client)..onSettings = () => saved++;
      final cams = await imou.discover();
      final cam = cams.single;
      expect(cam.name, 'Yard camera');
      expect(cam.kind, DeviceKind.camera);
      expect(cam.props['streamUrl'], 'https://cmgw.example.com/hd.m3u8');
      expect(cam.props['streamUrlLow'], 'https://cmgw.example.com/sd.m3u8');
      expect(config.setting('region'), 'https://openapi-fk.easy4ip.com');
      expect(saved, 1);
      expect(imou.liveStream(cam)!.rtsp.toString(), 'https://cmgw.example.com/hd.m3u8');
      expect(imou.reachesAnywhere(cam), isTrue);
      expect((await imou.refreshAll([cam]))[cam.id]!.reachable, isTrue);
      final picture = await imou.snapshot(cam);
      expect(picture!.first, 0xff);
      expect(methods.where((m) => m.endsWith('accessToken') && m.startsWith('openapi-fk')), hasLength(2),
          reason: 'the first try used the older signature');
    });
  });

  group('the store', () {
    test('away from home, devices with a cloud are switched directly and the rest through home', () async {
      var atHome = false;
      final store = HomeStore(
        repository: MemoryHomeRepository(),
        client: MockClient((req) async {
          if (req.url.host == 'shelly-49-eu.shelly.cloud') return http.Response('', 200);
          throw http.ClientException('no route');
        }),
        onHomeNetwork: () async => atHome,
      );
      await store.load();
      final shelly = store.addIntegration('shelly',
          settings: {'hosts': '10.0.0.5', 'cloud_server': 'shelly-49-eu.shelly.cloud', 'cloud_key': 'KEY'});
      final plug = store.addVirtualDevice(shelly.id, 'Porch plug', DeviceKind.outlet,
          props: {'host': '10.0.0.5', 'mac': 'a8032ab12345', 'gen': 2, 'component': 'switch', 'channel': 0});
      final tasmota = store.addIntegration('tasmota', settings: {'hosts': '10.0.0.9'});
      final lamp = store.addVirtualDevice(tasmota.id, 'Hall lamp', DeviceKind.light, props: {'host': '10.0.0.9'});
      final hub = FakeHub();
      store.remote = hub;
      expect(store.worksAnywhere(plug), isTrue);
      expect(store.worksAnywhere(lamp), isFalse);

      expect(await store.command(plug, const DeviceCommand(on: true)), isTrue);
      expect(await store.command(lamp, const DeviceCommand(on: true)), isTrue);
      expect(hub.sent, ['Hall lamp']);
      expect(store.driverFor(shelly.id)!.away, isTrue);
      atHome = true;
      await store.checkHomeNetwork();
      expect(store.driverFor(shelly.id)!.away, isFalse);
      store.dispose();
    });
  });
}
