import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/device.dart';
import '../../theme/nothing_theme.dart';
import '../../util/color_math.dart';
import '../../util/haptics.dart';
import 'controls.dart';

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
      DeviceKind.vacuum => Icons.cleaning_services_outlined,
      DeviceKind.mower => Icons.grass,
      DeviceKind.purifier => Icons.cyclone,
      DeviceKind.humidifier => active ? Icons.water_drop : Icons.water_drop_outlined,
      DeviceKind.appliance => Icons.local_laundry_service_outlined,
      DeviceKind.alarm => active ? Icons.shield : Icons.shield_outlined,
      DeviceKind.valve => Icons.plumbing,
      DeviceKind.siren => active ? Icons.campaign : Icons.campaign_outlined,
      DeviceKind.garage => active ? Icons.garage : Icons.garage_outlined,
      DeviceKind.button => active ? Icons.touch_app : Icons.touch_app_outlined,
      DeviceKind.other => Icons.devices_other_outlined,
    };

/// "Cleaning", "Going home", "Armed away"... for [DeviceState.activity].
String activityLabel(DeviceKind kind, String? activity) => switch (activity) {
      null => kind == DeviceKind.alarm ? 'Unknown' : 'Ready',
      Activity.running => switch (kind) {
          DeviceKind.vacuum => 'Cleaning',
          DeviceKind.mower => 'Mowing',
          _ => 'Running',
        },
      Activity.paused => 'Paused',
      Activity.returning => 'Going home',
      Activity.docked => 'Docked',
      Activity.charging => 'Charging',
      Activity.idle => 'Idle',
      Activity.error => 'Needs help',
      Activity.disarmed => 'Disarmed',
      Activity.armedHome => 'Armed home',
      Activity.armedAway => 'Armed away',
      Activity.armedNight => 'Armed night',
      Activity.armedVacation => 'Armed vacation',
      Activity.armedCustom => 'Armed',
      Activity.arming => 'Arming',
      Activity.pending => 'Entry delay',
      Activity.disarming => 'Disarming',
      Activity.triggered => 'ALARM',
      final String other => modeLabel(other),
    };

/// "fan_only" -> "Fan only", "heat_cool" -> "Heat/cool".
String modeLabel(String mode) {
  final m = mode.trim();
  if (m.isEmpty) return m;
  const known = {'heat_cool': 'Heat/cool', 'fan_only': 'Fan', 'dry': 'Dry', 'auto': 'Auto', 'off': 'Off'};
  final k = known[m.toLowerCase()];
  if (k != null) return k;
  final words = m.replaceAll('_', ' ');
  return words[0].toUpperCase() + words.substring(1);
}

