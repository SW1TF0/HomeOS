import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../../integrations/integration.dart';
import '../../theme/app_theme.dart';
import '../../util/digest_auth.dart';

/// Whether RTSP video plays here. Android plays it; Apple's player and the desktop apps have no RTSP, so there a
/// camera shows pictures (or MJPEG) instead.
bool get rtspPlays => debugRtspPlays ?? (!kIsWeb && Platform.isAndroid);

/// Tests have no video player: they set these to play RTSP with a stand-in. Always null in the app.
bool? debugRtspPlays;
Widget Function(Uri url)? debugRtspPlayer;

/// Live video from a camera: RTSP on Android, MJPEG everywhere, with sound, picture size and full screen.
class LiveCameraView extends StatefulWidget {
  const LiveCameraView({super.key, required this.stream, required this.name, this.client});
  final CameraStream stream;
  final String name;
  final http.Client? client;

  @override
  State<LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<LiveCameraView> {
  /// The smaller picture starts sooner and uses less data, so it comes first.
  bool _hd = false;
  bool _muted = true;
  int _attempt = 0;

  /// The video is closed here while it plays full screen: many cameras allow only one or two viewers.
  bool _away = false;

  bool get _rtsp => widget.stream.rtsp != null && rtspPlays;
  Uri get _rtspUrl => _hd || widget.stream.rtspLow == null ? widget.stream.rtsp! : widget.stream.rtspLow!;

  Widget _player(BoxFit fit, {bool muted = true}) => _rtsp
      ? debugRtspPlayer?.call(_rtspUrl) ??
          RtspPlayer(key: ValueKey('$_rtspUrl#$_attempt'), url: _rtspUrl, muted: muted, fit: fit)
      : MjpegPlayer(
          key: ValueKey('${widget.stream.mjpeg}#$_attempt'),
          url: widget.stream.mjpeg!,
          headers: widget.stream.headers,
          client: widget.client,
          fit: fit);

  Future<void> _fullScreen() async {
    setState(() => _away = true);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FullScreenCamera(name: widget.name, player: _player(BoxFit.contain, muted: _muted)),
    ));
    if (mounted) setState(() => _away = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(fit: StackFit.expand, children: [
              if (_away) const CameraMessage('Playing full screen') else _player(BoxFit.cover, muted: _muted),
              const Positioned(left: 14, top: 12, child: LiveBadge()),
              Positioned(
                right: 4,
                bottom: 2,
                child: Row(children: [
                  if (_rtsp)
                    IconButton(
                      key: const Key('camera-mute'),
                      tooltip: _muted ? 'Sound on' : 'Sound off',
                      color: Colors.white,
                      onPressed: () => setState(() => _muted = !_muted),
                      icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                    ),
                  IconButton(
                    key: const Key('camera-fullscreen'),
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
      const SizedBox(height: 8),
      Row(children: [
        Container(width: 6, height: 6, decoration: const BoxDecoration(color: KJPalette.danger, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(_rtsp ? 'LIVE · ${_hd || widget.stream.rtspLow == null ? 'HD' : 'SD'}' : 'Live', style: NType.label(color: p.textDim))),
        if (_rtsp && widget.stream.rtspLow != null)
          for (final (label, hd) in const [('SD', false), ('HD', true)])
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SmallChip(key: Key('camera-$label'), label: label, selected: _hd == hd, onTap: () => setState(() => _hd = hd)),
            ),
        IconButton(
          key: const Key('camera-reconnect'),
          tooltip: 'Connect again',
          onPressed: () => setState(() => _attempt++),
          icon: const Icon(Icons.refresh),
        ),
      ]),
    ]);
  }
}

/// A small pill to pick an option over or under a camera's video.
class SmallChip extends StatelessWidget {
  const SmallChip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? p.text : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? p.text : p.border),
        ),
        child: Text(label, style: NType.label(color: selected ? p.background : p.text)),
      ),
    );
  }
}

/// The red dot and "LIVE" over a camera's video.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: const BoxDecoration(color: KJPalette.danger, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('Live', style: NType.display(13, color: Colors.white)),
        ]),
      );
}

