import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/device.dart';
import '../../theme/nothing_theme.dart';
import '../../util/color_math.dart';

/// The dotted grid that sits behind Nothing-style surfaces and the floor plan.
class DotGridPainter extends CustomPainter {
  DotGridPainter({required this.color, this.spacing = 16, this.radius = 1.1, this.origin = Offset.zero});

  final Color color;
  final double spacing;
  final double radius;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    if (spacing < 4) return;
    final paint = Paint()..color = color;
    final startX = origin.dx % spacing;
    final startY = origin.dy % spacing;
    for (var y = startY; y <= size.height; y += spacing) {
      for (var x = startX; x <= size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(DotGridPainter old) =>
      old.color != color || old.spacing != spacing || old.radius != radius || old.origin != origin;
}

class DotGrid extends StatelessWidget {
  const DotGrid({super.key, this.spacing = 16, this.child});
  final double spacing;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: DotGridPainter(color: context.palette.dot, spacing: spacing),
        child: child,
      );
}

/// A rounded card with a hairline border.
class NCard extends StatelessWidget {
  const NCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.onLongPress,
    this.inverted = false,
    this.radius = 24,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool inverted;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: inverted ? p.text : p.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: inverted ? p.text : p.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// "● LABEL" section header.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.accent = false});
  final String text;
  final Widget? trailing;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: accent ? NothingPalette.red : p.textDim, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text.toUpperCase(), style: NType.label(color: p.textDim))),
          ?trailing,
        ],
      ),
    );
  }
}

IconData deviceIcon(DeviceKind kind, {bool active = false}) => switch (kind) {
      DeviceKind.light => active ? Icons.lightbulb : Icons.lightbulb_outline,
      DeviceKind.outlet => active ? Icons.power : Icons.power_outlined,
      DeviceKind.toggle => active ? Icons.toggle_on : Icons.toggle_off_outlined,
      DeviceKind.sensor => Icons.sensors,
      DeviceKind.climate => Icons.device_thermostat,
      DeviceKind.cover => active ? Icons.blinds : Icons.blinds_closed,
      DeviceKind.fan => Icons.air,
      DeviceKind.lock => active ? Icons.lock_open : Icons.lock_outline,
      DeviceKind.media => active ? Icons.tv : Icons.tv_off_outlined,
      DeviceKind.camera => Icons.videocam_outlined,
      DeviceKind.other => Icons.devices_other_outlined,
    };

/// One-line description of a device's state, e.g. "On · 72%".
String describeState(Device d) {
  final s = d.state;
  if (!s.reachable) return 'Not responding';
  switch (d.kind) {
    case DeviceKind.cover:
      final pos = s.position ?? 0;
      return pos <= 0.01 ? 'Closed' : (pos >= 0.99 ? 'Open' : 'Open ${(pos * 100).round()}%');
    case DeviceKind.lock:
      return s.locked == null ? 'Unknown' : (s.locked! ? 'Locked' : 'Unlocked');
    case DeviceKind.climate:
      final parts = [
        if (s.currentTemp != null) '${s.currentTemp!.toStringAsFixed(1)}°',
        if (s.on == false) 'Off' else if (s.targetTemp != null) 'set ${s.targetTemp!.toStringAsFixed(1)}°',
      ];
      return parts.isEmpty ? 'Climate' : parts.join(' · ');
    case DeviceKind.sensor:
      return s.readings.isEmpty ? 'No readings yet' : s.readings.values.take(2).join(' · ');
    default:
      if (s.on == null) return s.readings.isEmpty ? 'Unknown' : s.readings.values.first;
      if (!s.on!) return 'Off';
      if (d.has(Capability.brightness) && s.brightness != null) return 'On · ${(s.brightness! * 100).round()}%';
      return 'On';
  }
}

/// The colour a light gives off, for the glow on tiles and the map.
Color? lightColor(Device d) {
  if (d.kind != DeviceKind.light || d.state.on != true) return null;
  if (d.state.color != null) return Color(0xFF000000 | d.state.color!);
  if (d.state.colorTempK != null) return Color(0xFF000000 | kelvinToRgb(d.state.colorTempK!));
  return null;
}

/// Square device tile. Active devices invert to white, like Nothing widgets.
class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.device, required this.onTap, required this.onLongPress, this.subtitle});

  final Device device;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active = device.state.isActive && device.state.reachable;
    final fg = active ? p.background : p.text;
    final dim = active ? p.background.withValues(alpha: 0.6) : p.textDim;
    final glow = lightColor(device);
    return NCard(
      inverted: active,
      onTap: onTap,
      onLongPress: onLongPress,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? p.background.withValues(alpha: 0.06) : p.surfaceHigh,
                ),
                child: Icon(deviceIcon(device.kind, active: active), color: fg, size: 21),
              ),
              const Spacer(),
              if (!device.state.reachable)
                const _Dot(color: NothingPalette.red)
              else if (glow != null)
                _Dot(color: glow, ring: true),
            ],
          ),
          const Spacer(),
          Text(device.name,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.body(15, color: fg, weight: 500, height: 1.15)),
          const SizedBox(height: 3),
          Text(subtitle ?? describeState(device),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(12.5, color: dim)),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.ring = false});
  final Color color;
  final bool ring;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: ring ? Border.all(color: Colors.black26, width: 1) : null,
        ),
      );
}

