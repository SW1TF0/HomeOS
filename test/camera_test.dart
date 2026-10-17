import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/camera/camera_setup.dart';
import 'package:smartmenukj/integrations/camera/onvif.dart';
import 'package:smartmenukj/integrations/camera/rtsp.dart';
import 'package:smartmenukj/integrations/home_assistant.dart';
import 'package:smartmenukj/integrations/integration.dart';
import 'package:smartmenukj/integrations/lan/lan_driver.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/widgets/camera_live.dart';
import 'package:smartmenukj/ui/widgets/nothing_widgets.dart';
import 'package:smartmenukj/util/digest_auth.dart';

/// A camera's RTSP side: answers DESCRIBE for [paths], asking for a Digest login first.
class FakeRtsp {
  FakeRtsp._(this._server, this.paths, this.user, this.pass);

  static Future<FakeRtsp> start({Set<String> paths = const {'/stream1', '/stream2'}, String user = 'cam', String pass = 'p@ss:1'}) async {
    final f = FakeRtsp._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), paths, user, pass);
    f._server.listen(f._serve);
    return f;
  }

  final ServerSocket _server;
  final Set<String> paths;
  final String user;
  final String pass;
  final asked = <String>[];
  static const realm = 'TP-Link IP-Camera';
  static const nonce = 'c0ffee';

  int get port => _server.port;

  void _serve(Socket s) {
    var text = '';
    s.listen((d) {
      text += latin1.decode(d);
      while (text.contains('\r\n\r\n')) {
        final end = text.indexOf('\r\n\r\n');
        final head = text.substring(0, end);
        text = text.substring(end + 4);
        s.add(utf8.encode(_answer(head)));
      }
    }, onError: (_) {});
  }

  String _answer(String head) {
    final lines = head.split('\r\n');
    final url = Uri.parse(lines.first.split(' ')[1]);
    final seq = lines.firstWhere((l) => l.startsWith('CSeq')).split(':').last.trim();
    final auth = lines.where((l) => l.toLowerCase().startsWith('authorization:')).firstOrNull;
    final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
    asked.add(path);
    String reply(String status, [String extra = '', String body = '']) =>
        'RTSP/1.0 $status\r\nCSeq: $seq\r\n$extra${body.isEmpty ? '' : 'Content-Length: ${body.length}\r\n'}\r\n$body';
    if (auth == null) return reply('401 Unauthorized', 'WWW-Authenticate: Digest realm="$realm", nonce="$nonce"\r\n');
    final p = {
      for (final m in RegExp(r'(\w+)="([^"]*)"').allMatches(auth)) m.group(1)!: m.group(2)!,
    };
    final expected = md5Hex('${md5Hex('$user:$realm:$pass')}:$nonce:${md5Hex('DESCRIBE:${p['uri']}')}');
    if (p['username'] != user || p['response'] != expected || p['uri'] != url.toString()) {
      return reply('401 Unauthorized', 'WWW-Authenticate: Digest realm="$realm", nonce="$nonce"\r\n');
    }
    if (!paths.contains(path)) return reply('404 Stream Not Found');
    return reply('200 OK', 'Content-Type: application/sdp\r\n', 'v=0\r\nm=video 0 RTP/AVP 96\r\n');
  }

  Future<void> close() => _server.close();
}

