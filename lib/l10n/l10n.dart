import 'dart:ui' show PlatformDispatcher;

import 'bg.dart';

/// The app's words in Bulgarian or English. Screens are written in English; every [Text] looks its words up here
/// when it is drawn, so a line built from parts ("3 of 7 devices active.") is found through its pattern
/// ("{0} of {1} devices active."), and the parts in it are looked up too. Names people gave their homes, rooms and
/// devices are not in the list, so they stay as they are.
abstract final class L10n {
  /// 'en' or 'bg': the language the app speaks now.
  static String get code => _code;
  static String _code = 'en';

  static bool get bg => _code == 'bg';

  /// The languages to choose from in Settings, by code, each in its own language.
  static const choices = {'auto': 'Automatic', 'en': 'English', 'bg': 'Български'};

  /// Picks the language: 'en', 'bg', or 'auto' for the phone's own.
  static void use(String choice) {
    _code = choice == 'auto' ? phoneLanguage() : (choice == 'bg' ? 'bg' : 'en');
    _cache.clear();
  }

  static String phoneLanguage() {
    for (final l in PlatformDispatcher.instance.locales) {
      if (l.languageCode == 'bg') return 'bg';
      if (l.languageCode == 'en') return 'en';
    }
    return 'en';
  }

  static final Map<String, String> _cache = {};

  /// Words that were not found, to fill in the list (see test/l10n_test.dart).
  static Set<String>? missing;

  static final List<_Pattern> _patterns = _buildPatterns();
  static final Map<String, String> _lower = {for (final e in bgWords.entries) e.key.toLowerCase(): e.value};

  static List<_Pattern> _buildPatterns() {
    final out = <_Pattern>[];
    for (final e in bgPatterns.entries) {
      // "When {0} {1}" cannot be split back into its parts once filled in; such lines use [trf].
      if (_joined.hasMatch(e.key)) continue;
      final p = _Pattern.parse(e.key, e.value);
      if (p != null) out.add(p);
    }
    // The pattern with the most fixed words wins: "{0} of {1} devices active." before "{0} · {1}".
    out.sort((a, b) => b.weight.compareTo(a.weight));
    return out;
  }

  static String translate(String s, [int depth = 0]) {
    if (s.isEmpty) return s;
    final exact = bgWords[s];
    if (exact != null) return exact;
    if (depth == 0) {
      final hit = _cache[s];
      if (hit != null) return hit;
    }
    final out = _find(s, depth);
    if (depth == 0) {
      if (_cache.length > 4000) _cache.clear();
      _cache[s] = out;
    }
    return out;
  }

  static final _joined = RegExp(r'\{\d\}\s*\{\d\}');

  static final _plain = RegExp(r'^[\d\s.,:;%°+\-–—/()·|#×*!?…]*$');
  static final _hasLetter = RegExp(r'[A-Za-z]');

  static String _find(String s, int depth) {
    if (_plain.hasMatch(s) || !_hasLetter.hasMatch(s)) return s;
    // Space around a word ("  Mon 3 Nov") stays where it was.
    final trimmed = s.trim();
    if (trimmed.length != s.length && trimmed.isNotEmpty) {
      final inner = translate(trimmed, depth);
      if (inner != trimmed) return s.replaceFirst(trimmed, inner);
      return s;
    }
    // Labels in capitals ("DEVICES") are the same words.
    final caps = s == s.toUpperCase() && s != s.toLowerCase();
    if (caps) {
      final low = _lower[s.toLowerCase()];
      if (low != null) return low.toUpperCase();
    }
    if (depth < 4) {
      for (final p in _patterns) {
        final m = p.match(s, caseless: caps);
        if (m == null) continue;
        final parts = [for (final g in m) translate(g, depth + 1)];
        final out = p.fill(parts);
        return caps ? out.toUpperCase() : out;
      }
    }
    missing?.add(s);
    return s;
  }
}

