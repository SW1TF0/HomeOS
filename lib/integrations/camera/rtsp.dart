import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../util/digest_auth.dart';

/// What a camera said when asked about a video address.
enum RtspResult {
  /// The address and login are right: the video can play.
  ok,

  /// The user or password is wrong.
  login,

  /// The camera answers RTSP, but has no video at that path.
  notFound,

  /// Nothing listens on the RTSP port.
  refused,

  /// Something listens, but does not speak RTSP.
  noAnswer,
}

/// Asks the camera to describe the video at [url] (with its user and password in it) without playing it, which shows
/// whether the address and login are right. Digest and Basic logins both work.
Future<RtspResult> rtspDescribe(Uri url, {Duration timeout = const Duration(seconds: 4)}) async {
  final (user, pass) = loginOf(url);
  final bare = url.replace(userInfo: '').toString();
  final Socket socket;
  try {
    socket = await Socket.connect(url.host, url.hasPort ? url.port : 554, timeout: timeout);
  } catch (_) {
    return RtspResult.refused;
  }
  final reader = _RtspReader(socket);
  var seq = 0;
  Future<_RtspResponse> describe([String? auth]) {
    seq++;
    socket.add(utf8.encode('DESCRIBE $bare RTSP/1.0\r\nCSeq: $seq\r\nAccept: application/sdp\r\n'
        'User-Agent: SmartHomeKJ\r\n${auth == null ? '' : 'Authorization: $auth\r\n'}\r\n'));
    return reader.next().timeout(timeout);
  }

  try {
    var r = await describe();
    if (r.status == 401 && user.isNotEmpty) {
      r = await describe(authorization(AuthChallenge.pick(r.all('www-authenticate')), user, pass, 'DESCRIBE', bare));
    }
    return switch (r.status) {
      200 => RtspResult.ok,
      401 || 403 => RtspResult.login,
      0 => RtspResult.noAnswer,
      _ => RtspResult.notFound,
    };
  } catch (_) {
    return RtspResult.noAnswer;
  } finally {
    await reader.close();
    socket.destroy();
  }
}

class _RtspResponse {
  const _RtspResponse(this.status, this.headers);
  final int status;
  final List<(String, String)> headers;

  Iterable<String> all(String name) => headers.where((h) => h.$1 == name).map((h) => h.$2);
}

/// Splits what the camera sends into responses: a status line, headers, then Content-Length bytes of body.
class _RtspReader {
  _RtspReader(Socket socket) {
    _sub = socket.listen((d) {
      _bytes.addAll(d);
      _take();
    }, onError: (Object _) => _fail(), onDone: _fail);
  }

  late final StreamSubscription<List<int>> _sub;
  final _bytes = <int>[];
  Completer<_RtspResponse>? _waiting;

  Future<_RtspResponse> next() {
    final c = _waiting = Completer<_RtspResponse>();
    _take();
    return c.future;
  }

  void _take() {
    final c = _waiting;
    if (c == null) return;
    final end = _headEnd();
    if (end < 0) return;
    final lines = latin1.decode(_bytes.sublist(0, end)).split('\r\n');
    final first = lines.first.split(' ');
    final status = first.length > 1 && first[0].startsWith('RTSP/') ? int.tryParse(first[1]) ?? 0 : 0;
    final headers = [
      for (final l in lines.skip(1))
        if (l.contains(':')) (l.substring(0, l.indexOf(':')).trim().toLowerCase(), l.substring(l.indexOf(':') + 1).trim()),
    ];
    final length = int.tryParse(headers.where((h) => h.$1 == 'content-length').firstOrNull?.$2 ?? '') ?? 0;
    if (_bytes.length < end + 4 + length) return;
    _bytes.removeRange(0, end + 4 + length);
    _waiting = null;
    c.complete(_RtspResponse(status, headers));
  }

  int _headEnd() {
    for (var i = 0; i + 3 < _bytes.length; i++) {
      if (_bytes[i] == 13 && _bytes[i + 1] == 10 && _bytes[i + 2] == 13 && _bytes[i + 3] == 10) return i;
    }
    return -1;
  }

  void _fail() {
    final c = _waiting;
    _waiting = null;
    if (c != null && !c.isCompleted) c.completeError(const SocketException('The camera closed the connection.'));
  }

  Future<void> close() => _sub.cancel();
}
