import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../cloud/cloud_sync.dart';
import '../../l10n/text.dart';
import '../../state/app_settings.dart';
import '../../theme/app_theme.dart';
import '../../util/sounds.dart';
import '../widgets/motion.dart';
import 'auth_screen.dart';

/// Shows the welcome screens again, from Settings.
Future<void> replayWelcome(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => WelcomeScreen(onDone: () => Navigator.of(context).pop()),
    ));

/// The first thing a new install shows, once: what the app does, in three moving pictures, then a name to be
/// greeted by and an account (or none). [onDone] runs when it is gone through or skipped.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> with TickerProviderStateMixin {
  final _pages = PageController();
  late final _name = TextEditingController(text: context.read<AppSettings>().name);

  /// Each page's pictures draw themselves in when it comes into view...
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  /// ...and then keep moving.
  late final _loop = AnimationController(vsync: this, duration: const Duration(seconds: 12));
  bool _motion = false;
  bool _decided = false;
  int _page = 0;
  bool _busy = false;

  static const _features = [
    (
      _Picture.orbit,
      'Every device, one app',
      'Lights, plugs, TVs, cameras, robots and thermostats from any brand, on your Wi-Fi. No hub, no fees.',
    ),
    (
      _Picture.plan,
      'Draw your home',
      'Lay out your rooms on a floor plan, put each device where it really is, and tap it to switch it.',
    ),
    (
      _Picture.anywhere,
      'Control it from anywhere',
      'Sign in to keep your homes on every phone and computer, and switch things from wherever you are.',
    ),
  ];

  int get _last => _features.length;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    _motion = Motion.on(context);
    if (!_motion) {
      _intro.value = 1;
      _loop.value = 0.3;
      return;
    }
    _loop.repeat();
    if (Motion.revealed.value) {
      _intro.forward();
    } else {
      Motion.revealed.addListener(_revealed);
    }
  }

  void _revealed() {
    if (!Motion.revealed.value) return;
    Motion.revealed.removeListener(_revealed);
    if (mounted) _intro.forward(from: 0);
  }

  @override
  void dispose() {
    Motion.revealed.removeListener(_revealed);
    _pages.dispose();
    _name.dispose();
    _intro.dispose();
    _loop.dispose();
    super.dispose();
  }

  void _turned(int page) {
    if (page == _page) return;
    Sounds.tick();
    setState(() => _page = page);
    if (_motion) _intro.forward(from: 0);
  }

  void _go(int page) {
    if (_motion) {
      _pages.animateToPage(page, duration: const Duration(milliseconds: 520), curve: Curves.easeInOutCubic);
    } else {
      _pages.jumpToPage(page);
    }
  }

  Future<void> _finish({bool account = false, bool create = false}) async {
    if (_busy) return;
    final settings = context.read<AppSettings>();
    if (_name.text.trim().isNotEmpty) settings.name = _name.text;
    if (account) {
      setState(() => _busy = true);
      final ok = await openAuth(context, create: create, name: _name.text.trim());
      if (mounted) setState(() => _busy = false);
      if (!ok) return;
    }
    Sounds.scene();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      key: const Key('welcome'),
      resizeToAvoidBottomInset: true,
      body: Aurora(
        child: SafeArea(
          child: Column(children: [
            SizedBox(
              height: 52,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedOpacity(
                  opacity: _page < _last ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      key: const Key('welcome-skip'),
                      onPressed: _page < _last ? () => _go(_last) : null,
                      child: Text('Skip', style: NType.body(16, color: p.textDim, weight: 500)),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                key: const Key('welcome-pages'),
                controller: _pages,
                onPageChanged: _turned,
                children: [
                  for (var i = 0; i < _features.length; i++)
                    _FeaturePage(
                      index: i,
                      pages: _pages,
                      intro: _intro,
                      loop: _loop,
                      picture: _features[i].$1,
                      title: _features[i].$2,
                      body: _features[i].$3,
                    ),
                  _LastPage(
                    index: _last,
                    pages: _pages,
                    intro: _intro,
                    loop: _loop,
                    name: _name,
                    busy: _busy,
                    accounts: context.watch<CloudSync>().available && !context.watch<CloudSync>().signedIn,
                    onFinish: _finish,
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              child: _page < _last
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                      child: Column(children: [
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          for (var i = 0; i <= _last; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              width: i == _page ? 24 : 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: i == _page ? KJPalette.accent : p.text.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                        ]),
                        const SizedBox(height: 20),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: _BigButton(
                            key: const Key('welcome-next'),
                            label: 'Continue',
                            onPressed: () => _go(_page + 1),
                          ),
                        ),
                      ]),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ]),
        ),
      ),
    );
  }
}

