import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/md5.dart';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// The router turned down the user name or password.
class RouterLoginException extends IntegrationException {
  RouterLoginException() : super('The router did not accept that user name and password.');
}

/// One way into a MikroTik router. Every value comes back as text, as RouterOS shows it.
abstract class RouterOs {
  /// Every entry of a menu, like `/interface` (a menu with one entry, like `/system/resource`, gives one).
  Future<List<Map<String, String>>> print(String menu);

  /// Runs a command, like `/system/identity/set` with `name`.
  Future<List<Map<String, String>>> run(String command, [Map<String, String> args = const {}]);

  Future<void> close() async {}
}

Map<String, String> _texts(Map m) => {for (final e in m.entries) '${e.key}': e.value is String ? e.value as String : '${e.value}'};

/// The REST API of RouterOS 7, served by the router's web page (WebFig) on port 80.
class RouterOsRest implements RouterOs {
  RouterOsRest(this.ctx, this.host, this.user, this.password);
  final LanContext ctx;
  final String host;
  final String user;
  final String password;

  Map<String, String> get _headers => {
        'Authorization': 'Basic ${base64.encode(utf8.encode('$user:$password'))}',
        'Content-Type': 'application/json',
      };

  List<Map<String, String>> _decode(String body, int status) {
    if (status == 401) throw RouterLoginException();
    if (status == 404) throw const RouterOsMissing();
    dynamic j;
    try {
      j = body.trim().isEmpty ? const [] : jsonDecode(body);
    } catch (_) {
      throw IntegrationException('The router gave an answer this app does not understand (HTTP $status).');
    }
    if (status >= 400) {
      final why = j is Map ? (j['detail'] ?? j['message']) : null;
      throw IntegrationException(why == null ? 'The router refused that (HTTP $status).' : 'The router said: $why');
    }
    if (j is List) return [for (final e in j.whereType<Map>()) _texts(e)];
    if (j is Map) return [_texts(j)];
    return const [];
  }

  @override
  Future<List<Map<String, String>>> print(String menu) async {
    final res = await ctx.get(ctx.url(host, 80, '/rest$menu'), headers: _headers);
    return _decode(utf8.decode(res.bodyBytes, allowMalformed: true), res.statusCode);
  }

  @override
  Future<List<Map<String, String>>> run(String command, [Map<String, String> args = const {}]) async {
    final res = await ctx.post(ctx.url(host, 80, '/rest$command'), jsonEncode(args), headers: _headers);
    return _decode(utf8.decode(res.bodyBytes, allowMalformed: true), res.statusCode);
  }

  @override
  Future<void> close() async {}
}

/// The router has no REST API (RouterOS 6, or its web page is off).
class RouterOsMissing implements Exception {
  const RouterOsMissing();
}

/// The API of RouterOS 6 and 7 on port 8728: sentences of length-prefixed words.
class RouterOsApi implements RouterOs {
  RouterOsApi._(this._socket) {
    _socket.listen(_onData, onDone: _onDone, onError: (_) => _onDone(), cancelOnError: true);
  }

  final Socket _socket;
  final _buffer = BytesBuilder();
  final _sentences = <List<String>>[];
  final _waiting = <Completer<List<String>?>>[];
  bool _closed = false;

  /// Opens the API at [host] and logs in.
  static Future<RouterOsApi> open(LanContext ctx, String host, String user, String password) async {
    final Socket s;
    try {
      s = await ctx.connect(host, 8728);
    } catch (_) {
      throw IntegrationException('The router at $host does not answer. Turn on its web page or API: in WinBox, '
          'IP > Services, enable www or api.');
    }
    final api = RouterOsApi._(s);
    try {
      await api.login(user, password);
    } catch (_) {
      await api.close();
      rethrow;
    }
    return api;
  }

