import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';
import 'net.dart';

/// One answer to an SSDP search.
class SsdpReply {
  const SsdpReply({required this.host, required this.headers});
  final String host;
  final Map<String, String> headers;

  String? get location => headers['location'];
  String get server => headers['server'] ?? '';
  String get st => headers['st'] ?? headers['nt'] ?? '';
}

/// Parses an HTTP-over-UDP SSDP reply into lower-case headers.
Map<String, String> parseSsdpHeaders(String reply) {
  final out = <String, String>{};
  for (final line in reply.split(RegExp(r'\r?\n')).skip(1)) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    out[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
  }
  return out;
}

/// Asks every UPnP device on the network to answer (TVs, speakers, routers,
/// printers, consoles, NAS boxes...).
Stream<SsdpReply> ssdpSearch({Duration timeout = const Duration(seconds: 3), String target = 'ssdp:all'}) {
  final out = StreamController<SsdpReply>();
  Future<void> run() async {
    RawDatagramSocket socket;
    try {
      socket = await lanUdpSocket();
    } catch (_) {
      await out.close();
      return;
    }
    final sub = socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      final text = utf8.decode(d.data, allowMalformed: true);
      if (!text.startsWith('HTTP/1.1 200') && !text.startsWith('NOTIFY')) return;
      out.add(SsdpReply(host: d.address.address, headers: parseSsdpHeaders(text)));
    });
    final msg = utf8.encode('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\n'
        'MX: 2\r\nST: $target\r\nUSER-AGENT: SmartHomeKJ/1.1 UPnP/1.1\r\n\r\n');
    final roku = utf8.encode(utf8.decode(msg).replaceFirst('ST: $target', 'ST: roku:ecp'));
    for (var i = 0; i < 2; i++) {
      trySend(socket, msg, InternetAddress('239.255.255.250'), 1900);
      // Roku only answers its own search target.
      trySend(socket, roku, InternetAddress('239.255.255.250'), 1900);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await Future<void>.delayed(timeout);
    await sub.cancel();
    socket.close();
    await out.close();
  }

  run();
  return out.stream;
}

/// What a UPnP device says about itself in its description XML.
class UpnpDescription {
  const UpnpDescription({
    required this.friendlyName,
    required this.manufacturer,
    required this.model,
    required this.deviceType,
    required this.services,
  });

  final String? friendlyName;
  final String manufacturer;
  final String model;
  final String deviceType;

  /// serviceType -> absolute control URL.
  final Map<String, String> services;

  static UpnpDescription parse(String xml, Uri location) {
    final services = <String, String>{};
    for (final m in RegExp(r'<service>([\s\S]*?)</service>').allMatches(xml)) {
      final type = xmlTag(m.group(1)!, 'serviceType');
      final control = xmlTag(m.group(1)!, 'controlURL');
      if (type != null && control != null) services[type] = location.resolve(control).toString();
    }
    return UpnpDescription(
      friendlyName: xmlTag(xml, 'friendlyName'),
      manufacturer: xmlTag(xml, 'manufacturer') ?? '',
      model: xmlTag(xml, 'modelName') ?? '',
      deviceType: xmlTag(xml, 'deviceType') ?? '',
      services: services,
    );
  }

  String? serviceUrl(String kind) {
    for (final e in services.entries) {
      if (e.key.contains(':service:$kind:')) return e.value;
    }
    return null;
  }

  /// The protocol that should handle this device, from what it says it is.
  String protocolGuess({String server = ''}) {
    final m = '$manufacturer $model $server $deviceType'.toLowerCase();
    if (m.contains('roku')) return 'roku';
    if (m.contains('samsung') && (m.contains('tv') || deviceType.contains('MediaRenderer') || m.contains('tizen'))) {
      return 'samsung';
    }
    if (m.contains('lg electronics') || m.contains('webos') || m.contains('lge')) return 'webos';
    if (m.contains('sony') && (m.contains('bravia') || m.contains('tv') || m.contains('kd-') || m.contains('xr-'))) {
      return 'sony';
    }
    if (m.contains('belkin')) return 'wemo';
    if (m.contains('google') || m.contains('chromecast')) return 'cast';
    if (serviceUrl('RenderingControl') != null) return 'upnp';
    return 'generic';
  }

