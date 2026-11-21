import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../models/device.dart';
import '../util/color_math.dart';
import 'integration.dart';
import 'matter/crypto.dart';

/// Tuya's data centres. A Smart Life or Tuya Smart account made in Europe is in Central Europe.
const tuyaRegions = {
  'eu': 'https://openapi.tuyaeu.com',
  'eu-w': 'https://openapi-weaz.tuyaeu.com',
  'us': 'https://openapi.tuyaus.com',
  'us-e': 'https://openapi-ueaz.tuyaus.com',
  'in': 'https://openapi.tuyain.com',
  'cn': 'https://openapi.tuyacn.com',
  'sg': 'https://openapi-sg.iotbing.com',
};

/// The address of the data centre the user typed: a short code, its name, or the address itself.
String tuyaEndpoint(String region) {
  final r = region.trim().toLowerCase();
  if (r.startsWith('https://')) return r.replaceAll(RegExp(r'/+$'), '');
  if (tuyaRegions[r] != null) return tuyaRegions[r]!;
  final west = r.contains('west'), east = r.contains('east');
  if (r.contains('eu')) return tuyaRegions[west ? 'eu-w' : 'eu']!;
  if (r.contains('us') || r.contains('america')) return tuyaRegions[east ? 'us-e' : 'us']!;
  if (r.contains('ind')) return tuyaRegions['in']!;
  if (r.contains('chin')) return tuyaRegions['cn']!;
  if (r.contains('sing') || r.contains('asia')) return tuyaRegions['sg']!;
  return tuyaRegions['eu']!;
}

/// Tuya's cloud (the OpenAPI of a free cloud project on platform.tuya.com), which reaches every device of the
/// Smart Life or Tuya Smart accounts linked to the project, from anywhere.
class TuyaCloud {
  TuyaCloud(this.client, {required this.accessId, required this.secret, required String region})
      : endpoint = tuyaEndpoint(region);

  final http.Client client;
  final String accessId;
  final String secret;
  final String endpoint;

  String? _token;
  DateTime? _expires;
  Future<String>? _getting;

  static const timeout = Duration(seconds: 10);

  /// Tuya's request signature: HMAC-SHA256 of the access id, the token (none when asking for one), the time and the
  /// request (method, the body's SHA-256, no signed headers, the path with its query sorted), in capital hex.
  static String sign({
    required String accessId,
    required String secret,
    String token = '',
    required String t,
    required String method,
    required String path,
    Map<String, String> query = const {},
    String body = '',
  }) {
    final keys = query.keys.toList()..sort();
    final url = keys.isEmpty ? path : '$path?${keys.map((k) => '$k=${query[k]}').join('&')}';
    final request = '$method\n${hexOf(sha256(utf8.encode(body)))}\n\n$url';
    return hexOf(hmacSha256(utf8.encode(secret), utf8.encode('$accessId$token$t$request'))).toUpperCase();
  }

  Future<String> _accessToken() {
    final token = _token;
    if (token != null && _expires != null && clock.now().isBefore(_expires!)) return Future.value(token);
    return _getting ??= () async {
      try {
        final r = await _send('GET', '/v1.0/token', query: {'grant_type': '1'}, token: '') as Map;
        final secs = (r['expire_time'] as num?)?.toInt() ?? (r['expire'] as num?)?.toInt() ?? 7200;
        _expires = clock.now().add(Duration(seconds: secs - 120));
        return _token = '${r['access_token']}';
      } finally {
        _getting = null;
      }
    }();
  }

  Future<dynamic> get(String path, [Map<String, String> query = const {}]) => _call('GET', path, query: query);

  Future<dynamic> post(String path, Object body) => _call('POST', path, body: jsonEncode(body));

  Future<dynamic> _call(String method, String path, {Map<String, String> query = const {}, String body = ''}) async {
    try {
      return await _send(method, path, query: query, body: body, token: await _accessToken());
    } on _TokenExpired {
      _token = null;
      return _send(method, path, query: query, body: body, token: await _accessToken());
    }
  }

