import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../models/device.dart';
import '../../theme/app_theme.dart';
import '../../util/color_math.dart';
import '../../util/haptics.dart';
import 'controls.dart';
import '../../util/sounds.dart';

/// The faint dotted grid behind the floor plan.
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

/// Shrinks its child a little while a finger is down on it and springs back,
/// like buttons and tiles on iOS. Never takes the touch from the child.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.enabled = true, this.scale = 0.96});
  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  var _down = false;

  void _set(bool v) {
    if (widget.enabled && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: Duration(milliseconds: _down ? 90 : 260),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: widget.child,
        ),
      );
}

/// A rounded card: white on the light theme with a soft shadow, dark grey on the dark one.
/// [glass] makes it see-through, for cards laid on the home wallpaper.
class NCard extends StatelessWidget {
  const NCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.onLongPress,
    this.inverted = false,
    this.glass = false,
    this.radius = 18,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool inverted;
  final bool glass;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PressScale(
      enabled: onTap != null || onLongPress != null,
      scale: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: inverted ? p.tileOn : (glass ? p.glass : p.surface),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: inverted ? p.cardShadow : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            onTap: onTap == null
                ? null
                : () {
                    Sounds.tap();
                    onTap!();
                  },
            onLongPress: onLongPress,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A round frosted button for the top of a screen, like the + and ... in Apple Home.
class GlassButton extends StatelessWidget {
  const GlassButton({super.key, required this.icon, required this.onPressed, this.tooltip, this.size = 36});
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final button = Semantics(
      button: true,
      label: tooltip,
      child: PressScale(
        enabled: onPressed != null,
        scale: 0.9,
        child: GestureDetector(
          onTap: onPressed == null
              ? null
              : () {
                  Sounds.tap();
                  onPressed!();
                },
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: p.isDark ? p.glass : p.surface),
            child: Icon(icon, size: size * 0.5, color: p.text),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The soft coloured wallpaper behind the home screen, as in Apple Home.
class HomeWallpaper extends StatelessWidget {
  const HomeWallpaper({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = p.isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF1F2A3A), Color(0xFF12141C), Color(0xFF0B0B0F)]
              : const [Color(0xFFF3F6FB), Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.9, -0.85),
            radius: 1.1,
            colors: dark
                ? const [Color(0x40FF9F0A), Color(0x00FF9F0A)]
                : const [Color(0x26FFD7A8), Color(0x00FFD7A8)],
          ),
        ),
        child: child,
      ),
    );
  }
}

/// Section header, like the room names in Apple Home.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.accent = false});
  final String text;
  final Widget? trailing;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: NType.body(20, color: p.text, weight: 700))),
          ?trailing,
        ],
      ),
    );
  }
}

/// The colour of a device kind's icon when it is on, as in Apple Home.
Color kindColor(DeviceKind kind) => switch (kind) {
      DeviceKind.light => KJPalette.yellow,
      DeviceKind.climate || DeviceKind.humidifier => KJPalette.orange,
      DeviceKind.media => KJPalette.purple,
      DeviceKind.lock || DeviceKind.alarm || DeviceKind.camera || DeviceKind.garage => KJPalette.blue,
      DeviceKind.outlet || DeviceKind.toggle || DeviceKind.button => KJPalette.green,
      DeviceKind.cover || DeviceKind.fan || DeviceKind.purifier || DeviceKind.valve => KJPalette.teal,
      DeviceKind.vacuum || DeviceKind.mower || DeviceKind.appliance => KJPalette.indigo,
      DeviceKind.siren => KJPalette.danger,
      DeviceKind.sensor || DeviceKind.router || DeviceKind.other => KJPalette.blue,
    };

