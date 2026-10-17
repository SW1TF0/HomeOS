import 'dart:async';
import 'dart:convert';

import 'firebase.dart';

/// A pretend Firebase kept in memory, for tests and screenshots: accounts,
/// the database tree and live listeners. Database rules are not checked.
class MemoryCloud {
  final Map<String, Object?> root = {};
  final Map<String, (String password, String uid)> _accounts = {};
  final List<_Listener> _listeners = [];
  var _clock = 0;

  /// A separate signed-in app on this shared pretend cloud.
  MemoryCloudApi app() => MemoryCloudApi(this);

  Object? read(String path) {
    Object? node = root;
    for (final k in _keys(path)) {
      if (node is! Map) return null;
      node = node[k];
    }
    return _copy(node);
  }

  static List<String> _keys(String path) => path.split('/').where((k) => k.isNotEmpty).toList();

  static Object? _copy(Object? v) => v == null ? null : jsonDecode(jsonEncode(v));

  Object? _resolve(Object? v) {
    if (v is Map) {
      if (v.length == 1 && v['.sv'] == 'timestamp') return DateTime.now().millisecondsSinceEpoch;
      final out = <String, Object?>{};
      for (final e in v.entries) {
        final r = _resolve(e.value);
        if (r != null) out['${e.key}'] = r;
      }
      return out.isEmpty ? null : out;
    }
    return v;
  }

  void write(String path, Object? value) {
    final keys = _keys(path);
    final resolved = _resolve(_copy(value));
    if (keys.isEmpty) {
      root
        ..clear()
        ..addAll(resolved is Map ? resolved.cast<String, Object?>() : const {});
    } else {
      Map<String, Object?> node = root;
      for (final k in keys.take(keys.length - 1)) {
        final next = node[k];
        if (next is Map<String, Object?>) {
          node = next;
        } else {
          final created = <String, Object?>{};
          node[k] = created;
          node = created;
        }
      }
      if (resolved == null) {
        node.remove(keys.last);
      } else {
        node[keys.last] = resolved;
      }
      _prune(root);
    }
    _notify(keys);
  }

  static bool _prune(Map<String, Object?> m) {
    m.removeWhere((_, v) => v is Map<String, Object?> && _prune(v));
    return m.isEmpty;
  }

  String newKey() => '${(DateTime.now().millisecondsSinceEpoch * 1000 + _clock++).toRadixString(36)}${FirebaseClient.newId(6)}';

  void _notify(List<String> changed) {
    for (final l in List.of(_listeners)) {
      final at = l.keys;
      final n = changed.length < at.length ? changed.length : at.length;
      var related = true;
      for (var i = 0; i < n; i++) {
        if (changed[i] != at[i]) {
          related = false;
          break;
        }
      }
      if (!related) continue;
      final event = changed.length > at.length
          ? DbEvent('/${changed.sublist(at.length).join('/')}', read(changed.join('/')))
          : DbEvent('/', read(at.join('/')));
      scheduleMicrotask(() {
        if (!l.out.isClosed) l.out.add(event);
      });
    }
  }

  CloudSession _signIn(String email, String password, {required bool create}) {
    final known = _accounts[email.trim().toLowerCase()];
    if (create) {
      if (known != null) throw const CloudException('That email already has an account. Sign in instead.', code: 'EMAIL_EXISTS');
      if (password.length < 6) throw const CloudException('Use a password of at least 6 characters.', code: 'WEAK_PASSWORD');
      _accounts[email.trim().toLowerCase()] = (password, 'user-${_accounts.length + 1}');
    } else if (known == null || known.$1 != password) {
      throw const CloudException('Wrong email or password.', code: 'INVALID_LOGIN_CREDENTIALS');
    }
    final uid = _accounts[email.trim().toLowerCase()]!.$2;
    return CloudSession(
        uid: uid, email: email.trim(), idToken: 'token', refreshToken: 'refresh', expires: DateTime.now().add(const Duration(hours: 1)));
  }
}

class _Listener {
  _Listener(this.keys, this.out);
  final List<String> keys;
  final StreamController<DbEvent> out;
}

/// One app's view of a [MemoryCloud].
class MemoryCloudApi implements CloudApi {
  MemoryCloudApi(this.cloud);
  final MemoryCloud cloud;

  /// Makes every database call fail, as if the phone were offline.
  bool offline = false;

  @override
  CloudSession? session;

  @override
  void Function(CloudSession? session)? onSession;

  void _set(CloudSession? s) {
    session = s;
    onSession?.call(s);
  }

  void _check() {
    if (offline) throw const CloudException('No internet connection.', code: 'offline');
    if (session == null) throw const CloudException('Sign in first.', code: 'signed-out');
  }

  @override
  Future<CloudSession> signUp(String email, String password) async {
    final s = cloud._signIn(email, password, create: true);
    _set(s);
    return s;
  }

  @override
  Future<CloudSession> signIn(String email, String password) async {
    final s = cloud._signIn(email, password, create: false);
    _set(s);
    return s;
  }

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  void signOut() => _set(null);

  @override
  Future<Object?> get(String path, {bool shallow = false}) async {
    _check();
    final v = cloud.read(path);
    return shallow && v is Map ? {for (final k in v.keys) k: true} : v;
  }

  @override
  Future<void> put(String path, Object? value) async {
    _check();
    cloud.write(path, value);
  }

  @override
  Future<void> patch(String path, Map<String, Object?> value) async {
    _check();
    for (final e in value.entries) {
      cloud.write('$path/${e.key}', e.value);
    }
  }

  @override
  Future<String> post(String path, Object? value) async {
    _check();
    final key = cloud.newKey();
    cloud.write('$path/$key', value);
    return key;
  }

  @override
  Future<void> delete(String path) async {
    _check();
    cloud.write(path, null);
  }

  @override
  Stream<DbEvent> listen(String path) {
    late _Listener l;
    final out = StreamController<DbEvent>(
      onListen: () {
        cloud._listeners.add(l);
        final now = cloud.read(path);
        scheduleMicrotask(() {
          if (!l.out.isClosed) l.out.add(DbEvent('/', now));
        });
      },
      onCancel: () => cloud._listeners.remove(l),
    );
    l = _Listener(MemoryCloud._keys(path), out);
    return out.stream;
  }
}
