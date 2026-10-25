import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../integrations/camera/playback.dart';
import '../../models/device.dart';
import '../../state/app_settings.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../util/clock_text.dart';
import '../widgets/camera_live.dart';
import '../widgets/kj_widgets.dart';

/// Tests set this to a fixed time. Always null in the app.
DateTime Function()? debugPlaybackClock;

/// Opens what [device] recorded on its memory card.
Future<void> showCameraPlayback(BuildContext context, Device device) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CameraPlaybackScreen(device: device, clock: debugPlaybackClock ?? DateTime.now),
    ));


/// A camera's recordings: a week of days, a line through the day showing what was recorded (red where something
/// moved), and the video from wherever the line is tapped. Plays over RTSP, so on the Android app.
class CameraPlaybackScreen extends StatefulWidget {
  const CameraPlaybackScreen({super.key, required this.device, this.clock = DateTime.now});
  final Device device;
  final DateTime Function() clock;

  @override
  State<CameraPlaybackScreen> createState() => _CameraPlaybackScreenState();
}

class _CameraPlaybackScreenState extends State<CameraPlaybackScreen> {
  late final CameraPlayback? _playback = CameraPlayback.of(widget.device.props);
  late DateTime _day = _midnight(widget.clock());

  /// Where the video now playing started, and how far it has played since.
  DateTime? _start;
  Duration _played = Duration.zero;
  bool _paused = false;
  bool _muted = true;
  bool _away = false;
  int _attempt = 0;

  List<Recording>? _recordings;
  String? _problem;
  int _load = 0;

  /// Hours the line shows at once.
  int _zoom = 24;
  DateTime? _centre;

