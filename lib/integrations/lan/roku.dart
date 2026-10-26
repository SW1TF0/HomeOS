import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';

/// Roku TVs and sticks, over Roku's External Control Protocol (port 8060, no pairing).
class RokuProtocol extends LanProtocol {
  const RokuProtocol();

  @override
  String get id => 'roku';
  @override
  String get label => 'Roku';

  static const keys = {
    RemoteKey.power: 'Power',
    RemoteKey.volumeUp: 'VolumeUp',
    RemoteKey.volumeDown: 'VolumeDown',
    RemoteKey.mute: 'VolumeMute',
    RemoteKey.channelUp: 'ChannelUp',
    RemoteKey.channelDown: 'ChannelDown',
    RemoteKey.up: 'Up',
    RemoteKey.down: 'Down',
    RemoteKey.left: 'Left',
    RemoteKey.right: 'Right',
    RemoteKey.ok: 'Select',
    RemoteKey.back: 'Back',
    RemoteKey.home: 'Home',
    RemoteKey.menu: 'Info',
    RemoteKey.playPause: 'Play',
    RemoteKey.rewind: 'Rev',
    RemoteKey.forward: 'Fwd',
    RemoteKey.source: 'InputHDMI1',
  };

  Future<String> _info(LanContext ctx, String host) async {
    final res = await ctx.get(ctx.url(host, 8060, '/query/device-info'));
    if (res.statusCode != 200 || !res.body.contains('<device-info')) {
      throw IntegrationException('$host is not a Roku.');
    }
    return res.body;
  }

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    final String xml;
    try {
      xml = await _info(ctx, host);
    } catch (_) {
      return null;
    }
    final isTv = xmlTag(xml, 'is-tv') == 'true';
    final name = xmlTag(xml, 'user-device-name') ?? xmlTag(xml, 'friendly-device-name') ?? 'Roku';
    return [
      tvDevice(
        ctx,
        protocol: id,
        host: host,
        name: name,
        // Sticks have no power, channels or inputs of their own.
        keys: keys.keys.where((k) => isTv || !{RemoteKey.power, RemoteKey.channelUp, RemoteKey.channelDown, RemoteKey.source}.contains(k)),
        power: isTv,
        props: {
          'model': xmlTag(xml, 'model-name') ?? '',
          if (xmlTag(xml, 'wifi-mac') != null) 'mac': xmlTag(xml, 'wifi-mac'),
          if (xmlTag(xml, 'ethernet-mac') != null) 'mac': xmlTag(xml, 'ethernet-mac'),
        },
        state: _stateFrom(xml),
      ),
    ];
  }

  DeviceState _stateFrom(String xml) {
    final power = xmlTag(xml, 'power-mode');
    return DeviceState(on: power == null ? null : power == 'PowerOn');
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    try {
      return _stateFrom(await _info(ctx, device.props['host'] as String));
    } catch (_) {
      return offTv;
    }
  }

  Future<void> _press(LanContext ctx, Device d, String key) async {
    final res = await ctx.post(ctx.url(d.props['host'] as String, 8060, '/keypress/$key'), '');
    if (res.statusCode >= 400) throw IntegrationException('${d.name} refused $key (HTTP ${res.statusCode}).');
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    if (command.on != null) {
      await _press(ctx, device, command.on! ? 'PowerOn' : 'PowerOff');
      return DeviceState(on: command.on);
    }
    if (command.key != null) {
      final k = keys[command.key];
      if (k == null) throw unsupported(device, command.key!.name);
      await _press(ctx, device, k);
      return null;
    }
    if (command.volume != null) throw unsupported(device, 'volume level');
    return null;
  }
}
