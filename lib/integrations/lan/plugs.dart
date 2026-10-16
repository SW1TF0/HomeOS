import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/device.dart';
import '../../util/color_math.dart';
import '../integration.dart';
import 'lan_protocol.dart';
import 'net.dart';

// ---- TP-Link Kasa -------------------------------------------------------------

/// The "autokey" XOR cipher Kasa devices use on port 9999.
Uint8List kasaEncrypt(String json) {
  var key = 171;
  final out = Uint8List.fromList(utf8.encode(json));
  for (var i = 0; i < out.length; i++) {
    key = key ^ out[i];
    out[i] = key;
  }
  return out;
}

String kasaDecrypt(List<int> data) {
  var key = 171;
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = key ^ data[i];
    key = data[i];
  }
  return utf8.decode(out, allowMalformed: true);
}

/// TP-Link Kasa plugs, power strips, switches, dimmers and bulbs with the local
/// protocol on port 9999. Newer Tapo devices use an encrypted login this app
/// does not speak yet; they work through Home Assistant.
class KasaProtocol extends LanProtocol {
  const KasaProtocol();

  @override
  String get id => 'kasa';
  @override
  String get label => 'TP-Link Kasa';

  static const _bulb = 'smartlife.iot.smartbulb.lightingservice';

  Future<Map<String, dynamic>> query(LanContext ctx, String host, Map<String, dynamic> request) async {
    final socket = await ctx.connect(host, 9999);
    try {
      final payload = kasaEncrypt(jsonEncode(request));
      final len = ByteData(4)..setUint32(0, payload.length);
      socket.add([...len.buffer.asUint8List(), ...payload]);
      final buf = BytesBuilder();
      int? want;
      await for (final chunk in socket.timeout(ctx.timeout)) {
        buf.add(chunk);
        final bytes = buf.toBytes();
        if (want == null && bytes.length >= 4) want = ByteData.sublistView(bytes, 0, 4).getUint32(0);
        if (want != null && bytes.length >= 4 + want) {
          return Map<String, dynamic>.from(jsonDecode(kasaDecrypt(bytes.sublist(4, 4 + want))) as Map);
        }
      }
      throw IntegrationException('$host closed the connection.');
    } finally {
      socket.destroy();
    }
  }

