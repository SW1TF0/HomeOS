import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Where the app's Firebase project lives. The API key and the database
/// address are public identifiers, not secrets: the database rules decide
/// who may read and write what.
class FirebaseConfig {
  const FirebaseConfig({
    required this.apiKey,
    required this.databaseUrl,
    this.authHost = 'https://identitytoolkit.googleapis.com',
    this.tokenHost = 'https://securetoken.googleapis.com',
    this.namespace,
  });

  /// The local Firebase emulators, for tests.
  factory FirebaseConfig.emulator({String host = 'http://127.0.0.1', int authPort = 9099, int dbPort = 9000, required String project}) =>
      FirebaseConfig(
        apiKey: 'fake-api-key',
        databaseUrl: '$host:$dbPort',
        authHost: '$host:$authPort/identitytoolkit.googleapis.com',
        tokenHost: '$host:$authPort/securetoken.googleapis.com',
        namespace: '$project-default-rtdb',
      );

  final String apiKey;
  final String databaseUrl;
  final String authHost;
  final String tokenHost;

  /// The database name, only needed for the emulator.
  final String? namespace;

  bool get configured => apiKey.isNotEmpty && databaseUrl.isNotEmpty;
}

/// Something the cloud refused, in words for the user.
class CloudException implements Exception {
  const CloudException(this.message, {this.code});
  final String message;
  final String? code;

  bool get permissionDenied => code == 'permission';

  @override
  String toString() => message;
}

/// A signed-in account.
class CloudSession {
  CloudSession({required this.uid, required this.email, required this.idToken, required this.refreshToken, required this.expires});

  final String uid;
  final String email;
  String idToken;
  String refreshToken;
  DateTime expires;

  bool get fresh => DateTime.now().isBefore(expires.subtract(const Duration(minutes: 2)));

  Map<String, dynamic> toJson() =>
      {'uid': uid, 'email': email, 'idToken': idToken, 'refreshToken': refreshToken, 'expires': expires.toIso8601String()};