/// How far [page] is from where the pager stands: 0 in view, ±1 a page away.
double _away(PageController pages, int page) {
  if (!pages.hasClients || !pages.position.haveDimensions) return page.toDouble();
  return (pages.page ?? 0) - page;
}

/// One page: its moving picture, sliding at a different speed from the words, which rise in.
class _FeaturePage extends StatelessWidget {
  const _FeaturePage({
    required this.index,
    required this.pages,
    required this.intro,
    required this.loop,
    required this.picture,
    required this.title,
    required this.body,
  });
  final int index;
  final PageController pages;
  final Animation<double> intro;
  final Animation<double> loop;
  final _Picture picture;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return LayoutBuilder(builder: (context, c) {
      final art = math.min(c.maxWidth - 48, c.maxHeight * 0.6).clamp(160.0, 380.0);
      return AnimatedBuilder(
        animation: Listenable.merge([pages, intro]),
        builder: (context, _) {
          final away = _away(pages, index);
          final t = intro.value;
          final words = Curves.easeOutCubic.transform(((t - 0.25) / 0.6).clamp(0.0, 1.0));
          return Column(children: [
            const Spacer(),
            Transform.translate(
              offset: Offset(away * c.maxWidth * 0.35, 0),
              child: Opacity(
                opacity: (1 - away.abs() * 0.8).clamp(0.0, 1.0),
                child: SizedBox.square(
                  dimension: art,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: switch (picture) {
                        _Picture.orbit => _OrbitPainter(intro, loop, p),
                        _Picture.plan => _PlanPainter(intro, loop, p, _PlanPainter.names()),
                        _Picture.anywhere => _AnywherePainter(intro, loop, p),
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Opacity(
                opacity: words,
                child: Transform.translate(
                  offset: Offset(-away * 40, 18 * (1 - words)),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(children: [
                      Text(title, textAlign: TextAlign.center, style: NType.display(30, color: p.text)),
                      const SizedBox(height: 12),
                      Text(body, textAlign: TextAlign.center, style: NType.body(16, color: p.textDim, height: 1.4)),
                    ]),
                  ),
                ),
              ),
            ),
            const Spacer(),
          ]);
        },
      );
    });
  }
}

/// The last page: a name to be greeted by, then an account or none.
class _LastPage extends StatelessWidget {
  const _LastPage({
    required this.index,
    required this.pages,
    required this.intro,
    required this.loop,
    required this.name,
    required this.busy,
    required this.accounts,
    required this.onFinish,
  });
  final int index;
  final PageController pages;
  final Animation<double> intro;
  final Animation<double> loop;
  final TextEditingController name;
  final bool busy;
  final bool accounts;
  final Future<void> Function({bool account, bool create}) onFinish;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedBuilder(
      animation: Listenable.merge([pages, intro, loop]),
      builder: (context, _) {
        final away = _away(pages, index);
        final t = intro.value;
        double rise(int i) => Curves.easeOutCubic.transform(((t - 0.1 * i) / 0.55).clamp(0.0, 1.0));
        Widget step(int i, Widget child) => Opacity(
              opacity: rise(i) * (1 - away.abs()).clamp(0.0, 1.0),
              child: Transform.translate(offset: Offset(-away * 30, 22 * (1 - rise(i))), child: child),
            );
        final breathe = (math.sin(loop.value * 2 * math.pi * 3) + 1) / 2;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                step(
                  0,
                  SizedBox(
                    width: 170,
                    height: 150,
                    child: CustomPaint(
                      painter: _RingsPainter(loop.value),
                      child: Center(
                        child: Transform.scale(
                          scale: Curves.elasticOut.transform(rise(0)),
                          child: HouseMark(size: 92, glow: 0.4 + 0.6 * breathe),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                step(1, Text('Make it yours', textAlign: TextAlign.center, style: NType.display(30, color: p.text))),
                const SizedBox(height: 10),
                step(
                  2,
                  Text('What should we call you? The home screen will greet you by name.',
                      textAlign: TextAlign.center, style: NType.body(16, color: p.textDim, height: 1.4)),
                ),
                const SizedBox(height: 22),
                step(
                  3,
                  Container(
                    decoration: BoxDecoration(
                      color: p.isDark ? const Color(0xCC1C1C1E) : const Color(0xE6FFFFFF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: p.isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      Icon(CupertinoIcons.person_crop_circle, color: p.textDim),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextField(
                          key: const Key('welcome-name'),
                          controller: name,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.givenName],
                          textInputAction: TextInputAction.done,
                          style: NType.body(17, color: p.text),
                          decoration: InputDecoration(
                            hintText: tr('Your name'),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(vertical: 18),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 26),
                if (accounts) ...[
                  step(
                    4,
                    _BigButton(
                      key: const Key('welcome-create'),
                      label: 'Create account',
                      onPressed: busy ? null : () => onFinish(account: true, create: true),
                    ),
                  ),
                  const SizedBox(height: 12),
                  step(
                    5,
                    _BigButton(
                      key: const Key('welcome-sign-in'),
                      label: 'Sign in',
                      outlined: true,
                      onPressed: busy ? null : () => onFinish(account: true),
                    ),
                  ),
                  const SizedBox(height: 6),
                  step(
                    6,
                    TextButton(
                      key: const Key('welcome-start'),
                      onPressed: busy ? null : onFinish,
                      child: const Text('Continue without an account'),
                    ),
                  ),
                ] else
                  step(4, _BigButton(key: const Key('welcome-start'), label: 'Start', onPressed: onFinish)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// A full-width round button: blue, or outlined.
class _BigButton extends StatelessWidget {
  const _BigButton({super.key, required this.label, required this.onPressed, this.outlined = false});
  final String label;
  final VoidCallback? onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: outlined
          ? OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                shape: const StadiumBorder(),
                side: BorderSide(color: p.text.withValues(alpha: 0.18)),
                backgroundColor: p.isDark ? const Color(0x661C1C1E) : const Color(0x99FFFFFF),
              ),
              child: Text(label, style: NType.body(17, color: p.text, weight: 600)),
            )
          : DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(27),
                gradient: const LinearGradient(colors: [Color(0xFF3D9BFF), KJPalette.blue]),
                boxShadow: [BoxShadow(color: KJPalette.blue.withValues(alpha: 0.28), blurRadius: 16, offset: const Offset(0, 6))],
              ),
              child: TextButton(
                onPressed: onPressed == null
                    ? null
                    : () {
                        Sounds.tap();
                        onPressed!();
                      },
                style: TextButton.styleFrom(shape: const StadiumBorder(), foregroundColor: Colors.white),
                child: Text(label, style: NType.body(17, color: Colors.white, weight: 600)),
              ),
            ),
    );
  }
}

enum _Picture { orbit, plan, anywhere }

/// Icons drawn on a canvas, laid out once per icon and colour.
final _glyphs = <(int, int, double), TextPainter>{};

void _icon(Canvas canvas, IconData icon, Offset at, double size, Color colour) {
  final key = (icon.codePoint, colour.toARGB32(), size);
  final tp = _glyphs[key] ??= (TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size, color: colour),
    ),
    textDirection: TextDirection.ltr,
  )..layout());
  tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
}

double _ease(double t, Curve c) => c.transform(t.clamp(0.0, 1.0));

/// A soft glow of [colour] around [at].
void _halo(Canvas canvas, Offset at, double r, Color colour, double strength) {
  if (strength <= 0) return;
  canvas.drawCircle(
      at,
      r,
      Paint()
        ..shader = RadialGradient(colors: [colour.withValues(alpha: strength), colour.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: at, radius: r)));
}

/// Page one: the house in the middle, the devices of every brand going round it, switching on one after another.
class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.intro, this.loop, this.p) : super(repaint: Listenable.merge([intro, loop]));
  final Animation<double> intro;
  final Animation<double> loop;
  final KJPalette p;

  static const devices = [
    (CupertinoIcons.lightbulb_fill, KJPalette.yellow),
    (CupertinoIcons.power, KJPalette.green),
    (CupertinoIcons.thermometer, KJPalette.orange),
    (CupertinoIcons.lock_fill, KJPalette.blue),
    (CupertinoIcons.videocam_fill, KJPalette.indigo),
    (CupertinoIcons.tv_fill, KJPalette.purple),
    (CupertinoIcons.speaker_2_fill, KJPalette.pink),
    (CupertinoIcons.wind, KJPalette.teal),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.38;
    final t = intro.value;
    final l = loop.value;

    // Two dotted rings.
    final ring = _ease(t / 0.4, Curves.easeOutCubic);
    for (final (k, a) in const [(1.0, 0.35), (0.62, 0.2)]) {
      final dots = (48 * k).round();
      for (var i = 0; i < dots; i++) {
        final ang = i / dots * 2 * math.pi + l * 2 * math.pi * (k == 1 ? 0.25 : -0.4);
        if (i / dots > ring) continue;
        canvas.drawCircle(c + Offset(math.cos(ang), math.sin(ang)) * r * k, 1.4,
            Paint()..color = p.text.withValues(alpha: a));
      }
    }
    _halo(canvas, c, r * 0.9, KJPalette.blue, 0.18 * ring);

    // The devices, going round, each switching on in turn.
    for (var i = 0; i < devices.length; i++) {
      final out = _ease((t - 0.15 - i * 0.06) / 0.5, Curves.elasticOut);
      if (out <= 0) continue;
      final ang = -math.pi / 2 + i * 2 * math.pi / devices.length + l * 2 * math.pi * 0.25;
      final at = c + Offset(math.cos(ang), math.sin(ang)) * r * out;
      final phase = ((l * devices.length * 2 - i) % devices.length) / devices.length;
      final on = phase < 0.45 ? _ease(phase / 0.08, Curves.easeOut) * _ease((0.45 - phase) / 0.08, Curves.easeIn) : 0.0;
      final (icon, colour) = devices[i];
      final br = size.shortestSide * 0.075 * out.clamp(0.0, 1.15);
      _halo(canvas, at, br * 2.2, colour, 0.4 * on);
      canvas.drawCircle(at, br, Paint()..color = Color.lerp(p.isDark ? const Color(0xFF2C2C2E) : Colors.white, colour, on)!);
      if (on < 1) {
        canvas.drawCircle(
            at,
            br,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = p.text.withValues(alpha: 0.08 * (1 - on)));
      }
      final s = br * 0.95;
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, 1 - on));
      _icon(canvas, icon, at, s, p.textDim);
      canvas.restore();
      if (on > 0) {
        canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, on));
        _icon(canvas, icon, at, s, Colors.white);
        canvas.restore();
      }
    }

