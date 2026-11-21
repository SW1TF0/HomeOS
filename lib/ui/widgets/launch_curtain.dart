import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../util/haptics.dart';
import 'motion.dart';

/// The opening animation, over the app as it loads: on black, like Android's start screen, the house lights up,
/// the home's devices fly out around it and switch on, the name writes itself, and the app opens through the
/// door. A tap skips to the opening.
class LaunchCurtain extends StatefulWidget {
  const LaunchCurtain({super.key, required this.child});
  final Widget child;

  static const length = Duration(milliseconds: 2150);

  /// When the door starts to open, as a share of [length].
  static const opens = 1500 / 2150;

  @override
  State<LaunchCurtain> createState() => _LaunchCurtainState();
}

class _LaunchCurtainState extends State<LaunchCurtain> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: LaunchCurtain.length);
  bool _decided = false;
  bool _done = false;
  bool _buzzed = false;
  _Art? _art;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!Motion.on(context)) {
      _done = true;
      return;
    }
    Motion.revealed.value = false;
    _art = _Art(Directionality.of(context));
    _c.addListener(_tick);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _done = true);
    });
    _c.forward();
  }

  void _tick() {
    final ms = _c.value * LaunchCurtain.length.inMilliseconds;
    if (!_buzzed && ms > 700) {
      _buzzed = true;
      Haptics.selectionClick();
    }
    if (!Motion.revealed.value && _c.value >= LaunchCurtain.opens) Motion.revealed.value = true;
  }

  void _skip() {
    if (_c.value < LaunchCurtain.opens) _c.forward(from: LaunchCurtain.opens);
  }

  @override
  void dispose() {
    _c.dispose();
    if (!Motion.revealed.value) Motion.revealed.value = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: GestureDetector(
          key: const Key('launch-curtain'),
          behavior: HitTestBehavior.opaque,
          onTap: _skip,
          child: RepaintBoundary(child: CustomPaint(painter: _CurtainPainter(_c, _art!), size: Size.infinite)),
        ),
      ),
    ]);
  }
}

/// Text and icons laid out once for the painter.
class _Art {
  _Art(TextDirection dir) {
    final style = NType.display(31, color: Colors.white, weight: 700);
    word = TextPainter(
      text: TextSpan(style: style, children: const [
        TextSpan(text: 'SmartHome'),
        TextSpan(text: 'KJ', style: TextStyle(color: KJPalette.blue)),
      ]),
      textDirection: dir,
    )..layout();
    for (var i = 0; i < _name.length; i++) {
      letters.add(TextPainter(
        text: TextSpan(text: _name[i], style: style.copyWith(color: i >= 9 ? KJPalette.blue : Colors.white)),
        textDirection: dir,
      )..layout());
      offsets.add(word.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dx);
    }
    for (final (icon, _) in devices) {
      icons.add(TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 21, color: Colors.white),
        ),
        textDirection: dir,
      )..layout());
    }
  }

  static const _name = 'SmartHomeKJ';
  static const devices = [
    (CupertinoIcons.lightbulb_fill, KJPalette.yellow),
    (CupertinoIcons.power, KJPalette.green),
    (CupertinoIcons.thermometer, KJPalette.orange),
    (CupertinoIcons.lock_fill, KJPalette.blue),
    (CupertinoIcons.videocam_fill, KJPalette.indigo),
    (CupertinoIcons.tv_fill, KJPalette.purple),
  ];

  late final TextPainter word;
  final letters = <TextPainter>[];
  final offsets = <double>[];
  final icons = <TextPainter>[];
}

class _CurtainPainter extends CustomPainter {
  _CurtainPainter(this.t, this.art) : super(repaint: t);
  final Animation<double> t;
  final _Art art;

  static const _total = 2150.0;