  Future<void> login(String user, String password) async {
    final List<Map<String, String>> first;
    try {
      first = await _talk(['/login', '=name=$user', '=password=$password']);
    } on IntegrationException {
      throw RouterLoginException();
    }
    // Before RouterOS 6.43 the router answers with a challenge for an MD5 of the password.
    final challenge = _done?['ret'];
    if (first.isEmpty && challenge != null && challenge.length == 32) {
      final bytes = [0, ...utf8.encode(password), ..._hex(challenge)];
      final digest = MD5Digest().process(Uint8List.fromList(bytes));
      try {
        await _talk(['/login', '=name=$user', '=response=00${digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}']);
      } on IntegrationException {
        throw RouterLoginException();
      }
    }
  }

  static List<int> _hex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

  /// The values on the last `!done`.
  Map<String, String>? _done;

  static List<int> encodeLength(int n) {
    if (n < 0x80) return [n];
    if (n < 0x4000) return [(n >> 8) | 0x80, n & 0xff];
    if (n < 0x200000) return [(n >> 16) | 0xc0, (n >> 8) & 0xff, n & 0xff];
    if (n < 0x10000000) return [(n >> 24) | 0xe0, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
    return [0xf0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
  }

  /// Reads a length at [i]: (length, bytes it took), or null when [b] is too short.
  static (int, int)? decodeLength(List<int> b, int i) {
    if (i >= b.length) return null;
    final c = b[i];
    int need;
    if (c & 0x80 == 0) {
      return (c, 1);
    } else if (c & 0xc0 == 0x80) {
      need = 2;
    } else if (c & 0xe0 == 0xc0) {
      need = 3;
    } else if (c & 0xf0 == 0xe0) {
      need = 4;
    } else {
      need = 5;
    }
    if (i + need > b.length) return null;
    var n = need == 5 ? 0 : c & (0xff >> need);
    for (var k = 1; k < need; k++) {
      n = (n << 8) | b[i + k];
    }
    return (n, need);
  }

  static List<int> encodeSentence(List<String> words) => [
        for (final w in words) ...[...encodeLength(utf8.encode(w).length), ...utf8.encode(w)],
        0,
      ];

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    var b = _buffer.toBytes();
    var start = 0;
    while (true) {
      final words = <String>[];
      var i = start;
      var complete = false;
      while (true) {
        final len = decodeLength(b, i);
        if (len == null) break;
        final (n, used) = len;
        if (n == 0) {
          i += used;
          complete = true;
          break;
        }
        if (i + used + n > b.length) break;
        words.add(utf8.decode(b.sublist(i + used, i + used + n), allowMalformed: true));
        i += used + n;
      }
      if (!complete) break;
      start = i;
      _deliver(words);
    }
    if (start > 0) {
      b = b.sublist(start);
      _buffer
        ..clear()
        ..add(b);
    }
  }

  void _deliver(List<String> words) {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(words);
    } else {
      _sentences.add(words);
    }
  }

  void _onDone() {
    _closed = true;
    for (final w in _waiting) {
      w.complete(null);
    }
    _waiting.clear();
  }

  Future<List<String>?> _next() {
    if (_sentences.isNotEmpty) return Future.value(_sentences.removeAt(0));
    if (_closed) return Future.value(null);
    final c = Completer<List<String>?>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
  }

  static Map<String, String> _attributes(List<String> words) => {
        for (final w in words.skip(1))
          if (w.startsWith('=') && w.indexOf('=', 1) > 0) w.substring(1, w.indexOf('=', 1)): w.substring(w.indexOf('=', 1) + 1),
      };

  /// Commands go one at a time: replies carry no sign of which command they answer.
  Future<void> _turn = Future.value();

  Future<List<Map<String, String>>> _talk(List<String> words) {
    final mine = _turn.then((_) => _talkNow(words));
    _turn = mine.then((_) {}, onError: (_) {});
    return mine;
  }