  Future<dynamic> _send(String method, String path,
      {Map<String, String> query = const {}, String body = '', required String token}) async {
    final t = '${clock.now().millisecondsSinceEpoch}';
    final uri = Uri.parse('$endpoint$path').replace(queryParameters: query.isEmpty ? null : query);
    final req = http.Request(method, uri)
      ..headers.addAll({
        'client_id': accessId,
        'sign': sign(accessId: accessId, secret: secret, token: token, t: t, method: method, path: path, query: query, body: body),
        'sign_method': 'HMAC-SHA256',
        't': t,
        'lang': 'en',
        if (token.isNotEmpty) 'access_token': token,
        if (body.isNotEmpty) 'Content-Type': 'application/json',
      });
    if (body.isNotEmpty) req.body = body;
    final res = await http.Response.fromStream(await client.send(req).timeout(timeout)).timeout(timeout);
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw IntegrationException('Tuya answered HTTP ${res.statusCode}.');
    }
    if (j is! Map) throw IntegrationException('Tuya answered HTTP ${res.statusCode}.');
    if (j['success'] == true) return j['result'];
    final code = '${j['code']}', msg = '${j['msg'] ?? 'it said no'}';
    if (code == '1010' || code == '1011' || msg.contains('token invalid')) {
      if (token.isNotEmpty) throw const _TokenExpired();
    }
    throw IntegrationException(switch (code) {
      '1004' => 'Tuya did not accept the Access ID and Secret. Check them, and that the data centre is the one of '
          'your cloud project.',
      '1106' || '1100' => 'Tuya: no permission. In your cloud project open Devices > Link App Account and link your '
          'Smart Life app.',
      '28841002' || '28841101' || '28841105' => 'Tuya: $msg. In your cloud project check Service API: IoT Core must '
          'be subscribed (it is free, renew the trial every few months).',
      '2017' => 'Tuya: that device does not belong to the linked accounts.',
      _ => 'Tuya: $msg',
    });
  }

  /// Every device of the linked app accounts, with its name, kind (category), whether it is online and its status.
  Future<List<Map<String, dynamic>>> devices() async {
    final out = <Map<String, dynamic>>[];
    String? next;
    for (var page = 0; page < 20; page++) {
      final r = await get('/v1.0/iot-01/associated-users/devices', {'size': '50', 'last_row_key': ?next});
      final list = r is Map ? (r['devices'] ?? r['list']) as List? : r as List?;
      for (final d in list ?? const []) {
        if (d is Map) out.add(Map<String, dynamic>.from(d));
      }
      next = r is Map ? r['last_row_key'] as String? : null;
      if (r is! Map || r['has_more'] != true || next == null) break;
    }
    return out;
  }

  /// What [id] can be told to do: each code with its type and range.
  Future<List<Map<String, dynamic>>> functions(String id) async {
    final r = await get('/v1.0/iot-03/devices/$id/functions');
    return [for (final f in ((r as Map?)?['functions'] as List? ?? const [])) if (f is Map) Map<String, dynamic>.from(f)];
  }

  /// The status of up to 20 devices at a time: id -> [{code, value}].
  Future<Map<String, List>> status(List<String> ids) async {
    final out = <String, List>{};
    for (var i = 0; i < ids.length; i += 20) {
      final r = await get('/v1.0/iot-03/devices/status', {'device_ids': ids.sublist(i, (i + 20).clamp(0, ids.length)).join(',')});
      for (final d in (r as List? ?? const [])) {
        if (d is Map) out['${d['id']}'] = d['status'] as List? ?? const [];
      }
    }
    return out;
  }

  Future<void> command(String id, List<Map<String, dynamic>> commands) async {
    final r = await post('/v1.0/iot-03/devices/$id/commands', {'commands': commands});
    if (r == false) throw IntegrationException('Tuya did not pass the command on.');
  }
}

