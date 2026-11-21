import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/md5.dart';
import 'package:pointycastle/digests/sha1.dart';

String md5Hex(String s) => _hex(MD5Digest().process(Uint8List.fromList(utf8.encode(s))));

Uint8List sha1Bytes(List<int> data) => SHA1Digest().process(Uint8List.fromList(data));

String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

final _random = Random.secure();

/// Random bytes for nonces.
List<int> randomBytes(int n) => List<int>.generate(n, (_) => _random.nextInt(256));

/// One `WWW-Authenticate` challenge: its scheme (`basic` or `digest`) and parameters (realm, nonce...).
class AuthChallenge {
  const AuthChallenge(this.scheme, this.params);

  final String scheme;
  final Map<String, String> params;

  /// Every challenge in [headers]. One header can carry several, as HTTP joins repeated headers with commas.
  static List<AuthChallenge> parseAll(Iterable<String> headers) {
    final out = <AuthChallenge>[];
    for (final h in headers) {
      final starts = RegExp(r'(?:^|,)\s*(basic|digest)\s+', caseSensitive: false).allMatches(h).toList();
      for (var i = 0; i < starts.length; i++) {
        final body = h.substring(starts[i].end, i + 1 < starts.length ? starts[i + 1].start : h.length);
        out.add(AuthChallenge(starts[i].group(1)!.toLowerCase(), {
          for (final m in RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))').allMatches(body))
            m.group(1)!.toLowerCase(): m.group(2) ?? m.group(3)!,
        }));
      }
    }
    return out;
  }

  /// The strongest challenge offered: Digest over Basic.
  static AuthChallenge? pick(Iterable<String> headers) {
    final all = parseAll(headers);
    return all.where((c) => c.scheme == 'digest').firstOrNull ?? all.firstOrNull;
  }
}

/// The `Authorization` header that answers [challenge] for [method] on [uri] (an HTTP path, or a whole RTSP URL).
/// Without a Digest challenge it is HTTP Basic.
String authorization(AuthChallenge? challenge, String user, String pass, String method, String uri) {
  if (challenge == null || challenge.scheme != 'digest') return 'Basic ${base64.encode(utf8.encode('$user:$pass'))}';
  final p = challenge.params;
  final realm = p['realm'] ?? '';
  final nonce = p['nonce'] ?? '';
  final qop = (p['qop'] ?? '').split(',').map((q) => q.trim().toLowerCase()).contains('auth') ? 'auth' : null;
  final ha1 = md5Hex('$user:$realm:$pass');
  final ha2 = md5Hex('$method:$uri');
  const nc = '00000001';
  final cnonce = _hex(Uint8List.fromList(randomBytes(8)));
  final response = qop == null ? md5Hex('$ha1:$nonce:$ha2') : md5Hex('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
  return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$uri", response="$response"'
      '${p['opaque'] == null ? '' : ', opaque="${p['opaque']}"'}'
      '${qop == null ? '' : ', qop=$qop, nc=$nc, cnonce="$cnonce"'}'
      '${(p['algorithm'] ?? '').toUpperCase() == 'MD5' ? ', algorithm=MD5' : ''}';
}

/// The user and password written in an address (`rtsp://user:pass@host/...`), decoded.
(String, String) loginOf(Uri uri) {
  if (uri.userInfo.isEmpty) return ('', '');
  final at = uri.userInfo.indexOf(':');
  String dec(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  return at < 0 ? (dec(uri.userInfo), '') : (dec(uri.userInfo.substring(0, at)), dec(uri.userInfo.substring(at + 1)));
}

/// `user:pass` encoded for the user-info part of an address.
String loginInfo(String user, String pass) =>
    user.isEmpty ? '' : '${Uri.encodeComponent(user)}${pass.isEmpty ? '' : ':${Uri.encodeComponent(pass)}'}';
