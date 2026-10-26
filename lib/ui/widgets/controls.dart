import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/device.dart';
import '../../theme/app_theme.dart';
import '../../util/color_math.dart';
import '../../util/haptics.dart';
import 'kj_widgets.dart';
import '../../util/sounds.dart';

// ---- The one level a quick drag changes ---------------------------------------

/// What a drag across a tile changes: brightness, fan speed, blind position or volume.
/// Null when the device has no such level.
double? deviceLevel(Device d) {
  final s = d.state;
  if (!s.reachable) return null;
  if (d.has(Capability.brightness)) return s.on == false ? 0 : (s.brightness ?? 1);
  if (d.has(Capability.speed)) return s.on == false ? 0 : (s.speed ?? 1);
  if (d.has(Capability.position)) return s.position ?? 0;
  if (d.has(Capability.volume) && s.on != false) return s.volume ?? 0;
  return null;
}

DeviceCommand levelCommand(Device d, double v) {
  if (d.has(Capability.brightness)) return v <= 0.01 ? const DeviceCommand(on: false) : DeviceCommand(brightness: v);
  if (d.has(Capability.speed)) return v <= 0.01 ? const DeviceCommand(on: false) : DeviceCommand(speed: v);
  if (d.has(Capability.position)) return DeviceCommand(position: v);
  return DeviceCommand(volume: v);
}

/// Lights follow the finger. Blinds and speakers only get the final value,
/// so motors and TVs are not flooded with steps.
bool sendsLive(Device d) => d.has(Capability.brightness);

/// "64%", "Open 40%", "Volume 30".
String levelLabel(Device d, double v) {
  final pct = (v * 100).round();
  if (d.has(Capability.brightness)) return pct == 0 ? 'Off' : 'Brightness $pct%';
  if (d.has(Capability.speed)) return pct == 0 ? 'Off' : 'Speed $pct%';
  if (d.has(Capability.position)) return pct == 0 ? 'Closed' : (pct == 100 ? 'Open' : 'Open $pct%');
  return 'Volume $pct';
}

/// Passes values on at most every [every] while a finger moves.
class LiveSender<T> {
  LiveSender(this.send, {this.every = const Duration(milliseconds: 250)});
  final void Function(T v) send;
  final Duration every;
  final _clock = Stopwatch()..start();
  Duration? _last;
  Timer? _timer;
  T? _pending;
  bool _has = false;

  void add(T v) {
    _pending = v;
    _has = true;
    final since = _last == null ? every : _clock.elapsed - _last!;
    if (since >= every) {
      _flush();
    } else {
      _timer ??= Timer(every - since, _flush);
    }
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    if (!_has) return;
    final v = _pending as T;
    _has = false;
    _pending = null;
    _last = _clock.elapsed;
    send(v);
  }

  /// Drops what was not sent yet; the final value goes out on its own.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _has = false;
    _pending = null;
  }
}

// ---- Small pieces ------------------------------------------------------------------

/// A row of dots showing a level from 0 to 1. Not touchable.
class LevelBar extends StatelessWidget {
  const LevelBar({super.key, required this.value, required this.color, required this.track, this.height = 6});
  final double value;
  final Color color;
  final Color track;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _LevelBarPainter(value.clamp(0.0, 1.0), color, track)),
      );
}

class _LevelBarPainter extends CustomPainter {
  _LevelBarPainter(this.value, this.color, this.track);
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final h = math.min(size.height, 5.0);
    final top = (size.height - h) / 2;
    final radius = Radius.circular(h / 2);
    canvas.drawRRect(RRect.fromLTRBR(0, top, size.width, top + h, radius), Paint()..color = track);
    if (value <= 0.005) return;
    final w = math.max(h, size.width * value);
    canvas.drawRRect(RRect.fromLTRBR(0, top, w, top + h, radius), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LevelBarPainter old) => old.value != value || old.color != color || old.track != track;
}