  /// Sends one command and collects its `!re` replies until `!done`.
  Future<List<Map<String, String>>> _talkNow(List<String> words) async {
    if (_closed) throw IntegrationException('The connection to the router closed.');
    _socket.add(encodeSentence(words));
    final out = <Map<String, String>>[];
    String? trap;
    while (true) {
      final s = await _next();
      if (s == null) throw IntegrationException('The router stopped answering.');
      if (s.isEmpty) continue;
      switch (s.first) {
        case '!re':
          out.add(_attributes(s));
        case '!trap':
          trap = _attributes(s)['message'] ?? 'error';
        case '!fatal':
          throw IntegrationException('The router closed the connection: ${s.skip(1).join(' ')}');
        case '!done':
          _done = _attributes(s);
          if (trap != null) throw IntegrationException('The router said: $trap');
          return out;
      }
    }
  }

  @override
  Future<List<Map<String, String>>> print(String menu) => _talk(['$menu/print']);

  @override
  Future<List<Map<String, String>>> run(String command, [Map<String, String> args = const {}]) =>
      _talk([command, for (final e in args.entries) '=${e.key}=${e.value}']);

  @override
  Future<void> close() async {
    _closed = true;
    _socket.destroy();
  }
}

/// A Wi-Fi network the router sends out.
class RouterWifi {
  const RouterWifi(this.menu, this.entry, {this.ssid, this.band});
  final String menu;
  final Map<String, String> entry;
  final String? ssid;
  final String? band;

  String get id => entry['.id'] ?? '';
  String get name => entry['name'] ?? '';
  bool get enabled => entry['disabled'] != 'true' && entry['disabled'] != 'yes';
  bool get running => entry['running'] == 'true';

  /// RouterOS 7's wifi menus (`wifi`, `wifiwave2`) keep the name and password on the interface.
  bool get modern => menu != '/interface/wireless';
}

/// Something with an address on the router's network.
class RouterClient {
  const RouterClient(this.entry);
  final Map<String, String> entry;
  String get id => entry['.id'] ?? '';
  String get address => entry['active-address'] ?? entry['address'] ?? '';
  String get mac => entry['active-mac-address'] ?? entry['mac-address'] ?? '';
  String get name {
    final c = entry['comment'] ?? '';
    final h = entry['host-name'] ?? '';
    return c.isNotEmpty ? c : (h.isNotEmpty ? h : address);
  }

  bool get online => entry['status'] == 'bound';

  /// Whether the router hands out this address only for a while.
  bool get dynamic => entry['dynamic'] == 'true';
}

/// Everything shown about a router at once.
class RouterSnapshot {
  const RouterSnapshot({
    required this.resource,
    required this.identity,
    required this.interfaces,
    required this.wifi,
    required this.clients,
  });
  final Map<String, String> resource;
  final String identity;
  final List<Map<String, String>> interfaces;
  final List<RouterWifi> wifi;
  final List<RouterClient> clients;

  String get model => resource['board-name'] ?? '';
  String get version => (resource['version'] ?? '').split(' ').first;
  String get uptime => uptimeText(resource['uptime'] ?? '');
  String get cpu => resource['cpu-load'] == null ? '' : '${resource['cpu-load']}%';

  /// Memory in use, as a share.
  String get memory {
    final free = int.tryParse(resource['free-memory'] ?? '');
    final total = int.tryParse(resource['total-memory'] ?? '');
    if (free == null || total == null || total == 0) return '';
    return '${((total - free) * 100 / total).round()}%';
  }

  /// The router's ports and connections people switch on and off; bridges and VLANs are left alone.
  List<Map<String, String>> get ports => interfaces
      .where((i) => const {'ether', 'sfp', 'sfp-sfpplus', 'pppoe-out', 'lte', 'wlan', 'wifi', 'l2tp-out', 'ovpn-out', 'wg'}
          .contains(i['type']))
      .toList();
}

