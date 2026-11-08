import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../integrations/weather.dart';
import '../models/home.dart';

/// The weather at the open home, asked for when the app opens and then every half hour while it is open.
class HomeWeather extends ChangeNotifier {
  HomeWeather(http.Client client, {this.every = const Duration(minutes: 30)}) : api = OpenMeteo(client);

  final OpenMeteo api;
  final Duration every;

  /// The latest weather for [place], or null until it comes (or when the home has no place).
  Weather? get now => _now;
  Weather? _now;

  HomePlace? get place => _place;
  HomePlace? _place;
  DateTime? _fetched;
  bool _loading = false;
  bool get loading => _loading;

  /// Why the last try failed, until one works.
  String? get problem => _problem;
  String? _problem;

  static bool _same(HomePlace? a, HomePlace? b) => a?.lat == b?.lat && a?.lon == b?.lon;

  /// Asks again when [place] changed, [force] is set or the last answer is older than [every].
  Future<void> refresh(HomePlace? place, {bool force = false}) async {
    if (!_same(place, _place)) {
      _place = place;
      _now = null;
      _fetched = null;
      _problem = null;
      notifyListeners();
    }
    if (place == null || _loading) return;
    final at = clock.now();
    if (!force && _fetched != null && at.difference(_fetched!) < every) return;
    _loading = true;
    notifyListeners();
    try {
      final w = await api.forecast(place);
      if (_gone || !_same(place, _place)) return;
      _now = w ?? _now;
      _fetched = at;
      _problem = w == null ? 'The weather service sent nothing usable.' : null;
    } catch (e) {
      if (_same(place, _place)) _problem = e is WeatherException ? e.message : 'No weather: no internet connection?';
      debugPrint('Weather: $e');
    } finally {
      _loading = false;
      if (!_gone) notifyListeners();
    }
  }

  bool _gone = false;

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}