/// [en] in the app's language.
String tr(String en) => L10n.bg ? L10n.translate(en) : en;

/// [pattern] ("When {0} {1}") in the app's language, filled in with [parts], which the caller gives in the app's
/// language already (names stay as they are). For lines whose parts sit side by side, which [tr] cannot take apart.
String trf(String pattern, List<String> parts) {
  final p = L10n.bg ? (bgPatterns[pattern] ?? pattern) : pattern;
  return p.replaceAllMapped(_Pattern._slot, (m) {
    final i = int.parse(m.group(1)!);
    return i < parts.length ? parts[i] : '';
  });
}

/// One of the patterns of [bgPatterns]: fixed words with {0}, {1}... where any text goes.
class _Pattern {
  _Pattern(this.regex, this.caseless, this.pieces, this.target, this.weight);

  final RegExp regex;
  final RegExp caseless;

  /// The fixed words, the longest first, to rule a line out quickly.
  final List<String> pieces;
  final String target;
  final int weight;

  static final _slot = RegExp(r'\{(\d)\}');

  static _Pattern? parse(String en, String bg) {
    final buf = StringBuffer('^');
    final pieces = <String>[];
    var at = 0;
    final order = <int>[];
    for (final m in _slot.allMatches(en)) {
      final piece = en.substring(at, m.start);
      if (piece.isNotEmpty) pieces.add(piece);
      buf.write(RegExp.escape(piece));
      buf.write('(.+?)');
      order.add(int.parse(m.group(1)!));
      at = m.end;
    }
    if (order.isEmpty) return null;
    final rest = en.substring(at);
    if (rest.isNotEmpty) pieces.add(rest);
    buf
      ..write(RegExp.escape(rest))
      ..write(r'$');
    pieces.sort((a, b) => b.length.compareTo(a.length));
    final weight = pieces.fold<int>(0, (n, p) => n + p.trim().length);
    return _Pattern(RegExp(buf.toString(), dotAll: true), RegExp(buf.toString(), dotAll: true, caseSensitive: false),
        pieces, bg, weight * 10 - order.length)
      .._order = order;
  }

  List<int> _order = const [];

  bool get _dotted => pieces.any((p) => p.contains('·'));

  /// The text in each {n}, in the order of n; null when [s] is not this pattern.
  List<String>? match(String s, {bool caseless = false}) {
    final low = caseless ? s.toLowerCase() : s;
    for (final p in pieces) {
      if (!low.contains(caseless ? p.toLowerCase() : p)) return null;
    }
    final m = (caseless ? this.caseless : regex).firstMatch(s);
    if (m == null) return null;
    final out = List.filled(_order.length, '');
    for (var i = 0; i < _order.length; i++) {
      final slot = _order[i];
      final part = m.group(i + 1)!;
      // "Light · Virtual devices" is two things side by side, not "{0} devices" with "Light · Virtual" in it.
      if (!_dotted && part.contains(' · ')) return null;
      if (slot < out.length) out[slot] = part;
    }
    return out;
  }

  String fill(List<String> parts) =>
      target.replaceAllMapped(_slot, (m) {
        final i = int.parse(m.group(1)!);
        return i < parts.length ? parts[i] : '';
      });
}

/// [en] in the app's language where the same English word means something else elsewhere: [context] tells them
/// apart ("Open" on a blind's button is a verb, on a door sensor a state). Looked up as "en@context".
String tc(String en, String context) => L10n.bg ? (bgWords['$en@$context'] ?? L10n.translate(en)) : en;

/// The first letter of a day, Monday being 1, for rows of days.
String weekdayLetter(int weekday) =>
    (L10n.bg ? const ['П', 'В', 'С', 'Ч', 'П', 'С', 'Н'] : const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])[(weekday - 1) % 7];

/// Short day and month names, for charts and lists.
String weekdayShort(int weekday) => tr(const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][(weekday - 1) % 7]);

String monthShort(int month) =>
    tr(const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][(month - 1) % 12]);
