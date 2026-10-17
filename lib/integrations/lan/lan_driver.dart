import 'dart:async';
import 'dart:convert';

import '../../models/device.dart';
import '../integration.dart';
import 'camera.dart';
import 'cast.dart';
import 'lan_protocol.dart';
import 'plugs.dart';
import 'roku.dart';
import 'samsung.dart';
import 'sony.dart';
import 'upnp.dart';
import 'valetudo.dart';
import 'webos.dart';
import 'wol.dart';

/// What was found at an address: devices for this connection, or the name of
/// another connection that already handles that kind of device (Shelly, WLED...).
class LanMatch {
  const LanMatch.devices(this.devices) : family = null;
  const LanMatch.family(String this.family) : devices = const [];

  final List<Device> devices;
  final String? family;
}

/// "Network devices": anything on the home network, added from a scan or by
/// its address. Speaks the local protocols of TVs (Samsung, LG, Sony, Roku,
/// Google Cast), UPnP / DLNA players, Kasa, Yeelight, WeMo and Valetudo robot vacuums, and keeps
/// everything else as an online / offline device that can be woken with
/// Wake-on-LAN.
class LanDriver extends IntegrationDriver {
  LanDriver(super.config, super.client, {Map<int, int> portMap = const {}, bool allowTls = true}) {
    ctx = LanContext(client: client, make: makeDevice, portMap: portMap, allowTls: allowTls);
  }

  late final LanContext ctx;

  /// In order of preference when several answer (a Samsung TV is also a UPnP renderer).
  final List<LanProtocol> protocols = [
    const ValetudoProtocol(),
    const RokuProtocol(),
    SamsungProtocol(),
    SonyProtocol(),
    const CastProtocol(),
    WebOsProtocol(),
    const KasaProtocol(),
    const YeelightProtocol(),
    const WemoProtocol(),
    const UpnpRendererProtocol(),
    const CameraProtocol(),
    const GenericProtocol(),
  ];

  LanProtocol protocolOf(Device d) =>
      protocols.firstWhere((p) => p.id == d.props['protocol'], orElse: () => protocols.last);

  List<Device> _known = [];

  @override
  void attach(Iterable<Device> devices) => _known = devices.toList();

  /// Strips a scheme, path and port from what the user typed.
  static String cleanHost(String raw) {
    var h = raw.trim().replaceFirst(RegExp(r'^[a-z]+://'), '');
    h = h.split('/').first;
    if (h.startsWith('[')) return h; // IPv6 literal
    return h.split(':').first;
  }

  /// Works out what is at [host].
  Future<LanMatch> identify(String host, {Map<String, String> hints = const {}}) async {
    host = cleanHost(host);
    final hinted = hints['protocol'];
    if (hinted != null && hinted != 'generic') {
      final p = protocols.where((p) => p.id == hinted).firstOrNull;
      final found = await _try(p, host, hints);
      if (found != null) return LanMatch.devices(found);
    }
    if (hinted == null || hinted == 'generic') {
      final family = await detectFamily(host);
      if (family != null) return LanMatch.family(family);
    }
    final results = await Future.wait(protocols.map((p) => _try(p, host, hints)));
    for (final r in results) {
      if (r != null) return LanMatch.devices(r);
    }
    return const LanMatch.devices([]);
  }

  Future<List<Device>?> _try(LanProtocol? p, String host, Map<String, String> hints) async {
    if (p == null) return null;
    try {
      final r = await p.identify(ctx, host, hints).timeout(const Duration(seconds: 8));
      return r == null || r.isEmpty ? null : r;
    } catch (_) {
      return null;
    }
  }

  /// Device families that have their own connection in SmartMenuKJ.
  Future<String?> detectFamily(String host) async {
    Future<String?> probe(String path, String type, bool Function(dynamic j) test) async {
      try {
        final res = await ctx.get(ctx.url(host, 80, path));
        if (res.statusCode != 200) return null;
        return test(jsonDecode(res.body)) ? type : null;
      } catch (_) {
        return null;
      }
    }

    final answers = await Future.wait([
      probe('/shelly', 'shelly', (j) => j is Map && (j['mac'] != null || j['gen'] != null || j['type'] != null)),
      probe('/json/info', 'wled', (j) => j is Map && j['leds'] != null),
      probe('/cm?cmnd=Status', 'tasmota', (j) => j is Map && j['Status'] != null),
      probe('/api/config', 'hue', (j) => j is Map && j['bridgeid'] != null),
    ]);
    return answers.whereType<String>().firstOrNull;
  }

  @override
  Future<List<Device>> discover() async {
    final hosts = parseHosts(config.setting('hosts')).map(cleanHost).toSet();
    final out = <Device>[];
    for (final host in hosts) {
      // Re-use what was learned when the device was first added.
      final known = _known.where((d) => d.props['host'] == host).firstOrNull;
      final hints = <String, String>{
        if (known != null)
          for (final e in known.props.entries)
            if (e.value is String) e.key: e.value as String,
      };
      final match = await identify(host, hints: hints);
      out.addAll(match.devices);
    }
    return out;
  }

  @override
  Future<DeviceState?> refresh(Device device) => protocolOf(device).read(ctx, device);

  @override
  Future<DeviceState?> send(Device device, DeviceCommand command) async {
    final p = protocolOf(device);
    var c = command;
    // The screen already flipped power / mute; send the state it now shows.
    if (c.key == RemoteKey.power && device.has(Capability.onOff) && device.state.on != null) {
      c = DeviceCommand(on: device.state.on);
    } else if (c.key == RemoteKey.mute && device.has(Capability.volume) && device.state.muted != null) {
      c = DeviceCommand(muted: device.state.muted);
    }
    final mac = normalizeMac(device.props['mac'] as String?);
    if (c.on == true || (c.key == RemoteKey.power && !device.has(Capability.onOff))) {
      if (mac != null) {
        await wakeOnLan(mac, host: device.props['host'] as String?);
        // Many TVs also take a network "on" while in standby.
        try {
          await p.send(ctx, device, c).timeout(const Duration(seconds: 4));
        } catch (_) {}
        return const DeviceState(on: true);
      }
      try {
        final r = await p.send(ctx, device, c);
        if (r?.on == true || p is RokuProtocol || p is SonyProtocol || p is KasaProtocol || p is YeelightProtocol || p is WemoProtocol) {
          return r;
        }
      } catch (_) {
        if (p is! SamsungProtocol && p is! WebOsProtocol && p is! GenericProtocol) rethrow;
      }
      throw IntegrationException('${device.name} is switched on with Wake-on-LAN. Open the device, tap Wake-on-LAN and '
          'enter its MAC address (on the TV: Settings > Network > Network status).');
    }
    return p.send(ctx, device, c);
  }

  /// Sends a Wake-on-LAN packet to [device].
  Future<void> wake(Device device) async {
    final mac = normalizeMac(device.props['mac'] as String?);
    if (mac == null) throw IntegrationException('Add the MAC address of ${device.name} first.');
    await wakeOnLan(mac, host: device.props['host'] as String?);
  }

  Future<String?> setUp(Device device) => protocolOf(device).setUp(ctx, device);

  List<SettingField> fields(Device device) => protocolOf(device).fields(device);

  @override
  Future<void> stop() async {
    for (final p in protocols) {
      await p.close();
    }
  }
}