IconData deviceIcon(DeviceKind kind, {bool active = false}) => switch (kind) {
      DeviceKind.light => active ? CupertinoIcons.lightbulb_fill : CupertinoIcons.lightbulb,
      DeviceKind.outlet => CupertinoIcons.power,
      DeviceKind.toggle => active ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt,
      DeviceKind.sensor => CupertinoIcons.gauge,
      DeviceKind.climate => CupertinoIcons.thermometer,
      DeviceKind.cover => active ? CupertinoIcons.rectangle_split_3x1 : CupertinoIcons.rectangle_split_3x1_fill,
      DeviceKind.fan => CupertinoIcons.wind,
      DeviceKind.lock => active ? CupertinoIcons.lock_open_fill : CupertinoIcons.lock_fill,
      DeviceKind.media => active ? CupertinoIcons.tv_fill : CupertinoIcons.tv,
      DeviceKind.camera => active ? CupertinoIcons.videocam_fill : CupertinoIcons.videocam,
      DeviceKind.vacuum => Icons.cleaning_services_rounded,
      DeviceKind.mower => CupertinoIcons.leaf_arrow_circlepath,
      DeviceKind.purifier => CupertinoIcons.tornado,
      DeviceKind.humidifier => active ? CupertinoIcons.drop_fill : CupertinoIcons.drop,
      DeviceKind.appliance => Icons.local_laundry_service_rounded,
      DeviceKind.alarm => active ? CupertinoIcons.shield_fill : CupertinoIcons.shield,
      DeviceKind.valve => Icons.plumbing_rounded,
      DeviceKind.siren => active ? CupertinoIcons.bell_fill : CupertinoIcons.bell,
      DeviceKind.garage => Icons.garage_rounded,
      DeviceKind.button => active ? CupertinoIcons.hand_point_right_fill : CupertinoIcons.hand_point_right,
      DeviceKind.router => CupertinoIcons.wifi,
      DeviceKind.other => active ? CupertinoIcons.cube_box_fill : CupertinoIcons.cube_box,
    };

/// An icon for what a network device probably is ("iPhone or iPad", "Printer", "Computer or laptop").
IconData iconForGuess(String what, String? kind) {
  final w = what.toLowerCase();
  if (RegExp(r'phone|ipad|tablet').hasMatch(w)) return CupertinoIcons.device_phone_portrait;
  if (w.contains('printer')) return CupertinoIcons.printer;
  if (RegExp(r'computer|laptop|\bmac\b').hasMatch(w)) return CupertinoIcons.device_laptop;
  if (w.contains('nas') || w.contains('storage')) return Icons.storage;
  if (w.contains('console')) return CupertinoIcons.gamecontroller;
  if (w.contains('watch') || w.contains('fitness')) return Icons.watch_outlined;
  if (w.contains('router') || w.contains('access point')) return CupertinoIcons.wifi;
  if (w.contains('speaker') || w.contains('echo')) return CupertinoIcons.speaker_2;
  if (w.contains('plug') || w.contains('bulb')) return CupertinoIcons.power;
  final k = DeviceKind.values.asNameMap()[kind];
  return k == null ? CupertinoIcons.cube_box : deviceIcon(k);
}

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
      Activity.triggered => 'Alarm',
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

/// Apple Home accessory tile: a wide rounded tile with the icon in a circle on
/// the left and the name and state beside it. Off it is frosted glass, on it
/// turns white with a coloured icon, and a level (brightness, blind, volume)
/// fills it from the left.
/// Tap switches it; a sideways drag sets its level when [onLevelEnd] is
/// given; the arrow opens all its controls.
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

  /// Height of a tile in a grid.
  static const height = 76.0;

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
    Sounds.tick();
    widget.onLevelEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = widget.device;
    final level = _drag ?? _level;
    final active = d.state.isActive && d.state.reachable;
    final lit = active || _drag != null;
    final fg = lit ? p.onTileOn : p.text;
    final dim = lit ? const Color(0x99000000) : p.textDim;
    final glow = lightColor(d);
    final tint = glow ?? kindColor(d.kind);
    final iconBg = active ? tint : (lit ? const Color(0x14000000) : p.text.withValues(alpha: p.isDark ? 0.14 : 0.08));
    const radius = BorderRadius.all(Radius.circular(18));
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: lit ? p.tileOn : p.tileOff,
        borderRadius: radius,
        border: lit && !p.isDark ? Border.all(color: const Color(0x14000000), width: 0.5) : null,
        boxShadow: lit ? p.cardShadow : const [],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Stack(children: [
              // The level fills the tile from the left, like the sliders in Control Center.
              if (level != null && lit)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: level.clamp(0.0, 1.0),
                    child: AnimatedContainer(
                      duration: Duration(milliseconds: _drag != null ? 0 : 240),
                      color: tint.withValues(alpha: 0.16),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
                child: Row(children: [
                  Stack(clipBehavior: Clip.none, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 240),
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: iconBg,
                        border: active && glow != null && glow.computeLuminance() > 0.8
                            ? Border.all(color: Colors.black.withValues(alpha: 0.1))
                            : null,
                      ),
                      child: Icon(
                        deviceIcon(d.kind, active: active),
                        size: 19,
                        color: active ? (iconBg.computeLuminance() > 0.6 ? p.onTileOn : Colors.white) : dim,
                      ),
                    ),
                    if (!d.state.reachable)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: KJPalette.danger,
                            shape: BoxShape.circle,
                            border: Border.all(color: p.isDark ? const Color(0xFF3A3A3C) : Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ]),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.name,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.body(14, color: fg, weight: 600, height: 1.15)),
                      const SizedBox(height: 1),
                      Text(_drag != null ? levelLabel(d, _drag!) : (widget.subtitle ?? describeState(d)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NType.body(12.5, color: d.state.reachable ? dim : KJPalette.danger, height: 1.15)),
                    ]),
                  ),
                  if (widget.onOpen != null)
                    Semantics(
                      button: true,
                      label: 'All controls',
                      child: GestureDetector(
                        key: Key('open-${d.id}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onOpen,
                        child: SizedBox(
                          width: 26,
                          height: 56,
                          child: Icon(CupertinoIcons.chevron_right, size: 13, color: dim.withValues(alpha: 0.5)),
                        ),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
    final pressable = PressScale(child: tile);
    if (level == null) return pressable;
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
        child: pressable,
      ),
    );
  }
}

