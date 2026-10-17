import 'dart:async';

import 'package:http/http.dart' as http;

import '../../util/digest_auth.dart';

/// How a camera plays back what it recorded on its memory card.
enum PlaybackKind { dahua, hikvision }

/// One stretch of recorded video, by the camera's clock. [motion] when something moving started it.
class Recording {
  const Recording(this.start, this.end, {this.motion = false});
  final DateTime start;
  final DateTime end;
  final bool motion;

  @override
  String toString() => 'Recording($start - $end${motion ? ', motion' : ''})';
}

class PlaybackException implements Exception {
  const PlaybackException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Plays a camera's recordings from its memory card over RTSP: Dahua, Imou and Amcrest through `/cam/playback`,
/// Hikvision through `/Streaming/tracks`. Their web side lists what was recorded. Times are the camera's own clock,
/// which these cameras keep in the phone's time zone.
class CameraPlayback {
  CameraPlayback(this.kind, this.live, {this.channel = 1, this.httpPort = 80});

  final PlaybackKind kind;

  /// The live address with its login: recordings come from the same camera, port and login.
  final Uri live;
  final int channel;
  final int httpPort;

  static const timeout = Duration(seconds: 6);

  /// For a camera whose live video is set up, when its kind of camera plays recordings to other apps.
  static CameraPlayback? of(Map<String, dynamic> props) {
    final s = props['streamUrl'];
    final live = s is String ? Uri.tryParse(s.trim()) : null;
    if (live == null || live.scheme != 'rtsp' || live.host.isEmpty) return null;
    final path = live.path.toLowerCase();
    final brand = props['cameraBrand'];
    final onvif = Uri.tryParse(props['onvif'] as String? ?? '');
    final httpPort = onvif != null && onvif.host == live.host && onvif.hasPort ? onvif.port : 80;
    if (path.contains('/cam/realmonitor') || (brand == 'dahua' && !path.contains('/streaming/'))) {
      return CameraPlayback(PlaybackKind.dahua, live,
          channel: int.tryParse(live.queryParameters['channel'] ?? '') ?? 1, httpPort: httpPort);
    }
    final hik = RegExp(r'/streaming/channels/(\d+)').firstMatch(path);
    if (hik != null || brand == 'hikvision') {
      final n = int.tryParse(hik?.group(1) ?? '') ?? 101;
      return CameraPlayback(PlaybackKind.hikvision, live, channel: n >= 100 ? n ~/ 100 : n, httpPort: httpPort);
    }
    return null;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// The address that plays from [start] onwards.
  Uri at(DateTime start, {DateTime? now}) {
    final until = start.add(const Duration(hours: 12));
    final end = now != null && until.isAfter(now) ? now : until;
    switch (kind) {
      case PlaybackKind.dahua:
        String t(DateTime d) =>
            '${d.year}_${_two(d.month)}_${_two(d.day)}_${_two(d.hour)}_${_two(d.minute)}_${_two(d.second)}';
        return live.replace(
            path: '/cam/playback', query: 'channel=$channel&subtype=0&starttime=${t(start)}&endtime=${t(end)}');
      case PlaybackKind.hikvision:
        // Hikvision wants its own local time with a Z after it.
        String t(DateTime d) =>
            '${d.year}${_two(d.month)}${_two(d.day)}T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}Z';
        return live.replace(path: '/Streaming/tracks/${channel}01', query: 'starttime=${t(start)}&endtime=${t(end)}');
    }
  }

  /// What was recorded on [day], first to last. Throws [PlaybackException] when the camera will not say.
  Future<List<Recording>> find(DateTime day, http.Client client) async {
    final from = DateTime(day.year, day.month, day.day);
    final to = DateTime(day.year, day.month, day.day, 23, 59, 59);
    final List<Recording> found;
    try {
      found = kind == PlaybackKind.dahua ? await _dahua(from, to, client) : await _hikvision(from, to, client);
    } on PlaybackException {
      rethrow;
    } catch (_) {
      throw const PlaybackException('The camera did not answer with its list of recordings.');
    }
    return found..sort((a, b) => a.start.compareTo(b.start));
  }

  /// An address on the camera's web side. Dahua's CGI reads its query as written, so only spaces are encoded.
  Uri _web(String path, [Map<String, String>? query]) => Uri(
      scheme: 'http',
      host: live.host,
      port: httpPort,
      path: path,
      query: query?.entries.map((e) => '${e.key}=${e.value.replaceAll(' ', '%20')}').join('&'));

  Future<http.Response> _send(http.Client client, String method, Uri url, {String? body}) async {
    final (user, pass) = loginOf(live);
    final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
    http.Request request(String? auth) {
      final r = http.Request(method, url)..headers.addAll({'Authorization': ?auth});
      if (body != null) {
        r.headers['Content-Type'] = 'application/xml';
        r.body = body;
      }
      return r;
    }

    var res = await http.Response.fromStream(await client.send(request(null)).timeout(timeout));
    if (res.statusCode == 401 && user.isNotEmpty) {
      final challenge = AuthChallenge.pick([res.headers['www-authenticate'] ?? '']);
      res = await http.Response.fromStream(
          await client.send(request(authorization(challenge, user, pass, method, path))).timeout(timeout));
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const PlaybackException('The camera refused the login when asked for its list of recordings.');
    }
    if (res.statusCode >= 400) throw const PlaybackException('The camera does not share its list of recordings.');
    return res;
  }

  static DateTime? _time(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    final t = s.trim().replaceFirst(' ', 'T');
    // A Z on a Hikvision time is its own local time; a real offset is turned into the phone's time.
    if (t.endsWith('Z')) return DateTime.tryParse(t.substring(0, t.length - 1));
    final parsed = DateTime.tryParse(t);
    return parsed == null ? null : (parsed.isUtc ? parsed.toLocal() : parsed);
  }

  // Dahua: mediaFileFind.cgi makes a finder, is told what to look for, then hands out the files.
  Future<List<Recording>> _dahua(DateTime from, DateTime to, http.Client client) async {
    const cgi = '/cgi-bin/mediaFileFind.cgi';
    String t(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
    final made = await _send(client, 'GET', _web(cgi, {'action': 'factory.create'}));
    final object = RegExp(r'result=(\d+)').firstMatch(made.body)?.group(1);
    if (object == null) throw const PlaybackException('The camera does not share its list of recordings.');
    final out = <Recording>[];
    try {
      final asked = await _send(client, 'GET', _web(cgi, {
        'action': 'findFile',
        'object': object,
        'condition.Channel': '$channel',
        'condition.StartTime': t(from),
        'condition.EndTime': t(to),
      }));
      // An empty day answers "Error" here on some cameras.
      if (!asked.body.trim().toUpperCase().startsWith('OK')) return out;
      for (var page = 0; page < 20; page++) {
        final next = await _send(client, 'GET', _web(cgi, {'action': 'findNextFile', 'object': object, 'count': '100'}));
        final items = <int, Map<String, List<String>>>{};
        var count = 0;
        for (final line in next.body.split(RegExp(r'\r?\n'))) {
          final c = RegExp(r'^found=(\d+)').firstMatch(line.trim());
          if (c != null) count = int.parse(c.group(1)!);
          final m = RegExp(r'^items\[(\d+)\]\.(\w+)(?:\[\d+\])?=(.*)$').firstMatch(line.trim());
          if (m == null) continue;
          items.putIfAbsent(int.parse(m.group(1)!), () => {}).putIfAbsent(m.group(2)!, () => []).add(m.group(3)!.trim());
        }
        for (final item in items.values) {
          final start = _time(item['StartTime']?.first);
          final end = _time(item['EndTime']?.first);
          // Pictures it took are listed too; only video plays back.
          final type = item['Type']?.first.toLowerCase();
          if (start == null || end == null || (type != null && type != 'dav')) continue;
          final events = [...?item['Events'], ...?item['Flags']];
          final motion = events.any((e) => e.isNotEmpty && !const {'Timing', 'Manual', 'Normal'}.contains(e));
          out.add(Recording(start, end, motion: motion));
        }
        if (count < 100) break;
      }
    } finally {
      for (final action in const ['close', 'destroy']) {
        unawaited(_send(client, 'GET', _web(cgi, {'action': action, 'object': object})).then((_) {}, onError: (_) {}));
      }
    }
    return out;
  }

  // Hikvision: ISAPI search, a page of matches at a time.
  Future<List<Recording>> _hikvision(DateTime from, DateTime to, http.Client client) async {
    String t(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}Z';
    final id = randomBytes(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    final out = <Recording>[];
    var position = 0;
    for (var page = 0; page < 10; page++) {
      final body = '<?xml version="1.0" encoding="UTF-8"?>'
          '<CMSearchDescription><searchID>$id</searchID>'
          '<trackIDList><trackID>${channel}01</trackID></trackIDList>'
          '<timeSpanList><timeSpan><startTime>${t(from)}</startTime><endTime>${t(to)}</endTime></timeSpan></timeSpanList>'
          '<maxResults>100</maxResults><searchResultPostion>$position</searchResultPostion>'
          '<metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList>'
          '</CMSearchDescription>';
      final res = await _send(client, 'POST', _web('/ISAPI/ContentMgmt/search'), body: body);
      final matches = RegExp(r'<searchMatchItem>(.*?)</searchMatchItem>', dotAll: true).allMatches(res.body).toList();
      for (final m in matches) {
        final item = m.group(1)!;
        String? tag(String name) => RegExp('<$name>([^<]*)</$name>').firstMatch(item)?.group(1);
        final start = _time(tag('startTime'));
        final end = _time(tag('endTime'));
        if (start == null || end == null) continue;
        final meta = (tag('metadataDescriptor') ?? '').toLowerCase();
        out.add(Recording(start, end, motion: meta.contains('motion') || meta.contains('vmd') || meta.contains('event')));
      }
      position += matches.length;
      final status = RegExp(r'<responseStatusStrg>([^<]*)</responseStatusStrg>').firstMatch(res.body)?.group(1);
      if (status != 'MORE' || matches.isEmpty) break;
    }
    return out;
  }
}
