import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../integrations/weather.dart';
import '../../l10n/text.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../state/weather.dart';
import '../../theme/app_theme.dart';
import '../../util/sun.dart';
import 'motion.dart';

/// A line of text whose new value rolls in from below while the old one rolls out above, like the numbers on
/// iOS. Plain text when animations are off.
class RollText extends StatelessWidget {
  const RollText(this.text, {super.key, this.style, this.maxLines, this.overflow, this.textAlign});
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final line =
        Text(text, key: ValueKey(text), style: style, maxLines: maxLines, overflow: overflow, textAlign: textAlign);
    if (!Motion.on(context)) return line;
    final align = textAlign == TextAlign.center
        ? Alignment.center
        : (textAlign == TextAlign.right || textAlign == TextAlign.end ? Alignment.centerRight : Alignment.centerLeft);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 340),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(alignment: align, children: [...previous, ?current]),
        transitionBuilder: (child, t) {
          final incoming = child.key == ValueKey(text);
          return FadeTransition(
            opacity: t,
            child: SlideTransition(
              position: Tween(begin: Offset(0, incoming ? 0.7 : -0.7), end: Offset.zero).animate(t),
              child: child,
            ),
          );
        },
        child: line,
      ),
    );
  }
}

/// A repaint signal that ticks ten times a second while animations are on, for slow movement (drifting
/// light, twinkling stars) that does not need every frame and should not cost battery.
class _SlowTicker extends ChangeNotifier {
  _SlowTicker() {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => notifyListeners());
  }
  late final Timer _timer;
  final _started = clock.now();

  /// Seconds since it started.
  double get seconds => clock.now().difference(_started).inMilliseconds / 1000;

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}

/// The sky at one moment: its colour at the top of the screen, the light of the sun or moon and where it is,
/// and how much the stars show.
class Sky {
  const Sky({required this.top, required this.glow, required this.glowAt, required this.glowStrength, this.stars = 0});
  final Color top;
  final Color glow;

  /// Where the sun or moon is, as fractions of the screen's width and height.
  final Offset glowAt;
  final double glowStrength;
  final double stars;

  static const _light = {
    'night': (Color(0xFFE4E7F4), Color(0xFFB4BEF5)),
    'dawn': (Color(0xFFFBE3DE), Color(0xFFFFA98A)),
    'day': (Color(0xFFDAE8FA), Color(0xFFFFE2A0)),
    'golden': (Color(0xFFFCE6CC), Color(0xFFFFB054)),
    'dusk': (Color(0xFFEADFF3), Color(0xFFFF8F7A)),
  };
  static const _dark = {
    'night': (Color(0xFF0D1530), Color(0xFF7D8FE8)),
    'dawn': (Color(0xFF2A1F3D), Color(0xFFFF8A65)),
    'day': (Color(0xFF1F2A3A), Color(0xFFFF9F0A)),
    'golden': (Color(0xFF34261C), Color(0xFFFF9F0A)),
    'dusk': (Color(0xFF281C38), Color(0xFFFF6E6E)),
  };
  static const _starsBy = {'night': 1.0, 'dawn': 0.15, 'day': 0.0, 'golden': 0.0, 'dusk': 0.35};

  /// The sky over the home at [now]: [rise] and [set] are today's sunrise and sunset there (local), or 07:00 and
  /// 18:30 when the home has no town; [weather] is the WMO code of the weather now, if known.
  static Sky at(DateTime now, {DateTime? rise, DateTime? set, required bool dark, int? weather}) {
    final day = DateTime(now.year, now.month, now.day);
    double m(DateTime t) => t.difference(day).inSeconds / 60;
    final r = rise == null ? 7 * 60.0 : m(rise);
    final s = set == null || (rise != null && !set.isAfter(rise)) ? 18.5 * 60 : m(set);
    final keys = <(double, String)>[
      (0, 'night'),
      (r - 70, 'night'),
      (r - 10, 'dawn'),
      (r + 80, 'day'),
      (math.max(r + 81, s - 100), 'day'),
      (math.max(r + 82, s - 25), 'golden'),
      (s + 20, 'dusk'),
      (s + 75, 'night'),
      (24 * 60, 'night'),
    ];
    final at = m(now);
    var i = 0;
    while (i < keys.length - 2 && keys[i + 1].$1 <= at) {
      i++;
    }
    final (a, from) = keys[i];
    final (b, to) = keys[i + 1];
    final f = b <= a ? 1.0 : ((at - a) / (b - a)).clamp(0.0, 1.0);
    final colours = dark ? _dark : _light;
    var top = Color.lerp(colours[from]!.$1, colours[to]!.$1, f)!;
    final glow = Color.lerp(colours[from]!.$2, colours[to]!.$2, f)!;
    var stars = _starsBy[from]! + (_starsBy[to]! - _starsBy[from]!) * f;
    var strength = dark ? 0.32 : 0.5;

    // Grey skies under rain and clouds, and no stars.
    final code = weather ?? 0;
    final grey = dark ? const Color(0xFF1A1F27) : const Color(0xFFE6E9EE);
    final cover = Weather.isWet(code) || code >= 95
        ? 0.6
        : (code == 3 || code == 45 || code == 48 || (code >= 71 && code <= 86) ? 0.38 : (code == 2 ? 0.12 : 0.0));
    top = Color.lerp(top, grey, cover)!;
    strength *= 1 - cover * 0.8;
    stars *= 1 - cover;

    // The sun crosses the sky from sunrise to sunset, the moon from sunset to sunrise.
    final up = at >= r && at <= s;
    final double p;
    if (up) {
      p = (at - r) / (s - r);
    } else {
      final night = 24 * 60 - (s - r);
      p = ((at > s ? at - s : at + 24 * 60 - s) / night).clamp(0.0, 1.0);
    }
    final glowAt = Offset(0.12 + 0.76 * p, 0.04 + 0.2 * (1 - math.sin(math.pi * p)));
    return Sky(top: top, glow: glow, glowAt: glowAt, glowStrength: strength, stars: stars);
  }
}