  static DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);

  DateTime? get _now => _start?.add(_played);

  @override
  void initState() {
    super.initState();
    _find();
  }

  Future<void> _find() async {
    final playback = _playback;
    if (playback == null) return;
    final load = ++_load;
    setState(() {
      _recordings = null;
      _problem = null;
    });
    try {
      final found = await playback.find(_day, context.read<HomeStore>().client);
      if (mounted && load == _load) setState(() => _recordings = found);
    } on PlaybackException catch (e) {
      if (mounted && load == _load) setState(() => _problem = e.message);
    }
  }

  void _pickDay(DateTime day) {
    if (day == _day) return;
    setState(() {
      _day = day;
      _centre = null;
    });
    _find();
  }

  /// Plays from [t], never later than now.
  void _play(DateTime t) {
    final latest = widget.clock().subtract(const Duration(seconds: 5));
    final from = t.isAfter(latest) ? latest : t;
    final otherDay = _midnight(from) != _day;
    setState(() {
      _start = from;
      _played = Duration.zero;
      _paused = false;
      _attempt++;
      _centre = from;
      if (otherDay) _day = _midnight(from);
    });
    if (otherDay) _find();
  }

  void _skip(Duration by) {
    final at = _now;
    if (at != null) _play(at.add(by));
  }

  Uri _url(DateTime start) => _playback!.at(start, now: widget.clock());

  Widget _player(BoxFit fit) {
    final url = _url(_start!);
    return debugRtspPlayer?.call(url) ??
        RtspPlayer(
          key: ValueKey('$url#$_attempt'),
          url: url,
          muted: _muted,
          paused: _paused,
          fit: fit,
          failed: 'Nothing plays from then. The camera may have recorded nothing at that time, or have no memory '
              'card. Pick another time.',
          onPosition: (at) {
            if (mounted) setState(() => _played = at);
          },
        );
  }

  Future<void> _fullScreen() async {
    setState(() => _away = true);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FullScreenCamera(name: widget.device.name, player: _player(BoxFit.contain)),
    ));
    if (!mounted) return;
    // Carry on from where full screen got to.
    final at = _now;
    setState(() => _away = false);
    if (at != null) _play(at);
  }

  /// The stretch of the day the line shows: the whole day, or [_zoom] hours around what plays.
  (DateTime, DateTime) get _window {
    final dayEnd = _day.add(const Duration(days: 1));
    if (_zoom >= 24) return (_day, dayEnd);
    final span = Duration(hours: _zoom);
    final mid = _centre ?? _now ?? _recordings?.lastOrNull?.start ?? widget.clock();
    var from = mid.subtract(span ~/ 2);
    if (from.isBefore(_day)) from = _day;
    if (from.add(span).isAfter(dayEnd)) from = dayEnd.subtract(span);
    return (from, from.add(span));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final h24 = context.select<AppSettings, bool>((s) => s.clock24);
    final now = _now;
    final today = _midnight(widget.clock());
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 20, 4),
                child: Row(children: [
                  IconButton(
                    key: const Key('playback-back'),
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(CupertinoIcons.back, color: KJPalette.accent, size: 28),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(child: DisplayText('Recordings', size: 30)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Column(children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 10),
                      child: Text(widget.device.name, style: NType.label(color: p.textDim)),
                    ),
                  ),
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: ColoredBox(
                        color: Colors.black,
                        child: Stack(fit: StackFit.expand, children: [
                          if (_playback == null)
                            const _VideoNote('This camera does not let other apps play its recordings.')
                          else if (!rtspPlays)
                            const _VideoNote('Recordings play in the Android app.')
                          else if (_start == null)
                            const _VideoNote('Tap the line below or a recording to watch it.')
                          else if (_away)
                            const CameraMessage('Playing full screen')
                          else
                            _player(BoxFit.cover),
                          if (now != null)
                            Positioned(
                              left: 14,
                              top: 12,
                              child: _TimeBadge(
                                  key: const Key('playback-time'),
                                  text: '${_dayName(_midnight(now), today)} · ${clockText(now, h24, seconds: true)}'),
                            ),
                          if (_start != null && rtspPlays)
                            Positioned(
                              right: 4,
                              bottom: 2,
                              child: Row(children: [
                                IconButton(
                                  key: const Key('playback-mute'),
                                  tooltip: _muted ? 'Sound on' : 'Sound off',
                                  color: Colors.white,
                                  onPressed: () => setState(() => _muted = !_muted),
                                  icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                                ),
                                IconButton(
                                  key: const Key('playback-fullscreen'),
                                  tooltip: 'Full screen',
                                  color: Colors.white,
                                  onPressed: _away ? null : _fullScreen,
                                  icon: const Icon(Icons.fullscreen),
                                ),
                              ]),
                            ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    IconButton(
                      key: const Key('playback-rewind'),
                      tooltip: 'Back 30 seconds',
                      onPressed: now == null ? null : () => _skip(const Duration(seconds: -30)),
                      icon: const Icon(Icons.replay_30),
                    ),
                    IconButton(
                      key: const Key('playback-pause'),
                      tooltip: _paused ? 'Play' : 'Pause',
                      onPressed: now == null ? null : () => setState(() => _paused = !_paused),
                      icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                    ),
                    IconButton(
                      key: const Key('playback-forward'),
                      tooltip: 'Forward 30 seconds',
                      onPressed: now == null ? null : () => _skip(const Duration(seconds: 30)),
                      icon: const Icon(Icons.forward_30),
                    ),
                    const Spacer(),
                    for (final hours in const [24, 4, 1])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: SmallChip(
                          key: Key('playback-zoom-$hours'),
                          label: '${hours}H',
                          selected: _zoom == hours,
                          onTap: () => setState(() => _zoom = hours),
                        ),
                      ),
                  ]),
                  PlaybackTimeline(
                    key: const Key('playback-timeline'),
                    from: _window.$1,
                    to: _window.$2,
                    now: widget.clock(),
                    recordings: _recordings ?? const [],
                    cursor: now != null && _midnight(now) == _day ? now : null,
                    h24: h24,
                    onPick: _playback == null ? null : _play,
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 40,
                    child: ListView(scrollDirection: Axis.horizontal, children: [
                      for (var i = 0; i < 7; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: NChip(
                            key: Key('playback-day-$i'),
                            label: _dayName(today.subtract(Duration(days: i)), today),
                            selected: _day == today.subtract(Duration(days: i)),
                            onTap: () => _pickDay(today.subtract(Duration(days: i))),
                          ),
                        ),
                    ]),
                  ),
                ]),
              ),
              Expanded(child: _list(context, h24)),
            ]),
          ),
        ),
      ),
    );
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _dayName(DateTime day, DateTime today) {
    final ago = today.difference(day).inHours ~/ 24;
    if (ago == 0) return 'Today';
    if (ago == 1) return 'Yesterday';
    return '${_days[day.weekday - 1]} ${day.day}';
  }

  Widget _list(BuildContext context, bool h24) {
    final p = context.palette;
    final found = _recordings;
    final note = NType.body(13.5, color: p.textDim);
    final cardNote = 'Recordings come from the camera\'s memory card. Ones saved to a cloud play only in the camera\'s '
        'own app.';
    Widget message(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: NCard(key: const Key('playback-note'), child: Text(text, style: NType.body(13.5, color: p.text))),
        );
    final now = _now;
    return ListView(key: const Key('playback-list'), padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
      SectionLabel(found == null || found.isEmpty ? 'Recorded' : 'Recorded · ${found.length}'),
      if (_playback == null)
        message('Dahua, Imou, Amcrest, Hikvision and Ezviz cameras let SmartHomeKJ play what they recorded. '
            'This camera\'s recordings play in its own app.')
      else if (_problem != null)
        message('$_problem You can still tap a time on the line above to watch it. $cardNote')
      else if (found == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Text('Looking for recordings', style: note),
          ]),
        )
      else if (found.isEmpty)
        message('Nothing was recorded on this day. $cardNote Check that the camera has a memory card and that '
            'recording is on in its app.')
      else
        for (final (i, r) in found.reversed.indexed)
          ListTile(
            key: Key('playback-clip-$i'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(r.motion ? Icons.directions_run : Icons.videocam_outlined,
                color: r.motion ? KJPalette.danger : p.textDim),
            title: Text('${clockText(r.start, h24)} – ${clockText(r.end, h24)}'),
            subtitle: Text('${r.motion ? 'Motion' : 'Recording'} · ${_length(r.end.difference(r.start))}'),
            trailing: now != null && !now.isBefore(r.start) && now.isBefore(r.end)
                ? const Icon(Icons.play_arrow, color: KJPalette.accent)
                : null,
            onTap: () => _play(r.start),
          ),
    ]);
  }

  static String _length(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds} s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    final m = d.inMinutes % 60;
    return '${d.inHours} h${m == 0 ? '' : ' $m min'}';
  }
}

