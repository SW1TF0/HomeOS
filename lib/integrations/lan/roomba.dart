import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../models/device.dart';
import '../integration.dart';
import 'lan_protocol.dart';
import 'net.dart';

/// What an iRobot robot (Roomba, Braava) says about itself when asked "irobotmcs" on UDP port 5678.
class RoombaInfo {
  const RoombaInfo(this.host, this.json);
  final String host;
  final Map json;

  String get _hostname => '${json['hostname'] ?? ''}';

  /// Whether the answer came from an iRobot robot: they call themselves `Roomba-<id>` or `iRobot-<id>`.
  bool get isRobot => RegExp(r'^(Roomba|iRobot)-\w+$').hasMatch(_hostname);

  /// The robot's id (BLID), its user name for local control.
  String get blid => _hostname.substring(_hostname.indexOf('-') + 1);

  String get sku => '${json['sku'] ?? ''}';

  /// Braava mops have SKUs starting with m.
  bool get isMop => sku.toLowerCase().startsWith('m');

  String get name {
    final n = '${json['robotname'] ?? ''}'.trim();
    return n.isNotEmpty ? n : (isMop ? 'Braava' : 'Roomba');
  }

  Map<String, String> get hints => {
        'protocol': 'roomba',
        'blid': blid,
        'name': name,
        if (sku.isNotEmpty) 'sku': sku,
        if (json['mac'] is String) 'mac': json['mac'] as String,
      };
}

const roombaPort = 5678;