    // The house, springing up first.
    final pop = _ease(t / 0.45, Curves.elasticOut);
    final tile = size.shortestSide * 0.27 * pop;
    if (tile > 0) {
      final glow = (math.sin(l * 2 * math.pi * 4) + 1) / 2;
      _halo(canvas, c, tile * 1.2, KJPalette.blue, 0.25);
      canvas.save();
      canvas.translate(c.dx - tile / 2, c.dy - tile / 2);
      canvas.drawShadow(
          Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & Size.square(tile), Radius.circular(tile * 0.23))),
          Colors.black,
          8,
          false);
      HouseMarkPainter(glow: 0.3 + 0.7 * glow).paint(canvas, Size.square(tile));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.p != p;
}

/// Page two: a floor plan drawing its walls, the rooms filling in, then a lamp glowing and a robot cleaning.
class _PlanPainter extends CustomPainter {
  _PlanPainter(this.intro, this.loop, this.p, this.labels) : super(repaint: Listenable.merge([intro, loop]));
  final Animation<double> intro;
  final Animation<double> loop;
  final KJPalette p;
  final List<TextPainter> labels;

  static const rooms = [
    (Rect.fromLTRB(0.06, 0.14, 0.58, 0.62), KJPalette.blue),
    (Rect.fromLTRB(0.58, 0.14, 0.94, 0.44), KJPalette.orange),
    (Rect.fromLTRB(0.58, 0.44, 0.94, 0.86), KJPalette.purple),
    (Rect.fromLTRB(0.06, 0.62, 0.32, 0.86), KJPalette.teal),
    (Rect.fromLTRB(0.32, 0.62, 0.58, 0.86), KJPalette.green),
  ];