/// A small pill for quick values like 25% or Warm.
class PresetChip extends StatelessWidget {
  const PresetChip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: () {
          Haptics.selectionClick();
          Sounds.tick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? p.text : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? p.text : p.border),
          ),
          child: Text(label, style: NType.body(12.5, color: selected ? p.background : p.text, weight: 500)),
        ),
      ),
    );
  }
}

/// "● BRIGHTNESS ... 72%", a dot slider, then quick values.
class LevelControl extends StatefulWidget {
  const LevelControl({
    super.key,
    required this.label,
    required this.value,
    required this.display,
    required this.onChangeEnd,
    this.onLive,
    this.colorAt,
    this.presets = const [],
  });

  final String label;
  final double value;
  final String Function(double v) display;
  final ValueChanged<double> onChangeEnd;

  /// Called a few times a second while dragging, for devices that follow the finger.
  final ValueChanged<double>? onLive;
  final Color Function(double t)? colorAt;
  final List<(String, double)> presets;

  @override
  State<LevelControl> createState() => _LevelControlState();
}

class _LevelControlState extends State<LevelControl> {
  double? _live;
  late final _sender = LiveSender<double>((v) => widget.onLive?.call(v));

  @override
  void dispose() {
    _sender.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final v = _live ?? widget.value;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(widget.label, trailing: Text(widget.display(v), style: NType.display(18, color: p.text))),
      LevelSlider(
        semanticLabel: widget.label,
        value: widget.value,
        colorAt: widget.colorAt,
        onChanged: (x) {
          setState(() => _live = x);
          if (widget.onLive != null) _sender.add(x);
        },
        onChangeEnd: (x) {
          _sender.cancel();
          setState(() => _live = null);
          widget.onChangeEnd(x);
        },
      ),
      if (widget.presets.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (label, at) in widget.presets)
            PresetChip(label: label, selected: (v - at).abs() < 0.015, onTap: () => widget.onChangeEnd(at)),
        ]),
      ],
    ]);
  }
}

// ---- Colour ring ------------------------------------------------------------------

/// 36 coloured dots in a circle. Tap or drag around it to pick a colour.
class ColorRing extends StatefulWidget {
  const ColorRing({super.key, required this.color, required this.onChangeEnd, this.onLive, this.center, this.size = 228});

  /// The light's colour as 0xRRGGBB, or null while it is a white light.
  final int? color;

  /// What the middle shows while the light is white.
  final Color? center;
  final ValueChanged<int> onChangeEnd;
  final ValueChanged<int>? onLive;
  final double size;

  static const steps = 36;

  @override
  State<ColorRing> createState() => _ColorRingState();
}

class _ColorRingState extends State<ColorRing> {
  double? _hue;
  late final _sender = LiveSender<double>((h) => widget.onLive?.call(_colorFor(h)));

  @override
  void dispose() {
    _sender.cancel();
    super.dispose();
  }

  double get _sat {
    final c = widget.color;
    if (c == null) return 1;
    final s = rgbToHsv(c)[1];
    return s < 0.15 ? 1 : s;
  }

  int _colorFor(double hue) => hsvToRgb(hue, _sat, 1);

  double? get _shownHue {
    if (_hue != null) return _hue;
    final c = widget.color;
    if (c == null) return null;
    final hsv = rgbToHsv(c);
    if (hsv[1] < 0.15) return null;
    const step = 360 / ColorRing.steps;
    return ((hsv[0] / step).round() % ColorRing.steps) * step;
  }

  double? _hueAt(Offset local) {
    final v = local - Offset(widget.size / 2, widget.size / 2);
    if (v.distance < widget.size * 0.24) return null;
    final deg = (math.atan2(v.dx, -v.dy) * 180 / math.pi + 360) % 360;
    const step = 360 / ColorRing.steps;
    return ((deg / step).round() % ColorRing.steps) * step;
  }