/// One-line description of a device's state, e.g. "On · 72%".
String describeState(Device d) {
  final s = d.state;
  if (!s.reachable) return 'Not responding';
  switch (d.kind) {
    case DeviceKind.cover || DeviceKind.garage:
      if (s.position == null && s.on != null) return s.on! ? 'Open' : 'Closed';
      final pos = s.position ?? 0;
      return pos <= 0.01 ? 'Closed' : (pos >= 0.99 ? 'Open' : 'Open ${(pos * 100).round()}%');
    case DeviceKind.valve:
      if (s.on == null) return s.readings.isEmpty ? 'Unknown' : s.readings.values.first;
      return s.on! ? 'Open' : 'Closed';
    case DeviceKind.siren:
      return s.on == true ? 'Sounding' : (s.on == false ? 'Off' : 'Unknown');
    case DeviceKind.vacuum || DeviceKind.mower || DeviceKind.appliance:
      final problem = s.readings['Error'];
      return [
        if (s.activity == Activity.error && problem != null) problem else activityLabel(d.kind, s.activity),
        if (s.battery != null) '${(s.battery! * 100).round()}%',
        if (d.kind == DeviceKind.appliance && s.activity == Activity.running && s.readings['Left'] != null)
          '${s.readings['Left']} left',
      ].join(' · ');
    case DeviceKind.alarm:
      return activityLabel(d.kind, s.activity);
    case DeviceKind.button:
      return 'Tap to run';
    case DeviceKind.camera:
      if (s.readings.isNotEmpty) return s.readings.values.first;
      if (d.props['streamUrl'] != null || d.props['mjpegUrl'] != null) return 'Live';
      return d.has(Capability.snapshot) ? 'Tap to look' : 'Tap to set up';
    case DeviceKind.humidifier:
      final parts = [
        if (s.currentHumidity != null) '${s.currentHumidity!.round()}%',
        if (s.on == false) 'Off' else if (s.targetHumidity != null) 'set ${s.targetHumidity!.round()}%',
      ];
      return parts.isEmpty ? (s.on == true ? 'On' : 'Off') : parts.join(' · ');
    case DeviceKind.lock:
      return s.locked == null ? 'Unknown' : (s.locked! ? 'Locked' : 'Unlocked');
    case DeviceKind.climate:
      final mode = d.has(Capability.mode) && s.mode != null ? modeLabel(s.mode!) : 'set';
      final parts = [
        if (s.currentTemp != null) '${s.currentTemp!.toStringAsFixed(1)}°',
        if (s.on == false) 'Off' else if (s.targetTemp != null) '$mode ${s.targetTemp!.toStringAsFixed(1)}°',
      ];
      return parts.isEmpty ? 'Climate' : parts.join(' · ');
    case DeviceKind.sensor:
      return s.readings.isEmpty ? 'No readings yet' : s.readings.values.take(2).join(' · ');
    case DeviceKind.media:
      final parts = [
        if (s.on != null) s.on! ? 'On' : 'Off',
        if (s.on != false && s.muted == true) 'Muted' else if (s.on != false && s.volume != null) 'Vol ${(s.volume! * 100).round()}',
        if (s.on != false && s.readings['Playing'] != null && s.readings['Playing'] != 'Nothing') s.readings['Playing']!,
      ];
      return parts.isEmpty ? (s.readings.isEmpty ? 'Unknown' : s.readings.values.first) : parts.join(' · ');
    default:
      if (s.on == null) return s.readings.isEmpty ? 'Unknown' : s.readings.values.first;
      if (!s.on!) return 'Off';
      if (d.has(Capability.brightness) && s.brightness != null) return 'On · ${(s.brightness! * 100).round()}%';
      if (d.has(Capability.mode) && s.mode != null) return 'On · ${modeLabel(s.mode!)}';
      if (d.has(Capability.speed) && s.speed != null) return 'On · ${(s.speed! * 100).round()}%';
      return 'On';
  }
}

/// A device's temperature reading in °C, from a thermostat or a sensor.
double? temperatureOf(Device d) {
  if (!d.state.reachable) return null;
  if (d.state.currentTemp != null) return d.state.currentTemp;
  final raw = d.state.readings['Temperature'];
  if (raw == null) return null;
  return double.tryParse(RegExp(r'-?\d+(\.\d+)?').firstMatch(raw)?.group(0) ?? '');
}

/// The average temperature of the devices that measure one, or null.
double? averageTemperature(Iterable<Device> devices) {
  final temps = devices.map(temperatureOf).whereType<double>().toList();
  if (temps.isEmpty) return null;
  return temps.reduce((a, b) => a + b) / temps.length;
}

/// The colour a light gives off, for the glow on tiles and the map.
Color? lightColor(Device d) {
  if (d.kind != DeviceKind.light || d.state.on != true) return null;
  if (d.state.color != null) return Color(0xFF000000 | d.state.color!);
  if (d.state.colorTempK != null) return Color(0xFF000000 | kelvinToRgb(d.state.colorTempK!));
  return null;
}