  Map<String, String> hints(Uri location, {String server = ''}) => {
        'name': ?friendlyName,
        'manufacturer': manufacturer,
        'model': model,
        'deviceType': deviceType,
        'server': server,
        'location': location.toString(),
        'protocol': protocolGuess(server: server),
        if (serviceUrl('RenderingControl') != null) 'rendering': serviceUrl('RenderingControl')!,
        if (serviceUrl('AVTransport') != null) 'transport': serviceUrl('AVTransport')!,
      };
}

Future<UpnpDescription?> fetchDescription(http.Client client, Uri location) async {
  try {
    final res = await client.get(location).timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) return null;
    return UpnpDescription.parse(utf8.decode(res.bodyBytes, allowMalformed: true), location);
  } catch (_) {
    return null;
  }
}

/// Any UPnP / DLNA media renderer: smart TVs of every brand, Sonos and other
/// network speakers, AV receivers, consoles. Volume, mute and play / pause.
class UpnpRendererProtocol extends LanProtocol {
  const UpnpRendererProtocol();

  @override
  String get id => 'upnp';
  @override
  String get label => 'UPnP media player';

  static const _rc = 'urn:schemas-upnp-org:service:RenderingControl:1';
  static const _av = 'urn:schemas-upnp-org:service:AVTransport:1';

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    var rendering = hints['rendering'];
    var transport = hints['transport'];
    var name = hints['name'];
    if (rendering == null && hints['location'] != null) {
      final desc = await fetchDescription(ctx.client, Uri.parse(hints['location']!));
      rendering = desc?.serviceUrl('RenderingControl');
      transport = desc?.serviceUrl('AVTransport');
      name ??= desc?.friendlyName;
    }
    if (rendering == null) return null;
    return [
      tvDevice(
        ctx,
        protocol: id,
        host: host,
        name: name ?? 'Media player',
        keys: [
          RemoteKey.volumeUp,
          RemoteKey.volumeDown,
          RemoteKey.mute,
          if (transport != null) ...[RemoteKey.playPause, RemoteKey.stop, RemoteKey.forward],
        ],
        power: false,
        volume: true,
        props: {
          'rendering': rendering,
          'transport': ?transport,
          'model': hints['model'] ?? '',
          'location': ?hints['location'],
        },
      ),
    ];
  }

  Future<String> _rcCall(LanContext ctx, Device d, String action, [Map<String, String> args = const {}]) => soap(
      ctx, Uri.parse(d.props['rendering'] as String), _rc, action,
      args: {'InstanceID': '0', 'Channel': 'Master', ...args});

  Future<String> _avCall(LanContext ctx, Device d, String action, [Map<String, String> args = const {}]) {
    final url = d.props['transport'] as String?;
    if (url == null) throw unsupported(d, 'play / pause');
    return soap(ctx, Uri.parse(url), _av, action, args: {'InstanceID': '0', ...args});
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final vol = xmlTag(await _rcCall(ctx, device, 'GetVolume'), 'CurrentVolume');
    final mute = xmlTag(await _rcCall(ctx, device, 'GetMute'), 'CurrentMute');
    String? playing;
    if (device.props['transport'] != null) {
      try {
        playing = xmlTag(await _avCall(ctx, device, 'GetTransportInfo'), 'CurrentTransportState');
      } catch (_) {}
    }
    return DeviceState(
      volume: vol == null ? null : (int.tryParse(vol) ?? 0) / 100,
      muted: mute == null ? null : (mute == '1' || mute.toLowerCase() == 'true'),
      readings: playing == null ? const {} : {'Playing': _transportLabel(playing)},
    );
  }

  static String _transportLabel(String s) => switch (s) {
        'PLAYING' => 'Playing',
        'PAUSED_PLAYBACK' => 'Paused',
        'STOPPED' || 'NO_MEDIA_PRESENT' => 'Nothing',
        _ => s.toLowerCase(),
      };

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand c) async {
    if (c.on != null) throw unsupported(device, 'power');
    if (c.volume != null) {
      await _rcCall(ctx, device, 'SetVolume', {'DesiredVolume': '${(c.volume! * 100).round()}'});
      return DeviceState(volume: c.volume);
    }
    if (c.muted != null) {
      await _rcCall(ctx, device, 'SetMute', {'DesiredMute': c.muted! ? '1' : '0'});
      return DeviceState(muted: c.muted);
    }
    switch (c.key) {
      case RemoteKey.volumeUp || RemoteKey.volumeDown:
        final now = int.tryParse(xmlTag(await _rcCall(ctx, device, 'GetVolume'), 'CurrentVolume') ?? '') ?? 20;
        final next = (now + (c.key == RemoteKey.volumeUp ? 2 : -2)).clamp(0, 100);
        await _rcCall(ctx, device, 'SetVolume', {'DesiredVolume': '$next'});
        return DeviceState(volume: next / 100);
      case RemoteKey.mute:
        final m = !(device.state.muted ?? false);
        await _rcCall(ctx, device, 'SetMute', {'DesiredMute': m ? '1' : '0'});
        return DeviceState(muted: m);
      case RemoteKey.playPause:
        final s = xmlTag(await _avCall(ctx, device, 'GetTransportInfo'), 'CurrentTransportState');
        if (s == 'PLAYING') {
          await _avCall(ctx, device, 'Pause');
        } else {
          await _avCall(ctx, device, 'Play', {'Speed': '1'});
        }
        return null;
      case RemoteKey.stop:
        await _avCall(ctx, device, 'Stop');
        return null;
      case RemoteKey.forward:
        await _avCall(ctx, device, 'Next');
        return null;
      case null:
        return null;
      default:
        throw unsupported(device, c.key!.name);
    }
  }
}