/// "1w2d3h4m5s" as "9 days 3 h".
String uptimeText(String raw) {
  final parts = {for (final m in RegExp(r'(\d+)([wdhms])').allMatches(raw)) m.group(2)!: int.parse(m.group(1)!)};
  if (parts.isEmpty) return raw;
  final days = (parts['w'] ?? 0) * 7 + (parts['d'] ?? 0);
  final h = parts['h'] ?? 0;
  final m = parts['m'] ?? 0;
  if (days > 0) return '${days == 1 ? '1 day' : '$days days'} $h h';
  if (h > 0) return '$h h $m min';
  return '$m min';
}

/// A MikroTik router: what it is doing and the settings people change most.
class MikroTik {
  MikroTik(this.os);
  final RouterOs os;

  static const wifiMenus = ['/interface/wifi', '/interface/wifiwave2', '/interface/wireless'];

  Future<List<Map<String, String>>> _maybe(String menu) async {
    try {
      return await os.print(menu);
    } on RouterLoginException {
      rethrow;
    } catch (_) {
      return const [];
    }
  }

  Future<List<RouterWifi>> wifi() async {
    for (final menu in wifiMenus) {
      final list = await _maybe(menu);
      if (list.isEmpty) continue;
      final configs = menu == '/interface/wireless' ? const <Map<String, String>>[] : await _maybe('$menu/configuration');
      return [
        for (final e in list)
          RouterWifi(
            menu,
            e,
            ssid: e['ssid'] ??
                e['configuration.ssid'] ??
                configs.where((c) => c['name'] == e['configuration']).firstOrNull?['ssid'],
            band: e['band'] ?? e['channel.band'] ?? e['configuration.channel.band'],
          ),
      ];
    }
    return const [];
  }

  Future<RouterSnapshot> load() async {
    final resource = await os.print('/system/resource');
    final results = await Future.wait([
      _maybe('/system/identity'),
      _maybe('/interface'),
      wifi(),
      _maybe('/ip/dhcp-server/lease'),
    ]);
    return RouterSnapshot(
      resource: resource.firstOrNull ?? const {},
      identity: (results[0] as List<Map<String, String>>).firstOrNull?['name'] ?? '',
      interfaces: results[1] as List<Map<String, String>>,
      wifi: results[2] as List<RouterWifi>,
      clients: [for (final e in results[3] as List<Map<String, String>>) RouterClient(e)]
        ..sort((a, b) => a.online == b.online ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : (a.online ? -1 : 1)),
    );
  }

  Future<void> setEnabled(String menu, String id, bool on) => os.run('$menu/set', {'.id': id, 'disabled': on ? 'no' : 'yes'});

  Future<void> setWifiName(RouterWifi w, String ssid) =>
      os.run('${w.menu}/set', {'.id': w.id, w.modern ? 'configuration.ssid' : 'ssid': ssid});

  Future<void> setWifiPassword(RouterWifi w, String password) async {
    if (password.length < 8) throw IntegrationException('A Wi-Fi password needs at least 8 characters.');
    if (w.modern) {
      await os.run('${w.menu}/set', {'.id': w.id, 'security.passphrase': password});
      return;
    }
    final profile = w.entry['security-profile'] ?? 'default';
    final profiles = await os.print('/interface/wireless/security-profiles');
    final id = profiles.where((p) => p['name'] == profile).firstOrNull?['.id'] ?? profile;
    await os.run('/interface/wireless/security-profiles/set',
        {'.id': id, 'wpa2-pre-shared-key': password, 'wpa-pre-shared-key': password});
  }

  Future<void> rename(String name) => os.run('/system/identity/set', {'name': name});

  /// Makes the router always give [c] the same address, so the device keeps it in the app.
  Future<void> keepAddress(RouterClient c) => os.run('/ip/dhcp-server/lease/make-static', {'.id': c.id});

  Future<void> reboot() async {
    try {
      await os.run('/system/reboot');
    } on IntegrationException {
      // The router goes away mid-answer.
    }
  }
}

/// MikroTik routers: their state on the device, and their settings on the router screen. Needs the router's login.
class MikroTikProtocol extends LanProtocol {
  const MikroTikProtocol();

  @override
  String get id => 'mikrotik';
  @override
  String get label => 'MikroTik router';