  Future<Map> _sysinfo(LanContext ctx, String host) async {
    final r = await query(ctx, host, {
      'system': {'get_sysinfo': {}}
    });
    return r['system']['get_sysinfo'] as Map;
  }

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final Map info;
    try {
      info = await _sysinfo(ctx, host);
    } catch (_) {
      return null;
    }
    return devicesFrom(ctx, host, info);
  }

  List<Device> devicesFrom(LanContext ctx, String host, Map info) {
    final alias = '${info['alias'] ?? info['dev_name'] ?? 'Kasa device'}';
    final type = '${info['mic_type'] ?? info['type'] ?? ''}'.toUpperCase();
    final props = {'host': host, 'protocol': id, 'model': '${info['model'] ?? ''}', 'mac': ?(info['mac'] ?? info['mic_mac'])};
    if (type.contains('BULB')) {
      final ls = info['light_state'] is Map ? info['light_state'] as Map : const {};
      return [
        ctx.make(
          externalId: '$id:$host',
          name: alias,
          kind: DeviceKind.light,
          capabilities: {
            Capability.onOff,
            if (info['is_dimmable'] == 1) Capability.brightness,
            if (info['is_variable_color_temp'] == 1) Capability.colorTemp,
            if (info['is_color'] == 1) Capability.color,
          },
          props: {...props, 'bulb': true},
          state: _bulbState(ls),
        ),
      ];
    }
    final children = (info['children'] as List? ?? const []).whereType<Map>().toList();
    if (children.isNotEmpty) {
      return [
        for (final c in children)
          ctx.make(
            externalId: '$id:$host:${c['id']}',
            name: '${c['alias'] ?? '$alias ${children.indexOf(c) + 1}'}',
            kind: DeviceKind.outlet,
            props: {...props, 'child': '${c['id']}'},
            state: DeviceState(on: c['state'] == 1),
          ),
      ];
    }
    final dimmer = info['brightness'] != null;
    return [
      ctx.make(
        externalId: '$id:$host',
        name: alias,
        kind: dimmer ? DeviceKind.light : DeviceKind.outlet,
        capabilities: {Capability.onOff, if (dimmer) Capability.brightness},
        props: {...props, 'dimmer': dimmer},
        state: DeviceState(
          on: info['relay_state'] == 1,
          brightness: dimmer ? (info['brightness'] as num) / 100 : null,
        ),
      ),
    ];
  }

  static DeviceState _bulbState(Map ls) {
    final on = ls['on_off'] == 1;
    // When off, the bulb reports its last settings under dft_on_state.
    final s = on ? ls : (ls['dft_on_state'] is Map ? ls['dft_on_state'] as Map : ls);
    final ct = (s['color_temp'] as num?)?.toInt() ?? 0;
    final sat = (s['saturation'] as num?)?.toInt() ?? 0;
    return DeviceState(
      on: on,
      brightness: (s['brightness'] as num?) == null ? null : (s['brightness'] as num) / 100,
      colorTempK: ct > 0 ? ct : null,
      color: ct == 0 && sat > 0 ? hsvToRgb((s['hue'] as num? ?? 0).toDouble(), sat / 100, 1) : null,
    );
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final info = await _sysinfo(ctx, device.props['host'] as String);
    if (device.props['bulb'] == true) return _bulbState(info['light_state'] as Map? ?? const {});
    final child = device.props['child'];
    if (child != null) {
      final c = (info['children'] as List).whereType<Map>().firstWhere((c) => '${c['id']}'.endsWith('$child') || '$child'.endsWith('${c['id']}'));
      return DeviceState(on: c['state'] == 1);
    }
    return DeviceState(
      on: info['relay_state'] == 1,
      brightness: info['brightness'] == null ? null : (info['brightness'] as num) / 100,
    );
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand c) async {
    final host = device.props['host'] as String;
    if (device.props['bulb'] == true) {
      final st = <String, dynamic>{'transition_period': 300};
      if (c.on != null) st['on_off'] = c.on! ? 1 : 0;
      if (c.brightness != null) {
        st['on_off'] = 1;
        st['brightness'] = (c.brightness! * 100).round().clamp(1, 100);
      }
      if (c.colorTempK != null) {
        st['on_off'] = 1;
        st['color_temp'] = c.colorTempK!.clamp(2500, 9000);
      }
      if (c.color != null) {
        final hsv = rgbToHsv(c.color!);
        st.addAll({'on_off': 1, 'color_temp': 0, 'hue': hsv[0].round(), 'saturation': (hsv[1] * 100).round()});
      }
      final r = await query(ctx, host, {
        _bulb: {'transition_light_state': st}
      });
      final ls = r[_bulb]?['transition_light_state'];
      return ls is Map ? _bulbState(ls) : null;
    }
    final child = device.props['child'];
    final ctxPart = child == null
        ? const <String, dynamic>{}
        : {
            'context': {
              'child_ids': [child]
            }
          };
    if (c.brightness != null && device.props['dimmer'] == true) {
      await query(ctx, host, {
        ...ctxPart,
        'smartlife.iot.dimmer': {
          'set_brightness': {'brightness': (c.brightness! * 100).round().clamp(1, 100)}
        },
      });
    }
    final on = c.on ?? (c.brightness != null ? c.brightness! > 0 : null);
    if (on != null) {
      final r = await query(ctx, host, {
        ...ctxPart,
        'system': {
          'set_relay_state': {'state': on ? 1 : 0}
        },
      });
      final err = r['system']?['set_relay_state']?['err_code'];
      if (err != null && err != 0) throw IntegrationException('${device.name} refused (error $err).');
    }
    return null;
  }
}

