import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../util/digest_auth.dart';
import 'onvif.dart';
import 'rtsp.dart';

/// A camera maker with its usual video addresses and where its login is found.
class CameraBrand {
  const CameraBrand(this.id, this.name, {this.paths = const [], this.onvifPorts = const [], this.hint});
  final String id;
  final String name;

  /// RTSP paths: the full picture first, then the smaller one.
  final List<String> paths;
  final List<int> onvifPorts;

  /// Where to find the camera's user and password.
  final String? hint;
}

const cameraBrands = [
  CameraBrand('tapo', 'Tapo',
      paths: ['/stream1', '/stream2'],
      onvifPorts: [2020],
      hint: 'Use the camera account, not your TP-Link login. Make one in the Tapo app: open the camera, then the '
          'gear, Advanced settings, Camera account.'),
  CameraBrand('reolink', 'Reolink',
      paths: ['/h264Preview_01_main', '/h264Preview_01_sub'],
      onvifPorts: [8000],
      hint: 'The user is usually admin, with the password you set in the Reolink app. Turn on RTSP and ONVIF under '
          'Settings, Network, Advanced, Server settings.'),
  CameraBrand('hikvision', 'Hikvision / Ezviz',
      paths: ['/Streaming/Channels/101', '/Streaming/Channels/102'],
      onvifPorts: [80],
      hint: 'Ezviz: the user is admin and the password is the verification code on the camera\'s sticker. Turn on '
          'Local Service (RTSP) in the Ezviz app under the camera\'s settings, LAN Live View.'),
  CameraBrand('dahua', 'Dahua / Imou / Amcrest',
      paths: ['/cam/realmonitor?channel=1&subtype=0', '/cam/realmonitor?channel=1&subtype=1'],
      onvifPorts: [80],
      hint: 'Imou: the user is admin and the password is the safety code from the sticker or the Imou Life app, '
          'unless you changed it.'),
  CameraBrand('other', 'Other',
      paths: [
        '/stream1',
        '/h264Preview_01_main',
        '/Streaming/Channels/101',
        '/cam/realmonitor?channel=1&subtype=0',
        '/live/ch00_0',
        '/onvif1',
        '/11',
        '/live',
        '/videoMain',
        '/h264',
        '/ch0_0.h264',
        '/',
      ],
      onvifPorts: [80, 2020, 8000, 8080, 8899, 5000],
      hint: 'Use the user and password you set for the camera, often admin. Check its app or sticker.'),
];

CameraBrand brandOf(String? id) => cameraBrands.firstWhere((b) => b.id == id, orElse: () => cameraBrands.last);

/// Where a camera's video and pictures are, with its login in each address.
class CameraLinks {
  const CameraLinks({this.name, this.stream, this.streamLow, this.snapshot, this.mjpeg, this.checked = true});
  final String? name;

  /// RTSP: the full picture, and the smaller, quicker one.
  final String? stream;
  final String? streamLow;

  /// A still picture over HTTP.
  final String? snapshot;

  /// Moving pictures over HTTP (MJPEG), for cameras and boards that have no RTSP.
  final String? mjpeg;

  /// False when the camera could not be asked whether the video plays.
  final bool checked;
}

class CameraSetupException implements Exception {
  const CameraSetupException(this.message, {this.login = false});
  final String message;

  /// The camera refused the user and password.
  final bool login;

  @override
  String toString() => message;
}