/// Asks every iRobot robot on the network who it is, or only the one at [host].
Future<void> roombaSearch(void Function(RoombaInfo info) found,
    {String? host, int port = roombaPort, Duration timeout = const Duration(seconds: 3)}) async {
  RawDatagramSocket socket;
  List<InternetAddress> targets;
  try {
    if (host == null) {
      socket = await lanUdpSocket();
      targets = await broadcastTargets();
    } else {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      targets = [InternetAddress.tryParse(host) ?? (await InternetAddress.lookup(host)).first];
    }
  } catch (_) {
    return;
  }
  final seen = <String>{};
  final sub = socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    try {
      final j = jsonDecode(utf8.decode(d.data));
      if (j is! Map) return;
      final info = RoombaInfo(d.address.address, j);
      if (info.isRobot && seen.add(info.host)) found(info);
    } catch (_) {}
  });
  final msg = utf8.encode('irobotmcs');
  final end = DateTime.now().add(timeout);
  for (var i = 0; i < 3 && (host == null || seen.isEmpty); i++) {
    for (final t in targets) {
      trySend(socket, msg, t, port);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  while (DateTime.now().isBefore(end) && (host == null || seen.isEmpty)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await sub.cancel();
  socket.close();
}

/// The robot at [host], if it is an iRobot one.
Future<RoombaInfo?> roombaAt(String host, {int port = roombaPort, Duration timeout = const Duration(milliseconds: 1500)}) async {
  RoombaInfo? out;
  await roombaSearch((i) => out ??= i, host: host, port: port, timeout: timeout);
  return out;
}

/// Reads the password from what the robot answered: f0, length, ef cc 3b 29, a status byte, then the password.
String? roombaPasswordFrom(List<int> data) {
  if (data.length <= 7 || data[0] != 0xf0) return null;
  final p = utf8.decode(data.sublist(7), allowMalformed: true).replaceAll('\u0000', '').trim();
  return p.isEmpty ? null : p;
}

/// What a robot's error number means, for the most common ones.
const roombaErrors = {
  1: 'A wheel is off the floor',
  2: 'The main brushes are stuck',
  3: 'A wheel is off the floor',
  4: 'The left wheel is stuck',
  5: 'The right wheel is stuck',
  6: 'Stuck near a drop',
  7: 'Left wheel problem',
  8: 'Bin or fan problem',
  9: 'The bumper is stuck',
  10: 'Right wheel problem',
  11: 'Bin or fan problem',
  12: 'Clean the cliff sensors',
  13: 'Both wheels are off the floor',
  14: 'The bin is missing',
  15: 'Restart the robot',
  17: 'The way is blocked',
  18: 'Could not dock',
  19: 'Could not leave the dock',
  21: 'Lost its way',
  23: 'Battery problem',
  26: 'Vacuum problem',
  29: 'Needs a software update',
  36: 'The bin is full',
  37: 'Refill the tank',
  45: 'The lid is open',
  46: 'The battery is low',
  48: 'The way is blocked',
};

/// iRobot Roomba vacuums and Braava mops, on the home Wi-Fi with no cloud: found by their answer on UDP 5678,
/// then controlled over MQTT on port 8883 with the robot's own id and password. The robot hands out its password
/// for a minute after its HOME button is held (on the dock) until it plays a tone.
class RoombaProtocol extends LanProtocol {
  RoombaProtocol();

  @override
  String get id => 'roomba';
  @override
  String get label => 'iRobot Roomba';

  /// How to make the robot hand out its password.
  static const howToPair =
      'Put the robot on its dock, hold its HOME button for about 2 seconds until it plays a tone, then tap Get password '
      'within a minute. On a j or s series robot, hold HOME until the light ring turns blue.';

  final _links = <String, Future<_RoombaLink>>{};

  @override
  Future<List<Device>?> identify(LanContext ctx, String host, Map<String, String> hints) async {
    var known = hints['protocol'] == 'roomba' && (hints['blid'] ?? '').isNotEmpty ? hints : null;
    known ??= (await roombaAt(host, port: ctx.port(roombaPort)))?.hints;
    known ??= await ctx.tcpOpen(host, 8883) ? await _fromCertificate(ctx, host) : null;
    if (known == null) return null;
    final blid = known['blid']!;
    final sku = known['sku'] ?? hints['sku'] ?? '';
    final password = hints['password'];
    final name = hints['name'] ?? known['name'];
    final device = ctx.make(
      externalId: 'roomba:$host',
      name: name == null || name.isEmpty ? 'Roomba' : name,
      kind: DeviceKind.vacuum,
      capabilities: {Capability.run, Capability.dock, Capability.locate, Capability.readings},
      props: {
        'host': host,
        'protocol': id,
        'blid': blid,
        if (sku.isNotEmpty) 'model': 'iRobot $sku',
        if (sku.isNotEmpty) 'sku': sku,
        'mac': ?(hints['mac'] ?? known['mac']),
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
    if (password == null || password.isEmpty) {
      device.state = _needsPassword;
    } else {
      try {
        device.state = await read(ctx, device).timeout(const Duration(seconds: 6)) ?? const DeviceState();
      } catch (_) {}
    }
    return [device];
  }

  /// Robots that do not answer on UDP still name themselves in their certificate.
  Future<Map<String, String>?> _fromCertificate(LanContext ctx, String host) async {
    if (!ctx.allowTls) return null;
    try {
      final s = await ctx.connect(host, 8883, tls: true) as SecureSocket;
      final subject = s.peerCertificate?.subject ?? '';
      s.destroy();
      final m = RegExp(r'(?:Roomba|iRobot)-(\w+)').firstMatch(subject);
      return m == null ? null : {'protocol': 'roomba', 'blid': m.group(1)!};
    } catch (_) {
      return null;
    }
  }

  static const _needsPassword = DeviceState(readings: {'Status': 'Needs its password'});

  /// Asks the robot for its password; it gives it only for a minute after its HOME button was held.
  Future<String?> password(LanContext ctx, String host) async {
    final Socket s;
    try {
      s = await ctx.connect(host, 8883, tls: true);
    } catch (_) {
      throw IntegrationException('The robot at $host does not answer. Check that it is on its dock and on the Wi-Fi.');
    }
    final got = BytesBuilder();
    final done = Completer<String?>();
    void finish() {
      if (!done.isCompleted) done.complete(roombaPasswordFrom(got.toBytes()));
    }

    s.listen((chunk) {
      got.add(chunk);
      final b = got.toBytes();
      // Older robots send the first two bytes on their own.
      if (b.length > 7 && b.length >= b[1] + 2) finish();
    }, onDone: finish, onError: (_) => finish(), cancelOnError: true);
    s.add([0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x00]);
    try {
      return await done.future.timeout(const Duration(seconds: 6), onTimeout: () => roombaPasswordFrom(got.toBytes()));
    } finally {
      s.destroy();
    }
  }

  /// Fetches the password and keeps it on the device. Returns a message for the user when it did not work.
  @override
  Future<String?> setUp(LanContext ctx, Device device) async {
    final host = device.props['host'] as String;
    String? got;
    try {
      got = await password(ctx, host);
    } on IntegrationException catch (e) {
      return e.message;
    }
    if (got == null) {
      return '${device.name} did not hand out its password yet. Put it on its dock, hold its HOME button for about '
          '2 seconds until it plays a tone, then open it here and tap Get password.';
    }
    device.props['password'] = got;
    await _drop(host);
    device.state = await read(ctx, device).catchError((_) => null) ?? const DeviceState();
    return null;
  }

  @override
  List<SettingField> fields(Device device) => const [
        SettingField('password', 'Robot password', hint: 'Filled in by Get password', secret: true),
        SettingField('blid', 'Robot ID (BLID)', hint: 'In the iRobot app, under the robot\'s settings, About'),
      ];

  Future<_RoombaLink> _link(LanContext ctx, Device d) {
    final host = d.props['host'] as String;
    final password = d.props['password'] as String;
    final existing = _links[host];
    if (existing != null) {
      return existing.then((l) async {
        if (l.connected && l.password == password) return l;
        await _drop(host);
        return _link(ctx, d);
      });
    }
    final f = _connect(ctx, d, password);
    _links[host] = f;
    f.catchError((Object _) {
      if (identical(_links[host], f)) _links.remove(host);
      return _RoombaLink.failed;
    });
    return f;
  }

  Future<_RoombaLink> _connect(LanContext ctx, Device d, String password) async {
    final host = d.props['host'] as String;
    final blid = '${d.props['blid'] ?? ''}';
    if (blid.isEmpty) throw IntegrationException('Enter the robot ID of ${d.name} first.');
    final c = MqttServerClient.withPort(host, blid, ctx.port(8883))
      ..secure = ctx.allowTls
      ..onBadCertificate = ((Object _) => true)
      ..keepAlivePeriod = 30
      ..autoReconnect = false
      ..connectTimeoutPeriod = 6000
      ..logging(on: false)
      ..setProtocolV311()
      ..connectionMessage = MqttConnectMessage().withClientIdentifier(blid).startClean();
    try {
      await c.connect(blid, password);
    } catch (e) {
      c.disconnect();
      final code = c.connectionStatus?.returnCode;
      if (code == MqttConnectReturnCode.badUsernameOrPassword || code == MqttConnectReturnCode.notAuthorized) {
        throw IntegrationException('${d.name} did not take the password. Tap Get password again.');
      }
      throw IntegrationException('${d.name} does not answer. Close the iRobot app on this phone and try again.');
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      c.disconnect();
      throw IntegrationException('${d.name} did not take the password. Tap Get password again.');
    }
    final link = _RoombaLink(c, password);
    final externalId = d.externalId;
    link.sub = c.updates?.listen((messages) {
      for (final m in messages) {
        final msg = m.payload;
        if (msg is! MqttPublishMessage || !m.topic.contains('shadow')) continue;
        try {
          final j = jsonDecode(utf8.decode(msg.payload.message.toList()));
          final reported = j is Map ? (j['state'] is Map ? j['state']['reported'] : null) : null;
          if (reported is! Map) continue;
          _merge(link.reported, reported);
          if (!link.first.isCompleted) link.first.complete();
          if (link.reported['cleanMissionStatus'] != null && !link.mission.isCompleted) link.mission.complete();
          ctx.push?.call(externalId, stateOf(link.reported));
        } catch (_) {}
      }
    });
    c.onDisconnected = () => link.connected = false;
    c.subscribe('#', MqttQos.atMostOnce);
    return link;
  }

  static void _merge(Map into, Map from) {
    from.forEach((k, v) {
      if (v is Map && into[k] is Map) {
        _merge(into[k] as Map, v);
      } else {
        into[k] = v is Map ? {...v} : v;
      }
    });
  }

  Future<void> _drop(String host) async {
    final f = _links.remove(host);
    if (f == null) return;
    try {
      (await f).close();
    } catch (_) {}
  }

  /// What the robot is doing, from what it reported.
  static DeviceState stateOf(Map reported) {
    final mission = reported['cleanMissionStatus'] is Map ? reported['cleanMissionStatus'] as Map : const {};
    final phase = mission['phase'] as String?;
    final cycle = mission['cycle'] as String?;
    final battery = reported['batPct'];
    final error = mission['error'] is num ? (mission['error'] as num).toInt() : 0;
    var activity = switch (phase) {
      'run' => Activity.running,
      'charge' || 'recharge' => battery is num && battery >= 100 ? Activity.docked : Activity.charging,
      'evac' => Activity.docked,
      'hmUsrDock' || 'hmPostMsn' || 'hmMidMsn' => Activity.returning,
      'pause' => Activity.paused,
      'stop' => cycle != null && cycle != 'none' ? Activity.paused : Activity.idle,
      'stuck' => Activity.error,
      _ => null,
    };
    if (error != 0 && activity != Activity.running) activity = Activity.error;
    final bin = reported['bin'] is Map ? reported['bin'] as Map : null;
    return DeviceState(
      activity: activity,
      battery: battery is num ? battery.clamp(0, 100) / 100 : null,
      readings: {
        'Status': '',
        'Error': error == 0 ? '' : (roombaErrors[error] ?? 'Error $error'),
        if (bin != null && bin['present'] != false) 'Bin': bin['full'] == true ? 'Full' : 'OK',
        if (bin != null && bin['present'] == false) 'Bin': 'Missing',
        if (mission['mssnM'] is num && activity == Activity.running) 'Cleaning for': '${mission['mssnM']} min',
      },
    );
  }

  @override
  Future<DeviceState?> read(LanContext ctx, Device device) async {
    if ((device.props['password'] ?? '') == '') return _needsPassword;
    final link = await _link(ctx, device).timeout(const Duration(seconds: 8));
    // The robot tells its state in pieces right after connecting; what it is doing comes a moment after the rest.
    await link.mission.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    return link.reported.isEmpty ? const DeviceState(reachable: true) : stateOf(link.reported);
  }

  @override
  Future<DeviceState?> send(LanContext ctx, Device device, DeviceCommand command) async {
    if ((device.props['password'] ?? '') == '') throw IntegrationException('${device.name} needs its password. $howToPair');
    final link = await _link(ctx, device).timeout(const Duration(seconds: 8));
    final now = link.reported.isEmpty ? device.state.activity : stateOf(link.reported).activity;
    switch (command.action) {
      case DeviceAction.start:
        link.command(now == Activity.paused ? 'resume' : 'start');
        return const DeviceState(activity: Activity.running);
      case DeviceAction.pause:
        link.command('pause');
        return const DeviceState(activity: Activity.paused);
      case DeviceAction.stop:
        link.command('stop');
        return const DeviceState(activity: Activity.idle);
      case DeviceAction.dock:
        // A cleaning robot has to stop before it can head home.
        if (now == Activity.running) {
          link.command('pause');
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
        link.command('dock');
        return const DeviceState(activity: Activity.returning);
      case DeviceAction.locate:
        link.command('find');
        return null;
      default:
        throw unsupported(device, command.action?.name ?? 'that');
    }
  }

  @override
  Future<void> close() async {
    for (final host in _links.keys.toList()) {
      await _drop(host);
    }
  }
}

class _RoombaLink {
  _RoombaLink(this.client, this.password);
  final MqttServerClient? client;
  final String password;
  final Map reported = {};
  final first = Completer<void>();
  final mission = Completer<void>();
  StreamSubscription? sub;
  bool connected = true;

  static final failed = _RoombaLink(null, '')..connected = false;

  void command(String what) {
    final c = client;
    if (c == null) return;
    final payload = MqttClientPayloadBuilder()
      ..addUTF8String(jsonEncode({
        'command': what,
        'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'initiator': 'localApp',
      }));
    c.publishMessage('cmd', MqttQos.atMostOnce, payload.payload!);
  }

  void close() {
    connected = false;
    sub?.cancel();
    client?.disconnect();
  }
}
