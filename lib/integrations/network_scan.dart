import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import 'lan/plugs.dart';
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

  /// Whether to also knock on TV ports of every address in the local /24.
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

  /// Ports that only TVs listen on, for networks that block multicast.
  static const tvPorts = {8060: 'roku', 8001: 'samsung', 3000: 'webos', 8008: 'cast'};

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
    final List<NetworkInterface> ifaces;
    try {
      ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } catch (_) {
      return;
    }
    final prefixes = <String>{};
    for (final i in ifaces) {
      for (final a in i.addresses) {
        final p = a.address.split('.');
        final private = p[0] == '10' || (p[0] == '192' && p[1] == '168') ||
            (p[0] == '172' && (int.tryParse(p[1]) ?? 0) >= 16 && (int.tryParse(p[1]) ?? 0) < 32);
        if (private) prefixes.add('${p[0]}.${p[1]}.${p[2]}');
      }
    }
    final jobs = <(String, int)>[
      for (final pre in prefixes.take(2))
        for (var i = 1; i < 255; i++)
          for (final port in tvPorts.keys) ('$pre.$i', port),
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final (host, port) = jobs[next++];
        try {
          final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 350));
          s.destroy();
          final protocol = tvPorts[port]!;
          emit(FoundService(
            name: host,
            host: host,
            port: port,
            service: 'port $port',
            integrationType: 'lan',
            // Below SSDP / mDNS answers, which carry the real name.
            hints: {'protocol': protocol},
          ));
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(64, (_) => worker()));
  }

  Future<void> _mdns(void Function(FoundService) emit, Duration timeout) async {
    final client = MDnsClient();
    try {
      await client.start();
    } catch (_) {
      return;
    }
    try {
      // Every service type anyone announces, so unknown devices show up too.
      final types = <String, String?>{...services, ...lanServices};
      try {
        await for (final ptr in client.lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_services._dns-sd._udp.local'),
            timeout: const Duration(seconds: 2))) {
          final t = ptr.domainName.replaceFirst(RegExp(r'\.local\.?$'), '');
          if (types.length < 40) types.putIfAbsent(t, () => 'generic');
        }
      } catch (_) {}

      await Future.wait(types.entries.map((svc) async {
        await for (final ptr in client
            .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('${svc.key}.local'), timeout: timeout)) {
          var instance = ptr.domainName.split('.').first;
          final isLan = svc.value == 'generic' || lanServices.containsKey(svc.key);
          var type = isLan ? 'lan' : svc.value;
          if (type == 'http') {
            type = guessFromName(instance);
            if (type == 'skip') continue;
          }
          final hints = <String, String>{if (isLan) 'protocol': svc.value!, 'service': svc.key};
          if (svc.key == '_googlecast._tcp') {
            await for (final txt in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName),
                timeout: const Duration(seconds: 1))) {
              for (final line in txt.text.split('\n')) {
                if (line.startsWith('fn=')) instance = line.substring(3);
                if (line.startsWith('md=')) hints['model'] = line.substring(3);
              }
              break;
            }
          }
          if (isLan) hints['name'] = instance;
          await for (final srv in client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName), timeout: timeout)) {
            await for (final ip in client.lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target), timeout: timeout)) {
              emit(FoundService(
                name: instance,
                host: ip.address.address,
                port: srv.port,
                service: svc.key,
                integrationType: type,
                hints: {...hints, 'port': '${srv.port}'},
              ));
              break;
            }
          }
        }
      }));
    } catch (_) {
      // Some networks block multicast; the other searches still run.
    } finally {
      client.stop();
    }
  }
}