/// The wallpaper behind the home screen: a sky that follows the time of day at the home, dawn pink, daytime
/// blue, golden before sunset, then dusk and night with stars on the dark theme, greyer under rain and clouds,
/// with the sun's or moon's light where it is in the sky. It drifts slowly when animations are on.
class SkyWallpaper extends StatefulWidget {
  const SkyWallpaper({super.key, required this.child});
  final Widget child;

  @override
  State<SkyWallpaper> createState() => _SkyWallpaperState();
}

class _SkyWallpaperState extends State<SkyWallpaper> {
  Timer? _minute;
  _SlowTicker? _ticker;

  @override
  void initState() {
    super.initState();
    _minute = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Still while another tab is open.
    final moving = Motion.on(context) && TickerMode.valuesOf(context).enabled;
    if (moving && _ticker == null) _ticker = _SlowTicker();
    if (!moving && _ticker != null) {
      _ticker!.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _minute?.cancel();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final place = context.select<HomeStore, HomePlace?>((s) => s.data.place);
    final code = context.select<HomeWeather, int?>((w) => w.now?.code);
    final now = clock.now();
    final sun = place == null ? null : SunTimes.on(now, place.lat, place.lon);
    final sky = Sky.at(now, rise: sun?.rise?.toLocal(), set: sun?.set?.toLocal(), dark: p.isDark, weather: code);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SkyPainter(sky, background: p.background, ticker: _ticker),
        // The screen itself is not drawn again when only the sky moves.
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.sky, {required this.background, _SlowTicker? ticker})
      : _ticker = ticker,
        super(repaint: ticker);
  final Sky sky;
  final Color background;
  final _SlowTicker? _ticker;

  static final _stars = () {
    final r = math.Random(11);
    return [
      for (var i = 0; i < 46; i++)
        (
          Offset(r.nextDouble(), math.pow(r.nextDouble(), 1.6) * 0.4),
          0.6 + r.nextDouble(),
          r.nextDouble(),
          0.2 + r.nextDouble() * 0.5,
        ),
    ];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final t = _ticker?.seconds ?? 0;
    final rect = Offset.zero & size;
    final mid = Color.lerp(sky.top, background, 0.55)!;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [sky.top, mid, background],
            stops: const [0, 0.3, 0.62],
          ).createShader(rect));

    if (sky.stars > 0.02) {
      for (final (at, radius, phase, speed) in _stars) {
        final twinkle = _ticker == null ? 0.8 : 0.55 + 0.45 * math.sin(2 * math.pi * (t * speed + phase));
        final fade = 1 - at.dy / 0.45;
        canvas.drawCircle(Offset(at.dx * size.width, at.dy * size.height), radius,
            Paint()..color = Colors.white.withValues(alpha: (sky.stars * twinkle * fade * 0.85).clamp(0.0, 1.0)));
      }
    }

    final drift = _ticker == null ? Offset.zero : Offset(math.sin(t / 9) * 14, math.cos(t / 13) * 8);
    final c = Offset(sky.glowAt.dx * size.width, sky.glowAt.dy * size.height) + drift;
    final radius = size.width * 0.95;
    canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            sky.glow.withValues(alpha: sky.glowStrength),
            sky.glow.withValues(alpha: sky.glowStrength * 0.35),
            sky.glow.withValues(alpha: 0),
          ], stops: const [0, 0.35, 1])
              .createShader(Rect.fromCircle(center: c, radius: radius)));
  }

  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.sky.top != sky.top ||
      old.sky.glow != sky.glow ||
      old.sky.glowAt != sky.glowAt ||
      old.sky.stars != sky.stars ||
      old.background != background ||
      old._ticker != _ticker;
}