  void _move(Offset local) {
    final h = _hueAt(local);
    if (h == null || h == _hue) return;
    if (_hue != null) Haptics.selectionClick();
    setState(() => _hue = h);
    if (widget.onLive != null) _sender.add(h);
  }

  void _end() {
    final h = _hue;
    _sender.cancel();
    if (h == null) return;
    setState(() => _hue = null);
    widget.onChangeEnd(_colorFor(h));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hue = _shownHue;
    final middle = _hue != null
        ? Color(0xFF000000 | _colorFor(_hue!))
        : (widget.color != null ? Color(0xFF000000 | widget.color!) : (widget.center ?? p.surfaceHigh));
    return Semantics(
      label: 'Colour',
      child: GestureDetector(
        onPanStart: (d) => _move(d.localPosition),
        onPanUpdate: (d) => _move(d.localPosition),
        onPanEnd: (_) => _end(),
        onTapDown: (d) => _move(d.localPosition),
        onTapUp: (_) => _end(),
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _RingPainter(hue: hue, middle: middle, outline: p.text, border: p.border)),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.hue, required this.middle, required this.outline, required this.border});
  final double? hue;
  final Color middle;
  final Color outline;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 16;
    final paint = Paint();
    for (var i = 0; i < ColorRing.steps; i++) {
      final h = i * 360 / ColorRing.steps;
      final a = h * math.pi / 180;
      final pos = c + Offset(math.sin(a), -math.cos(a)) * r;
      final selected = hue != null && (h - hue!).abs() < 0.5;
      paint.color = Color(0xFF000000 | hsvToRgb(h, 1, 1));
      canvas.drawCircle(pos, selected ? 10 : 6, paint);
      if (selected) {
        canvas.drawCircle(
            pos,
            14,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = outline);
      }
    }
    final mid = size.width * 0.19;
    canvas.drawCircle(c, mid, Paint()..color = middle);
    canvas.drawCircle(
        c,
        mid,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = border);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.hue != hue || old.middle != middle || old.outline != outline || old.border != border;
}

// ---- Thermostat dial ----------------------------------------------------------------

/// A 270° arc of dots. Drag the red knob to set the target temperature.
class TempDial extends StatefulWidget {
  const TempDial({
    super.key,
    required this.target,
    required this.onChangeEnd,
    this.current,
    this.min = 5,
    this.max = 35,
    this.step = 0.5,
    this.off = false,
    this.size = 248,
    this.unit = '°',
    this.decimals = 1,
    this.semanticLabel = 'Target temperature',
  });

  final double target;
  final double? current;
  final ValueChanged<double> onChangeEnd;
  final double min;
  final double max;
  final double step;
  final bool off;
  final double size;

  /// '°' for temperatures, '%' for humidity.
  final String unit;
  final int decimals;
  final String semanticLabel;

  @override
  State<TempDial> createState() => _TempDialState();
}

class _TempDialState extends State<TempDial> {
  static const _start = 135.0, _sweep = 270.0;
  double? _live;

  double? _valueAt(Offset local) {
    final v = local - Offset(widget.size / 2, widget.size / 2);
    if (v.distance < widget.size * 0.22) return null;
    final deg = (math.atan2(v.dy, v.dx) * 180 / math.pi + 360) % 360;
    var rel = (deg - _start + 360) % 360;
    if (rel > _sweep) rel = rel > _sweep + (360 - _sweep) / 2 ? 0 : _sweep;
    final raw = widget.min + rel / _sweep * (widget.max - widget.min);
    return ((raw / widget.step).round() * widget.step).clamp(widget.min, widget.max).toDouble();
  }

  void _move(Offset local) {
    final v = _valueAt(local);
    if (v == null || v == _live) return;
    // Never jump from one end to the other across the gap at the bottom.
    if (_live != null && (v - _live!).abs() > (widget.max - widget.min) / 2) return;
    if (_live != null) Haptics.selectionClick();
    setState(() => _live = v);
  }

