import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart' show IconData;
import 'package:http/http.dart' as http;

import '../models/home.dart';

/// The weather at a home: now, the next hours and the next days. From Open-Meteo, which is free and needs no key.
class Weather {
  const Weather({
    required this.temp,
    required this.feelsLike,
    required this.code,
    required this.day,
    required this.humidity,
    required this.wind,
    required this.hours,
    required this.days,
  });

  final double temp;
  final double feelsLike;

  /// The WMO weather code: 0 clear, 3 overcast, 61 rain, 71 snow, 95 thunderstorm...
  final int code;

  /// Whether the sun is up, for the icon.
  final bool day;
  final double? humidity;

  /// km/h.
  final double? wind;
  final List<WeatherHour> hours;
  final List<WeatherDay> days;

  String get text => describe(code);
  IconData get icon => iconOf(code, day: day);

  /// Whether rain, drizzle, showers or a storm is falling, which "when it starts to rain" waits for.
  bool get raining => isWet(code);

  static bool isWet(int code) => (code >= 51 && code <= 67) || (code >= 80 && code <= 82) || code >= 95;

  static String describe(int code) => switch (code) {
        0 => 'Clear sky',
        1 => 'Mostly clear',
        2 => 'Partly cloudy',
        3 => 'Cloudy',
        45 || 48 => 'Fog',
        51 || 53 || 55 => 'Drizzle',
        56 || 57 || 66 || 67 => 'Freezing rain',
        61 || 63 => 'Rain',
        65 => 'Heavy rain',
        71 || 73 || 77 => 'Snow',
        75 => 'Heavy snow',
        80 || 81 => 'Showers',
        82 => 'Heavy showers',
        85 || 86 => 'Snow showers',
        95 => 'Thunderstorm',
        96 || 99 => 'Thunderstorm with hail',
        _ => 'Cloudy',
      };

  static IconData iconOf(int code, {bool day = true}) => switch (code) {
        0 || 1 => day ? CupertinoIcons.sun_max_fill : CupertinoIcons.moon_stars_fill,
        2 => day ? CupertinoIcons.cloud_sun_fill : CupertinoIcons.cloud_moon_fill,
        45 || 48 => CupertinoIcons.cloud_fog_fill,
        51 || 53 || 55 || 56 || 57 => CupertinoIcons.cloud_drizzle_fill,
        61 || 63 || 66 || 67 || 80 || 81 => CupertinoIcons.cloud_rain_fill,
        65 || 82 => CupertinoIcons.cloud_heavyrain_fill,
        71 || 73 || 75 || 77 || 85 || 86 => CupertinoIcons.cloud_snow_fill,
        95 => CupertinoIcons.cloud_bolt_rain_fill,
        96 || 99 => CupertinoIcons.cloud_hail_fill,
        _ => CupertinoIcons.cloud_fill,
      };