class _TokenExpired implements Exception {
  const _TokenExpired();
}

/// Tuya devices (Smart Life, Tuya Smart and the hundreds of brands built on them: cheap Wi-Fi plugs, bulbs, LED
/// strips, curtains, thermostats, robots and sensors), through Tuya's cloud. They answer from anywhere.
class TuyaDriver extends IntegrationDriver {
  TuyaDriver(super.config, super.client);

  TuyaCloud? _api;

  TuyaCloud get api {
    final id = config.setting('access_id'), secret = config.setting('access_secret');
    final endpoint = tuyaEndpoint(config.setting('region'));
    if (id.isEmpty || secret.isEmpty) {
      throw IntegrationException('Enter the Access ID and Access Secret of your Tuya cloud project.');
    }
    final a = _api;
    if (a != null && a.accessId == id && a.secret == secret && a.endpoint == endpoint) return a;
    return _api = TuyaCloud(client, accessId: id, secret: secret, region: endpoint);
  }

  @override
  bool reachesAnywhere(Device device) => true;

  /// The last list from the cloud and when. Tuya's free plan counts calls, so it is read at most every [poll].
  List<Map<String, dynamic>>? _last;
  DateTime? _lastAt;
  static const poll = Duration(seconds: 30);

  /// When each device was last switched: until the cloud has caught up, its new state stays on screen.
  final Map<String, DateTime> _sentAt = {};

  @override
  Future<List<Device>> discover() async {
    final list = await api.devices();
    if (list.isEmpty) {
      throw IntegrationException('Tuya lists no devices. In your cloud project open Devices > Link App Account and '
          'scan the code with the Smart Life app (Me > the scan button).');
    }
    _last = list;
    _lastAt = clock.now();
    final out = <Device>[];
    for (final dev in list) {
      var functions = const <Map<String, dynamic>>[];
      try {
        functions = await api.functions('${dev['id']}');
      } catch (_) {}
      out.addAll(TuyaModel.devicesOf(this, dev, functions));
    }
    return out;
  }

  @override
  Future<Map<String, DeviceState>> refreshAll(List<Device> devices) async {
    List<Map<String, dynamic>> list;
    final last = _last;
    try {
      list = last != null && _lastAt != null && clock.now().difference(_lastAt!) < poll ? last : await api.devices();
    } catch (_) {
      return {for (final d in devices) d.id: d.state.merge(DeviceState.unreachable)};
    }
    if (!identical(list, last)) {
      _last = list;
      _lastAt = clock.now();
    }
    final byId = {for (final d in list) '${d['id']}': d};
    // The list carries each device's status; ask for it on its own when it does not.
    final missing = [
      for (final d in devices)
        if (byId[d.props['tuyaId']] != null && byId[d.props['tuyaId']]!['status'] == null) '${d.props['tuyaId']}',
    ];
    if (missing.isNotEmpty) {
      try {
        final st = await api.status(missing.toSet().toList());
        st.forEach((id, s) => byId[id]?['status'] = s);
      } catch (_) {}
    }
    final out = <String, DeviceState>{};
    for (final d in devices) {
      final dev = byId[d.props['tuyaId']];
      final sent = _sentAt[d.id];
      if (sent != null && _lastAt != null && !_lastAt!.isAfter(sent.add(const Duration(seconds: 3)))) {
        out[d.id] = d.state;
        continue;
      }
      out[d.id] = dev == null
          ? d.state.merge(DeviceState.unreachable)
          : d.state.merge(TuyaModel.stateOf(d, TuyaModel.statusMap(dev['status']), online: dev['online'] != false));
    }
    return out;
  }

  @override
  Future<DeviceState?> refresh(Device device) async => (await refreshAll([device]))[device.id];

  @override
  Future<DeviceState?> send(Device device, DeviceCommand c) async {
    final commands = TuyaModel.commandsFor(device, c);
    if (commands.isEmpty) throw IntegrationException('${device.name} cannot do that through Tuya.');
    await api.command('${device.props['tuyaId']}', commands);
    _sentAt[device.id] = clock.now();
    _last = null;
    return null;
  }
}

