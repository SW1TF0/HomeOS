import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

/// Something found on the local network.
class FoundService {
  const FoundService({
    required this.name,
    required this.host,
    required this.port,
    required this.service,
    this.integrationType,
  });

  final String name;
  final String host;
  final int port;
  final String service;

  /// Which integration can use it, or null when it needs Home Assistant (Matter).
  final String? integrationType;

  /// Address to store in an integration's settings. Hue and ESPHome advertise
  /// other ports (HTTPS, native API) than the HTTP API this app uses.
  String get address => switch (integrationType) {
        'homeassistant' => 'http://$host:$port',
        'hue' || 'esphome' || 'mqtt' => host,
        _ => port == 80 || port == 0 ? host : '$host:$port',
      };

  String get key => '$integrationType|$host|$port';
}

/// Looks for smart home devices with mDNS (Bonjour) and the free Hue discovery endpoint.
class NetworkScanner {
  NetworkScanner({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

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
    final seen = <String>{};
    void emit(FoundService s) {
      if (seen.add(s.key) && !out.isClosed) out.add(s);
    }

    Future<void> run() async {
      await Future.wait([_hueCloud(emit), _mdns(emit, timeout)]);
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

  Future<void> _mdns(void Function(FoundService) emit, Duration timeout) async {
    final client = MDnsClient();
    try {
      await client.start();
    } catch (_) {
      return;
    }
    try {
      await Future.wait(services.entries.map((svc) async {
        await for (final ptr in client
            .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('${svc.key}.local'), timeout: timeout)) {
          final instance = ptr.domainName.split('.').first;
          var type = svc.value;
          if (type == 'http') {
            type = guessFromName(instance);
            if (type == 'skip') continue;
          }
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
              ));
              break;
            }
          }
        }
      }));
    } catch (_) {
      // Some networks block multicast; the Hue cloud lookup still runs.
    } finally {
      client.stop();
    }
  }
}