/// Finds Kasa devices with one UDP broadcast on port 9999. Calls [found] with
/// each host and its system info.
Future<void> kasaBroadcast(void Function(String host, Map info) found,
    {Duration timeout = const Duration(seconds: 3)}) async {
  RawDatagramSocket socket;
  try {
    socket = await lanUdpSocket();
  } catch (_) {
    return;
  }
  final done = Completer<void>();
  final sub = socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    try {
      final j = jsonDecode(kasaDecrypt(d.data)) as Map;
      found(d.address.address, j['system']['get_sysinfo'] as Map);
    } catch (_) {}
  });
  final msg = kasaEncrypt(jsonEncode({
    'system': {'get_sysinfo': {}}
  }));
  final targets = await broadcastTargets();
  for (var i = 0; i < 2; i++) {
    for (final t in targets) {
      trySend(socket, msg, t, 9999);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  Timer(timeout, () => done.complete());
  await done.future;
  await sub.cancel();
  socket.close();
}

// ---- Yeelight ---------------------------------------------------------------------

/// Xiaomi Yeelight bulbs and strips. Turn on "LAN Control" in the Yeelight app first.
class YeelightProtocol extends LanProtocol {
  const YeelightProtocol();

  @override
  String get id => 'yeelight';
  @override
  String get label => 'Yeelight';

  Future<dynamic> call(LanContext ctx, String host, String method, List<dynamic> params) async {
    final socket = await ctx.connect(host, 55443);
    try {
      socket.add(utf8.encode('${jsonEncode({'id': 1, 'method': method, 'params': params})}\r\n'));
      final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines.timeout(ctx.timeout)) {
        final j = jsonDecode(line);
        if (j is! Map || j['id'] != 1) continue; // skip notifications
        if (j['error'] != null) throw IntegrationException('The Yeelight said: ${j['error']['message'] ?? j['error']}');
        return j['result'];
      }
      throw IntegrationException('$host closed the connection.');
    } finally {
      socket.destroy();
    }
  }

  static const _props = ['power', 'bright', 'ct', 'rgb', 'color_mode', 'name'];

  DeviceState _stateFrom(List values) {
    String v(int i) => i < values.length ? '${values[i]}' : '';
    final mode = v(4);
    return DeviceState(
      on: v(0) == 'on',
      brightness: int.tryParse(v(1)) == null ? null : int.parse(v(1)) / 100,
      colorTempK: mode == '2' ? int.tryParse(v(2)) : null,
      color: mode == '1' ? int.tryParse(v(3)) : null,
    );
  }

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final List values;
    try {
      final r = await call(ctx, host, 'get_prop', _props);
      if (r is! List) return null;
      values = r;
    } catch (_) {
      return null;
    }
    final name = values.length > 5 && '${values[5]}'.isNotEmpty ? '${values[5]}' : (hints['name'] ?? 'Yeelight');
    final model = hints['model'] ?? '';
    final mono = model == 'mono' || model == 'ct_bulb';
    return [
      ctx.make(
        externalId: '$id:$host',
        name: name,
        kind: DeviceKind.light,
        capabilities: {Capability.onOff, Capability.brightness, Capability.colorTemp, if (!mono) Capability.color},
        props: {'host': host, 'protocol': id, 'model': model},
        state: _stateFrom(values),
      ),
    ];
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final r = await call(ctx, device.props['host'] as String, 'get_prop', _props);
    return _stateFrom(r as List);
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand c) async {
    final host = device.props['host'] as String;
    if (c.on == false) {
      await call(ctx, host, 'set_power', ['off', 'smooth', 300]);
      return const DeviceState(on: false);
    }
    if (c.on == true || c.brightness != null || c.colorTempK != null || c.color != null) {
      if (device.state.on != true || c.on == true) await call(ctx, host, 'set_power', ['on', 'smooth', 300]);
    }
    if (c.brightness != null) await call(ctx, host, 'set_bright', [(c.brightness! * 100).round().clamp(1, 100), 'smooth', 300]);
    if (c.colorTempK != null) await call(ctx, host, 'set_ct_abx', [c.colorTempK!.clamp(1700, 6500), 'smooth', 300]);
    if (c.color != null) await call(ctx, host, 'set_rgb', [c.color!.clamp(1, 0xffffff), 'smooth', 300]);
    return null;
  }
}

/// Parses the headers of a Yeelight discovery answer (an SSDP-like reply on port 1982).
Map<String, String> parseYeelightReply(String reply) {
  final out = <String, String>{};
  for (final line in reply.split(RegExp(r'\r?\n'))) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    out[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
  }
  return out;
}

/// Finds Yeelights with their own multicast search.
Future<void> yeelightSearch(void Function(String host, Map<String, String> headers) found,
    {Duration timeout = const Duration(seconds: 3)}) async {
  RawDatagramSocket socket;
  try {
    socket = await lanUdpSocket();
  } catch (_) {
    return;
  }
  final sub = socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    final h = parseYeelightReply(utf8.decode(d.data, allowMalformed: true));
    final loc = Uri.tryParse(h['location'] ?? '');
    found(loc?.host.isNotEmpty == true ? loc!.host : d.address.address, h);
  });
  final msg = utf8.encode('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: "ssdp:discover"\r\nST: wifi_bulb\r\n\r\n');
  trySend(socket, msg, InternetAddress('239.255.255.250'), 1982);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  trySend(socket, msg, InternetAddress('239.255.255.250'), 1982);
  await Future<void>.delayed(timeout);
  await sub.cancel();
  socket.close();
}