  factory CloudSession.fromJson(Map<String, dynamic> j) => CloudSession(
        uid: j['uid'] as String,
        email: j['email'] as String? ?? '',
        idToken: j['idToken'] as String? ?? '',
        refreshToken: j['refreshToken'] as String,
        expires: DateTime.tryParse(j['expires'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// One change seen by a live listener: [data] now sits at [path] (relative to
/// the listened place, "/" for all of it). A patch only replaces the keys it names.
class DbEvent {
  const DbEvent(this.path, this.data, {this.patch = false});
  final String path;
  final Object? data;
  final bool patch;

  /// The path as keys, without empty parts.
  List<String> get keys => path.split('/').where((k) => k.isNotEmpty).toList();
}

/// Accounts and a live JSON database: what the app needs from a cloud.
abstract class CloudApi {
  /// The signed-in account, or null.
  CloudSession? session;

  /// Called whenever the session's tokens change, so they can be saved.
  void Function(CloudSession? session)? onSession;

  Future<CloudSession> signUp(String email, String password);
  Future<CloudSession> signIn(String email, String password);
  Future<void> sendPasswordReset(String email);
  void signOut();

  Future<Object?> get(String path, {bool shallow = false});
  Future<void> put(String path, Object? value);
  Future<void> patch(String path, Map<String, Object?> value);
  Future<String> post(String path, Object? value);
  Future<void> delete(String path);

  /// Follows [path] live: first a put of everything there, then each change.
  Stream<DbEvent> listen(String path);
}

/// Firebase Authentication (email and password) and the Realtime Database,
/// over their REST APIs, so it works the same on phones and computers.
class FirebaseClient implements CloudApi {
  FirebaseClient(this.config, {http.Client? client}) : _http = client ?? http.Client();

  final FirebaseConfig config;
  final http.Client _http;

  @override
  CloudSession? session;

  @override
  void Function(CloudSession? session)? onSession;

  Future<CloudSession>? _refreshing;

  // ---- Accounts -------------------------------------------------------------------

  @override
  Future<CloudSession> signUp(String email, String password) => _account('accounts:signUp', email, password);

  @override
  Future<CloudSession> signIn(String email, String password) => _account('accounts:signInWithPassword', email, password);

  Future<CloudSession> _account(String method, String email, String password) async {
    final j = await _authPost('${config.authHost}/v1/$method', {'email': email.trim(), 'password': password, 'returnSecureToken': true});
    final s = CloudSession(
      uid: j['localId'] as String,
      email: j['email'] as String? ?? email.trim(),
      idToken: j['idToken'] as String,
      refreshToken: j['refreshToken'] as String,
      expires: DateTime.now().add(Duration(seconds: int.tryParse('${j['expiresIn']}') ?? 3600)),
    );
    _setSession(s);
    return s;
  }

  @override
  Future<void> sendPasswordReset(String email) async =>
      await _authPost('${config.authHost}/v1/accounts:sendOobCode', {'requestType': 'PASSWORD_RESET', 'email': email.trim()});

  @override
  void signOut() => _setSession(null);

  void _setSession(CloudSession? s) {
    session = s;
    onSession?.call(s);
  }

  /// A valid ID token, refreshed when it is about to run out.
  Future<String> token({bool force = false}) async {
    final s = session;
    if (s == null) throw const CloudException('Sign in first.', code: 'signed-out');
    if (s.fresh && !force) return s.idToken;
    _refreshing ??= _refresh(s).whenComplete(() => _refreshing = null);
    return (await _refreshing!).idToken;
  }

  Future<CloudSession> _refresh(CloudSession s) async {
    final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('${config.tokenHost}/v1/token?key=${config.apiKey}'),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(s.refreshToken)}')
          .timeout(const Duration(seconds: 15));
    } on Object {
      throw const CloudException('No internet connection.', code: 'offline');
    }
    final j = _json(res.body);
    if (res.statusCode != 200) {
      final code = _errorCode(j);
      if (code == 'TOKEN_EXPIRED' || code == 'USER_NOT_FOUND' || code == 'USER_DISABLED' || code == 'INVALID_REFRESH_TOKEN') {
        _setSession(null);
        throw const CloudException('Signed out. Sign in again.', code: 'signed-out');
      }
      throw CloudException(_authMessage(code), code: code);
    }
    s
      ..idToken = j['id_token'] as String
      ..refreshToken = j['refresh_token'] as String? ?? s.refreshToken
      ..expires = DateTime.now().add(Duration(seconds: int.tryParse('${j['expires_in']}') ?? 3600));
    _setSession(s);
    return s;
  }

  Future<Map<String, dynamic>> _authPost(String url, Map<String, dynamic> body) async {
    final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('$url?key=${config.apiKey}'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
    } on Object {
      throw const CloudException('No internet connection.', code: 'offline');
    }
    final j = _json(res.body);
    if (res.statusCode != 200) {
      final code = _errorCode(j);
      throw CloudException(_authMessage(code), code: code);
    }
    return j;
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final j = jsonDecode(body);
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {};
    }
  }

  static String _errorCode(Map<String, dynamic> j) {
    final e = j['error'];
    final message = e is Map ? '${e['message']}' : '$e';
    // "WEAK_PASSWORD : Password should be at least 6 characters" -> WEAK_PASSWORD
    return message.split(' ').first;
  }

  static String _authMessage(String code) => switch (code) {
        'EMAIL_EXISTS' => 'That email already has an account. Sign in instead.',
        'EMAIL_NOT_FOUND' || 'INVALID_PASSWORD' || 'INVALID_LOGIN_CREDENTIALS' => 'Wrong email or password.',
        'INVALID_EMAIL' || 'MISSING_EMAIL' => 'That is not an email address.',
        'WEAK_PASSWORD' || 'MISSING_PASSWORD' => 'Use a password of at least 6 characters.',
        'USER_DISABLED' => 'This account is turned off.',
        'TOO_MANY_ATTEMPTS_TRY_LATER' => 'Too many tries. Wait a few minutes and try again.',
        'OPERATION_NOT_ALLOWED' || 'PASSWORD_LOGIN_DISABLED' => 'Email sign-in is not turned on in Firebase yet.',
        'API_KEY_INVALID' || 'INVALID_API_KEY' => 'The app has the wrong Firebase key.',
        _ => 'The account service said: ${code.isEmpty ? 'no answer' : code}.',
      };

  // ---- Database ---------------------------------------------------------------------

  /// A database key for any text: Firebase keys cannot hold . # $ [ ] or /.
  static String key(String text) => text.replaceAllMapped(RegExp(r'[%.#$\[\]/]'),
      (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(2, '0')}');

  static String unkey(String key) => Uri.decodeComponent(key);

  /// A new random id, for homes and commands.
  static String newId([int length = 20]) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return String.fromCharCodes(Iterable.generate(length, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
  }

  /// Asks the server to fill in its own time.
  static const serverTime = {'.sv': 'timestamp'};

  Future<Uri> _url(String path, [Map<String, String> query = const {}]) async => Uri.parse('${config.databaseUrl}/$path.json')
      .replace(queryParameters: {...query, 'auth': await token(), 'ns': ?config.namespace});

  @override
  Future<Object?> get(String path, {bool shallow = false}) =>
      _db('GET', path, query: {if (shallow) 'shallow': 'true'});

  @override
  Future<void> put(String path, Object? value) => _db('PUT', path, body: value, query: const {'print': 'silent'});

  @override
  Future<void> patch(String path, Map<String, Object?> value) => _db('PATCH', path, body: value, query: const {'print': 'silent'});

  /// Adds [value] under a new key that sorts by time, and returns the key.
  @override
  Future<String> post(String path, Object? value) async => (await _db('POST', path, body: value) as Map)['name'] as String;

  @override
  Future<void> delete(String path) => _db('DELETE', path, query: const {'print': 'silent'});

  Future<Object?> _db(String method, String path, {Object? body, Map<String, String> query = const {}}) async {
    for (var attempt = 0;; attempt++) {
      final req = http.Request(method, await _url(path, query));
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final http.Response res;
      try {
        res = await http.Response.fromStream(await _http.send(req)).timeout(const Duration(seconds: 15));
      } on Object {
        throw const CloudException('No internet connection.', code: 'offline');
      }
      if (res.statusCode == 401 && attempt == 0) {
        // The token may have run out early; get a new one and try once more.
        await token(force: true);
        continue;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const CloudException('Not allowed. Is this home still shared with you?', code: 'permission');
      }
      if (res.statusCode == 204 || res.body.isEmpty) return null;
      final j = jsonDecode(res.body);
      if (res.statusCode >= 400) {
        throw CloudException('The cloud said: ${j is Map ? j['error'] : res.statusCode}', code: 'http-${res.statusCode}');
      }
      return j;
    }
  }

  /// Reconnects by itself (with a new token when the old one runs out) until cancelled.
  @override
  Stream<DbEvent> listen(String path) {
    late StreamController<DbEvent> out;
    http.Client? conn;
    var stopped = false;
    var delay = const Duration(seconds: 1);

    Future<void> run() async {
      while (!stopped) {
        var gotData = false;
        try {
          conn = http.Client();
          final req = http.Request('GET', await _url(path))..headers['Accept'] = 'text/event-stream';
          final res = await conn!.send(req).timeout(const Duration(seconds: 20));
          if (res.statusCode == 401) {
            await token(force: true);
            continue;
          }
          if (res.statusCode >= 400) throw CloudException('Live updates refused (${res.statusCode}).', code: 'permission');
          String? event;
          final data = StringBuffer();
          await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
            if (stopped) break;
            if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              data.write(line.substring(5).trim());
            } else if (line.isEmpty && event != null) {
              final payload = data.toString();
              data.clear();
              final e = event;
              event = null;
              if (e == 'put' || e == 'patch') {
                final j = jsonDecode(payload) as Map;
                gotData = true;
                delay = const Duration(seconds: 1);
                if (!out.isClosed) out.add(DbEvent(j['path'] as String? ?? '/', j['data'], patch: e == 'patch'));
              } else if (e == 'auth_revoked') {
                await token(force: true);
                break;
              } else if (e == 'cancel') {
                throw const CloudException('Live updates refused.', code: 'permission');
              }
            }
          }
        } on CloudException catch (e) {
          if (e.code == 'signed-out' || e.permissionDenied) {
            if (!out.isClosed) out.addError(e);
            if (e.code == 'signed-out') return;
          }
        } catch (_) {
          // The connection dropped: try again in a moment.
        } finally {
          conn?.close();
          conn = null;
        }
        if (stopped) return;
        await Future<void>.delayed(gotData ? const Duration(milliseconds: 300) : delay);
        if (!gotData) delay = Duration(seconds: min(delay.inSeconds * 2, 30));
      }
    }

    out = StreamController<DbEvent>(
      onListen: run,
      onCancel: () {
        stopped = true;
        conn?.close();
      },
    );
    return out.stream;
  }

  void close() => _http.close();
}