  static const _needsLogin = DeviceState(readings: {'Status': 'Needs its login'});

  /// Whether [host] is a MikroTik: WinBox listens on 8291, and its web page says RouterOS.
  static Future<bool> isOne(LanContext ctx, String host) async {
    if (await ctx.tcpOpen(host, 8291, within: const Duration(milliseconds: 900))) return true;
    try {
      final res = await ctx.get(ctx.url(host, 80, '/'));
      final body = res.body.toLowerCase();
      return body.contains('routeros') || body.contains('mikrotik');
    } catch (_) {
      return false;
    }
  }

  /// Logs in to the router of [device] (its saved login, or the factory admin with no password).
  static Future<RouterOs> open(LanContext ctx, Device device) =>
      openAt(ctx, device.props['host'] as String,
          user: '${device.props['username'] ?? 'admin'}', password: '${device.props['password'] ?? ''}',
          via: device.props['api'] as String?);

  static Future<RouterOs> openAt(LanContext ctx, String host, {String user = 'admin', String password = '', String? via}) async {
    if (via != 'api') {
      final rest = RouterOsRest(ctx, host, user, password);
      try {
        await rest.print('/system/identity');
        return rest;
      } on RouterLoginException {
        rethrow;
      } catch (_) {
        if (via == 'rest') rethrow;
      }
    }
    return RouterOsApi.open(ctx, host, user, password);
  }

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    if (hints['protocol'] != id && !await isOne(ctx, host)) return null;
    final device = ctx.make(
      externalId: 'mikrotik:$host',
      name: hints['name'] ?? 'MikroTik router',
      kind: DeviceKind.router,
      capabilities: {Capability.readings},
      props: {
        'host': host,
        'protocol': id,
        'username': hints['username'] ?? 'admin',
        if ((hints['password'] ?? '').isNotEmpty) 'password': hints['password'],
        'api': ?hints['api'],
        'mac': ?hints['mac'],
      },
    );
    try {
      final os = await open(ctx, device);
      try {
        final snap = await MikroTik(os).load();
        device.props['api'] = os is RouterOsApi ? 'api' : 'rest';
        if (snap.model.isNotEmpty) device.props['model'] = 'MikroTik ${snap.model}';
        if (hints['name'] == null && snap.identity.isNotEmpty) device.name = snap.identity;
        device.state = stateOf(snap);
      } finally {
        await os.close();
      }
    } on RouterLoginException {
      device.state = _needsLogin;
    } catch (_) {
      device.state = _needsLogin;
    }
    return [device];
  }

  static DeviceState stateOf(RouterSnapshot s) {
    final online = s.clients.where((c) => c.online).length;
    return DeviceState(readings: {
        'Status': 'Online',
        'Uptime': s.uptime,
        'CPU': s.cpu,
        'Connected': online == 1 ? '1 device' : '$online devices',
        if (s.wifi.isNotEmpty) 'Wi-Fi': s.wifi.any((w) => w.enabled) ? 'On' : 'Off',
        'RouterOS': s.version,
      });
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final RouterOs os;
    try {
      os = await open(ctx, device);
    } on RouterLoginException {
      return _needsLogin;
    }
    try {
      return stateOf(await MikroTik(os).load());
    } finally {
      await os.close();
    }
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async =>
      throw IntegrationException('Open ${device.name} and tap Router settings.');

  @override
  List<SettingField> fields(Device device) => const [
        SettingField('username', 'Router user', hint: 'admin', defaultValue: 'admin'),
        SettingField('password', 'Router password', hint: 'On the sticker under the router, or the one you set', secret: true),
      ];
}

/// Opens [d]'s router as a [MikroTik], for the router screen.
Future<MikroTik> openMikroTik(LanContext ctx, Device d) async => MikroTik(await MikroTikProtocol.open(ctx, d));

/// Whether [e] is a socket error a router gives when it reboots or drops the link.
bool isConnectionLost(Object e) => e is SocketException || e is TimeoutException;