// ---- Belkin WeMo -------------------------------------------------------------------

/// Belkin WeMo plugs, switches and dimmers over UPnP (SOAP).
class WemoProtocol extends LanProtocol {
  const WemoProtocol();

  @override
  String get id => 'wemo';
  @override
  String get label => 'Belkin WeMo';

  static const _service = 'urn:Belkin:service:basicevent:1';
  static const ports = [49153, 49152, 49154, 49155, 49151];

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final candidates = <Uri>[
      if (hints['location'] != null) Uri.parse(hints['location']!),
      if (hints['protocol'] == null || hints['protocol'] == id || hints['protocol'] == 'generic')
        for (final p in ports) ctx.url(host, p, '/setup.xml'),
    ];
    for (final loc in candidates) {
      try {
        final res = await ctx.get(loc);
        if (res.statusCode != 200 || !res.body.contains('Belkin')) continue;
        final xml = res.body;
        final type = xmlTag(xml, 'deviceType') ?? '';
        final dimmer = type.contains('dimmer');
        return [
          ctx.make(
            externalId: '$id:$host',
            name: xmlTag(xml, 'friendlyName') ?? 'WeMo',
            kind: dimmer ? DeviceKind.light : (type.contains('lightswitch') ? DeviceKind.toggle : DeviceKind.outlet),
            capabilities: {Capability.onOff, if (dimmer) Capability.brightness},
            props: {
              'host': host,
              'protocol': id,
              'port': loc.port,
              'model': xmlTag(xml, 'modelName') ?? '',
              'mac': ?xmlTag(xml, 'macAddress'),
            },
          ),
        ];
      } catch (_) {}
    }
    return null;
  }

  Uri _control(Device d) => Uri.parse('http://${d.props['host']}:${d.props['port']}/upnp/control/basicevent1');

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final xml = await soap(ctx, _control(device), _service, 'GetBinaryState');
    final state = xmlTag(xml, 'BinaryState') ?? '0';
    final bright = xmlTag(xml, 'brightness');
    return DeviceState(
      on: state.startsWith('1') || state.startsWith('8'),
      brightness: bright == null ? null : (int.tryParse(bright) ?? 100) / 100,
    );
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand c) async {
    final on = c.on ?? (c.brightness != null ? c.brightness! > 0 : null);
    if (c.brightness != null && device.has(Capability.brightness)) {
      await soap(ctx, _control(device), _service, 'SetBinaryState',
          args: {'BinaryState': '1', 'brightness': '${(c.brightness! * 100).round().clamp(1, 100)}'});
      return DeviceState(on: true, brightness: c.brightness);
    }
    if (on == null) return null;
    await soap(ctx, _control(device), _service, 'SetBinaryState', args: {'BinaryState': on ? '1' : '0'});
    return DeviceState(on: on);
  }
}

/// RGB (0xRRGGBB) to hue 0..360, saturation 0..1, value 0..1.
List<double> rgbToHsv(int rgb) {
  final c = intToRgb(rgb).map((v) => v / 255).toList();
  final mx = c.reduce(math.max), mn = c.reduce(math.min);
  final d = mx - mn;
  double h = 0;
  if (d > 0) {
    if (mx == c[0]) {
      h = 60 * (((c[1] - c[2]) / d) % 6);
    } else if (mx == c[1]) {
      h = 60 * (((c[2] - c[0]) / d) + 2);
    } else {
      h = 60 * (((c[0] - c[1]) / d) + 4);
    }
  }
  return [h < 0 ? h + 360 : h, mx == 0 ? 0 : d / mx, mx];
}

int hsvToRgb(double h, double s, double v) {
  final c = v * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = v - c;
  final (r, g, b) = switch (h % 360) {
    < 60 => (c, x, 0.0),
    < 120 => (x, c, 0.0),
    < 180 => (0.0, c, x),
    < 240 => (0.0, x, c),
    < 300 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  int ch(double v) => ((v + m) * 255).round().clamp(0, 255);
  return (ch(r) << 16) | (ch(g) << 8) | ch(b);
}
