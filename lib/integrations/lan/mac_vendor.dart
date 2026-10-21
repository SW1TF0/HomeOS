import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../models/device.dart';
import 'wol.dart';

/// Who made a network card, from the first half of its MAC address (the IEEE
/// registry, in `assets/mac_vendors.txt.gz`, made by `tool/mac_vendors.py`).
class MacVendors {
  MacVendors._(this._prefixes);

  final Map<String, String> _prefixes;

  static MacVendors? _loaded;
  static Future<MacVendors?>? _loading;

  /// The list once [load] has finished, or null before.
  static MacVendors? get loaded => _loaded;

  /// Reads the list once; later calls get the same one. Null when the asset is missing.
  static Future<MacVendors?> load({AssetBundle? bundle}) {
    if (_loaded != null) return Future.value(_loaded);
    return _loading ??= _read(bundle ?? rootBundle).whenComplete(() => _loading = null);
  }

  static Future<MacVendors?> _read(AssetBundle bundle) async {
    try {
      final data = await bundle.load('assets/mac_vendors.txt.gz');
      return _loaded = MacVendors.parse(gzip.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)));
    } catch (_) {
      return null;
    }
  }

  /// Lines of `PREFIX<tab>Name`.
  factory MacVendors.parse(List<int> text) {
    final map = <String, String>{};
    for (final line in const LineSplitter().convert(utf8.decode(text, allowMalformed: true))) {
      final tab = line.indexOf('\t');
      if (tab > 0) map[line.substring(0, tab)] = line.substring(tab + 1);
    }
    return MacVendors._(map);
  }

  /// The maker of [mac], or null when it is unknown or [mac] is a private (random) address.
  String? vendorOf(String? mac) {
    final m = normalizeMac(mac);
    if (m == null || isPrivateMac(m)) return null;
    final hex = m.replaceAll(':', '').toUpperCase();
    // Small and medium blocks sit inside large ones that say only "IEEE Registration Authority".
    return _prefixes[hex.substring(0, 9)] ?? _prefixes[hex.substring(0, 7)] ?? _prefixes[hex.substring(0, 6)];
  }
}

/// Whether [mac] is made up by the device rather than burnt in: phones, tablets
/// and laptops use a different random one on every Wi-Fi.
bool isPrivateMac(String? mac) {
  final m = normalizeMac(mac);
  if (m == null) return false;
  return int.parse(m.substring(0, 2), radix: 16) & 0x02 != 0;
}

/// What a device most likely is.
class DeviceGuess {
  const DeviceGuess(this.what, [this.kind = DeviceKind.other]);

  /// e.g. "iPhone or iPad", "Printer".
  final String what;
  final DeviceKind kind;
}

const _phones = {'Huawei', 'Honor', 'OPPO', 'vivo', 'OnePlus', 'realme', 'Motorola', 'ZTE', 'Nokia'};
const _computers = {
  'Intel', 'Foxconn', 'AzureWave', 'Lite-On', 'USI', 'Dell', 'Lenovo', 'Microsoft', 'Realtek', 'MediaTek', 'Qualcomm', //
  'Broadcom',
};
const _gadgets = {'Espressif', 'Tuya', 'Silicon Labs', 'Texas Instruments', 'Murata', 'Shelly', 'Yeelight'};
const _tvs = {'TCL', 'Hisense', 'Philips TV', 'Vizio', 'Panasonic', 'Sharp', 'Roku'};
const _cameras = {'Hikvision', 'Dahua / Imou', 'EZVIZ', 'Reolink', 'Ring', 'Arlo', 'Wyze', 'Netatmo'};
const _robots = {'iRobot', 'Ecovacs', 'Roborock', 'Dreame'};
const _routers = {
  'MikroTik', 'Ubiquiti', 'NETGEAR', 'D-Link', 'Zyxel', 'AVM FRITZ!', 'Tenda', 'Linksys', 'eero', 'Cisco', 'Sagemcom', //
  'Arcadyan', 'Technicolor',
};
const _printers = {'Epson', 'Canon', 'Brother', 'Xerox'};
const _appliances = {'Bosch Siemens', 'Miele', 'Electrolux', 'Haier'};
const _climate = {'Gree', 'Midea', 'Daikin'};