/// A camera's ONVIF side. It checks the WS-Security password digest like a real camera.
Future<HttpServer> fakeOnvif({required int rtspPort, String user = 'cam', String pass = 'p@ss:1'}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  server.listen((req) async {
    final body = await utf8.decodeStream(req);
    String envelope(String inner) => '<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
        '<s:Body>$inner</s:Body></s:Envelope>';
    req.response.headers.contentType = ContentType('application', 'soap+xml', charset: 'utf-8');
    if (body.contains('GetSystemDateAndTime')) {
      final t = DateTime.now().toUtc().add(const Duration(minutes: 7)); // the camera's clock is off
      req.response.write(envelope('<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime>'
          '<tt:Time><tt:Hour>${t.hour}</tt:Hour><tt:Minute>${t.minute}</tt:Minute><tt:Second>${t.second}</tt:Second></tt:Time>'
          '<tt:Date><tt:Year>${t.year}</tt:Year><tt:Month>${t.month}</tt:Month><tt:Day>${t.day}</tt:Day></tt:Date>'
          '</tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>'));
      await req.response.close();
      return;
    }
    final name = RegExp(r'<Username>([^<]*)</Username>').firstMatch(body)?.group(1);
    final digest = RegExp(r'<Password[^>]*>([^<]*)</Password>').firstMatch(body)?.group(1);
    final nonce = RegExp(r'<Nonce[^>]*>([^<]*)</Nonce>').firstMatch(body)?.group(1);
    final created = RegExp(r'<Created[^>]*>([^<]*)</Created>').firstMatch(body)?.group(1);
    final ok = name == user &&
        nonce != null &&
        created != null &&
        digest == base64.encode(sha1Bytes([...base64.decode(nonce), ...utf8.encode(created), ...utf8.encode(pass)])) &&
        DateTime.parse(created).difference(DateTime.now().toUtc()).inMinutes.abs() >= 6; // used the camera's clock
    if (!ok) {
      req.response.statusCode = 400;
      req.response.write(envelope('<s:Fault><s:Code><s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code></s:Fault>'));
    } else if (body.contains('GetDeviceInformation')) {
      req.response.write(envelope('<tds:GetDeviceInformationResponse><tds:Manufacturer>tp-link</tds:Manufacturer>'
          '<tds:Model>C200</tds:Model></tds:GetDeviceInformationResponse>'));
    } else if (body.contains('GetCapabilities')) {
      // Cameras often report an address of their own; the one the user typed is used instead.
      req.response.write(envelope('<tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media>'
          '<tt:XAddr>http://10.9.9.9:$port/onvif/media</tt:XAddr></tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse>'));
    } else if (body.contains('GetProfiles')) {
      req.response.write(envelope('<trt:GetProfilesResponse><trt:Profiles token="main" fixed="true"><tt:Name>mainStream</tt:Name>'
          '</trt:Profiles><trt:Profiles token="minor" fixed="true"><tt:Name>minorStream</tt:Name></trt:Profiles></trt:GetProfilesResponse>'));
    } else if (body.contains('GetStreamUri')) {
      final path = body.contains('>minor<') ? 'stream2' : 'stream1';
      req.response.write(envelope('<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://10.9.9.9:$rtspPort/$path</tt:Uri>'
          '</trt:MediaUri></trt:GetStreamUriResponse>'));
    } else if (body.contains('GetSnapshotUri')) {
      req.response.write(envelope('<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>http://10.9.9.9:$port/snap.jpg?a=1&amp;b=2</tt:Uri>'
          '</trt:MediaUri></trt:GetSnapshotUriResponse>'));
    } else {
      req.response.statusCode = 400;
    }
    await req.response.close();
  });
  return server;
}