/// A line of dot-matrix text on the black of a camera picture.
class CameraMessage extends StatelessWidget {
  const CameraMessage(this.text, {super.key, this.problem = false});
  final String text;
  final bool problem;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!problem) ...[
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
              const SizedBox(height: 12),
            ],
            Text(text,
                textAlign: TextAlign.center,
                style: problem ? NType.body(13.5, color: const Color(0xFFFF6B6B)) : NType.label(color: Colors.white70)),
          ]),
        ),
      );
}

/// A camera's video on the whole screen, with pinch to zoom and a button to turn it sideways.
class FullScreenCamera extends StatefulWidget {
  const FullScreenCamera({super.key, required this.name, required this.player});
  final String name;
  final Widget player;

  @override
  State<FullScreenCamera> createState() => _FullScreenCameraState();
}

class _FullScreenCameraState extends State<FullScreenCamera> {
  bool _sideways = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          InteractiveViewer(
            maxScale: 6,
            child: RotatedBox(
              quarterTurns: _sideways ? 1 : 0,
              child: Center(child: AspectRatio(aspectRatio: 16 / 9, child: widget.player)),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IconButton(
                  key: const Key('camera-close'),
                  tooltip: 'Close',
                  color: Colors.white,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(widget.name, style: NType.display(16, color: Colors.white)),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('camera-rotate'),
                  tooltip: 'Turn sideways',
                  color: Colors.white,
                  onPressed: () => setState(() => _sideways = !_sideways),
                  icon: const Icon(Icons.screen_rotation_outlined),
                ),
              ]),
            ),
          ),
        ]),
      );
}

// ---- RTSP ---------------------------------------------------------------------------

/// Plays an RTSP camera with Android's own video player.
class RtspPlayer extends StatefulWidget {
  const RtspPlayer(
      {super.key, required this.url, this.muted = true, this.paused = false, this.fit = BoxFit.cover, this.onPosition, this.failed});
  final Uri url;
  final bool muted;
  final bool paused;
  final BoxFit fit;

  /// How far it has played, as it plays.
  final ValueChanged<Duration>? onPosition;

  /// What to say when the video does not start.
  final String? failed;

  @override
  State<RtspPlayer> createState() => _RtspPlayerState();
}

class _RtspPlayerState extends State<RtspPlayer> {
  late final _video =
      VideoPlayerController.networkUrl(widget.url, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
  String? _problem;
  Timer? _slow;

  static const _didNotStart = 'The video did not start. Check the camera\'s login under Live video, and that the camera '
      'and this phone are on the same Wi-Fi.';
  String get _failed => widget.failed ?? _didNotStart;
  Duration _at = Duration.zero;

  @override
  void initState() {
    super.initState();
    _video.addListener(_changed);
    _video.initialize().then((_) async {
      await _video.setVolume(widget.muted ? 0 : 1);
      if (!widget.paused) await _video.play();
      if (mounted) setState(() {});
    }).catchError((Object _) {
      if (mounted) setState(() => _problem = _failed);
    });
    _slow = Timer(const Duration(seconds: 20), () {
      if (mounted && !_video.value.isInitialized && _problem == null) {
        setState(() => _problem = 'The camera sends no video. Check that it is switched on and on this Wi-Fi.');
      }
    });
  }

  void _changed() {
    if (_video.value.hasError && _problem == null && mounted) setState(() => _problem = _failed);
    final at = _video.value.position;
    if (at != _at) {
      _at = at;
      widget.onPosition?.call(at);
    }
  }

  @override
  void didUpdateWidget(RtspPlayer old) {
    super.didUpdateWidget(old);
    if (old.muted != widget.muted && _video.value.isInitialized) _video.setVolume(widget.muted ? 0 : 1);
    if (old.paused != widget.paused && _video.value.isInitialized) widget.paused ? _video.pause() : _video.play();
  }

  @override
  void dispose() {
    _slow?.cancel();
    _video.removeListener(_changed);
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_problem != null) return CameraMessage(_problem!, problem: true);
    final v = _video.value;
    if (!v.isInitialized || v.size.isEmpty) return const CameraMessage('Connecting');
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: v.size.width, height: v.size.height, child: VideoPlayer(_video)),
    );
  }
}

// ---- MJPEG --------------------------------------------------------------------------