class _VideoNote extends StatelessWidget {
  const _VideoNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.history, color: Colors.white54, size: 28),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: NType.body(13.5, color: Colors.white70)),
          ]),
        ),
      );
}

class _TimeBadge extends StatelessWidget {
  const _TimeBadge({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.history, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(text, style: NType.display(13, color: Colors.white)),
        ]),
      );
}

/// A line through part of a day: dots where time has passed, bars where the camera recorded (red where something
/// moved) and a red mark at what plays. Tapping or sliding along it picks a time.
class PlaybackTimeline extends StatefulWidget {
  const PlaybackTimeline({
    super.key,
    required this.from,
    required this.to,
    required this.now,
    required this.recordings,
    required this.h24,
    this.cursor,
    this.onPick,
  });

  final DateTime from;
  final DateTime to;
  final DateTime now;
  final List<Recording> recordings;
  final DateTime? cursor;
  final bool h24;
  final ValueChanged<DateTime>? onPick;

  @override
  State<PlaybackTimeline> createState() => _PlaybackTimelineState();
}

class _PlaybackTimelineState extends State<PlaybackTimeline> {
  DateTime? _sliding;

  DateTime _at(double x, double width) {
    final span = widget.to.difference(widget.from);
    var t = widget.from.add(span * (x / width).clamp(0.0, 1.0));
    if (t.isAfter(widget.now)) t = widget.now;
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pick = widget.onPick;
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 18,
          child: _sliding == null
              ? null
              : Text(clockText(_sliding!, widget.h24), textAlign: TextAlign.center, style: NType.display(15, color: KJPalette.accent)),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: pick == null ? null : (d) => pick(_at(d.localPosition.dx, width)),
          onHorizontalDragStart: pick == null ? null : (d) => setState(() => _sliding = _at(d.localPosition.dx, width)),
          onHorizontalDragUpdate: pick == null ? null : (d) => setState(() => _sliding = _at(d.localPosition.dx, width)),
          onHorizontalDragEnd: pick == null
              ? null
              : (_) {
                  final t = _sliding;
                  setState(() => _sliding = null);
                  if (t != null) pick(t);
                },
          child: CustomPaint(
            size: Size(width, 58),
            painter: _TimelinePainter(
              from: widget.from,
              to: widget.to,
              now: widget.now,
              recordings: widget.recordings,
              cursor: _sliding ?? widget.cursor,
              h24: widget.h24,
              dot: p.textDim.withValues(alpha: 0.45),
              bar: p.text.withValues(alpha: 0.7),
              label: p.textDim,
            ),
          ),
        ),
      ]);
    });
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.from,
    required this.to,
    required this.now,
    required this.recordings,
    required this.cursor,
    required this.h24,
    required this.dot,
    required this.bar,
    required this.label,
  });

  final DateTime from;
  final DateTime to;
  final DateTime now;
  final List<Recording> recordings;
  final DateTime? cursor;
  final bool h24;
  final Color dot;
  final Color bar;
  final Color label;

  static const _mid = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final span = to.difference(from).inMilliseconds.toDouble();
    double x(DateTime t) => (t.difference(from).inMilliseconds / span * size.width).clamp(0.0, size.width);
    final passed = now.isBefore(to) ? x(now) : size.width;

    final dots = Paint()..color = dot;
    for (var dx = 2.0; dx <= passed; dx += 7) {
      canvas.drawCircle(Offset(dx, _mid), 1.4, dots);
    }
    for (final motion in const [false, true]) {
      final paint = Paint()..color = motion ? KJPalette.danger : bar;
      for (final r in recordings.where((r) => r.motion == motion)) {
        if (!r.end.isAfter(from) || !r.start.isBefore(to)) continue;
        final left = x(r.start);
        final right = x(r.end);
        canvas.drawRRect(
            RRect.fromLTRBR(left, _mid - 6, right - left < 3 ? left + 3 : right, _mid + 6, const Radius.circular(3)), paint);
      }
    }

    // Ticks with the time under them.
    final hours = to.difference(from).inMinutes / 60;
    final step = hours > 12 ? const Duration(hours: 6) : (hours > 2 ? const Duration(hours: 1) : const Duration(minutes: 15));
    final midnight = DateTime(from.year, from.month, from.day);
    var tick = midnight;
    while (tick.isBefore(from)) {
      tick = tick.add(step);
    }
    final ticks = Paint()
      ..color = label
      ..strokeWidth = 1;
    for (; !tick.isAfter(to); tick = tick.add(step)) {
      final tx = x(tick);
      canvas.drawLine(Offset(tx, _mid + 10), Offset(tx, _mid + 14), ticks);
      final text = tick.difference(midnight).inHours >= 24
          ? (h24 ? '24' : '12A')
          : (step.inHours >= 1
              ? (h24 ? tick.hour.toString().padLeft(2, '0') : '${tick.hour % 12 == 0 ? 12 : tick.hour % 12}${tick.hour < 12 ? 'A' : 'P'}')
              : clockText(tick, h24).replaceAll(' AM', '').replaceAll(' PM', ''));
      final tp = TextPainter(
        text: TextSpan(text: text, style: NType.label(color: label)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((tx - tp.width / 2).clamp(0.0, size.width - tp.width), _mid + 17));
    }

    final c = cursor;
    if (c != null && !c.isBefore(from) && !c.isAfter(to)) {
      final cx = x(c);
      final red = Paint()
        ..color = KJPalette.accent
        ..strokeWidth = 2;
      canvas.drawLine(Offset(cx, _mid - 14), Offset(cx, _mid + 12), red);
      canvas.drawCircle(Offset(cx, _mid - 14), 4, red);
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.from != from ||
      old.to != to ||
      old.cursor != cursor ||
      old.recordings != recordings ||
      old.now.minute != now.minute ||
      old.h24 != h24 ||
      old.bar != bar;
}
