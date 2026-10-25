import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/home.dart';
import 'demo.dart';
import 'esphome.dart';
import 'home_assistant.dart';
import 'hue.dart';
import 'imou.dart';
import 'integration.dart';
import 'lan/lan_driver.dart';
import 'matter/matter_driver.dart';
import 'mqtt.dart';
import 'shelly.dart';
import 'tasmota.dart';
import 'tuya.dart';
import 'wled.dart';

/// A kind of integration the user can add.
class IntegrationSpec {
  const IntegrationSpec({
    required this.type,
    required this.name,
    required this.tagline,
    required this.description,
    required this.icon,
    required this.fields,
    required this.create,
    this.canPair = false,
    this.manualDevices = false,
    this.polls = true,
  });

  final String type;
  final String name;
  final String tagline;
  final String description;
  final IconData icon;
  final List<SettingField> fields;
  final IntegrationDriver Function(IntegrationConfig config, http.Client client) create;
  final bool canPair;

  /// Whether devices can be typed in by hand (virtual devices, MQTT topics).
  final bool manualDevices;

  /// Whether the app should poll it for state (false when it pushes updates).
  final bool polls;
}

const _hosts = SettingField('hosts', 'Device addresses',
    hint: 'One IP or hostname per line, e.g. 192.168.1.40', multiline: true, required: true);

/// The type of the "Network devices" connection (TVs and anything else on the LAN).
const lanType = 'lan';