  void _end() {
    final v = _live;
    if (v == null) return;
    setState(() => _live = null);
    if (v != widget.target) widget.onChangeEnd(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final value = (_live ?? widget.target).clamp(widget.min, widget.max).toDouble();
    String show(double v) => '${v.toStringAsFixed(widget.decimals)}${widget.unit}';
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: show(value),
      child: GestureDetector(
        onPanStart: (d) => _move(d.localPosition),
        onPanUpdate: (d) => _move(d.localPosition),
        onPanEnd: (_) => _end(),
        onTapDown: (d) => _move(d.localPosition),
        onTapUp: (_) => _end(),
        child: SizedBox.square(
          dimension: widget.size,
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _DialPainter(
                  t: (value - widget.min) / (widget.max - widget.min),
                  current: widget.current == null
                      ? null
                      : ((widget.current! - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0),
                  steps: ((widget.max - widget.min) / widget.step).round(),
                  majorEvery: (5 / widget.step).round(),
                  on: widget.off ? p.textDim : KJPalette.orange,
                  off: p.surfaceHigh,
                  knob: widget.off ? p.textDim : KJPalette.orange,
                  hole: p.background,
                  mark: p.textDim,
                ),
              ),
            ),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.off ? 'Off' : 'Target', style: NType.label(color: p.textDim)),
              const SizedBox(height: 4),
              DisplayText(show(value), size: widget.size * 0.22, color: widget.off ? p.textDim : p.text),
              if (widget.current != null) ...[
                const SizedBox(height: 6),
                Text('Now ${show(widget.current!)}', style: NType.label(color: p.textDim)),
              ],
            ]),
          ]),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.t,
    required this.current,
    required this.steps,
    required this.majorEvery,
    required this.on,
    required this.off,
    required this.knob,
    required this.hole,
    required this.mark,
  });

  final double t;
  final double? current;
  final int steps;
  final int majorEvery;
  final Color on;
  final Color off;
  final Color knob;
  final Color hole;
  final Color mark;

  static Offset _at(Offset c, double r, double t) {
    final a = (135 + 270 * t) * math.pi / 180;
    return c + Offset(math.cos(a), math.sin(a)) * r;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 16;
    final rect = Rect.fromCircle(center: c, radius: r);
    const start = 135 * math.pi / 180, sweep = 270 * math.pi / 180;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, stroke..color = off);
    if (t > 0.002) {
      stroke
        ..color = on
        ..shader = on != KJPalette.orange
            ? null
            : const SweepGradient(
                endAngle: sweep,
                colors: [Color(0xFFFFB340), Color(0xFFFF6A2B), Color(0xFFFF3B30)],
                transform: GradientRotation(start),
              ).createShader(rect);
      canvas.drawArc(rect, start, sweep * t, false, stroke);
    }
    final paint = Paint();
    if (current != null) {
      canvas.drawCircle(_at(c, r - 18, current!), 3, paint..color = mark);
    }
    final k = _at(c, r, t);
    canvas.drawCircle(k, 13, Paint()..color = const Color(0x33000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(k, 11, paint..color = Colors.white);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.t != t || old.current != current || old.on != on || old.off != off || old.knob != knob || old.hole != hole;
}

// ---- Blind ------------------------------------------------------------------------

/// A window with a dotted blind. Drag down to close it, up to open it.
class BlindControl extends StatefulWidget {
  const BlindControl({super.key, required this.position, required this.onChangeEnd, this.width = 168, this.height = 200});

  /// 0 closed .. 1 open.
  final double position;
  final ValueChanged<double> onChangeEnd;
  final double width;
  final double height;

  static const inset = 14.0;

  @override
  State<BlindControl> createState() => _BlindControlState();
}

class _BlindControlState extends State<BlindControl> {
  double? _live;

  double _at(Offset local) {
    final inner = widget.height - BlindControl.inset * 2;
    final covered = ((local.dy - BlindControl.inset) / inner).clamp(0.0, 1.0);
    return ((1 - covered) / 0.05).round() * 0.05;
  }

  void _move(Offset local) {
    final v = _at(local);
    if (v == _live) return;
    if (_live != null && (v == 0 || v == 1)) Haptics.selectionClick();
    setState(() => _live = v);
  }

  void _end() {
    final v = _live;
    if (v == null) return;
    setState(() => _live = null);
    widget.onChangeEnd(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pos = (_live ?? widget.position).clamp(0.0, 1.0);
    return Semantics(
      slider: true,
      label: 'Blind',
      value: '${(pos * 100).round()}% open',
      child: GestureDetector(
        onVerticalDragStart: (d) => _move(d.localPosition),
        onVerticalDragUpdate: (d) => _move(d.localPosition),
        onVerticalDragEnd: (_) => _end(),
        onTapDown: (d) => _move(d.localPosition),
        onTapUp: (_) => _end(),
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: CustomPaint(
            painter: _BlindPainter(
                open: pos, frame: p.border, slat: p.text, glass: p.dot, fill: p.surfaceHigh, handle: KJPalette.accent),
          ),
        ),
      ),
    );
  }
}

class _BlindPainter extends CustomPainter {
  _BlindPainter(
      {required this.open,
      required this.frame,
      required this.slat,
      required this.glass,
      required this.fill,
      required this.handle});
  final double open;
  final Color frame;
  final Color slat;
  final Color glass;
  final Color fill;
  final Color handle;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = BlindControl.inset;
    final outer = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(22));
    canvas.drawRRect(
        outer,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = frame);
    final inner = Rect.fromLTRB(inset, inset, size.width - inset, size.height - inset);
    final line = Paint()
      ..color = frame
      ..strokeWidth = 1;
    // The window behind: a faint cross and dots for glass.
    canvas.drawLine(Offset(inner.center.dx, inner.top), Offset(inner.center.dx, inner.bottom), line);
    canvas.drawLine(Offset(inner.left, inner.center.dy), Offset(inner.right, inner.center.dy), line);
    final dot = Paint()..color = glass;
    for (var y = inner.top + 6; y < inner.bottom; y += 12) {
      for (var x = inner.left + 6; x < inner.right; x += 12) {
        canvas.drawCircle(Offset(x, y), 1.1, dot);
      }
    }
    // The blind: rows of dots from the top down to its bar.
    final bottom = inner.top + inner.height * (1 - open);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(inner.left, inner.top, inner.right, bottom));
    canvas.drawRect(inner, Paint()..color = fill);
    final s = Paint()..color = slat;
    for (var y = inner.top + 5; y < bottom - 3; y += 9) {
      for (var x = inner.left + 5; x < inner.right - 2; x += 8) {
        canvas.drawCircle(Offset(x, y), 2, s);
      }
    }
    canvas.restore();
    final bar = RRect.fromRectAndRadius(
        Rect.fromLTRB(inner.left - 4, bottom - 3, inner.right + 4, bottom + 3), const Radius.circular(3));
    canvas.drawRRect(bar, Paint()..color = slat);
    canvas.drawCircle(Offset(inner.center.dx, bottom + 9), 4, Paint()..color = handle);
  }

  @override
  bool shouldRepaint(_BlindPainter old) =>
      old.open != open ||
      old.frame != frame ||
      old.slat != slat ||
      old.glass != glass ||
      old.fill != fill ||
      old.handle != handle;
}