/// Square device tile. Active devices invert to white, like Nothing widgets.
/// Tap switches it; a sideways drag sets its level (brightness, blind,
/// volume) when [onLevelEnd] is given; the arrow opens all its controls.
class DeviceTile extends StatefulWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.onTap,
    required this.onLongPress,
    this.subtitle,
    this.onOpen,
    this.onLevel,
    this.onLevelEnd,
  });

  final Device device;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? subtitle;
  final VoidCallback? onOpen;

  /// Called a few times a second while a finger drags across the tile.
  final ValueChanged<double>? onLevel;

  /// Called once when the finger lifts.
  final ValueChanged<double>? onLevelEnd;

  @override
  State<DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<DeviceTile> {
  double? _drag;
  double _from = 0;
  double _dx = 0;
  late final _sender = LiveSender<double>((v) => widget.onLevel?.call(v));

  @override
  void dispose() {
    _sender.cancel();
    super.dispose();
  }

  double? get _level => widget.onLevelEnd == null ? null : deviceLevel(widget.device);

  void _start(DragStartDetails _) {
    _from = _level ?? 0;
    _dx = 0;
    Haptics.selectionClick();
    setState(() => _drag = _from);
  }

  void _update(DragUpdateDetails d) {
    final width = context.size?.width ?? 160;
    _dx += d.delta.dx;
    final v = (_from + _dx / (width * 0.9)).clamp(0.0, 1.0);
    if (v == _drag) return;
    if (v == 0 || v == 1) Haptics.selectionClick();
    setState(() => _drag = v);
    if (widget.onLevel != null) _sender.add(v);
  }

  void _end() {
    final v = _drag;
    _sender.cancel();
    if (v == null) return;
    setState(() => _drag = null);
    widget.onLevelEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = widget.device;
    final level = _drag ?? _level;
    final active = d.state.isActive && d.state.reachable;
    final fg = active ? p.background : p.text;
    final dim = active ? p.background.withValues(alpha: 0.6) : p.textDim;
    final glow = lightColor(d);
    final tile = NCard(
      inverted: active,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: glow ?? (active ? p.background.withValues(alpha: 0.06) : p.surfaceHigh),
                    border: glow == null ? null : Border.all(color: p.background.withValues(alpha: 0.15)),
                  ),
                  child: Icon(
                    deviceIcon(d.kind, active: active),
                    size: 21,
                    color: glow == null ? fg : (glow.computeLuminance() > 0.4 ? Colors.black : Colors.white),
                  ),
                ),
                if (!d.state.reachable)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: NothingPalette.red,
                        shape: BoxShape.circle,
                        border: Border.all(color: p.surface, width: 2),
                      ),
                    ),
                  ),
              ]),
              const Spacer(),
              if (widget.onOpen != null)
                Semantics(
                  button: true,
                  label: 'All controls',
                  child: GestureDetector(
                    key: Key('open-${d.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onOpen,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: active ? p.background.withValues(alpha: 0.2) : p.border),
                          ),
                          child: Icon(Icons.arrow_outward, size: 15, color: fg),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(d.name,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.body(15, color: fg, weight: 500, height: 1.15)),
          ),
          const SizedBox(height: 3),
          Text(_drag != null ? levelLabel(d, _drag!) : (widget.subtitle ?? describeState(d)),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(12.5, color: dim)),
          if (level != null) ...[
            const SizedBox(height: 9),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: LevelBar(
                value: level,
                color: fg,
                track: active ? p.background.withValues(alpha: 0.22) : p.border,
              ),
            ),
          ],
        ],
      ),
    );
    if (level == null) return tile;
    final pct = (level * 100).round();
    return Semantics(
      value: '$pct%',
      increasedValue: '${math.min(100, pct + 10)}%',
      decreasedValue: '${math.max(0, pct - 10)}%',
      onIncrease: () => widget.onLevelEnd!(math.min(1, level + 0.1)),
      onDecrease: () => widget.onLevelEnd!(math.max(0, level - 0.1)),
      child: GestureDetector(
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: (_) => _end(),
        onHorizontalDragCancel: _end,
        child: tile,
      ),
    );
  }
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
                background: p.background,
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
  _DotSliderPainter({
    required this.value,
    required this.on,
    required this.off,
    required this.knob,
    required this.background,
    this.colorAt,
  });

  final double value;
  final Color on;
  final Color off;
  final Color knob;
  final Color background;
  final Color Function(double t)? colorAt;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 11.0;
    final count = math.max(2, (size.width / gap).floor());
    final step = size.width / (count - 1);
    final cy = size.height / 2;
    final paint = Paint();
    // Colours close to the background (cool white on the light theme) get a thin ring so they still show.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = off;
    final backLum = background.computeLuminance();
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      final filled = t <= value + 1e-6;
      final c = colorAt?.call(t);
      final at = Offset(i * step, cy);
      final r = filled ? 3.2 : 2.4;
      paint.color = c != null ? c.withValues(alpha: filled ? 1 : 0.5) : (filled ? on : off);
      canvas.drawCircle(at, r, paint);
      if (c != null && (c.computeLuminance() - backLum).abs() < 0.3) canvas.drawCircle(at, r, ring);
    }
    final kx = value * size.width;
    canvas.drawCircle(Offset(kx, cy), 9, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(_DotSliderPainter old) =>
      old.value != value || old.on != on || old.off != off || old.background != background || old.colorAt != colorAt;
}

/// Big round power button.
class PowerOrb extends StatelessWidget {
  const PowerOrb({super.key, required this.on, required this.onTap, this.icon = Icons.power_settings_new, this.size = 120});

  final bool on;

  /// Null shows the state only.
  final VoidCallback? onTap;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: onTap != null,
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
  const NChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap,
      this.onLongPress,
      this.icon,
      this.trailingIcon});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData? icon;
  final IconData? trailingIcon;

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
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              Icon(trailingIcon, size: 16, color: selected ? p.background : p.text),
            ],
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
