import 'dart:math' as math;

/// Colour conversions shared by the integrations.

int miredToKelvin(num mired) => mired <= 0 ? 4000 : (1000000 / mired).round();
int kelvinToMired(num kelvin) => kelvin <= 0 ? 250 : (1000000 / kelvin).round();

int rgbToInt(int r, int g, int b) => ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff);
List<int> intToRgb(int c) => [(c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff];
String intToHex(int c) => '#${(c & 0xffffff).toRadixString(16).padLeft(6, '0')}';

int? hexToInt(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceAll('#', '').trim();
  if (h.length < 6) return null;
  return int.tryParse(h.substring(0, 6), radix: 16);
}

/// sRGB to CIE xy (Philips Hue / Zigbee colour space).
List<double> rgbToXy(int color) {
  final rgb = intToRgb(color).map((v) => v / 255.0).toList();
  double lin(double v) => v > 0.04045 ? math.pow((v + 0.055) / 1.055, 2.4).toDouble() : v / 12.92;
  final r = lin(rgb[0]), g = lin(rgb[1]), b = lin(rgb[2]);
  final x = r * 0.4124 + g * 0.3576 + b * 0.1805;
  final y = r * 0.2126 + g * 0.7152 + b * 0.0722;
  final z = r * 0.0193 + g * 0.1192 + b * 0.9505;
  final sum = x + y + z;
  if (sum == 0) return [0.3127, 0.3290];
  return [x / sum, y / sum];
}

/// CIE xy at full brightness back to sRGB.
int xyToRgb(double x, double y) {
  if (y == 0) return 0xffffff;
  const bigY = 1.0;
  final bigX = (bigY / y) * x;
  final bigZ = (bigY / y) * (1 - x - y);
  var r = bigX * 3.2406 - bigY * 1.5372 - bigZ * 0.4986;
  var g = -bigX * 0.9689 + bigY * 1.8758 + bigZ * 0.0415;
  var b = bigX * 0.0557 - bigY * 0.2040 + bigZ * 1.0570;
  double gamma(double v) => v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
  r = gamma(r);
  g = gamma(g);
  b = gamma(b);
  final maxV = [r, g, b, 1.0].reduce(math.max);
  int ch(double v) => ((v / maxV).clamp(0.0, 1.0) * 255).round();
  return rgbToInt(ch(r), ch(g), ch(b));
}

/// Rough colour of a white light at [kelvin], for drawing it on screen.
int kelvinToRgb(int kelvin) {
  final t = kelvin / 100.0;
  double r, g, b;
  if (t <= 66) {
    r = 255;
    g = 99.4708025861 * math.log(t) - 161.1195681661;
    b = t <= 19 ? 0 : 138.5177312231 * math.log(t - 10) - 305.0447927307;
  } else {
    r = 329.698727446 * math.pow(t - 60, -0.1332047592);
    g = 288.1221695283 * math.pow(t - 60, -0.0755148492);
    b = 255;
  }
  int c(double v) => v.clamp(0, 255).round();
  return rgbToInt(c(r), c(g), c(b));
}