  /// Reads Open-Meteo's forecast answer.
  static Weather? parse(Object? json) {
    if (json is! Map) return null;
    final now = json['current'];
    if (now is! Map || now['temperature_2m'] is! num) return null;
    List<T> zip<T>(Object? block, String key, T? Function(Map b, int i) make) {
      if (block is! Map || block[key] is! List) return const [];
      return [
        for (var i = 0; i < (block[key] as List).length; i++)
          if (make(block, i) case final T v) v,
      ];
    }

    num? at(Map b, String k, int i) {
      final list = b[k];
      return list is List && i < list.length && list[i] is num ? list[i] as num : null;
    }

    DateTime? when(Map b, String k, int i) {
      final list = b[k];
      return list is List && i < list.length && list[i] is String ? DateTime.tryParse(list[i] as String) : null;
    }

    return Weather(
      temp: (now['temperature_2m'] as num).toDouble(),
      feelsLike: ((now['apparent_temperature'] ?? now['temperature_2m']) as num).toDouble(),
      code: (now['weather_code'] as num?)?.toInt() ?? 3,
      day: (now['is_day'] as num?) != 0,
      humidity: (now['relative_humidity_2m'] as num?)?.toDouble(),
      wind: (now['wind_speed_10m'] as num?)?.toDouble(),
      hours: zip(json['hourly'], 'time', (b, i) {
        final t = when(b, 'time', i);
        final temp = at(b, 'temperature_2m', i);
        if (t == null || temp == null) return null;
        return WeatherHour(
          at: t,
          temp: temp.toDouble(),
          code: at(b, 'weather_code', i)?.toInt() ?? 3,
          rain: at(b, 'precipitation_probability', i)?.toInt(),
          day: at(b, 'is_day', i) != 0,
        );
      }),
      days: zip(json['daily'], 'time', (b, i) {
        final t = when(b, 'time', i);
        final high = at(b, 'temperature_2m_max', i);
        final low = at(b, 'temperature_2m_min', i);
        if (t == null || high == null || low == null) return null;
        return WeatherDay(
          date: t,
          high: high.toDouble(),
          low: low.toDouble(),
          code: at(b, 'weather_code', i)?.toInt() ?? 3,
          rain: at(b, 'precipitation_probability_max', i)?.toInt(),
          sunrise: when(b, 'sunrise', i),
          sunset: when(b, 'sunset', i),
        );
      }),
    );
  }

  /// The hours from [now] on, at most [count].
  List<WeatherHour> next(DateTime now, {int count = 24}) {
    final from = DateTime(now.year, now.month, now.day, now.hour);
    return hours.where((h) => !h.at.isBefore(from)).take(count).toList();
  }
}

class WeatherHour {
  const WeatherHour({required this.at, required this.temp, required this.code, this.rain, this.day = true});
  final DateTime at;
  final double temp;
  final int code;

  /// Chance of rain, in percent.
  final int? rain;
  final bool day;
}

class WeatherDay {
  const WeatherDay({
    required this.date,
    required this.high,
    required this.low,
    required this.code,
    this.rain,
    this.sunrise,
    this.sunset,
  });
  final DateTime date;
  final double high;
  final double low;
  final int code;
  final int? rain;
  final DateTime? sunrise;
  final DateTime? sunset;
}

/// Open-Meteo: the forecast for a place, and towns that match a name.
class OpenMeteo {
  OpenMeteo(this.client);
  final http.Client client;

  static Uri forecastUri(HomePlace place) => Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': place.lat.toStringAsFixed(4),
        'longitude': place.lon.toStringAsFixed(4),
        'current': 'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day',
        'hourly': 'temperature_2m,weather_code,precipitation_probability,is_day',
        'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset',
        'forecast_days': '7',
        'timezone': 'auto',
      });

  Future<Weather?> forecast(HomePlace place) async {
    final r = await client.get(forecastUri(place)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw WeatherException('The weather service answered ${r.statusCode}.');
    return Weather.parse(jsonDecode(r.body));
  }

  /// Towns whose name starts with [name], in [language] where the service knows it.
  Future<List<HomePlace>> search(String name, {String language = 'en'}) async {
    final q = name.trim();
    if (q.length < 2) return const [];
    final r = await client
        .get(Uri.https('geocoding-api.open-meteo.com', '/v1/search',
            {'name': q, 'count': '8', 'language': language, 'format': 'json'}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw WeatherException('The town search answered ${r.statusCode}.');
    final j = jsonDecode(r.body);
    final results = j is Map ? j['results'] : null;
    if (results is! List) return const [];
    return [
      for (final e in results)
        if (e is Map && e['latitude'] is num && e['longitude'] is num && e['name'] is String)
          HomePlace(
            name: e['name'] as String,
            region: [e['admin1'], e['country']].whereType<String>().where((s) => s.isNotEmpty).join(', '),
            lat: (e['latitude'] as num).toDouble(),
            lon: (e['longitude'] as num).toDouble(),
          ),
    ];
  }
}

class WeatherException implements Exception {
  const WeatherException(this.message);
  final String message;
  @override
  String toString() => message;
}
