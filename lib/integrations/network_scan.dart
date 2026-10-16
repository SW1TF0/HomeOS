import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'lan/mdns.dart';
import 'lan/net.dart';
import 'lan/plugs.dart';
import 'lan/sweep.dart';
import 'lan/upnp.dart';

/// Something found on the local network.
class FoundService {
  const FoundService({
    required this.name,
    required this.host,
    required this.port,
    required this.service,
    this.integrationType,
    this.hints = const {},
  });

  final String name;
  final String host;
  final int port;
  final String service;

  /// Which integration can use it, or null when it needs Home Assistant (Matter).
  /// `lan` means the Network devices connection.
  final String? integrationType;

  /// What discovery learned, passed on to the Network devices connection.
  final Map<String, String> hints;

  bool get isLan => integrationType == 'lan';
  String get protocol => hints['protocol'] ?? 'generic';

  /// Address to store in an integration's settings. Hue and ESPHome advertise
  /// other ports (HTTPS, native API) than the HTTP API this app uses.
  String get address => switch (integrationType) {
        'homeassistant' => 'http://$host:$port',
        'hue' || 'esphome' || 'mqtt' || 'lan' => host,
        _ => port == 80 || port == 0 ? host : '$host:$port',
      };

  /// Network devices are one entry per address, whatever they announce.
  String get key => isLan ? 'lan|$host' : '$integrationType|$host|$port';

  static const protocolLabels = {
    'roku': 'Roku',
    'samsung': 'Samsung TV',
    'webos': 'LG TV',
    'sony': 'Sony TV',
    'cast': 'Google Cast',
    'kasa': 'TP-Link Kasa',
    'yeelight': 'Yeelight',
    'wemo': 'Belkin WeMo',
    'upnp': 'Media player',
    'generic': 'Network device',
  };

  /// How sure discovery is about what this is. Better guesses replace worse ones.
  int get rank =>
      switch (protocol) {
        'generic' => 0,
        'upnp' => 2,
        _ => 4,
      } +
      (name != host ? 1 : 0);
}

