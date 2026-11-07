import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An Open-Meteo forecast the way the service sends it: a week of hours and days from the start of [day], times in
/// the home's own time without a zone.
Map<String, Object?> sampleForecast(DateTime day, {double temp = 12, int code = 2, bool isDay = true}) {
  final start = DateTime(day.year, day.month, day.day);
  String iso(DateTime t) => t.toIso8601String().substring(0, 16);
  final hours = [for (var i = 0; i < 7 * 24; i++) start.add(Duration(hours: i))];
  final days = [for (var i = 0; i < 7; i++) DateTime(start.year, start.month, start.day + i)];
  const codes = [2, 3, 61, 80, 0, 1, 71];
  return {
    'latitude': 42.7,
    'longitude': 23.32,
    'timezone': 'Europe/Sofia',
    'current': {
      'time': iso(day),
      'interval': 900,
      'temperature_2m': temp,
      'apparent_temperature': temp - 2.4,
      'relative_humidity_2m': 71,
      'weather_code': code,
      'wind_speed_10m': 9.7,
      'is_day': isDay ? 1 : 0,
    },
    'hourly': {
      'time': [for (final h in hours) iso(h)],
      'temperature_2m': [for (final h in hours) temp - 4 + 6 * (1 - ((h.hour - 14).abs() / 12))],
      'weather_code': [for (final h in hours) codes[(h.hour ~/ 5) % codes.length]],
      'precipitation_probability': [for (final h in hours) (h.hour * 7) % 90],
      'is_day': [for (final h in hours) h.hour >= 7 && h.hour < 17 ? 1 : 0],
    },
    'daily': {
      'time': [for (final d in days) iso(d).substring(0, 10)],
      'weather_code': [for (var i = 0; i < days.length; i++) codes[i % codes.length]],
      'temperature_2m_max': [for (var i = 0; i < days.length; i++) temp + 3 - i % 3],
      'temperature_2m_min': [for (var i = 0; i < days.length; i++) temp - 6 + i % 2],
      'precipitation_probability_max': [for (var i = 0; i < days.length; i++) (i * 23) % 100],
      'sunrise': [for (final d in days) iso(d.add(const Duration(hours: 7, minutes: 2)))],
      'sunset': [for (final d in days) iso(d.add(const Duration(hours: 17, minutes: 8)))],
    },
  };
}

/// Two towns called Sofia, as the town search answers.
const sampleTowns = {
  'results': [
    {'id': 727011, 'name': 'Sofia', 'latitude': 42.69751, 'longitude': 23.32415, 'country': 'Bulgaria', 'admin1': 'Sofia-Capital'},
    {'id': 3372500, 'name': 'Sofia', 'latitude': 38.97, 'longitude': -28.0, 'country': 'Portugal', 'admin1': ''},
  ],
};

/// Answers the weather and the town search like Open-Meteo, and everything else with [other]. [forecast] gives the
/// forecast for each ask, so a test can change the weather between two.
MockClient weatherClient({
  Map<String, Object?> Function()? forecast,
  Object towns = sampleTowns,
  http.Response Function(http.Request)? other,
  List<Uri>? asked,
}) =>
    MockClient((r) async {
      asked?.add(r.url);
      if (r.url.host == 'api.open-meteo.com') {
        return http.Response(jsonEncode((forecast ?? () => sampleForecast(DateTime.now()))()), 200);
      }
      if (r.url.host == 'geocoding-api.open-meteo.com') return http.Response(jsonEncode(towns), 200);
      return other?.call(r) ?? http.Response('[]', 200);
    });