/// A slider drawn as a row of dots. [onChanged] fires while dragging,
/// [onChangeEnd] once when the finger lifts (send that to the device).
class DotSlider extends StatefulWidget {
  const DotSlider({
    super.key,
    required this.value,
    required this.onChangeEnd,
    this.onChanged,
    this.colorAt,
    this.enabled = true,
    this.semanticLabel,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double> onChangeEnd;

  /// Colour of the dot at position t (0..1), for colour temperature tracks.
  final Color Function(double t)? colorAt;
  final bool enabled;
  final String? semanticLabel;

  @override
  State<DotSlider> createState() => _DotSliderState();
}

class _DotSliderState extends State<DotSlider> {
  double? _drag;

  double get _value => (_drag ?? widget.value).clamp(0.0, 1.0);

  void _update(Offset local, double width) {
    final v = (local.dx / width).clamp(0.0, 1.0);
    setState(() => _drag = v);
    widget.onChanged?.call(v);
  }

  void _end() {
    final v = _drag;
    setState(() => _drag = null);
    if (v != null) widget.onChangeEnd(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: '${(_value * 100).round()}%',
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled ? (d) => _update(d.localPosition, w) : null,
          onHorizontalDragUpdate: widget.enabled ? (d) => _update(d.localPosition, w) : null,
          onHorizontalDragEnd: widget.enabled ? (_) => _end() : null,
          onTapDown: widget.enabled ? (d) => _update(d.localPosition, w) : null,
          onTapUp: widget.enabled ? (_) => _end() : null,
          child: SizedBox(
            height: 44,
            width: w,
            child: CustomPaint(
              painter: _DotSliderPainter(
                value: _value,
                on: p.text,
                off: p.border,
                knob: NothingPalette.red,
                colorAt: widget.colorAt,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _DotSliderPainter extends CustomPainter {
  _DotSliderPainter({required this.value, required this.on, required this.off, required this.knob, this.colorAt});

  final double value;
  final Color on;
  final Color off;
  final Color knob;
  final Color Function(double t)? colorAt;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 11.0;
    final count = math.max(2, (size.width / gap).floor());
    final step = size.width / (count - 1);
    final cy = size.height / 2;
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      final filled = t <= value + 1e-6;
      paint.color = colorAt != null ? colorAt!(t).withValues(alpha: filled ? 1 : 0.5) : (filled ? on : off);
      canvas.drawCircle(Offset(i * step, cy), filled ? 3.2 : 2.4, paint);
    }
    final kx = value * size.width;
    canvas.drawCircle(Offset(kx, cy), 9, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(_DotSliderPainter old) =>
      old.value != value || old.on != on || old.off != off || old.colorAt != colorAt;
}

/// Big round power button.
class PowerOrb extends StatelessWidget {
  const PowerOrb({super.key, required this.on, required this.onTap, this.icon = Icons.power_settings_new, this.size = 120});

  final bool on;
  final VoidCallback onTap;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      toggled: on,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? p.text : Colors.transparent,
            border: Border.all(color: on ? p.text : p.border, width: 1.5),
          ),
          child: Icon(icon, size: size * 0.36, color: on ? p.background : p.text),
        ),
      ),
    );
  }
}

/// Text in the dot-matrix font.
class DotText extends StatelessWidget {
  const DotText(this.text, {super.key, this.size = 32, this.color, this.weight = 800, this.maxLines});
  final String text;
  final double size;
  final Color? color;
  final double weight;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: NType.dot(size, color: color ?? context.palette.text, weight: weight),
      );
}

/// Pill-shaped choice used for floors, filters and kinds.
class NChip extends StatelessWidget {
  const NChip({super.key, required this.label, required this.selected, required this.onTap, this.onLongPress, this.icon});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? p.text : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? p.text : p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: selected ? p.background : p.text),
              const SizedBox(width: 6),
            ],
            Text(label, style: NType.body(13, color: selected ? p.background : p.text, weight: 500)),
          ],
        ),
      ),
    );
  }
}

/// Shows store messages as snack bars.
class ToastListener extends StatefulWidget {
  const ToastListener({super.key, required this.message, required this.child});
  final ValueNotifier<String?> message;
  final Widget child;

  @override
  State<ToastListener> createState() => _ToastListenerState();
}

class _ToastListenerState extends State<ToastListener> {
  @override
  void initState() {
    super.initState();
    widget.message.addListener(_show);
  }

  @override
  void dispose() {
    widget.message.removeListener(_show);
    super.dispose();
  }

  void _show() {
    final text = widget.message.value;
    if (text == null || !mounted) return;
    widget.message.value = null;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