  static List<TextPainter> names() => [
        for (final n in const ['Living room', 'Kitchen', 'Bedroom', 'Bathroom', 'Hall'])
          TextPainter(
            text: TextSpan(text: tr(n), style: NType.body(11.5, weight: 600, color: const Color(0xFF8E8E93))),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '…',
          ),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final o = Offset((size.width - s) / 2, (size.height - s) / 2);
    Offset at(double x, double y) => o + Offset(x * s, y * s);
    Rect box(Rect r) => Rect.fromPoints(at(r.left, r.top), at(r.right, r.bottom));
    final t = intro.value;
    final l = loop.value;

    // A card under the plan.
    final card = RRect.fromRectAndRadius(Rect.fromLTRB(o.dx, o.dy + s * 0.04, o.dx + s, o.dy + s * 0.96), Radius.circular(s * 0.07));
    canvas.drawShadow(Path()..addRRect(card), Colors.black.withValues(alpha: 0.5), 10, false);
    canvas.drawRRect(card, Paint()..color = p.isDark ? const Color(0xFF1C1C1E) : Colors.white);

    // Dots of the grid.
    final grid = _ease(t / 0.25, Curves.easeOut);
    for (var x = 0.1; x < 0.95; x += 0.08) {
      for (var y = 0.12; y < 0.92; y += 0.08) {
        canvas.drawCircle(at(x, y), 1, Paint()..color = p.dot.withValues(alpha: grid));
      }
    }

    for (var i = 0; i < rooms.length; i++) {
      final (r, colour) = rooms[i];
      final rect = box(r).deflate(s * 0.008);
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.025));
      final walls = _ease((t - 0.08 - i * 0.07) / 0.35, Curves.easeInOutCubic);
      final fill = _ease((t - 0.35 - i * 0.07) / 0.3, Curves.easeOut);
      if (fill > 0) canvas.drawRRect(rr, Paint()..color = colour.withValues(alpha: (p.isDark ? 0.2 : 0.12) * fill));
      if (walls > 0) {
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.011
          ..strokeCap = StrokeCap.round
          ..color = colour.withValues(alpha: 0.85);
        for (final m in (Path()..addRRect(rr)).computeMetrics()) {
          canvas.drawPath(m.extractPath(0, m.length * walls), paint);
        }
      }
      if (fill > 0) {
        final label = labels[i]..layout(maxWidth: rect.width - s * 0.05);
        canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, fill));
        label.paint(canvas, rect.topLeft + Offset(s * 0.025, s * 0.02));
        canvas.restore();
      }
    }

    // Devices pop in where they stand.
    final things = [
      (0.2, 0.32, CupertinoIcons.lightbulb_fill, KJPalette.yellow, true),
      (0.47, 0.27, CupertinoIcons.tv_fill, KJPalette.purple, false),
      (0.82, 0.3, CupertinoIcons.thermometer, KJPalette.orange, true),
      (0.8, 0.66, CupertinoIcons.bed_double_fill, KJPalette.indigo, false),
      (0.45, 0.78, CupertinoIcons.lock_fill, KJPalette.blue, true),
    ];
    for (var i = 0; i < things.length; i++) {
      final (x, y, icon, colour, lit) = things[i];
      final pop = _ease((t - 0.6 - i * 0.06) / 0.35, Curves.elasticOut);
      if (pop <= 0) continue;
      final c = at(x, y);
      final br = s * 0.045 * pop;
      if (lit) {
        final pulse = (math.sin((l * 6 + i * 0.3) * 2 * math.pi) + 1) / 2;
        _halo(canvas, c, br * (3 + pulse), colour, 0.35 + 0.15 * pulse);
      }
      canvas.drawCircle(c, br, Paint()..color = lit ? colour : (p.isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA)));
      _icon(canvas, icon, c, br * 1.1, lit ? Colors.white : p.textDim);
    }

    // A robot cleaning the living room, leaving a fading trail.
    final robot = _ease((t - 0.85) / 0.15, Curves.easeOut);
    if (robot > 0) {
      Offset path(double k) => at(0.32 + 0.19 * math.sin(k * 2 * math.pi * 2), 0.42 + 0.13 * math.sin(k * 2 * math.pi * 3 + 0.6));
      for (var j = 14; j >= 1; j--) {
        canvas.drawCircle(path(l - j * 0.004), s * 0.012, Paint()..color = KJPalette.green.withValues(alpha: 0.18 * robot * (1 - j / 15)));
      }
      final c = path(l);
      canvas.drawCircle(c, s * 0.03, Paint()..color = p.isDark ? const Color(0xFFE5E5EA) : const Color(0xFF3A3A3C));
      canvas.drawCircle(c, s * 0.03, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.006
        ..color = KJPalette.green.withValues(alpha: robot));
      canvas.drawCircle(c + Offset(0, -s * 0.012), s * 0.006, Paint()..color = KJPalette.green);
    }
  }

  @override
  bool shouldRepaint(_PlanPainter old) => old.p != p;
}