final List<IntegrationSpec> integrationCatalog = [
  IntegrationSpec(
    type: lanType,
    name: 'Network devices',
    tagline: 'TVs, speakers, plugs, anything on Wi-Fi',
    description: 'Adds anything on your home network, found by Scan network or typed in by address. '
        'Samsung, LG, Sony and Roku TVs, Chromecast and Google TV, UPnP / DLNA players and speakers, '
        'TP-Link Kasa, Yeelight and Belkin WeMo get real controls. Everything else shows whether it is online '
        'and can be woken with Wake-on-LAN.',
    icon: Icons.tv,
    fields: const [
      SettingField('hosts', 'Device addresses', hint: 'One IP per line, e.g. 192.168.1.50', multiline: true),
    ],
    create: LanDriver.new,
  ),
  IntegrationSpec(
    type: matterType,
    name: 'Matter',
    tagline: 'Lights, plugs, sensors, blinds, no hub',
    description: 'Adds Matter devices straight to SmartHomeKJ with their pairing code, with no hub, cloud or account. '
        'The device must already be on your network: share it from Google Home, Apple Home, SmartThings, Alexa or '
        'another Matter app (look for "Linked Matter apps" or "Turn on pairing mode") to get a new code. '
        'Bridges such as Hue, IKEA and Aqara bring all their devices.',
    icon: Icons.join_inner,
    fields: const [],
    create: MatterDriver.new,
  ),
  IntegrationSpec(
    type: 'homeassistant',
    name: 'Home Assistant',
    tagline: 'Thousands of brands, Matter, Zigbee, Z-Wave',
    description:
        'Connect a free, self-hosted Home Assistant server and control everything it knows: Matter and Thread devices, '
        'Zigbee, Z-Wave, Google Nest, Sonos, IKEA, Xiaomi, Tuya, TP-Link, thermostats, locks and more. '
        'Create a long-lived access token in Home Assistant under Profile > Security. To use everything from anywhere, '
        'add its outside address too: Home Assistant Cloud (Settings > Home Assistant Cloud > Remote access) or your own.',
    icon: Icons.hub_outlined,
    fields: const [
      SettingField('url', 'Server address', hint: 'http://homeassistant.local:8123', required: true),
      SettingField('token', 'Long-lived access token', secret: true, required: true),
      SettingField('remote_url', 'Outside address, for away from home (optional)', hint: 'https://xxxx.ui.nabu.casa'),
    ],
    create: HomeAssistantDriver.new,
  ),
  IntegrationSpec(
    type: 'hue',
    name: 'Philips Hue',
    tagline: 'Hue bridge, local, no account',
    description: 'Controls lights and plugs on a Hue bridge over your home network. Enter the bridge address (or use '
        'Scan network), press the round link button on the bridge, then tap Pair.',
    icon: Icons.lightbulb_outline,
    fields: const [
      SettingField('host', 'Bridge address', hint: '192.168.1.20', required: true),
      SettingField('username', 'App key', hint: 'Filled in by Pair', secret: true),
    ],
    canPair: true,
    create: HueDriver.new,
  ),
  IntegrationSpec(
    type: 'mqtt',
    name: 'MQTT & Zigbee2MQTT',
    tagline: 'Any MQTT broker, live updates',
    description: 'Connects to an MQTT broker such as Mosquitto. Imports every Zigbee2MQTT device (over 4,000 models) '
        'and any device that uses Home Assistant MQTT discovery (Tasmota, ESPHome, Shelly, OpenMQTTGateway...). '
        'You can also add devices by typing their topics.',
    icon: Icons.podcasts,
    fields: const [
      SettingField('host', 'Broker address', hint: '192.168.1.10', required: true),
      SettingField('port', 'Port', hint: '1883', defaultValue: '1883'),
      SettingField('username', 'Username'),
      SettingField('password', 'Password', secret: true),
      SettingField('z2m_base', 'Zigbee2MQTT base topic', hint: 'zigbee2mqtt', defaultValue: 'zigbee2mqtt'),
      SettingField('discovery_prefix', 'Discovery prefix', hint: 'homeassistant', defaultValue: 'homeassistant'),
    ],
    manualDevices: true,
    polls: false,
    create: MqttDriver.new,
  ),
  IntegrationSpec(
    type: 'shelly',
    name: 'Shelly',
    tagline: 'Relays, plugs, dimmers, shutters',
    description: 'Shelly Gen1, Plus, Pro, Gen3 and Gen4 devices, straight over your Wi-Fi. To switch them from anywhere '
        'too, add your Shelly Cloud key: in the Shelly app open User settings > Authorization cloud key and copy the key '
        'and the server. Then devices in the Shelly app are added even without an address, and away from home every '
        'Shelly goes through the Shelly cloud.',
    icon: Icons.electrical_services,
    fields: const [
      SettingField('hosts', 'Device addresses', hint: 'One IP or hostname per line, e.g. 192.168.1.40', multiline: true),
      SettingField('cloud_server', 'Shelly Cloud server (optional)', hint: 'shelly-49-eu.shelly.cloud'),
      SettingField('cloud_key', 'Shelly Cloud key (optional)', secret: true),
    ],
    create: ShellyDriver.new,
  ),
  IntegrationSpec(
    type: 'tuya',
    name: 'Tuya & Smart Life',
    tagline: 'Cheap Wi-Fi plugs, bulbs, sensors, from anywhere',
    description: 'Smart Life, Tuya Smart and the hundreds of Wi-Fi plugs, bulbs, LED strips, curtains, thermostats, '
        'robots and sensors built on Tuya, through Tuya\'s cloud, so they work from anywhere. Set it up once:\n'
        '1. Sign up free at platform.tuya.com and open Cloud > Development > Create Cloud Project (Smart Home, '
        'data centre Central Europe for Europe).\n'
        '2. In the project open Devices > Link App Account and scan the code with the Smart Life app (Me, then the '
        'scan button at the top).\n'
        '3. Copy the Access ID and Access Secret from the project\'s Overview here.',
    icon: Icons.cloud_outlined,
    fields: const [
      SettingField('access_id', 'Access ID', required: true),
      SettingField('access_secret', 'Access Secret', secret: true, required: true),
      SettingField('region', 'Data centre', hint: 'eu = Central Europe; also eu-w, us, us-e, in, cn, sg', defaultValue: 'eu'),
    ],
    create: TuyaDriver.new,
  ),
  IntegrationSpec(
    type: 'imou',
    name: 'Imou cloud',
    tagline: 'Imou cameras from anywhere',
    description: 'Imou cameras through Imou\'s cloud: whether they are online, new pictures and live video, from '
        'anywhere. Set it up once: sign up free at open.imoulife.com with the same login as your Imou Life app, open '
        'My App > App Information and copy the App ID and App Secret here. Live video uses the free allowance of '
        'Imou\'s developer plan; at home, Add a camera plays it straight from the camera instead.',
    icon: Icons.videocam_outlined,
    fields: const [
      SettingField('app_id', 'App ID', required: true),
      SettingField('app_secret', 'App Secret', secret: true, required: true),
      SettingField('region', 'Data centre (optional)', hint: 'Found by itself; or eu, sg, us'),
    ],
    create: ImouDriver.new,
  ),
  IntegrationSpec(
    type: 'tasmota',
    name: 'Tasmota',
    tagline: 'Open firmware plugs, bulbs, sensors',
    description: 'Thousands of plugs, bulbs and switches flashed with the open Tasmota firmware, over HTTP.',
    icon: Icons.power_outlined,
    fields: const [_hosts, SettingField('password', 'Web password (if set)', secret: true)],
    create: TasmotaDriver.new,
  ),
  IntegrationSpec(
    type: 'wled',
    name: 'WLED',
    tagline: 'LED strips',
    description: 'LED strips and lamps running the open WLED firmware.',
    icon: Icons.linear_scale,
    fields: const [_hosts],
    create: WledDriver.new,
  ),
  IntegrationSpec(
    type: 'esphome',
    name: 'ESPHome',
    tagline: 'DIY boards with web_server',
    description: 'ESPHome devices with the `web_server:` component enabled. Lights, switches, fans, covers, locks and sensors.',
    icon: Icons.memory,
    fields: const [_hosts],
    create: EspHomeDriver.new,
  ),
  IntegrationSpec(
    type: 'demo',
    name: 'Virtual devices',
    tagline: 'Try the app, plan before you buy',
    description: 'Devices that live only in SmartHomeKJ. Use them to try the app or to plan a room before the hardware arrives.',
    icon: Icons.blur_on,
    fields: const [],
    manualDevices: true,
    polls: false,
    create: DemoDriver.new,
  ),
];

IntegrationSpec? specFor(String type) {
  for (final s in integrationCatalog) {
    if (s.type == type) return s;
  }
  return null;
}
