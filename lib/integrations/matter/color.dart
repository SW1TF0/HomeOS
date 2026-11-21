import 'dart:math';

// Conversions between the app's 0xRRGGBB colours and the colour spaces of
// Matter's colour control cluster (hue/saturation and CIE 1931 xy).

/// 0xRRGGBB to Matter hue and saturation (each 0..254). Brightness is not part of it.
(int hue, int saturation) rgbToHueSat(int rgb) {
  final r = ((rgb >> 16) & 0xff) / 255, g = ((rgb >> 8) & 0xff) / 255, b = (rgb & 0xff) / 255;
  final mx = max(r, max(g, b)), mn = min(r, min(g, b));
  final d = mx - mn;
  double h;
  if (d == 0) {
    h = 0;
  } else if (mx == r) {
    h = 60 * (((g - b) / d) % 6);
  } else if (mx == g) {
    h = 60 * ((b - r) / d + 2);
  } else {
    h = 60 * ((r - g) / d + 4);
  }
  if (h < 0) h += 360;
  final s = mx == 0 ? 0.0 : d / mx;
  return ((h / 360 * 254).round().clamp(0, 254), (s * 254).round().clamp(0, 254));
}

/// Matter hue and saturation (0..254) to a fully bright 0xRRGGBB.
int hueSatToRgb(int hue, int saturation) {
  final h = hue / 254 * 360, s = saturation / 254;
  final c = s, x = c * (1 - ((h / 60) % 2 - 1).abs()), m = 1 - c;
  final (r, g, b) = switch (h ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  int ch(double v) => ((v + m) * 255).round().clamp(0, 255);
  return (ch(r) << 16) | (ch(g) << 8) | ch(b);
}

/// 0xRRGGBB (sRGB) to Matter's CurrentX / CurrentY (x and y times 65536).
(int x, int y) rgbToXy(int rgb) {
  double lin(int c) {
    final v = c / 255;
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = lin((rgb >> 16) & 0xff), g = lin((rgb >> 8) & 0xff), b = lin(rgb & 0xff);
  final bigX = 0.4124 * r + 0.3576 * g + 0.1805 * b;
  final bigY = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final bigZ = 0.0193 * r + 0.1192 * g + 0.9505 * b;
  final sum = bigX + bigY + bigZ;
  final x = sum == 0 ? 0.3127 : bigX / sum, y = sum == 0 ? 0.3290 : bigY / sum;
  return ((x * 65536).round().clamp(0, 0xfeff), (y * 65536).round().clamp(0, 0xfeff));
}

/// Matter's CurrentX / CurrentY to a fully bright 0xRRGGBB.
int xyToRgb(int currentX, int currentY) {
  final x = currentX / 65536, y = max(currentY / 65536, 1e-6);
  final bigX = x / y, bigZ = (1 - x - y) / y;
  var r = 3.2406 * bigX - 1.5372 - 0.4986 * bigZ;
  var g = -0.9689 * bigX + 1.8758 + 0.0415 * bigZ;
  var b = 0.0557 * bigX - 0.2040 + 1.0570 * bigZ;
  r = max(r, 0);
  g = max(g, 0);
  b = max(b, 0);
  final m = max(r, max(g, b));
  if (m > 0) {
    r /= m;
    g /= m;
    b /= m;
  }
  int ch(double v) {
    final c = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055;
    return (c * 255).round().clamp(0, 255);
  }

  return (ch(r) << 16) | (ch(g) << 8) | ch(b);
}