/// Page three: a phone sends a switch across the world to the house, whose door lights up as each one lands.
class _AnywherePainter extends CustomPainter {
  _AnywherePainter(this.intro, this.loop, this.p) : super(repaint: Listenable.merge([intro, loop]));
  final Animation<double> intro;
  final Animation<double> loop;
  final KJPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final o = Offset((size.width - s) / 2, (size.height - s) / 2);
    final t = intro.value;
    final l = loop.value;
    final slide = _ease(t / 0.5, Curves.easeOutCubic);

    final phone = Rect.fromCenter(center: o + Offset(s * (0.2 - 0.3 * (1 - slide)), s * 0.64), width: s * 0.22, height: s * 0.4);
    final houseAt = o + Offset(s * (0.8 + 0.3 * (1 - slide)), s * 0.66);
    final tile = s * 0.26;
    final cloud = o + Offset(s * 0.5, s * 0.2);

    // The way between them, over the cloud.
    final route = Path()
      ..moveTo(phone.topCenter.dx, phone.top - s * 0.02)
      ..quadraticBezierTo(cloud.dx - s * 0.28, cloud.dy - s * 0.04, cloud.dx, cloud.dy)
      ..quadraticBezierTo(cloud.dx + s * 0.28, cloud.dy - s * 0.04, houseAt.dx, houseAt.dy - tile / 2 - s * 0.03);
    final metric = route.computeMetrics().first;
    final drawn = _ease((t - 0.3) / 0.45, Curves.easeInOutCubic);
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.008
      ..strokeCap = StrokeCap.round
      ..color = p.text.withValues(alpha: 0.18);
    for (var d = 0.0; d < metric.length * drawn; d += s * 0.04) {
      canvas.drawPath(metric.extractPath(d, math.min(d + s * 0.018, metric.length * drawn)), dash);
    }