// ---- Lock ---------------------------------------------------------------------------

/// Hold to unlock (a red ring of dots fills up), tap to lock.
class HoldOrb extends StatefulWidget {
  const HoldOrb({super.key, required this.locked, required this.onLock, required this.onUnlock, this.size = 128});

  final bool locked;
  final VoidCallback onLock;
  final VoidCallback onUnlock;
  final double size;

  static const hold = Duration(milliseconds: 800);

  @override
  State<HoldOrb> createState() => _HoldOrbState();
}

class _HoldOrbState extends State<HoldOrb> with SingleTickerProviderStateMixin {
  late final _ring = AnimationController(vsync: this, duration: HoldOrb.hold)..addStatusListener(_onStatus);
  bool _pressLocked = false;
  bool _fired = false;
  bool _nudge = false;
  Timer? _nudgeTimer;

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _ring.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _fired) return;
    _fired = true;
    Haptics.heavyImpact();
    widget.onUnlock();
    _ring.value = 0;
  }

  void _down() {
    _pressLocked = widget.locked;
    _fired = false;
    if (!_pressLocked) return;
    Haptics.selectionClick();
    _ring.forward();
  }

  void _up() {
    if (!_pressLocked) {
      Haptics.mediumImpact();
      widget.onLock();
      return;
    }
    if (_fired) return;
    _ring.reverse();
    _nudgeTimer?.cancel();
    setState(() => _nudge = true);
    _nudgeTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _nudge = false);
    });
  }

  void _cancel() {
    if (!_fired) _ring.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final unlocked = !widget.locked;
    final ring = widget.size + 30;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        button: true,
        label: widget.locked ? 'Locked. Hold to unlock' : 'Unlocked. Tap to lock',
        child: GestureDetector(
          onTapDown: (_) => _down(),
          onTapUp: (_) => _up(),
          onTapCancel: _cancel,
          child: SizedBox.square(
            dimension: ring,
            child: Stack(alignment: Alignment.center, children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _ring,
                  builder: (context, _) => CustomPaint(
                    painter: _HoldRingPainter(progress: _ring.value, track: p.border, fill: KJPalette.accent),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: unlocked ? p.text : Colors.transparent,
                  border: Border.all(color: unlocked ? p.text : p.border, width: 1.5),
                ),
                child: Icon(unlocked ? Icons.lock_open : Icons.lock_outline,
                    size: widget.size * 0.34, color: unlocked ? p.background : p.text),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 8),
      AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 160),
        style: NType.label(color: _nudge ? KJPalette.accent : p.textDim),
        child: Text(widget.locked ? (_nudge ? 'Keep holding to unlock' : 'Hold to unlock') : 'Tap to lock'),
      ),
    ]);
  }
}