/// A grid of [DeviceTile]s: two across on a phone, more on wider screens.
SliverGridDelegate deviceGridDelegate(double width) => SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: (width / 190).floor().clamp(2, 6),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      mainAxisExtent: DeviceTile.height,
    );

/// A slider with a round white knob on a thick track. [onChanged] fires while dragging,
/// [onChangeEnd] once when the finger lifts (send that to the device).
class LevelSlider extends StatefulWidget {
  const LevelSlider({
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
  State<LevelSlider> createState() => _LevelSliderState();
}

class _LevelSliderState extends State<LevelSlider> {
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
              painter: _LevelSliderPainter(
                value: _value,
                on: KJPalette.accent,
                off: p.surfaceHigh,
                knob: Colors.white,
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

class _LevelSliderPainter extends CustomPainter {
  _LevelSliderPainter({
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
    const h = 8.0;
    final cy = size.height / 2;
    final track = RRect.fromLTRBR(0, cy - h / 2, size.width, cy + h / 2, const Radius.circular(h / 2));
    final kx = value * size.width;
    if (colorAt != null) {
      // Colour temperature or hue: the whole track shows the colours.
      final stops = [for (var i = 0; i <= 12; i++) i / 12];
      final shader = LinearGradient(colors: [for (final t in stops) colorAt!(t)], stops: stops)
          .createShader(Offset.zero & size);
      canvas.drawRRect(track, Paint()..shader = shader);
      if ((colorAt!(1).computeLuminance() - background.computeLuminance()).abs() < 0.3) {
        canvas.drawRRect(track, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = off);
      }
    } else {
      canvas.drawRRect(track, Paint()..color = off);
      if (value > 0.001) {
        canvas.drawRRect(
            RRect.fromLTRBR(0, cy - h / 2, math.max(h, kx), cy + h / 2, const Radius.circular(h / 2)), Paint()..color = on);
      }
    }
    final at = Offset(kx.clamp(11.0, math.max(11.0, size.width - 11)), cy);
    canvas.drawCircle(at + const Offset(0, 1), 12,
        Paint()
          ..color = const Color(0x40000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(at, 11, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(_LevelSliderPainter old) =>
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
        onTap: onTap == null
            ? null
            : () {
                Sounds.power(!on);
                onTap!();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? KJPalette.accent : p.surfaceHigh,
            boxShadow: on ? [BoxShadow(color: KJPalette.accent.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8))] : const [],
          ),
          child: Icon(icon, size: size * 0.36, color: on ? Colors.white : p.text),
        ),
      ),
    );
  }
}

/// Heading text: big, bold and tightly spaced.
class DisplayText extends StatelessWidget {
  const DisplayText(this.text, {super.key, this.size = 32, this.color, this.weight = 700, this.maxLines});
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
        style: NType.display(size, color: color ?? context.palette.text, weight: weight),
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
      onTap: () {
        Sounds.tick();
        onTap();
      },
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? p.text : p.surfaceHigh,
          borderRadius: BorderRadius.circular(999),
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