/// Finds a camera's video at [host] with its [user] and [pass]: from ONVIF if the camera speaks it, otherwise by
/// trying the usual RTSP addresses of its [brand]. A [link] the user typed (rtsp:// or http://) is used as it is.
/// Throws [CameraSetupException] with a message to show.
Future<CameraLinks> findCameraLinks({
  required String host,
  required String user,
  required String pass,
  String brand = 'other',
  String? link,
  Uri? onvifUrl,
  required http.Client client,
  int rtspPort = 554,
  List<int>? onvifPorts,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final b = brandOf(brand);
  final login = loginInfo(user, pass);
  final wrongLogin = CameraSetupException(
      'The camera refused that user and password.${b.hint == null ? '' : ' ${b.hint}'}',
      login: true);
  final typed = link?.trim() ?? '';
  if (typed.isNotEmpty) return _typedLink(typed, login, client, wrongLogin, timeout);

  // A camera with ONVIF says where its video is.
  final ports = onvifPorts ?? {...b.onvifPorts, 80, 2020, 8000, 8080, 8899};
  final services = <Uri>{
    ?onvifUrl,
    for (final p in ports) Uri.parse('http://$host${p == 80 ? '' : ':$p'}/onvif/device_service'),
  }.toList();
  final listening = await Future.wait(services.map((u) => _open(u.host, u.port)));
  OnvifStreams? onvif;
  var loginRefused = false;
  for (final (i, url) in services.indexed) {
    if (!listening[i]) continue;
    try {
      onvif = await OnvifClient(url, user: user, pass: pass, client: client, timeout: timeout).streams();
      if (onvif.main != null) break;
    } on OnvifException catch (e) {
      if (e.login) loginRefused = true;
    } catch (_) {}
  }
  String? withLogin(Uri? u) => u == null || u.host.isEmpty ? null : u.replace(host: host, userInfo: login).toString();
  final rtspUp = await _open(host, rtspPort);
  if (onvif?.main != null) {
    final main = withLogin(onvif!.main)!;
    final check = rtspUp || Uri.parse(main).port != rtspPort ? await rtspDescribe(Uri.parse(main), timeout: timeout) : null;
    if (check == RtspResult.login) throw wrongLogin;
    if (check == RtspResult.ok) {
      return CameraLinks(name: onvif.name, stream: main, streamLow: withLogin(onvif.sub), snapshot: withLogin(onvif.snapshot));
    }
  }

  // Otherwise try the usual addresses.
  if (rtspUp) {
    final base = 'rtsp://${login.isEmpty ? '' : '$login@'}$host${rtspPort == 554 ? '' : ':$rtspPort'}';
    for (final (i, path) in b.paths.indexed) {
      final r = await rtspDescribe(Uri.parse('$base$path'), timeout: timeout);
      if (r == RtspResult.login) throw wrongLogin;
      if (r != RtspResult.ok) continue;
      // The brand's second address is its smaller picture.
      final low = b.id != 'other' && i == 0 && b.paths.length > 1 ? '$base${b.paths[1]}' : null;
      final lowOk = low != null && await rtspDescribe(Uri.parse(low), timeout: timeout) == RtspResult.ok;
      return CameraLinks(
          name: onvif?.name, stream: '$base$path', streamLow: lowOk ? low : null, snapshot: withLogin(onvif?.snapshot));
    }
  }
  if (onvif?.main != null) {
    return CameraLinks(
        name: onvif!.name,
        stream: withLogin(onvif.main),
        streamLow: withLogin(onvif.sub),
        snapshot: withLogin(onvif.snapshot),
        checked: false);
  }
  if (loginRefused) throw wrongLogin;
  if (!rtspUp && onvif == null) {
    final anything = await _open(host, 80) || await _open(host, 443);
    throw CameraSetupException(anything
        ? '$host answers, but sends no video. Turn on RTSP or ONVIF in the camera\'s own app, or type its video link.'
        : 'Nothing answers at $host. Check the address, and that the camera and this phone are on the same Wi-Fi.');
  }
  throw const CameraSetupException(
      'Found the camera, but not where its video is. Pick its brand, or type its RTSP link from the manual.');
}

Future<CameraLinks> _typedLink(
    String typed, String login, http.Client client, CameraSetupException wrongLogin, Duration timeout) async {
  final uri = Uri.tryParse(typed.contains('://') ? typed : 'rtsp://$typed');
  if (uri == null || uri.host.isEmpty) throw const CameraSetupException('That does not look like a link.');
  final withLogin = uri.userInfo.isEmpty && login.isNotEmpty ? uri.replace(userInfo: login) : uri;
  if (uri.scheme == 'rtsp' || uri.scheme == 'rtsps') {
    final r = await rtspDescribe(withLogin, timeout: timeout);
    if (r == RtspResult.login) throw wrongLogin;
    if (r == RtspResult.refused) throw CameraSetupException('Nothing answers at ${uri.host}:${uri.hasPort ? uri.port : 554}.');
    if (r == RtspResult.notFound) throw const CameraSetupException('The camera has no video at that link.');
    return CameraLinks(stream: withLogin.toString(), checked: r == RtspResult.ok);
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const CameraSetupException('Type a link that starts with rtsp:// or http://');
  }
  // An HTTP link is either moving pictures (MJPEG) or one picture.
  final (user, pass) = loginOf(withLogin);
  final bare = withLogin.replace(userInfo: '');
  final req = http.Request('GET', bare);
  if (user.isNotEmpty) req.headers['Authorization'] = authorization(null, user, pass, 'GET', bare.path);
  try {
    var res = await client.send(req).timeout(timeout);
    if (res.statusCode == 401 && user.isNotEmpty) {
      final challenge = AuthChallenge.pick([res.headers['www-authenticate'] ?? '']);
      unawaited(res.stream.drain<void>().catchError((_) {}));
      final again = http.Request('GET', bare)
        ..headers['Authorization'] = authorization(challenge, user, pass, 'GET', bare.hasQuery ? '${bare.path}?${bare.query}' : bare.path);
      res = await client.send(again).timeout(timeout);
    }
    final type = res.headers['content-type'] ?? '';
    unawaited(res.stream.listen(null).cancel());
    if (res.statusCode == 401 || res.statusCode == 403) throw wrongLogin;
    if (res.statusCode >= 400) throw CameraSetupException('${uri.host} answered HTTP ${res.statusCode}.');
    if (type.contains('multipart')) return CameraLinks(mjpeg: withLogin.toString());
    if (type.startsWith('image/')) return CameraLinks(snapshot: withLogin.toString());
    throw const CameraSetupException('That link sends neither video nor a picture.');
  } on CameraSetupException {
    rethrow;
  } catch (_) {
    throw CameraSetupException('Nothing answers at ${uri.host}.');
  }
}

Future<bool> _open(String host, int port) async {
  try {
    final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