    // Switches travelling along it; each lights the house as it lands.
    var lit = 0.0;
    if (drawn >= 1) {
      for (var k = 0; k < 3; k++) {
        final f = (l * 4 + k / 3) % 1;
        final pos = metric.getTangentForOffset(metric.length * Curves.easeInOutSine.transform(f))!.position;
        for (var j = 1; j <= 6; j++) {
          final back = (f - j * 0.012).clamp(0.0, 1.0);
          final q = metric.getTangentForOffset(metric.length * Curves.easeInOutSine.transform(back))!.position;
          canvas.drawCircle(q, s * 0.012 * (1 - j / 7), Paint()..color = KJPalette.blue.withValues(alpha: 0.25 * (1 - j / 7)));
        }
        _halo(canvas, pos, s * 0.05, KJPalette.blue, 0.35);
        canvas.drawCircle(pos, s * 0.015, Paint()..color = KJPalette.blue);
        if (f > 0.85) lit = math.max(lit, 1 - (f - 0.85) / 0.15);
        if (f < 0.25) lit = math.max(lit, 0.6 * (1 - f / 0.25));
      }
    }

    // The cloud in the middle.
    final cloudIn = _ease((t - 0.35) / 0.4, Curves.elasticOut);
    if (cloudIn > 0) {
      final r = s * 0.085 * cloudIn;
      _halo(canvas, cloud, r * 2.2, KJPalette.teal, 0.3);
      canvas.drawCircle(cloud, r, Paint()..color = p.isDark ? const Color(0xFF2C2C2E) : Colors.white);
      canvas.drawCircle(cloud, r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = p.text.withValues(alpha: 0.08));
      _icon(canvas, CupertinoIcons.globe, cloud, r * 1.15, KJPalette.blue);
    }

