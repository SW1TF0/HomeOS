import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/esphome.dart';
import 'package:smartmenukj/integrations/home_assistant.dart';
import 'package:smartmenukj/integrations/hue.dart';
import 'package:smartmenukj/integrations/integration.dart';
import 'package:smartmenukj/integrations/mqtt_model.dart';
import 'package:smartmenukj/integrations/shelly.dart';
import 'package:smartmenukj/integrations/tasmota.dart';
import 'package:smartmenukj/integrations/wled.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';

/// A fake LAN: answers by "METHOD host/path?query" and records requests.
class FakeLan {
  FakeLan(this.routes);
  final Map<String, Object Function(http.Request req)> routes;
  final List<String> calls = [];
  final List<String> bodies = [];

  http.Client get client => MockClient((req) async {
        final key = '${req.method} ${req.url.authority}${req.url.path}';
        calls.add('${req.method} ${req.url}');
        if (req.body.isNotEmpty) bodies.add(req.body);
        final handler = routes[key];
        if (handler == null) return http.Response('not found', 404);
        return http.Response(jsonEncode(handler(req)), 200, headers: {'content-type': 'application/json'});
      });
}

IntegrationConfig cfg(String type, Map<String, dynamic> settings) =>
    IntegrationConfig(id: type, type: type, name: type, settings: settings);