  /// How far along [from]..[to] milliseconds the animation is, 0 to 1, through [curve].
  double _at(double from, double to, [Curve curve = Curves.linear]) {
    final ms = t.value * _total;
    return curve.transform(((ms - from) / (to - from)).clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ms = t.value * _total;
    final centre = Offset(size.width / 2, size.height * 0.43);
    final orbit = math.min(118.0, size.shortestSide * 0.3);
    final houseWidth = math.min(74.0, size.shortestSide * 0.19);

    // The house: settles in, swells as it lights up, then rushes at the screen as the door opens.
    final grow = ms < 300
        ? 1 - 0.08 * _at(0, 300, Curves.easeInOut)
        : 0.92 + 0.26 * _at(300, 760, Curves.easeOutBack);
    final rush = _at(1450, 2150, Curves.easeInCubic);
    final scale = grow * (1 + rush * 14);
    final span = houseWidth * scale * 108 / 40;
    final at = centre - Offset(span / 2, span * 53 / 108);
    final door = HouseMarkPainter.door(span, at);

    // Opening: a circle grows from the door and the app shows through it.
    final open = _at(1500, 2150, Curves.easeInQuad);
    if (open > 0) {
      final r = open * (size.longestSide * 1.15);
      canvas.clipPath(Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addOval(Rect.fromCircle(center: door.center, radius: r)));
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    // A blue light behind the house.
    final bloom = _at(350, 1000, Curves.easeOut) * (1 - _at(1450, 1800));
    if (bloom > 0) {
      final r = orbit * 2.2;
      canvas.drawCircle(
          centre,
          r,
          Paint()
            ..shader = RadialGradient(colors: [
              const Color(0xFF0A84FF).withValues(alpha: 0.42 * bloom),
              const Color(0xFF5AC8FA).withValues(alpha: 0.12 * bloom),
              const Color(0x00000000),
            ], stops: const [0, 0.45, 1])
                .createShader(Rect.fromCircle(center: centre, radius: r)));
    }

    // Two rings ripple out as the lights come on.
    for (final start in const [420.0, 640.0]) {
      final k = _at(start, start + 900, Curves.easeOutCubic);
      if (k <= 0 || k >= 1) continue;
      canvas.drawCircle(
          centre,
          houseWidth * 0.6 + k * orbit * 1.7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFF0A84FF).withValues(alpha: 0.55 * (1 - k)));
    }

    // The devices fly out to their places around the house, switch on, and fly back in as the door opens.
    final turn = -math.pi / 2 + _at(500, 1500) * 0.5;
    final gather = _at(1400, 1720, Curves.easeInBack);
    for (var i = 0; i < _Art.devices.length; i++) {
      final start = 520.0 + i * 70;
      final out = _at(start, start + 520, Curves.elasticOut) * (1 - gather);
      if (out <= 0) continue;
      final on = _at(start + 260, start + 460, Curves.easeOut);
      final angle = turn + i * 2 * math.pi / _Art.devices.length;
      final dir = Offset(math.cos(angle), math.sin(angle));
      final p = centre + dir * (orbit * out);
      final colour = _Art.devices[i].$2;
      final fade = (1 - _at(1500, 1700)).clamp(0.0, 1.0);
      // A thread back to the house.
      final from = centre + dir * (houseWidth * 0.75);
      if ((p - centre).distance > houseWidth * 0.75) {
        canvas.drawLine(
            from,
            p,
            Paint()
              ..strokeWidth = 1.2
              ..color = Colors.white.withValues(alpha: 0.16 * fade));
      }
      final radius = 23.0 * out.clamp(0.0, 1.2);
      if (on > 0) {
        canvas.drawCircle(
            p,
            radius * 1.9,
            Paint()
              ..shader = RadialGradient(colors: [colour.withValues(alpha: 0.45 * on * fade), colour.withValues(alpha: 0)])
                  .createShader(Rect.fromCircle(center: p, radius: radius * 1.9)));
      }
      canvas.drawCircle(p, radius, Paint()..color = Color.lerp(const Color(0xFF2C2C2E), colour, on)!.withValues(alpha: fade));
      final icon = art.icons[i];
      canvas.save();
      canvas.translate(p.dx, p.dy);
      final s = out.clamp(0.0, 1.2);
      canvas.scale(s, s);
      icon.paint(canvas, Offset(-icon.width / 2, -icon.height / 2));
      canvas.restore();
    }

    // The house, its door lighting up warm.
    final glow = _at(380, 820, Curves.easeOut);
    final fadeHouse = 1 - _at(1750, 2050);
    if (fadeHouse > 0) {
      canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: fadeHouse));
      if (glow > 0) {
        final r = span * 0.42;
        canvas.drawCircle(
            door.center,
            r,
            Paint()
              ..shader = RadialGradient(colors: [
                const Color(0xFFFFD60A).withValues(alpha: 0.38 * glow),
                const Color(0x00FF9F0A),
              ]).createShader(Rect.fromCircle(center: door.center, radius: r)));
      }
      canvas.drawPath(HouseMarkPainter.house(span, at), Paint()..color = Colors.white);
      canvas.drawRect(door, Paint()..color = HouseMarkPainter.doorColour(glow));
      canvas.restore();
    }

    // The name writes itself in under the house, a letter at a time.
    final nameFade = 1 - _at(1420, 1620);
    if (nameFade > 0) {
      final left = centre.dx - art.word.width / 2;
      final top = centre.dy + orbit + 54;
      for (var i = 0; i < art.letters.length; i++) {
        final k = _at(860.0 + i * 38, 1180.0 + i * 38, Curves.easeOutCubic) * nameFade;
        if (k <= 0) continue;
        canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: k));
        art.letters[i].paint(canvas, Offset(left + art.offsets[i], top + (1 - k) * 16));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_CurtainPainter old) => true;
}