/// A weather icon that moves with its weather: the sun turns, the moon rocks, clouds drift, rain and snow fall
/// and a storm flashes. Still when animations are off.
class WeatherGlyph extends StatefulWidget {
  const WeatherGlyph({super.key, required this.code, required this.color, this.day = true, this.size = 24});
  final int code;
  final bool day;
  final double size;
  final Color color;

  @override
  State<WeatherGlyph> createState() => _WeatherGlyphState();
}

class _WeatherGlyphState extends State<WeatherGlyph> with TickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.on(context)) {
      _c ??= AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();
    } else {
      _c?.dispose();
      _c = null;
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Weather.iconOf(widget.code, day: widget.day), size: widget.size, color: widget.color);
    final c = _c;
    if (c == null) return icon;
    final code = widget.code;
    final s = widget.size;
    final wet = Weather.isWet(code) && code < 95;
    final snow = code >= 71 && code <= 86;
    return SizedBox.square(
      dimension: s,
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          final t = c.value;
          Widget moving;
          if (code <= 1 && widget.day) {
            moving = Transform.rotate(angle: t * 2 * math.pi, child: icon);
          } else if (code <= 1) {
            moving = Transform.rotate(angle: math.sin(t * 2 * math.pi * 4) * 0.12, child: icon);
          } else {
            final dx = math.sin(t * 2 * math.pi * 3) * s * 0.05;
            final dy = wet || snow ? math.sin(t * 2 * math.pi * 6) * s * 0.025 : 0.0;
            moving = Transform.translate(offset: Offset(dx, dy), child: icon);
          }
          final storm = code >= 95;
          final flash = storm ? math.max(0.0, 1 - ((t * 6) % 1 - 0.8).abs() * 20) : 0.0;
          return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            if (flash > 0)
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
                  BoxShadow(color: const Color(0xFFFFE066).withValues(alpha: 0.6 * flash), blurRadius: s * 0.5),
                ]),
              ),
            moving,
            if (wet || snow)
              Positioned.fill(
                child: CustomPaint(painter: _FallPainter(t, snow: snow, color: widget.color)),
              ),
          ]);
        },
      ),
    );
  }
}

/// Drops or flakes falling from under a cloud.
class _FallPainter extends CustomPainter {
  _FallPainter(this.t, {required this.snow, required this.color});
  final double t;
  final bool snow;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final f = (t * (snow ? 10 : 18) + i / 3) % 1;
      final x = s * (0.3 + 0.2 * i) + (snow ? math.sin((f + i) * math.pi * 2) * s * 0.04 : -f * s * 0.05);
      final y = s * (0.72 + f * 0.36);
      final fade = 1 - f;
      paint.color = color.withValues(alpha: 0.85 * fade);
      if (snow) {
        canvas.drawCircle(Offset(x, y), s * 0.035, paint);
      } else {
        canvas.drawLine(Offset(x, y), Offset(x - s * 0.02, y + s * 0.07), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FallPainter old) => old.t != t;
}

/// A soft bright band that sweeps across its child again and again, for something busy (a scene running).
class Sweep extends StatefulWidget {
  const Sweep({super.key, required this.child, required this.color, this.active = true, this.radius = 18});
  final Widget child;
  final Color color;
  final bool active;
  final double radius;

  @override
  State<Sweep> createState() => _SweepState();
}

class _SweepState extends State<Sweep> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Sweep old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final go = widget.active && Motion.on(context);
    if (go && !_c.isAnimating) _c.repeat();
    if (!go && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || !_c.isAnimating) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => Stack(children: [
        child!,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.radius),
              child: CustomPaint(painter: _SweepPainter(Curves.easeInOut.transform(_c.value), widget.color)),
            ),
          ),
        ),
      ]),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width * 0.55;
    final x = -w + (size.width + w) * t;
    final band = Rect.fromLTWH(x, 0, w, size.height);
    canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
                  colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.35), color.withValues(alpha: 0)])
              .createShader(band));
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t || old.color != color;
}

/// Pops its child in with a spring when it first appears (a tick after something is done).
class PopIn extends StatelessWidget {
  const PopIn({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Motion.on(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      child: child,
      builder: (context, v, child) => Transform.scale(scale: 0.4 + 0.6 * v, child: child),
    );
  }
}