void main() {
  group('Hue', () {
    final lan = FakeLan({
      'POST 10.0.0.2/api': (_) => [
            {'success': {'username': 'abc123'}}
          ],
      'GET 10.0.0.2/api/abc123/lights': (_) => {
            '1': {
              'name': 'Desk',
              'type': 'Extended color light',
              'state': {'on': true, 'bri': 254, 'ct': 370, 'xy': [0.3, 0.3], 'colormode': 'ct', 'reachable': true},
            },
            '2': {
              'name': 'Plug',
              'type': 'On/Off plug-in unit',
              'state': {'on': false, 'reachable': false},
            },
          },
      'PUT 10.0.0.2/api/abc123/lights/1/state': (_) => [
            {'success': {}}
          ],
    });

    test('pairs and imports lights and plugs', () async {
      final d = HueDriver(cfg('hue', {'host': '10.0.0.2'}), lan.client);
      expect(await d.pair(), {'username': 'abc123'});
      final hue = HueDriver(cfg('hue', {'host': '10.0.0.2', 'username': 'abc123'}), lan.client);
      final devices = await hue.discover();
      expect(devices.map((e) => e.name), ['Desk', 'Plug']);
      final desk = devices.first;
      expect(desk.capabilities, containsAll([Capability.brightness, Capability.colorTemp, Capability.color]));
      expect(desk.state.brightness, closeTo(1, 0.01));
      expect(desk.state.colorTempK, 2703);
      expect(devices[1].kind, DeviceKind.outlet);
      expect(devices[1].state.reachable, isFalse);

      await hue.send(desk, const DeviceCommand(brightness: 0.5, colorTempK: 4000));
      final body = jsonDecode(lan.bodies.last) as Map;
      expect(body['on'], isTrue);
      expect(body['bri'], 128);
      expect(body['ct'], 250);
    });

    test('explains a missing link button press', () async {
      final lan = FakeLan({
        'POST 10.0.0.2/api': (_) => [
              {'error': {'type': 101, 'description': 'link button not pressed'}}
            ],
      });
      final d = HueDriver(cfg('hue', {'host': '10.0.0.2'}), lan.client);
      expect(d.pair(), throwsA(isA<IntegrationException>()));
    });
  });

  group('Shelly', () {
    test('Gen2: finds switch and cover, sends RPC commands', () async {
      final lan = FakeLan({
        'GET 10.0.0.5/shelly': (_) => {'name': 'Hall', 'gen': 2},
        'GET 10.0.0.5/rpc/Shelly.GetStatus': (_) => {
              'switch:0': {'output': true, 'apower': 12.5},
              'cover:0': {'current_pos': 40},
              'temperature:0': {'tC': 21.4},
              'sys': {},
            },
        'GET 10.0.0.5/rpc/Shelly.GetConfig': (_) => {
              'switch:0': {'name': 'Hall light'},
            },
        'GET 10.0.0.5/rpc/Switch.Set': (_) => {'was_on': true},
        'GET 10.0.0.5/rpc/Cover.GoToPosition': (_) => {},
      });
      final d = ShellyDriver(cfg('shelly', {'hosts': '10.0.0.5'}), lan.client);
      final devices = await d.discover();
      final sw = devices.firstWhere((e) => e.kind == DeviceKind.outlet);
      final cover = devices.firstWhere((e) => e.kind == DeviceKind.cover);
      final sensor = devices.firstWhere((e) => e.kind == DeviceKind.sensor);
      expect(sw.name, 'Hall light');
      expect(sw.state.on, isTrue);
      expect(cover.state.position, closeTo(0.4, 1e-9));
      expect(sensor.state.readings['Temperature'], '21.4 °C');

      await d.send(sw, const DeviceCommand(on: false));
      expect(lan.calls.last, 'GET http://10.0.0.5/rpc/Switch.Set?id=0&on=false');
      await d.send(cover, const DeviceCommand(position: 0.75));
      expect(lan.calls.last, 'GET http://10.0.0.5/rpc/Cover.GoToPosition?id=0&pos=75');

      final states = await d.refreshAll(devices);
      expect(states[sw.id]!.on, isTrue);
    });

    test('Gen1: relay', () async {
      final lan = FakeLan({
        'GET 10.0.0.6/shelly': (_) => {'type': 'SHSW-1'},
        'GET 10.0.0.6/status': (_) => {
              'relays': [
                {'ison': false}
              ],
            },
        'GET 10.0.0.6/settings': (_) => {'mode': 'relay'},
        'GET 10.0.0.6/relay/0': (_) => {'ison': true},
      });
      final d = ShellyDriver(cfg('shelly', {'hosts': 'http://10.0.0.6/'}), lan.client);
      final devices = await d.discover();
      expect(devices.single.name, 'SHSW-1');
      expect(devices.single.state.on, isFalse);
      await d.send(devices.single, const DeviceCommand(on: true));
      expect(lan.calls.last, 'GET http://10.0.0.6/relay/0?turn=on');
    });

    test('reports unreachable hosts clearly', () async {
      final d = ShellyDriver(cfg('shelly', {'hosts': '10.0.0.99'}), FakeLan({}).client);
      expect(d.discover(), throwsA(isA<IntegrationException>()));
    });
  });

  test('Tasmota: dimmer light and sensor', () async {
    final lan = FakeLan({
      'GET 10.0.0.7/cm': (req) => req.url.queryParameters['cmnd'] == 'Status 0'
          ? {
              'Status': {'DeviceName': 'Lamp', 'FriendlyName': ['Lamp']},
              'StatusSTS': {'POWER': 'ON', 'Dimmer': 60, 'CT': 300},
              'StatusSNS': {'AM2301': {'Temperature': 22.1, 'Humidity': 50}, 'TempUnit': 'C'},
            }
          : {'POWER': 'OFF'},
    });
    final d = TasmotaDriver(cfg('tasmota', {'hosts': '10.0.0.7'}), lan.client);
    final devices = await d.discover();
    final lamp = devices.firstWhere((e) => e.kind == DeviceKind.light);
    expect(lamp.state.on, isTrue);
    expect(lamp.state.brightness, closeTo(0.6, 1e-9));
    expect(devices.firstWhere((e) => e.kind == DeviceKind.sensor).state.readings['Temperature'], '22.1 °C');
    await d.send(lamp, const DeviceCommand(on: false));
    expect(Uri.parse(lan.calls.last.split(' ').last).queryParameters['cmnd'], 'Power1 Off');
  });

  test('WLED: state and colour', () async {
    final lan = FakeLan({
      'GET 10.0.0.8/json': (_) => {
            'info': {'name': 'Strip', 'leds': {'count': 60}},
            'state': {
              'on': true,
              'bri': 128,
              'seg': [
                {
                  'col': [
                    [255, 0, 0]
                  ]
                }
              ]
            },
          },
      'POST 10.0.0.8/json/state': (_) => {'on': true, 'bri': 255, 'seg': []},
    });
    final d = WledDriver(cfg('wled', {'hosts': '10.0.0.8'}), lan.client);
    final strip = (await d.discover()).single;
    expect(strip.name, 'Strip');
    expect(strip.state.color, 0xff0000);
    await d.send(strip, const DeviceCommand(color: 0x00ff00));
    expect((jsonDecode(lan.bodies.last) as Map)['seg'], [
      {
        'col': [
          [0, 255, 0]
        ]
      }
    ]);
  });

  test('ESPHome entity ids from web_server v2 and v3', () {
    expect(EspHomeDriver.entityKey('light-desk_lamp'), 'light/desk_lamp');
    expect(EspHomeDriver.entityKey('switch/Relay 1'), 'switch/Relay 1');
    expect(EspHomeDriver.entityKey('nonsense'), isNull);
  });

  group('Home Assistant', () {
    final lan = FakeLan({
      'GET ha.local:8123/api/states': (_) => [
            {
              'entity_id': 'light.kitchen',
              'state': 'on',
              'attributes': {
                'friendly_name': 'Kitchen',
                'brightness': 255,
                'supported_color_modes': ['color_temp', 'xy'],
                'color_mode': 'color_temp',
                'color_temp_kelvin': 3000,
              },
            },
            {'entity_id': 'cover.blind', 'state': 'open', 'attributes': {'current_position': 70, 'supported_features': 15}},
            {'entity_id': 'climate.hall', 'state': 'heat', 'attributes': {'temperature': 21, 'current_temperature': 19.5}},
            {'entity_id': 'lock.front', 'state': 'locked', 'attributes': {}},
            {
              'entity_id': 'sensor.bed_temp',
              'state': '19.2',
              'attributes': {'device_class': 'temperature', 'unit_of_measurement': '°C', 'friendly_name': 'Bed temp'},
            },
            {'entity_id': 'sensor.uptime', 'state': '1000', 'attributes': {}},
            {'entity_id': 'automation.x', 'state': 'on', 'attributes': {}},
          ],
      'POST ha.local:8123/api/services/light/turn_on': (_) => [],
      'POST ha.local:8123/api/services/lock/unlock': (_) => [],
    });

    test('imports useful entities only and calls services', () async {
      final d = HomeAssistantDriver(cfg('homeassistant', {'url': 'ha.local:8123/', 'token': 't0k'}), lan.client);
      final devices = await d.discover();
      expect(devices.map((e) => e.externalId),
          ['light.kitchen', 'cover.blind', 'climate.hall', 'lock.front', 'sensor.bed_temp']);
      final light = devices.first;
      expect(light.capabilities, containsAll([Capability.brightness, Capability.colorTemp, Capability.color]));
      expect(light.state.colorTempK, 3000);
      expect(devices[1].state.position, closeTo(0.7, 1e-9));
      expect(devices[2].state.targetTemp, 21);
      expect(devices[3].state.locked, isTrue);
      expect(devices[4].state.readings.values.single, '19.2 °C');

      await d.send(light, const DeviceCommand(brightness: 0.3));
      expect(jsonDecode(lan.bodies.last), {'entity_id': 'light.kitchen', 'brightness_pct': 30});
      await d.send(devices[3], const DeviceCommand(locked: false));
      expect(lan.calls.last, 'POST http://ha.local:8123/api/services/lock/unlock');
    });

    test('needs a token', () {
      final d = HomeAssistantDriver(cfg('homeassistant', {'url': 'ha.local'}), lan.client);
      expect(d.discover(), throwsA(isA<IntegrationException>()));
    });
  });

  group('MQTT', () {
    test('Zigbee2MQTT devices, states and commands', () {
      final m = MqttModel();
      m.handle(
          'zigbee2mqtt/bridge/devices',
          jsonEncode([
            {'friendly_name': 'Coordinator', 'type': 'Coordinator'},
            {
              'friendly_name': 'living/bulb',
              'type': 'Router',
              'definition': {
                'vendor': 'IKEA',
                'model': 'LED1545G12',
                'exposes': [
                  {
                    'type': 'light',
                    'features': [
                      {'name': 'state'},
                      {'name': 'brightness'},
                      {'name': 'color_temp'}
                    ]
                  }
                ]
              }
            },
            {
              'friendly_name': 'door_sensor',
              'type': 'EndDevice',
              'definition': {
                'vendor': 'Aqara',
                'model': 'MCCGQ11LM',
                'exposes': [
                  {'type': 'binary', 'name': 'contact'},
                  {'type': 'numeric', 'name': 'battery'}
                ]
              }
            },
          ]));
      final (changed, _) =
          m.handle('zigbee2mqtt/living/bulb', jsonEncode({'state': 'ON', 'brightness': 127, 'color_temp': 370, 'color_mode': 'color_temp'}));
      expect(changed['z2m:living/bulb']!.on, isTrue);
      expect(changed['z2m:living/bulb']!.colorTempK, 2703);
      m.handle('zigbee2mqtt/door_sensor', jsonEncode({'contact': false, 'battery': 90}));

      final devices = m.devices((id, name, kind, caps, props, state) => Device(
          id: id, name: name, kind: kind, integrationId: 'mqtt', externalId: id, capabilities: caps, props: props, state: state));
      expect(devices.map((d) => d.name), ['living/bulb', 'door_sensor']);
      expect(devices.first.kind, DeviceKind.light);
      expect(devices.first.capabilities, contains(Capability.colorTemp));
      expect(devices.last.kind, DeviceKind.sensor);
      expect(devices.last.state.readings, {'Contact': 'Open', 'Battery': '90 %'});

      final out = m.commandsFor(devices.first, const DeviceCommand(on: true, brightness: 0.5));
      expect(out.single.topic, 'zigbee2mqtt/living/bulb/set');
      expect(jsonDecode(out.single.payload), {'state': 'ON', 'brightness': 127});
    });

    test('Home Assistant discovery with abbreviations and templates', () {
      final m = MqttModel();
      final (_, topics) = m.handle(
          'homeassistant/switch/tasmota_ABC/relay_0/config',
          jsonEncode({
            '~': 'tasmota/plug/',
            'name': 'Plug',
            'stat_t': '~stat',
            'cmd_t': '~cmnd/POWER',
            'pl_on': 'ON',
            'pl_off': 'OFF',
            'val_tpl': '{{ value_json.POWER }}',
            'dev': {'name': 'Kitchen'},
          }));
      expect(topics, ['tasmota/plug/stat']);
      final (changed, _) = m.handle('tasmota/plug/stat', '{"POWER":"ON"}');
      expect(changed.values.single.on, isTrue);
      final dev = m.devices((id, name, kind, caps, props, state) =>
          Device(id: id, name: name, kind: kind, integrationId: 'mqtt', externalId: id, capabilities: caps, props: props, state: state));
      expect(dev.single.name, 'Kitchen Plug');
      expect(m.commandsFor(dev.single, const DeviceCommand(on: false)).single.toString(), 'tasmota/plug/cmnd/POWER <- OFF');
    });

    test('templates', () {
      expect(MqttModel.applyTemplate("{{ value_json['temp'] }}", '{"temp": 21.5}'), '21.5');
      expect(MqttModel.applyTemplate('{{ value_json.a.b }}', '{"a": {"b": "x"}}'), 'x');
      expect(MqttModel.applyTemplate('{{ value }}', ' ON '), 'ON');
      expect(MqttModel.applyTemplate(null, '42'), '42');
    });

    test('hand-made sensor follows its state topic', () {
      final m = MqttModel();
      m.register('manual:1', {'component': 'sensor', 'state_topic': 'garden/temp', 'name': 'Garden', 'unit_of_measurement': '°C'});
      final (changed, _) = m.handle('garden/temp', '14.2');
      expect(changed['manual:1']!.readings, {'Garden': '14.2 °C'});
    });
  });

  test('hosts setting accepts lines, commas and URLs', () {
    expect(parseHosts('http://10.0.0.1/, 10.0.0.2\n10.0.0.2  shelly.local'), ['10.0.0.1', '10.0.0.2', 'shelly.local']);
  });
}
