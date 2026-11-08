import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';
import '../../theme/app_theme.dart';

/// When the app plays its animations: in the app itself (main sets [allowed]), unless Settings > Animations
/// or the phone's own "remove animations" turns them off. Tests and screenshots run without them.
abstract final class Motion {
  static bool allowed = false;

  /// False while the opening animation still covers the app, so what glides in waits until it can be seen.
  static final revealed = ValueNotifier<bool>(true);

  static bool on(BuildContext context) =>
      allowed &&
      (Provider.of<AppSettings?>(context, listen: false)?.animations ?? true) &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

/// Fades and slides its child in once, the [index]th of a group, after the opening animation.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.index = 0, this.offset = 26, this.scale = 0.97});
  final Widget child;
  final int index;
  final double offset;
  final double scale;

  static const step = Duration(milliseconds: 55);
  static const length = Duration(milliseconds: 560);

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  late Animation<double> _t;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!Motion.on(context)) return;
    final wait = Entrance.step * widget.index.clamp(0, 14);
    final c = _c = AnimationController(vsync: this, duration: wait + Entrance.length);
    _t = CurvedAnimation(
        parent: c, curve: Interval(wait.inMicroseconds / c.duration!.inMicroseconds, 1, curve: Curves.easeOutCubic));
    if (Motion.revealed.value) {
      c.forward();
    } else {
      Motion.revealed.addListener(_go);
    }
  }

  void _go() {
    if (!Motion.revealed.value) return;
    Motion.revealed.removeListener(_go);
    if (mounted) _c?.forward();
  }

  @override
  void dispose() {
    Motion.revealed.removeListener(_go);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c == null) return widget.child;
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        final t = _t.value;
        if (t >= 1) return child!;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * widget.offset),
            child: Transform.scale(scale: widget.scale + (1 - widget.scale) * t, child: child),
          ),
        );
      },
    );
  }
}

/// Shakes its child sideways, as a field refused, whenever [trigger] changes.
class Shake extends StatefulWidget {
  const Shake({super.key, required this.trigger, required this.child});
  final int trigger;
  final Widget child;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

  @override
  void didUpdateWidget(Shake old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          final t = _c.value;
          final dx = math.sin(t * math.pi * 6) * 14 * (1 - t);
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
      );
}

/// Slow coloured light behind the welcome and sign-in screens. Still when animations are off.
class Aurora extends StatefulWidget {
  const Aurora({super.key, required this.child});
  final Widget child;

  @override
  State<Aurora> createState() => _AuroraState();
}

class _AuroraState extends State<Aurora> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 22));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.on(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _AuroraPainter(_c, dark: p.isDark, background: p.background),
        child: widget.child,
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t, {required this.dark, required this.background}) : super(repaint: t);
  final Animation<double> t;
  final bool dark;
  final Color background;

  static const _colors = [KJPalette.blue, Color(0xFF5AC8FA), KJPalette.purple, Color(0xFFFF9F0A)];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final a = t.value * 2 * math.pi;
    final r = size.longestSide * 0.62;
    for (var i = 0; i < _colors.length; i++) {
      final phase = i * 1.7;
      final c = Offset(
        size.width * (0.5 + 0.42 * math.sin(a + phase) * (i.isEven ? 1 : -0.8)),
        size.height * (0.32 + 0.3 * math.cos(a * (i.isEven ? 1 : 2) + phase) + i * 0.08),
      );
      final color = _colors[i].withValues(alpha: dark ? 0.30 : (i == 3 ? 0.13 : 0.17));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.dark != dark || old.background != background;
}

/// The app's mark: a white house with a blue door on a rounded tile, as on the app icon. [glow] lights the
/// door and the windows from inside; [draw] below 1 draws the house as an outline still being traced.
class HouseMark extends StatelessWidget {
  const HouseMark({super.key, this.size = 72, this.glow = 0, this.draw = 1, this.tile = true});
  final double size;
  final double glow;
  final double draw;
  final bool tile;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: HouseMarkPainter(glow: glow, draw: draw, tile: tile)),
      );
}

class HouseMarkPainter extends CustomPainter {
  const HouseMarkPainter({this.glow = 0, this.draw = 1, this.tile = true, this.tileColor});
  final double glow;
  final double draw;
  final bool tile;
  final Color? tileColor;

  /// The house of the app icon (tool/make_icons.py), on its 108 square.
  static Path house(double s, Offset at) {
    final k = s / 108;
    Offset o(double x, double y) => at + Offset(x * k, y * k);
    return Path()
      ..moveTo(o(54, 33).dx, o(54, 33).dy)
      ..lineTo(o(74, 50.6).dx, o(74, 50.6).dy)
      ..lineTo(o(69.2, 50.6).dx, o(69.2, 50.6).dy)
      ..lineTo(o(69.2, 73).dx, o(69.2, 73).dy)
      ..lineTo(o(38.8, 73).dx, o(38.8, 73).dy)
      ..lineTo(o(38.8, 50.6).dx, o(38.8, 50.6).dy)
      ..lineTo(o(34, 50.6).dx, o(34, 50.6).dy)
      ..close();
  }

  /// The door's colour as the light comes on: blue, through warm white, to lamp yellow.
  static Color doorColour(double glow) => glow < 0.5
      ? Color.lerp(const Color(0xFF0071E3), const Color(0xFFFFF3D1), glow * 2)!
      : Color.lerp(const Color(0xFFFFF3D1), const Color(0xFFFFD60A), (glow - 0.5) * 2)!;

  static Rect door(double s, Offset at) {
    final k = s / 108;
    return Rect.fromLTRB(at.dx + 49.2 * k, at.dy + 57 * k, at.dx + 58.8 * k, at.dy + 73 * k);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    // The icon's house sits in the middle 40 of 108; on a tile it is drawn a little bigger.
    final scale = tile ? 1.5 : 2.4;
    final art = s * scale;
    final at = Offset((size.width - art) / 2, (size.height - art) / 2 + s * 0.02);
    if (tile) {
      final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(s * 0.23));
      canvas.drawRRect(
          r,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: tileColor == null ? const [Color(0xFF2C2C2E), Color(0xFF000000)] : [tileColor!, tileColor!],
            ).createShader(Offset.zero & size));
    }
    final h = house(art, at);
    final d = door(art, at);
    if (glow > 0) {
      final c = d.center;
      final r = art * 0.42 * (0.6 + 0.4 * glow);
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(colors: [
              const Color(0xFFFFD60A).withValues(alpha: 0.55 * glow),
              const Color(0xFFFF9F0A).withValues(alpha: 0),
            ]).createShader(Rect.fromCircle(center: c, radius: r)));
    }
    if (draw >= 1) {
      canvas.drawPath(h, Paint()..color = Colors.white);
    } else {
      final stroke = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = art * 0.022
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final m in h.computeMetrics()) {
        canvas.drawPath(m.extractPath(0, m.length * draw.clamp(0.0, 1.0)), stroke);
      }
    }
    if (draw > 0.6) {
      final door = doorColour(glow);
      final o = ((draw - 0.6) / 0.4).clamp(0.0, 1.0);
      canvas.drawRect(d, Paint()..color = door.withValues(alpha: o));
    }
  }

  @override
  bool shouldRepaint(HouseMarkPainter old) =>
      old.glow != glow || old.draw != draw || old.tile != tile || old.tileColor != tileColor;
}