class _HoldRingPainter extends CustomPainter {
  _HoldRingPainter({required this.progress, required this.track, required this.fill});
  final double progress;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: c, radius: size.width / 2 - 5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
    if (progress > 0) canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * progress, false, paint..color = fill);
  }

  @override
  bool shouldRepaint(_HoldRingPainter old) => old.progress != progress || old.track != track || old.fill != fill;
}

// ---- Robots and appliances -----------------------------------------------------------

/// A robot vacuum, mower or appliance: one big start / pause button, ringed
/// by its battery as dots (red when it runs low).
class RobotOrb extends StatelessWidget {
  const RobotOrb({super.key, required this.running, required this.onTap, this.battery, this.size = 184});

  final bool running;
  final VoidCallback? onTap;

  /// 0..1, or null when it has no battery.
  final double? battery;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = battery?.clamp(0.0, 1.0);
    final low = b != null && b < 0.2;
    final fg = running ? p.background : p.text;
    return Semantics(
      button: onTap != null,
      label: running ? 'Pause' : 'Start',
      value: b == null ? null : 'Battery ${(b * 100).round()}%',
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                Haptics.mediumImpact();
                onTap!();
              },
        child: SizedBox.square(
          dimension: size,
          child: Stack(alignment: Alignment.center, children: [
            if (b != null)
              Positioned.fill(
                child: CustomPaint(painter: _HoldRingPainter(progress: b, track: p.border, fill: low ? KJPalette.danger : p.text)),
              ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: size - 40,
              height: size - 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: running ? p.text : Colors.transparent,
                border: Border.all(color: running ? p.text : p.border, width: 1.5),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(running ? Icons.pause : Icons.play_arrow, size: size * 0.24, color: fg),
                if (b != null) ...[
                  const SizedBox(height: 2),
                  Text('${(b * 100).round()}%', style: NType.display(20, color: low && !running ? KJPalette.danger : fg)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---- Apple Home pill ------------------------------------------------------------

/// The tall rounded slider of Apple Home: it fills from the bottom with the
/// light's colour. Drag up or down to set the level, tap to switch on or off.
class PillSlider extends StatefulWidget {
  const PillSlider({
    super.key,
    required this.value,
    required this.color,
    required this.icon,
    required this.onChangeEnd,
    this.onLive,
    this.onTap,
    this.semanticLabel,
    this.width = 116,
    this.height = 280,
  });

  final double value;
  final Color color;
  final IconData icon;
  final ValueChanged<double> onChangeEnd;

  /// Called a few times a second while dragging, for devices that follow the finger.
  final ValueChanged<double>? onLive;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double width;
  final double height;

  @override
  State<PillSlider> createState() => _PillSliderState();
}

class _PillSliderState extends State<PillSlider> {
  double? _drag;
  double _from = 0;
  double _dy = 0;
  late final _sender = LiveSender<double>((v) => widget.onLive?.call(v));

  @override
  void dispose() {
    _sender.cancel();
    super.dispose();
  }

  void _start(DragStartDetails _) {
    _from = widget.value.clamp(0.0, 1.0);
    _dy = 0;
    Haptics.selectionClick();
    setState(() => _drag = _from);
  }

  void _update(DragUpdateDetails d) {
    _dy -= d.delta.dy;
    final v = (_from + _dy / widget.height).clamp(0.0, 1.0);
    if (v == _drag) return;
    if (v == 0 || v == 1) Haptics.selectionClick();
    setState(() => _drag = v);
    if (widget.onLive != null) _sender.add(v);
  }

  void _end() {
    final v = _drag;
    _sender.cancel();
    if (v == null) return;
    setState(() => _drag = null);
    Sounds.tick();
    widget.onChangeEnd(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final v = (_drag ?? widget.value).clamp(0.0, 1.0);
    final pct = (v * 100).round();
    final radius = BorderRadius.circular(widget.width * 0.3);
    final iconOnFill = v > 0.18;
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: '$pct%',
      increasedValue: '${math.min(100, pct + 10)}%',
      decreasedValue: '${math.max(0, pct - 10)}%',
      onIncrease: () => widget.onChangeEnd(math.min(1, v + 0.1)),
      onDecrease: () => widget.onChangeEnd(math.max(0, v - 0.1)),
      child: GestureDetector(
        onVerticalDragStart: _start,
        onVerticalDragUpdate: _update,
        onVerticalDragEnd: (_) => _end(),
        onVerticalDragCancel: _end,
        onTap: widget.onTap == null
            ? null
            : () {
                Sounds.power(widget.value <= 0.005);
                widget.onTap!();
              },
        child: PressScale(
          scale: 0.98,
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: p.isDark ? const Color(0xFF3A3A3C) : const Color(0xFFDCDCE0),
              borderRadius: radius,
              boxShadow: p.cardShadow,
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedContainer(
                  duration: Duration(milliseconds: _drag != null ? 0 : 260),
                  curve: Curves.easeOutCubic,
                  height: widget.height * v,
                  width: double.infinity,
                  color: widget.color,
                ),
              ),
              Align(
                alignment: const Alignment(0, 0.78),
                child: Icon(widget.icon,
                    size: 30,
                    color: iconOnFill
                        ? (widget.color.computeLuminance() > 0.55 ? const Color(0xCC000000) : Colors.white)
                        : p.textDim),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