/// Anything else on the network: shown with its name and whether it is online,
/// and woken with Wake-on-LAN when its MAC address is known.
class GenericProtocol extends LanProtocol {
  const GenericProtocol();

  @override
  String get id => 'generic';
  @override
  String get label => 'Network device';

  static const ports = [80, 443, 8080, 22, 445, 139, 554, 631, 9100, 5000, 8443, 62078, 7000, 1400, 8008];

  /// Guesses what a device is from what discovery found.
  static DeviceKind kindFrom(Map<String, String> hints) {
    final t = '${hints['deviceType']} ${hints['service']} ${hints['name']} ${hints['model']}'.toLowerCase();
    if (t.contains('camera') || t.contains('_rtsp') || t.contains('onvif') || t.contains('ipc')) return DeviceKind.camera;
    if (t.contains('mediarenderer') || t.contains('airplay') || t.contains('_raop') || t.contains('spotify') ||
        t.contains('tv') || t.contains('speaker') || t.contains('sonos') || t.contains('androidtv')) {
      return DeviceKind.media;
    }
    if (t.contains('thermostat') || t.contains('climate')) return DeviceKind.climate;
    if (t.contains('light') || t.contains('bulb') || t.contains('lamp')) return DeviceKind.light;
    if (t.contains('plug') || t.contains('outlet') || t.contains('socket')) return DeviceKind.outlet;
    return DeviceKind.other;
  }

  /// The address of a device's own web page, when it has one.
  static String? webPage(String host, Iterable<int> open) => switch (open) {
        final o when o.contains(80) => 'http://$host/',
        final o when o.contains(443) => 'https://$host/',
        final o when o.contains(8080) => 'http://$host:8080/',
        final o when o.contains(8443) => 'https://$host:8443/',
        _ => null,
      };

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final candidates = {?int.tryParse(hints['port'] ?? ''), ...ports}.toList();
    final answers = await Future.wait(candidates.map((p) => ctx.knock(host, p, within: const Duration(milliseconds: 900))));
    final open = [for (var i = 0; i < candidates.length; i++) if (answers[i] == true) candidates[i]];
    final web = webPage(host, open);
    return [
      ctx.make(
        externalId: '$id:$host',
        name: hints['name'] ?? host,
        kind: kindFrom(hints),
        capabilities: {Capability.readings},
        props: {
          'host': host,
          'protocol': id,
          'port': ?open.firstOrNull,
          'web': ?web,
          'mac': ?hints['mac'],
          'model': [hints['manufacturer'], hints['model']].where((s) => s != null && s.isNotEmpty).join(' '),
          if (hints['service'] != null) 'service': hints['service'],
        },
        state: _state(host, answers.any((a) => a != null)),
      ),
    ];
  }

  static DeviceState _state(String host, bool online) => DeviceState(
        readings: {'Status': online ? 'Online' : 'Offline', 'Address': host},
      );

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    final host = device.props['host'] as String;
    final port = device.props['port'] as int?;
    // A device that turns a knock down is there too: phones and many gadgets have no open port.
    final answers =
        await Future.wait({?port, ...ports.take(5)}.map((p) => ctx.knock(host, p, within: const Duration(milliseconds: 900))));
    return _state(host, answers.any((a) => a != null));
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    if (command.on == true || command.key == RemoteKey.power) return null; // the driver sends Wake-on-LAN
    throw IntegrationException(
        '${device.name} does not offer a control this app knows yet. If it works with Home Assistant, connect it there.');
  }
}