/// How Tuya's standard codes ("data points") become devices, states and commands.
abstract final class TuyaModel {
  static Map<String, dynamic> statusMap(Object? status) => {
        for (final s in (status as List? ?? const []))
          if (s is Map && s['code'] != null) '${s['code']}': s['value'],
      };

  /// A function's range ({min, max, scale} or {range: [...]}), from its `values`, which Tuya sends as JSON text.
  static Map<String, dynamic> valuesOf(Map<String, dynamic>? f) {
    final v = f?['values'];
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String && v.trim().startsWith('{')) {
      try {
        return Map<String, dynamic>.from(jsonDecode(v) as Map);
      } catch (_) {}
    }
    return const {};
  }

  static const _plugs = {'cz', 'pc', 'znjdq'};
  static const _lights = {'dj', 'dd', 'fwd', 'xdd', 'dc', 'tgq', 'tgkg', 'fsd', 'gyd', 'tyndj', 'sxd'};
  static const _covers = {'cl', 'clkg', 'mc', 'ckmkzq'};
  static const _climate = {'kt', 'wk', 'wkf', 'qn', 'rs', 'ktkzq', 'wkcz'};
  static const _sensors = {
    'wsdcg', 'mcs', 'pir', 'ywbj', 'rqbj', 'sj', 'cobj', 'co2bj', 'ldcg', 'hjjcy', 'pm2.5', 'jwbj', 'sos', 'hps', 'zd',
    'cwysj', 'wnykq', 'wxkg',
  };

  /// The devices one Tuya device becomes: one per switch channel, or one light, cover, thermostat, robot or sensor.
  static List<Device> devicesOf(IntegrationDriver driver, Map<String, dynamic> dev, List<Map<String, dynamic>> functions) {
    final id = '${dev['id']}';
    final cat = '${dev['category'] ?? ''}';
    final name = '${dev['name'] ?? 'Tuya device'}'.trim();
    final fn = {for (final f in functions) '${f['code']}': f};
    final status = statusMap(dev['status']);
    bool has(String code) => fn.containsKey(code) || status.containsKey(code);
    String? first(List<String> codes) => codes.where(has).firstOrNull;
    final base = <String, dynamic>{'tuyaId': id, 'category': cat};
    final online = dev['online'] != false;

    Device make(String suffix, String label, DeviceKind kind, Set<Capability> caps, Map<String, dynamic> props) {
      final d = driver.makeDevice(
        externalId: suffix.isEmpty ? id : '$id#$suffix',
        name: label,
        kind: kind,
        capabilities: caps,
        props: {...base, ...props},
      );
      d.state = d.state.merge(stateOf(d, status, online: online));
      return d;
    }

    // Lights: one, or one per channel of a dimmer.
    final lightChannels = [
      if (has('switch_led')) '',
      for (var n = 1; n <= 4; n++)
        if (has('switch_led_$n')) '_$n',
    ];
    if (lightChannels.isNotEmpty && (_lights.contains(cat) || !_covers.contains(cat))) {
      return [
        for (final ch in lightChannels)
          () {
            final bright = first(['bright_value_v2$ch', 'bright_value$ch']);
            final temp = first(['temp_value_v2$ch', 'temp_value$ch']);
            final colour = ch.isEmpty ? first(['colour_data_v2', 'colour_data']) : null;
            final b = valuesOf(fn[bright]), t = valuesOf(fn[temp]);
            final v2 = (bright ?? '').contains('_v2');
            return make(
              ch.isEmpty ? '' : 'light$ch',
              lightChannels.length == 1 ? name : '$name ${ch.substring(1)}',
              DeviceKind.light,
              {
                Capability.onOff,
                if (bright != null) Capability.brightness,
                if (temp != null) Capability.colorTemp,
                if (colour != null) Capability.color,
              },
              {
                'on': 'switch_led$ch',
                'bright': ?bright,
                if (bright != null) ...{
                  'brightMin': (b['min'] as num?) ?? (v2 ? 10 : 25),
                  'brightMax': (b['max'] as num?) ?? (v2 ? 1000 : 255),
                },
                'temp': ?temp,
                if (temp != null) 'tempMax': (t['max'] as num?) ?? ((temp).contains('_v2') ? 1000 : 255),
                'colour': ?colour,
                if (colour != null) 'colourMax': colour.contains('_v2') ? 1000 : 255,
                if (ch.isEmpty && has('work_mode')) 'mode': 'work_mode',
              },
            );
          }(),
      ];
    }

    // Curtains, blinds, garage doors.
    final control = first(['control', 'control_1', 'mach_operate']);
    if (_covers.contains(cat) && (control != null || has('percent_control'))) {
      final garage = cat == 'ckmkzq';
      return [
        make('', name, garage ? DeviceKind.garage : DeviceKind.cover, {Capability.position}, {
          'control': ?control,
          if (has('percent_control')) 'percent': 'percent_control',
          if (has('percent_state')) 'percentState': 'percent_state',
        }),
      ];
    }

    // Thermostats, heaters, air conditioners.
    final setpoint = first(['temp_set', 'temp_set_f']);
    if (_climate.contains(cat) && setpoint != null) {
      final s = valuesOf(fn[setpoint]);
      final modes = [for (final m in (valuesOf(fn['mode'])['range'] as List? ?? const [])) '$m'];
      return [
        make('', name, DeviceKind.climate, {
          Capability.targetTemp,
          if (has('switch')) Capability.onOff,
          if (modes.length > 1) Capability.mode,
        }, {
          'target': setpoint,
          'targetScale': (s['scale'] as num?) ?? 0,
          if (has('switch')) 'on': 'switch',
          if (has('temp_current')) 'current': 'temp_current',
          if (modes.length > 1) ...{'mode': 'mode', 'modes': modes},
        }),
      ];
    }

    // Robot vacuums.
    if (cat == 'sd' && has('power_go')) {
      final modes = [for (final m in (valuesOf(fn['mode'])['range'] as List? ?? const [])) '$m'];
      final dock = has('switch_charge') || modes.contains('chargego');
      return [
        make('', name, DeviceKind.vacuum, {Capability.run, if (dock) Capability.dock}, {
          if (has('switch_charge')) 'charge': 'switch_charge',
          if (modes.contains('chargego')) 'chargeMode': true,
        }),
      ];
    }

    // Fans and air purifiers.
    if ((cat == 'fs' || cat == 'kj' || cat == 'fsd') && has('switch')) {
      final speed = first(['fan_speed_percent', 'fan_speed']);
      final sp = valuesOf(fn[speed]);
      final percent = speed == 'fan_speed_percent' || sp['min'] != null;
      final modes = [for (final m in (valuesOf(fn['mode'])['range'] as List? ?? const [])) '$m'];
      return [
        make('', name, cat == 'kj' ? DeviceKind.purifier : DeviceKind.fan, {
          Capability.onOff,
          if (speed != null && percent) Capability.speed,
          if (modes.length > 1) Capability.mode,
        }, {
          'on': 'switch',
          if (speed != null && percent) ...{
            'speed': speed,
            'speedMin': (sp['min'] as num?) ?? 1,
            'speedMax': (sp['max'] as num?) ?? 100,
          },
          if (modes.length > 1) ...{'mode': 'mode', 'modes': modes},
        }),
      ];
    }

    // Plugs and switches, one per channel.
    final switches = [
      if (has('switch')) 'switch',
      for (var n = 1; n <= 8; n++)
        if (has('switch_$n')) 'switch_$n',
      for (var n = 1; n <= 2; n++)
        if (has('switch_usb$n')) 'switch_usb$n',
    ];
    if (switches.isNotEmpty && !_sensors.contains(cat)) {
      final kind = switch (cat) {
        _ when _plugs.contains(cat) => DeviceKind.outlet,
        'sfkzq' => DeviceKind.valve,
        'sgbj' => DeviceKind.siren,
        'jsq' => DeviceKind.humidifier,
        _ => DeviceKind.toggle,
      };
      final main = switches.where((s) => !s.contains('usb')).toList();
      return [
        for (final (i, code) in switches.indexed)
          make(
            switches.length == 1 ? '' : code,
            switches.length == 1
                ? name
                : code.contains('usb')
                    ? '$name USB'
                    : '$name ${main.length == 1 ? '' : main.indexOf(code) + 1}'.trim(),
            kind == DeviceKind.humidifier ? DeviceKind.toggle : kind,
            {Capability.onOff, if (i == 0) Capability.readings},
            {'on': code, if (i == 0) 'meter': true},
          ),
      ];
    }

    // Sensors and anything else: what it reports.
    return [
      make('', name, _sensors.contains(cat) || readingsOf(status).isNotEmpty ? DeviceKind.sensor : DeviceKind.other,
          {Capability.readings}, {}),
    ];
  }

  static num _num(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;

  static String _fmt(num v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  /// The readings a sensor or a plug's meter shows, by Tuya's standard codes.
  static Map<String, String> readingsOf(Map<String, dynamic> s) {
    final out = <String, String>{};
    void r(String code, String label, String Function(dynamic v) f) {
      if (s[code] != null && out[label] == null) out[label] = f(s[code]);
    }

    bool alarm(dynamic v) => v == true || v == 'alarm' || v == '1' || v == 1;
    r('va_temperature', 'Temperature', (v) => '${_fmt(_num(v) / 10)} °C');
    r('temp_current', 'Temperature', (v) => '${_fmt(_num(v) > 100 ? _num(v) / 10 : _num(v))} °C');
    r('va_humidity', 'Humidity', (v) => '${_fmt(_num(v) > 100 ? _num(v) / 10 : _num(v))} %');
    r('humidity_value', 'Humidity', (v) => '${_fmt(_num(v) > 100 ? _num(v) / 10 : _num(v))} %');
    r('doorcontact_state', 'Contact', (v) => v == true ? 'Open' : 'Closed');
    r('pir', 'Motion', (v) => v == 'pir' || v == true ? 'Detected' : 'Clear');
    r('presence_state', 'Presence', (v) => v == 'presence' || v == true ? 'Detected' : 'Clear');
    r('smoke_sensor_status', 'Smoke', (v) => alarm(v) ? 'Smoke!' : 'Clear');
    r('smoke_sensor_state', 'Smoke', (v) => alarm(v) ? 'Smoke!' : 'Clear');
    r('gas_sensor_status', 'Gas', (v) => alarm(v) ? 'Gas!' : 'Clear');
    r('gas_sensor_state', 'Gas', (v) => alarm(v) ? 'Gas!' : 'Clear');
    r('co_status', 'CO', (v) => alarm(v) ? 'CO!' : 'Clear');
    r('co_state', 'CO', (v) => alarm(v) ? 'CO!' : 'Clear');
    r('watersensor_state', 'Leak', (v) => alarm(v) ? 'Leak!' : 'Dry');
    r('sos_state', 'SOS', (v) => v == true ? 'Pressed!' : 'Clear');
    r('co2_value', 'CO2', (v) => '$v ppm');
    r('pm25_value', 'PM2.5', (v) => '$v µg/m³');
    r('bright_value', 'Light', (v) => '$v lx');
    r('cur_power', 'Power', (v) => '${_fmt(_num(v) / 10)} W');
    r('cur_voltage', 'Voltage', (v) => '${_fmt(_num(v) / 10)} V');
    r('battery_percentage', 'Battery', (v) => '$v %');
    r('battery_state', 'Battery', (v) => '$v'.isEmpty ? '' : '${'$v'[0].toUpperCase()}${'$v'.substring(1)}');
    return out;
  }

  static double _between(num v, num min, num max) => max <= min ? 0 : ((v - min) / (max - min)).clamp(0, 1).toDouble();

  /// The state of [d] from the codes the cloud reports for its Tuya device.
  static DeviceState stateOf(Device d, Map<String, dynamic> s, {bool online = true}) {
    if (!online) return DeviceState.unreachable;
    final p = d.props;
    final on = p['on'] as String?;
    switch (d.kind) {
      case DeviceKind.light:
        final mode = p['mode'] == null ? null : s[p['mode']];
        final colour = p['colour'] == null ? null : _colour(s[p['colour']]);
        final max = _num(p['colourMax'] ?? 1000);
        if (colour != null && mode == 'colour') {
          return DeviceState(
            on: s[on] as bool?,
            color: hsvToRgb(_num(colour['h']).toDouble(), _between(_num(colour['s']), 0, max), 1),
            brightness: _between(_num(colour['v']), 0, max),
          );
        }
        final bright = p['bright'] == null ? null : s[p['bright']];
        final temp = p['temp'] == null ? null : s[p['temp']];
        return DeviceState(
          on: s[on] as bool?,
          brightness: bright == null ? null : _between(_num(bright), _num(p['brightMin'] ?? 10), _num(p['brightMax'] ?? 1000)),
          colorTempK: temp == null ? null : (2700 + _between(_num(temp), 0, _num(p['tempMax'] ?? 1000)) * 3800).round(),
        );
      case DeviceKind.cover || DeviceKind.garage:
        final pos = s[p['percentState']] ?? s[p['percent']];
        final control = s[p['control']];
        return DeviceState(
          position: pos != null ? _num(pos) / 100 : (control == 'open' ? 1 : (control == 'close' ? 0 : null)),
        );
      case DeviceKind.climate:
        final scale = _num(p['targetScale'] ?? 0).toInt();
        num scaled(Object? v) => scale <= 0 ? _num(v) : _num(v) / [1, 10, 100, 1000][scale.clamp(0, 3)];
        final cur = p['current'] == null ? null : s[p['current']];
        return DeviceState(
          on: on == null ? null : s[on] as bool?,
          targetTemp: s[p['target']] == null ? null : scaled(s[p['target']]).toDouble(),
          currentTemp: cur == null ? null : (_num(cur) > 100 || scale > 0 ? scaled(cur) : _num(cur)).toDouble(),
          mode: p['mode'] == null ? null : s[p['mode']] as String?,
        );
      case DeviceKind.vacuum:
        final st = '${s['status'] ?? ''}';
        final activity = switch (st) {
          'charging' || 'charge_done' || 'chargecompleted' => Activity.docked,
          'goto_charge' || 'goto_pos' || 'back' => Activity.returning,
          'paused' || 'pause' => Activity.paused,
          'standby' || 'sleep' => Activity.idle,
          'fault' || 'error' => Activity.error,
          '' => s['power_go'] == true ? Activity.running : Activity.idle,
          _ => Activity.running,
        };
        final battery = s['electricity_left'] ?? s['battery_percentage'];
        return DeviceState(activity: activity, battery: battery == null ? null : _num(battery).clamp(0, 100) / 100);
      case DeviceKind.fan || DeviceKind.purifier:
        final speed = p['speed'] == null ? null : s[p['speed']];
        return DeviceState(
          on: s[on] as bool?,
          speed: speed == null ? null : _between(_num(speed), _num(p['speedMin'] ?? 1), _num(p['speedMax'] ?? 100)),
          mode: p['mode'] == null ? null : s[p['mode']] as String?,
          readings: readingsOf(s),
        );
      default:
        return DeviceState(
          on: on == null ? null : s[on] as bool?,
          readings: on == null || p['meter'] == true ? readingsOf(s) : const {},
        );
    }
  }

  static Map? _colour(Object? v) {
    if (v is Map) return v;
    if (v is String && v.trim().startsWith('{')) {
      try {
        return jsonDecode(v) as Map;
      } catch (_) {}
    }
    return null;
  }

  static int _scaleTo(double v, num min, num max) => (min + v.clamp(0, 1) * (max - min)).round();

  /// The commands that carry out [c] on [d].
  static List<Map<String, dynamic>> commandsFor(Device d, DeviceCommand c) {
    final p = d.props;
    final on = p['on'] as String?;
    final out = <Map<String, dynamic>>[];
    void add(String? code, Object value) {
      if (code != null) out.add({'code': code, 'value': value});
    }

    switch (d.kind) {
      case DeviceKind.light:
        if (c.on != null) add(on, c.on!);
        final max = _num(p['colourMax'] ?? 1000);
        if (c.color != null && p['colour'] != null) {
          final hsv = rgbToHsv(c.color!);
          add(p['mode'] as String?, 'colour');
          add(p['colour'] as String, {
            'h': hsv[0].round(),
            's': (hsv[1] * max).round(),
            'v': ((c.brightness ?? d.state.brightness ?? 1) * max).round().clamp(1, max.toInt()),
          });
          if (c.on == null) add(on, true);
          break;
        }
        if (c.colorTempK != null && p['temp'] != null) {
          add(p['mode'] as String?, 'white');
          add(p['temp'] as String, _scaleTo((c.colorTempK! - 2700) / 3800, 0, _num(p['tempMax'] ?? 1000)));
        }
        if (c.brightness != null) {
          final colour = d.state.color != null && d.state.colorTempK == null && c.colorTempK == null;
          if (colour && p['colour'] != null) {
            final hsv = rgbToHsv(d.state.color!);
            add(p['colour'] as String, {'h': hsv[0].round(), 's': (hsv[1] * max).round(), 'v': (c.brightness! * max).round().clamp(1, max.toInt())});
          } else if (p['bright'] != null) {
            add(p['bright'] as String, _scaleTo(c.brightness!, _num(p['brightMin'] ?? 10), _num(p['brightMax'] ?? 1000)));
          }
          if (c.on == null) add(on, c.brightness! > 0);
        }
      case DeviceKind.cover || DeviceKind.garage:
        if (c.position != null) {
          if (p['percent'] != null && c.position! > 0 && c.position! < 1) {
            add(p['percent'] as String, (c.position! * 100).round());
          } else if (p['control'] != null) {
            add(p['control'] as String, c.position! >= 0.5 ? 'open' : 'close');
          } else {
            add(p['percent'] as String?, (c.position! * 100).round());
          }
        }
        if (c.action == DeviceAction.stop) add(p['control'] as String?, 'stop');
      case DeviceKind.climate:
        if (c.on != null) add(on, c.on!);
        if (c.targetTemp != null) {
          final scale = _num(p['targetScale'] ?? 0).toInt().clamp(0, 3);
          add(p['target'] as String, (c.targetTemp! * [1, 10, 100, 1000][scale]).round());
        }
        if (c.mode != null) add(p['mode'] as String?, c.mode!);
      case DeviceKind.vacuum:
        switch (c.action) {
          case DeviceAction.start:
            add('power_go', true);
          case DeviceAction.pause || DeviceAction.stop:
            add('power_go', false);
          case DeviceAction.dock:
            if (p['charge'] != null) {
              add(p['charge'] as String, true);
            } else if (p['chargeMode'] == true) {
              add('mode', 'chargego');
            }
          default:
        }
      case DeviceKind.fan || DeviceKind.purifier:
        if (c.on != null) add(on, c.on!);
        if (c.speed != null && p['speed'] != null) {
          add(p['speed'] as String, _scaleTo(c.speed!, _num(p['speedMin'] ?? 1), _num(p['speedMax'] ?? 100)));
          if (c.on == null) add(on, true);
        }
        if (c.mode != null) add(p['mode'] as String?, c.mode!);
      default:
        if (c.on != null) add(on, c.on!);
    }
    return out;
  }
}