/// Plays moving pictures sent as one JPEG after another over HTTP (MJPEG): Home Assistant cameras, ESP32 boards and
/// cameras with an MJPEG address. Works on every device.
class MjpegPlayer extends StatefulWidget {
  const MjpegPlayer(
      {super.key, required this.url, this.headers = const {}, this.client, this.fit = BoxFit.cover});
  final Uri url;
  final Map<String, String> headers;
  final http.Client? client;
  final BoxFit fit;

  @override
  State<MjpegPlayer> createState() => _MjpegPlayerState();
}

class _MjpegPlayerState extends State<MjpegPlayer> {
  Uint8List? _frame;
  String? _problem;
  StreamSubscription<List<int>>? _sub;
  http.Client? _own;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final client = widget.client ?? (_own = http.Client());
    final (user, pass) = loginOf(widget.url);
    final bare = widget.url.replace(userInfo: '');
    final path = bare.hasQuery ? '${bare.path}?${bare.query}' : bare.path;
    http.Request request(String? auth) =>
        http.Request('GET', bare)..headers.addAll({...widget.headers, 'Authorization': ?auth});
    try {
      var res = await client
          .send(request(user.isEmpty ? null : authorization(null, user, pass, 'GET', path)))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 401 && user.isNotEmpty) {
        final challenge = AuthChallenge.pick([res.headers['www-authenticate'] ?? '']);
        unawaited(res.stream.listen(null).cancel());
        res = await client.send(request(authorization(challenge, user, pass, 'GET', path))).timeout(const Duration(seconds: 10));
      }
      if (res.statusCode >= 400) {
        unawaited(res.stream.listen(null).cancel());
        _fail(res.statusCode == 401 || res.statusCode == 403
            ? 'The camera refused the login.'
            : 'The camera answered HTTP ${res.statusCode}.');
        return;
      }
      final frames = MjpegSplitter();
      _sub = res.stream.listen((chunk) {
        final got = frames.add(chunk);
        if (got.isNotEmpty && mounted) setState(() => _frame = got.last);
      }, onError: (Object _) => _fail(), onDone: _fail);
    } catch (_) {
      _fail();
    }
  }

  void _fail([String? why]) {
    if (!mounted) return;
    setState(() => _problem = why ?? 'The video stopped. Tap the refresh button to connect again.');
  }

  @override
  void dispose() {
    _sub?.cancel();
    _own?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_frame != null) {
      return Stack(fit: StackFit.expand, children: [
        Image.memory(_frame!, fit: widget.fit, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
        if (_problem != null) Align(alignment: Alignment.bottomCenter, child: CameraMessage(_problem!, problem: true)),
      ]);
    }
    return CameraMessage(_problem ?? 'Connecting', problem: _problem != null);
  }
}

/// Cuts MJPEG bytes into pictures: each JPEG starts with FF D8 and ends with FF D9, whatever comes in between.
class MjpegSplitter {
  final _bytes = <int>[];
  int _start = -1;
  int _scanned = 0;

  /// The pictures completed by [chunk].
  List<Uint8List> add(List<int> chunk) {
    _bytes.addAll(chunk);
    final out = <Uint8List>[];
    while (true) {
      if (_start < 0) {
        _start = _find(0xD8, 0);
        if (_start < 0) {
          // Keep a last FF: it may start the next picture.
          final keep = _bytes.isNotEmpty && _bytes.last == 0xFF;
          _bytes.clear();
          if (keep) _bytes.add(0xFF);
          _scanned = 0;
          break;
        }
        _scanned = _start + 2;
      }
      final end = _find(0xD9, _scanned);
      if (end < 0) {
        _scanned = _bytes.isEmpty ? 0 : _bytes.length - 1;
        break;
      }
      out.add(Uint8List.fromList(_bytes.sublist(_start, end + 2)));
      _bytes.removeRange(0, end + 2);
      _start = -1;
      _scanned = 0;
    }
    // A stream that never ends a picture must not fill the memory.
    if (_bytes.length > 16 << 20) {
      _bytes.clear();
      _start = -1;
      _scanned = 0;
    }
    return out;
  }

  int _find(int marker, int from) {
    for (var i = from; i + 1 < _bytes.length; i++) {
      if (_bytes[i] == 0xFF && _bytes[i + 1] == marker) return i;
    }
    return -1;
  }
}