void main() {
  group('logins', () {
    test('Digest is picked over Basic and answered the way cameras check it', () {
      final c = AuthChallenge.pick(['Basic realm="cam", Digest realm="IP Camera(C2)", nonce="abc", qop="auth,auth-int"'])!;
      expect((c.scheme, c.params['realm'], c.params['nonce']), ('digest', 'IP Camera(C2)', 'abc'));
      final header = authorization(c, 'admin', 'secret', 'GET', '/snap.jpg');
      final p = {for (final m in RegExp(r'(\w+)="?([^",]*)"?').allMatches(header.substring(7))) m.group(1)!: m.group(2)!};
      final ha1 = md5Hex('admin:IP Camera(C2):secret');
      expect(p['response'], md5Hex('$ha1:abc:00000001:${p['cnonce']}:auth:${md5Hex('GET:/snap.jpg')}'));
      expect(authorization(null, 'a', 'b', 'GET', '/'), 'Basic ${base64.encode(utf8.encode('a:b'))}');
      expect(md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('a login in an address is read back with its special characters', () {
      final u = Uri.parse('rtsp://${loginInfo('me@home', 'p@ss:1/x')}@10.0.0.2/stream1');
      expect(loginOf(u), ('me@home', 'p@ss:1/x'));
      expect(loginOf(Uri.parse('rtsp://10.0.0.2/')), ('', ''));
    });
  });

  group('RTSP', () {
    late FakeRtsp cam;
    setUp(() async => cam = await FakeRtsp.start());
    tearDown(() => cam.close());

    Uri at(String path, {String pass = 'p@ss:1'}) => Uri.parse('rtsp://${loginInfo('cam', pass)}@127.0.0.1:${cam.port}$path');

    test('tells a working address from a wrong login, a wrong path and nothing at all', () async {
      expect(await rtspDescribe(at('/stream1')), RtspResult.ok);
      expect(await rtspDescribe(at('/stream1', pass: 'nope')), RtspResult.login);
      expect(await rtspDescribe(at('/nope')), RtspResult.notFound);
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      expect(await rtspDescribe(Uri.parse('rtsp://127.0.0.1:$port/x')), RtspResult.refused);
    });

    test('a brand finds its full and small picture', () async {
      final links = await findCameraLinks(
          host: '127.0.0.1', user: 'cam', pass: 'p@ss:1', brand: 'tapo', client: http.Client(), rtspPort: cam.port, onvifPorts: []);
      expect(links.stream, 'rtsp://cam:p%40ss%3A1@127.0.0.1:${cam.port}/stream1');
      expect(links.streamLow, 'rtsp://cam:p%40ss%3A1@127.0.0.1:${cam.port}/stream2');
      expect(links.checked, isTrue);
    });

    test('an unknown camera is found by trying the usual addresses', () async {
      await cam.close();
      cam = await FakeRtsp.start(paths: {'/cam/realmonitor?channel=1&subtype=0'});
      final links = await findCameraLinks(
          host: '127.0.0.1', user: 'cam', pass: 'p@ss:1', client: http.Client(), rtspPort: cam.port, onvifPorts: []);
      expect(links.stream, endsWith('/cam/realmonitor?channel=1&subtype=0'));
      expect(links.streamLow, isNull);
      expect(cam.asked, contains('/stream1'), reason: 'common addresses come first');
    });

    test('a wrong password says where the login is', () async {
      final e = await findCameraLinks(
              host: '127.0.0.1', user: 'cam', pass: 'wrong', brand: 'tapo', client: http.Client(), rtspPort: cam.port, onvifPorts: [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<CameraSetupException>().having((e) => e.login, 'login', isTrue));
      expect('$e', contains('Camera account'));
    });

    test('a typed link is checked as it is', () async {
      final links = await findCameraLinks(
          host: '', user: 'cam', pass: 'p@ss:1', link: 'rtsp://127.0.0.1:${cam.port}/stream2', client: http.Client());
      expect(links.stream, 'rtsp://cam:p%40ss%3A1@127.0.0.1:${cam.port}/stream2');
    });

    test('nothing at the address is explained', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final e = await findCameraLinks(host: '127.0.0.1', user: 'a', pass: 'b', client: http.Client(), rtspPort: port, onvifPorts: [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<CameraSetupException>());
    });
  });

  group('ONVIF', () {
    late FakeRtsp cam;
    late HttpServer onvif;
    setUp(() async {
      cam = await FakeRtsp.start();
      onvif = await fakeOnvif(rtspPort: cam.port);
    });
    tearDown(() async {
      await cam.close();
      await onvif.close(force: true);
    });

    test('the camera says where its video is, with the right clock and login', () async {
      final links = await findCameraLinks(
          host: '127.0.0.1', user: 'cam', pass: 'p@ss:1', client: http.Client(), rtspPort: cam.port, onvifPorts: [onvif.port]);
      expect(links.name, 'tp-link C200');
      expect(links.stream, 'rtsp://cam:p%40ss%3A1@127.0.0.1:${cam.port}/stream1');
      expect(links.streamLow, 'rtsp://cam:p%40ss%3A1@127.0.0.1:${cam.port}/stream2');
      expect(links.snapshot, 'http://cam:p%40ss%3A1@127.0.0.1:${onvif.port}/snap.jpg?a=1&b=2');
    });

    test('a wrong password over ONVIF is a login problem', () async {
      final e = await OnvifClient(Uri.parse('http://127.0.0.1:${onvif.port}/onvif/device_service'),
              user: 'cam', pass: 'nope', client: http.Client())
          .streams()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<OnvifException>().having((e) => e.login, 'login', isTrue));
    });

    test('cameras on the Wi-Fi answer the search', () async {
      final responder = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      responder.listen((ev) {
        final d = responder.receive();
        if (d == null || !utf8.decode(d.data).contains('NetworkVideoTransmitter')) return;
        responder.send(utf8.encode('<e:Envelope><e:Body><d:ProbeMatches><d:ProbeMatch>'
            '<d:Scopes>onvif://www.onvif.org/name/TP-IPC onvif://www.onvif.org/hardware/C200 onvif://www.onvif.org/Profile/Streaming</d:Scopes>'
            '<d:XAddrs>http://[fe80::1]:2020/onvif/device_service http://127.0.0.1:2020/onvif/device_service</d:XAddrs>'
            '</d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>'), d.address, d.port);
      });
      final found = await onvifProbe(timeout: const Duration(milliseconds: 300), to: InternetAddress.loopbackIPv4, port: responder.port);
      responder.close();
      expect(found.single.host, '127.0.0.1');
      expect(found.single.name, 'TP-IPC C200');
      expect(found.single.deviceUrl.toString(), 'http://127.0.0.1:2020/onvif/device_service');
    });
  });

  group('MJPEG', () {
    final a = Uint8List.fromList([0xFF, 0xD8, 1, 2, 0xFF, 0x00, 3, 0xFF, 0xD9]);
    final b = Uint8List.fromList([0xFF, 0xD8, 9, 9, 0xFF, 0xD9]);

    test('the stream is cut into pictures, wherever the chunks break', () {
      final all = [
        ...utf8.encode('--frame\r\nContent-Type: image/jpeg\r\n\r\n'),
        ...a,
        ...utf8.encode('\r\n--frame\r\nContent-Type: image/jpeg\r\n\r\n'),
        ...b,
        ...utf8.encode('\r\n--frame\r\n'),
      ];
      for (final size in [1, 2, 3, 7, all.length]) {
        final s = MjpegSplitter();
        final got = <Uint8List>[];
        for (var i = 0; i < all.length; i += size) {
          got.addAll(s.add(all.sublist(i, (i + size).clamp(0, all.length))));
        }
        expect(got, [a, b], reason: 'chunks of $size');
      }
    });
  });

  group('live video', () {
    test('comes from the camera\'s addresses, and from Home Assistant for its cameras', () {
      expect(CameraStream.fromProps({}), isNull);
      final s = CameraStream.fromProps({'streamUrl': 'rtsp://a/1', 'streamUrlLow': 'rtsp://a/2'})!;
      expect((s.rtsp.toString(), s.rtspLow.toString(), s.mjpeg), ('rtsp://a/1', 'rtsp://a/2', null));

      final ha = HomeAssistantDriver(
          IntegrationConfig(id: 'ha', type: 'homeassistant', name: 'HA', settings: {'url': 'http://ha.local:8123', 'token': 't0k'}),
          MockClient((_) async => http.Response('', 404)));
      Device cam(String id) => Device(id: 'ha::$id', name: 'Door', kind: DeviceKind.camera, integrationId: 'ha', externalId: id);
      final live = ha.liveStream(cam('camera.door'))!;
      expect(live.mjpeg.toString(), 'http://ha.local:8123/api/camera_proxy_stream/camera.door');
      expect(live.headers['Authorization'], 'Bearer t0k');
      expect(ha.liveStream(cam('light.door')), isNull);
    });

    test('pictures that need a Digest login are fetched', () async {
      final calls = <String?>[];
      final client = MockClient((req) async {
        calls.add(req.headers['Authorization']);
        if (!(req.headers['Authorization'] ?? '').startsWith('Digest')) {
          return http.Response('', 401, headers: {'www-authenticate': 'Digest realm="cam", nonce="n1", qop="auth"'});
        }
        return http.Response.bytes([0xFF, 0xD8, 0xFF, 0xD9], 200, headers: {'content-type': 'image/jpeg'});
      });
      final driver = LanDriver(IntegrationConfig(id: 'lan', type: 'lan', name: 'Network devices'), client);
      final img = await driver.getImage(Uri.parse('http://admin:pw@10.0.0.5/ISAPI/Streaming/channels/101/picture'));
      expect(img, [0xFF, 0xD8, 0xFF, 0xD9]);
      expect(calls.first, startsWith('Basic '));
      expect(calls.last, contains('uri="/ISAPI/Streaming/channels/101/picture"'));
    });
  });

  group('cameras in the app', () {
    late HomeStore store;
    late FakeRtsp cam;
    setUp(() async {
      cam = await FakeRtsp.start();
      store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 404)));
      await store.load();
    });
    tearDown(() async {
      store.dispose();
      await cam.close();
    });

    test('a camera is added with its login, plays live, and keeps its video after a sync', () async {
      final d = await store.setUpCamera(
          host: '127.0.0.1', user: 'cam', pass: 'p@ss:1', brand: 'tapo', rtspPort: cam.port, onvifPorts: []);
      expect(d.kind, DeviceKind.camera);
      expect(store.integration(d.integrationId)!.type, 'lan');
      expect(store.liveStream(d)!.rtsp!.path, '/stream1');
      expect(describeState(d), 'Live');

      d.props['snapshotUrl'] = 'http://127.0.0.1:1/snap.jpg';
      d.capabilities = {Capability.snapshot};
      final cfg = store.integration(d.integrationId)!;
      await store.sync(cfg);
      final again = store.device(d.id)!;
      expect(store.devices.where((x) => x.kind == DeviceKind.camera).length, 1);
      expect(again.props['streamUrl'], d.props['streamUrl']);
      expect(again.has(Capability.snapshot), isTrue, reason: 'a sync keeps the picture');

      store.clearCamera(again);
      expect(store.liveStream(again), isNull);
      expect(describeState(again), 'Tap to look');
    });

    test('setting up asks for an address first', () async {
      expect(() => store.setUpCamera(host: ' ', user: 'a', pass: 'b'), throwsA(isA<CameraSetupException>()));
    });

    test('rtsp only plays on Android', () => expect(rtspPlays, Platform.isAndroid));
  });
}