    // The phone, with a switch on its screen.
    final pr = RRect.fromRectAndRadius(phone, Radius.circular(s * 0.04));
    canvas.drawShadow(Path()..addRRect(pr), Colors.black.withValues(alpha: 0.6), 8, false);
    canvas.drawRRect(pr, Paint()..color = p.isDark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E));
    final screen = RRect.fromRectAndRadius(phone.deflate(s * 0.012), Radius.circular(s * 0.03));
    canvas.drawRRect(screen, Paint()..color = p.isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7));
    final on = (l * 4 % 1) < 0.5;
    final pill = RRect.fromRectAndRadius(
        Rect.fromCenter(center: phone.center + Offset(0, s * 0.02), width: s * 0.11, height: s * 0.062), Radius.circular(s * 0.031));
    canvas.drawRRect(pill, Paint()..color = on ? KJPalette.green : p.surfaceHigh);
    canvas.drawCircle(
        Offset(on ? pill.right - pill.height / 2 : pill.left + pill.height / 2, pill.center.dy), s * 0.026, Paint()..color = Colors.white);
    _icon(canvas, CupertinoIcons.lightbulb_fill, phone.center - Offset(0, s * 0.08), s * 0.05, on ? KJPalette.yellow : p.textDim);

    // The house.
    _halo(canvas, houseAt, tile * 1.3, const Color(0xFFFFD60A), 0.45 * lit);
    canvas.save();
    canvas.translate(houseAt.dx - tile / 2, houseAt.dy - tile / 2);
    canvas.drawShadow(
        Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & Size.square(tile), Radius.circular(tile * 0.23))), Colors.black, 8, false);
    HouseMarkPainter(glow: lit).paint(canvas, Size.square(tile));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AnywherePainter old) => old.p != p;
}

/// Rings rippling out from the house on the last page.
class _RingsPainter extends CustomPainter {
  _RingsPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final k = (t * 4 + i / 3) % 1;
      canvas.drawCircle(
          c,
          50 + k * 40,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = KJPalette.blue.withValues(alpha: 0.35 * (1 - k)));
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.t != t;
}