/// Puts together what the open [ports], the maker and the MAC say about a device.
DeviceGuess? guessDevice({String? vendor, String? mac, Set<int> ports = const {}}) {
  final open = ports;
  if (open.contains(8291) || open.contains(8728) || vendor == 'MikroTik') {
    return const DeviceGuess('MikroTik router', DeviceKind.router);
  }
  if (open.contains(9100) || open.contains(631) || _printers.contains(vendor)) return const DeviceGuess('Printer');
  if (open.contains(554) || _cameras.contains(vendor)) return const DeviceGuess('Camera', DeviceKind.camera);
  if (_robots.contains(vendor)) return const DeviceGuess('Robot vacuum', DeviceKind.vacuum);
  switch (vendor) {
    case 'Apple':
      if (open.contains(62078)) return const DeviceGuess('iPhone or iPad');
      if (open.contains(7000)) return const DeviceGuess('Apple TV or HomePod', DeviceKind.media);
      if (open.contains(22) || open.contains(445) || open.contains(5000)) return const DeviceGuess('Mac');
      return const DeviceGuess('iPhone, iPad, Mac or Apple TV');
    case 'Samsung':
      if (open.contains(8001) || open.contains(8002)) return const DeviceGuess('Samsung TV', DeviceKind.media);
      return const DeviceGuess('Samsung phone, tablet or TV');
    case 'Xiaomi':
      return const DeviceGuess('Xiaomi phone or smart device');
    case 'LG':
      return const DeviceGuess('LG TV or appliance', DeviceKind.media);
    case 'Sony':
      return const DeviceGuess('Sony TV or speaker', DeviceKind.media);
    case 'PlayStation' || 'Nintendo':
      return const DeviceGuess('Game console', DeviceKind.media);
    case 'Sonos' || 'Bose' || 'Harman':
      return const DeviceGuess('Speaker', DeviceKind.media);
    case 'Amazon':
      return const DeviceGuess('Echo, Fire TV or Kindle', DeviceKind.media);
    case 'Google' || 'Google Nest':
      return const DeviceGuess('Google Nest, Chromecast or Pixel');
    case 'TP-Link':
      return const DeviceGuess('TP-Link router, plug or camera');
    case 'Philips Hue':
      return const DeviceGuess('Philips Hue bridge or lamp', DeviceKind.light);
    case 'IKEA':
      return const DeviceGuess('IKEA smart home hub');
    case 'Raspberry Pi':
      return const DeviceGuess('Raspberry Pi');
    case 'Synology' || 'QNAP':
      return const DeviceGuess('Network storage (NAS)');
    case 'HP' || 'HPE' || 'ASUS':
      return DeviceGuess(vendor == 'ASUS' ? 'ASUS router or computer' : 'HP computer or printer');
    case 'Garmin' || 'Fitbit' || 'Withings':
      return const DeviceGuess('Watch, scale or fitness tracker');
  }
  if (_phones.contains(vendor)) return DeviceGuess('$vendor phone or tablet');
  if (_tvs.contains(vendor)) return DeviceGuess('$vendor TV', DeviceKind.media);
  if (_routers.contains(vendor)) return const DeviceGuess('Router or Wi-Fi access point', DeviceKind.router);
  if (_appliances.contains(vendor)) return const DeviceGuess('Home appliance', DeviceKind.appliance);
  if (_climate.contains(vendor)) return const DeviceGuess('Air conditioner', DeviceKind.climate);
  if (_gadgets.contains(vendor)) return const DeviceGuess('Smart plug, bulb or sensor');
  if (open.contains(53) && (open.contains(80) || open.contains(443))) return const DeviceGuess('Wi-Fi router', DeviceKind.router);
  if (open.contains(62078)) return const DeviceGuess('iPhone or iPad');
  if (open.contains(445) || open.contains(139) || _computers.contains(vendor)) return const DeviceGuess('Computer or laptop');
  if (open.contains(5555)) return const DeviceGuess('Android device');
  if (open.contains(6668)) return const DeviceGuess('Tuya smart device');
  if (open.contains(1883)) return const DeviceGuess('MQTT broker');
  if (open.contains(8123)) return const DeviceGuess('Home Assistant');
  if (isPrivateMac(mac)) return const DeviceGuess('Phone, tablet or laptop');
  return null;
}