/// Looks for devices with mDNS (Bonjour), SSDP (UPnP), the Kasa and Yeelight
/// broadcasts, a quick check of TV ports, and the free Hue discovery endpoint.
class NetworkScanner {
  NetworkScanner({http.Client? client, this.sweep = true}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Whether to also knock on every address in the local /24, so devices that
  /// announce nothing still show up.
  final bool sweep;

  static const services = {
    '_hue._tcp': 'hue',
    '_shelly._tcp': 'shelly',
    '_wled._tcp': 'wled',
    '_esphomelib._tcp': 'esphome',
    '_home-assistant._tcp': 'homeassistant',
    '_mqtt._tcp': 'mqtt',
    '_matter._tcp': null,
    '_matterc._udp': null,
    '_http._tcp': 'http',
  };

  /// mDNS services of things the Network devices connection handles, with the protocol to try.
  static const lanServices = {
    '_googlecast._tcp': 'cast',
    '_airplay._tcp': 'generic',
    '_spotify-connect._tcp': 'generic',
    '_androidtvremote2._tcp': 'generic',
    '_sonos._tcp': 'generic',
    '_hap._tcp': 'generic',
    '_ipp._tcp': 'generic',
    '_printer._tcp': 'generic',
    '_smb._tcp': 'generic',
    '_companion-link._tcp': 'generic',
  };

  static const _lock = MethodChannel('smartmenukj/multicast');

  /// Guesses the integration for a generic `_http._tcp` service from its name.
  static String? guessFromName(String name) {
    final n = name.toLowerCase();
    if (n.startsWith('shelly')) return 'shelly';
    if (n.contains('tasmota')) return 'tasmota';
    if (n.startsWith('wled')) return 'wled';
    return 'skip';
  }

  Stream<FoundService> scan({Duration timeout = const Duration(seconds: 4)}) {
    final out = StreamController<FoundService>();
    final lan = <String, FoundService>{};
    final familyHosts = <String>{};
    final seen = <String>{};
    void emit(FoundService s) {
      if (out.isClosed) return;
      if (s.isLan) {
        if (familyHosts.contains(s.host)) return;
        final before = lan[s.host];
        if (before != null && before.rank >= s.rank) return;
        lan[s.host] = s;
        out.add(s);
        return;
      }
      if (s.integrationType != null) familyHosts.add(s.host);
      if (seen.add(s.key)) out.add(s);
    }

    Future<void> run() async {
      try {
        await _lock.invokeMethod('acquire');
      } catch (_) {}
      await Future.wait([
        _hueCloud(emit),
        _mdns(emit, timeout),
        _ssdp(emit, timeout),
        kasaBroadcast((host, info) => emit(FoundService(
              name: '${info['alias'] ?? 'Kasa device'}',
              host: host,
              port: 9999,
              service: 'Kasa',
              integrationType: 'lan',
              hints: {'protocol': 'kasa', 'name': '${info['alias'] ?? 'Kasa device'}'},
            ))),
        yeelightSearch((host, h) => emit(FoundService(
              name: (h['name'] ?? '').isEmpty ? 'Yeelight' : h['name']!,
              host: host,
              port: 55443,
              service: 'Yeelight',
              integrationType: 'lan',
              hints: {'protocol': 'yeelight', 'model': h['model'] ?? '', if ((h['name'] ?? '').isNotEmpty) 'name': h['name']!},
            ))),
        if (sweep) _sweep(emit),
      ]);
      try {
        await _lock.invokeMethod('release');
      } catch (_) {}
      await out.close();
    }

    run();
    return out.stream;
  }

  Future<void> _hueCloud(void Function(FoundService) emit) async {
    try {
      final res = await _client.get(Uri.parse('https://discovery.meethue.com/')).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return;
      for (final b in (jsonDecode(res.body) as List).whereType<Map>()) {
        final ip = b['internalipaddress'] as String?;
        if (ip != null) {
          emit(FoundService(name: 'Hue bridge', host: ip, port: 80, service: '_hue._tcp', integrationType: 'hue'));
        }
      }
    } catch (_) {}
  }

  Future<void> _ssdp(void Function(FoundService) emit, Duration timeout) async {
    final locations = <String>{};
    final pending = <Future<void>>[];
    await for (final r in ssdpSearch(timeout: timeout)) {
      final loc = r.location;
      if (loc == null || !locations.add(loc)) continue;
      final uri = Uri.tryParse(loc);
      if (uri == null) continue;
      pending.add(() async {
        final desc = await fetchDescription(_client, uri);
        final hints = desc?.hints(uri, server: r.server) ??
            {'location': loc, 'server': r.server, 'protocol': r.st.startsWith('roku') ? 'roku' : 'generic'};
        emit(FoundService(
          name: desc?.friendlyName ?? r.host,
          host: r.host,
          port: uri.port,
          service: 'UPnP',
          integrationType: 'lan',
          hints: hints,
        ));
      }());
    }
    await Future.wait(pending);
  }

  Future<void> _sweep(void Function(FoundService) emit) async {
    final nets = await localNetworks();
    final own = nets.map((n) => n.address.address).toSet();
    final hosts = <String>[
      for (final pre in nets.map((n) => n.prefix24).toSet().take(2))
        for (var i = 1; i < 255; i++)
          if (!own.contains('$pre.$i')) '$pre.$i',
    ];
    final named = <Future<void>>[];
    await sweepHosts(hosts, (hit) {
      named.add(() async {
        final protocol = guessFromPorts(hit.openPorts);
        final label = labelFromPorts(hit.openPorts);
        final name = await reverseName(hit.host) ?? (label == 'Device' ? null : label);
        emit(FoundService(
          name: name ?? hit.host,
          host: hit.host,
          port: hit.openPorts.isEmpty ? 0 : hit.openPorts.first,
          service: 'Network',
          integrationType: 'lan',
          hints: {
            'protocol': protocol ?? 'generic',
            if (hit.openPorts.isNotEmpty) 'port': '${hit.openPorts.first}',
            'name': ?name,
          },
        ));
      }());
    });
    await Future.wait(named);
  }

  Future<void> _mdns(void Function(FoundService) emit, Duration timeout) async {
    final types = <String, String?>{...services, ...lanServices};
    await mdnsBrowse(types.keys, (svc) {
      // Types learned only by asking "what is out there" are network devices.
      final known = types.containsKey(svc.type);
      final value = known ? types[svc.type] : 'generic';
      final isLan = value == 'generic' || lanServices.containsKey(svc.type);
      var type = isLan ? 'lan' : value;
      if (type == 'http') {
        type = guessFromName(svc.instance);
        if (type == 'skip') return;
      }
      var name = svc.instance;
      final hints = <String, String>{if (isLan) 'protocol': value!, 'service': svc.type};
      if (svc.type == '_googlecast._tcp') {
        name = svc.txt['fn'] ?? name;
        if (svc.txt['md'] != null) hints['model'] = svc.txt['md']!;
      }
      if (isLan) hints['name'] = name;
      emit(FoundService(
        name: name,
        host: svc.host,
        port: svc.port ?? 0,
        service: svc.type,
        integrationType: type,
        hints: {...hints, if (svc.port != null) 'port': '${svc.port}'},
      ));
    }, timeout: timeout);
  }
}
