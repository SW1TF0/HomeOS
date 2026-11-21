import 'dart:math' as math;

/// When the sun rises and sets on one day at one place, worked out on the phone (the sunrise equation, good to
/// a minute or two), so timers at sunset need no internet. Times are UTC; null on a day the sun stays up or down.
class SunTimes {
  const SunTimes(this.rise, this.set);
  final DateTime? rise;
  final DateTime? set;

  /// The sun on the local calendar day of [day], at [lat] and [lon] (east positive).
  factory SunTimes.on(DateTime day, double lat, double lon) {
    final n = DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(2000, 1, 1)).inDays;
    double rad(double d) => d * math.pi / 180;
    double deg(double r) => r * 180 / math.pi;
    final j = n - lon / 360;
    final m = (357.5291 + 0.98560028 * j) % 360;
    final c = 1.9148 * math.sin(rad(m)) + 0.02 * math.sin(rad(2 * m)) + 0.0003 * math.sin(rad(3 * m));
    final l = (m + c + 180 + 102.9372) % 360;
    final transit = 2451545.0 + j + 0.0053 * math.sin(rad(m)) - 0.0069 * math.sin(rad(2 * l));
    final sinD = math.sin(rad(l)) * math.sin(rad(23.4397));
    final cosD = math.cos(math.asin(sinD));
    final cosW = (math.sin(rad(-0.833)) - math.sin(rad(lat)) * sinD) / (math.cos(rad(lat)) * cosD);
    if (cosW.isNaN || cosW < -1 || cosW > 1) return const SunTimes(null, null);
    final w = deg(math.acos(cosW));
    DateTime at(double julian) =>
        DateTime.fromMillisecondsSinceEpoch(((julian - 2440587.5) * 86400000).round(), isUtc: true);
    return SunTimes(at(transit - w / 360), at(transit + w / 360));
  }
}
