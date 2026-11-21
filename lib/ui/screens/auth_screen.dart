import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../cloud/cloud_sync.dart';
import '../../cloud/firebase.dart';
import '../../l10n/text.dart';
import '../../state/app_settings.dart';
import '../../theme/app_theme.dart';
import '../../util/haptics.dart';
import '../../util/sounds.dart';
import '../widgets/motion.dart';

/// Opens the sign-in screen, on [create] to make an account. True once signed in.
Future<bool> openAuth(BuildContext context, {bool create = false, String name = ''}) async =>
    await Navigator.of(context).push<bool>(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => AuthScreen(create: create, name: name),
      transitionsBuilder: (_, a, _, child) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: t,
          child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(t), child: child),
        );
      },
    )) ??
    false;

/// Signing in and making an account, on a screen of its own: the house mark glowing over slow colour,
/// Sign in and Create account side by side, a meter for the password, and a tick drawn on success.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.create = false, this.name = ''});
  final bool create;
  final String name;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  late bool _create = widget.create;
  late final _name = TextEditingController(text: widget.name);
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _hide = true;
  bool _working = false;
  String? _error;
  String? _note;
  int _shakes = 0;
  bool _done = false;
  late final _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  late final _tick = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  bool _motion = false;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = Motion.on(context);
    if (_motion && !_glow.isAnimating) _glow.repeat(reverse: true);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    _glow.dispose();
    _tick.dispose();
    super.dispose();
  }

  void _refuse(String message) {
    setState(() {
      _error = message;
      _shakes++;
    });
    Haptics.mediumImpact();
  }

  Future<void> _submit() async {
    final cloud = context.read<CloudSync>();
    final settings = context.read<AppSettings>();
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) return _refuse('That is not an email address.');
    if (_password.text.length < 6) return _refuse('Use a password of at least 6 characters.');
    FocusScope.of(context).unfocus();
    setState(() {
      _working = true;
      _error = null;
      _note = null;
    });
    try {
      await cloud.signIn(email, _password.text, create: _create, name: _create ? _name.text : '');
    } on CloudException catch (e) {
      if (mounted) setState(() => _working = false);
      return _refuse(e.message);
    } catch (e) {
      if (mounted) setState(() => _working = false);
      return _refuse('$e');
    }
    // The name typed here, or the one the account was given on another device.
    final given = _create ? _name.text.trim() : (cloud.account?.name ?? '');
    if (given.isNotEmpty && (_create || settings.name.isEmpty)) settings.name = given;
    if (!mounted) return;
    Sounds.scene();
    Haptics.mediumImpact();
    setState(() {
      _working = false;
      _done = true;
    });
    if (_motion) {
      await _tick.forward();
      await Future<void>.delayed(const Duration(milliseconds: 900));
    } else {
      _tick.value = 1;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _forgot() async {
    final cloud = context.read<CloudSync>();
    if (!_email.text.contains('@')) return _refuse('Type your email first.');
    setState(() {
      _working = true;
      _error = null;
      _note = null;
    });
    try {
      await cloud.resetPassword(_email.text);
      _note = 'Check your email for a link to set a new password.';
    } on CloudException catch (e) {
      _error = e.message;
      _shakes++;
    }
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = context.watch<AppSettings>();
    return Scaffold(
      body: Aurora(
        child: Stack(children: [
          SafeArea(
            child: Column(children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: IconButton(
                    key: const Key('auth-close'),
                    tooltip: tr('Close'),
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: Icon(CupertinoIcons.xmark, color: p.textDim),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(children: [
                        Entrance(index: 0, child: _GlowingMark(glow: _glow)),
                        const SizedBox(height: 22),
                        Entrance(
                          index: 1,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 280),
                            transitionBuilder: _slideFade,
                            child: Text(
                              _create ? 'Create your account' : 'Welcome back',
                              key: ValueKey(_create),
                              textAlign: TextAlign.center,
                              style: NType.display(30, color: p.text),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Entrance(
                          index: 2,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 280),
                            transitionBuilder: _slideFade,
                            child: Text(
                              _create
                                  ? 'Free. Your homes on every phone and computer, and control from anywhere.'
                                  : 'Sign in to bring your homes to this device.',
                              key: ValueKey('s$_create'),
                              textAlign: TextAlign.center,
                              style: NType.body(15, color: p.textDim),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Entrance(
                          index: 3,
                          child: SizedBox(
                            width: double.infinity,
                            child: CupertinoSlidingSegmentedControl<bool>(
                              groupValue: _create,
                              onValueChanged: (v) {
                                if (v == null || v == _create || _working) return;
                                Sounds.tick();
                                setState(() {
                                  _create = v;
                                  _error = null;
                                  _note = null;
                                });
                              },
                              children: {
                                false: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Text('Sign in', key: const Key('auth-mode-signin'), style: NType.body(14, weight: 600)),
                                ),
                                true: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Text('Create account',
                                      key: const Key('auth-mode-create'), style: NType.body(14, weight: 600)),
                                ),
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Entrance(
                          index: 4,
                          child: Shake(
                            trigger: _shakes,
                            child: _Card(
                              child: AnimatedSize(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.topCenter,
                                child: AutofillGroup(
                                  child: Column(children: [
                                    if (_create) ...[
                                      _Field(
                                        key: const Key('auth-name'),
                                        controller: _name,
                                        icon: CupertinoIcons.person,
                                        label: 'Your name',
                                        hints: const [AutofillHints.name],
                                        capital: true,
                                      ),
                                      const _Line(),
                                    ],
                                    _Field(
                                      key: const Key('account-email'),
                                      controller: _email,
                                      icon: CupertinoIcons.mail,
                                      label: 'Email',
                                      keyboard: TextInputType.emailAddress,
                                      hints: const [AutofillHints.email],
                                      next: () => _passwordFocus.requestFocus(),
                                    ),
                                    const _Line(),
                                    _Field(
                                      key: const Key('account-password'),
                                      controller: _password,
                                      focus: _passwordFocus,
                                      icon: CupertinoIcons.lock,
                                      label: 'Password',
                                      secret: _hide,
                                      hints: [_create ? AutofillHints.newPassword : AutofillHints.password],
                                      done: _working ? null : _submit,
                                      trailing: IconButton(
                                        key: const Key('auth-show-password'),
                                        tooltip: tr(_hide ? 'Show password' : 'Hide password'),
                                        onPressed: () => setState(() => _hide = !_hide),
                                        icon: Icon(_hide ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                                            size: 20, color: p.textDim),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          child: Column(children: [
                            if (_create) ...[
                              const SizedBox(height: 12),
                              _Strength(password: _password.text),
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Row(children: [
                                const Icon(CupertinoIcons.exclamationmark_circle_fill, size: 18, color: KJPalette.danger),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(_error!,
                                      key: const Key('account-error'),
                                      style: NType.body(14, color: KJPalette.danger, weight: 500)),
                                ),
                              ]),
                            ],
                            if (_note != null) ...[
                              const SizedBox(height: 12),
                              Row(children: [
                                const Icon(CupertinoIcons.envelope_badge_fill, size: 18, color: KJPalette.accent),
                                const SizedBox(width: 8),
                                Expanded(child: Text(_note!, key: const Key('auth-note'), style: NType.body(14, color: p.text))),
                              ]),
                            ],
                          ]),
                        ),
                        const SizedBox(height: 20),
                        Entrance(
                          index: 5,
                          child: _SubmitButton(
                            label: _create ? 'Create account' : 'Sign in',
                            working: _working,
                            onPressed: _working ? null : _submit,
                          ),
                        ),
                        const SizedBox(height: 6),
                        AnimatedOpacity(
                          opacity: _create ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          child: TextButton(
                            key: const Key('auth-forgot'),
                            onPressed: _create || _working ? null : _forgot,
                            child: const Text('Forgot password?'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('Without an account everything still works on your Wi-Fi.',
                            textAlign: TextAlign.center, style: NType.body(13, color: p.textDim)),
                      ]),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          if (_done) _Success(tick: _tick, name: settings.name, created: _create, email: _email.text.trim()),
        ]),
      ),
    );
  }

  static Widget _slideFade(Widget child, Animation<double> a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
      );
}

/// The house mark with a soft blue light breathing behind it.
class _GlowingMark extends StatelessWidget {
  const _GlowingMark({required this.glow});
  final Animation<double> glow;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: glow,
        builder: (context, _) {
          final g = Curves.easeInOut.transform(glow.value);
          return SizedBox(
            width: 150,
            height: 120,
            child: Stack(alignment: Alignment.center, children: [
              Container(
                width: 120 + 16 * g,
                height: 120 + 16 * g,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    KJPalette.blue.withValues(alpha: 0.32 + 0.12 * g),
                    KJPalette.blue.withValues(alpha: 0),
                  ]),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(19),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 8))],
                ),
                child: HouseMark(size: 80, glow: 0.35 + 0.65 * g),
              ),
            ]),
          );
        },
      );
}

/// Frosted card the fields sit on.
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.isDark ? const Color(0xCC1C1C1E) : const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000)),
        boxShadow: p.isDark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: child,
    );
  }
}

class _Line extends StatelessWidget {
  const _Line();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 52),
        child: Divider(height: 1, thickness: 0.5, color: context.palette.border),
      );
}

/// One row of the card: an icon, the text, maybe a button at the end.
class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.icon,
    required this.label,
    this.focus,
    this.keyboard,
    this.hints = const [],
    this.secret = false,
    this.capital = false,
    this.trailing,
    this.next,
    this.done,
  });
  final TextEditingController controller;
  final FocusNode? focus;
  final IconData icon;
  final String label;
  final TextInputType? keyboard;
  final List<String> hints;
  final bool secret;
  final bool capital;
  final Widget? trailing;
  final VoidCallback? next;
  final VoidCallback? done;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Icon(icon, size: 20, color: p.textDim),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focus,
            keyboardType: keyboard,
            obscureText: secret,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: capital ? TextCapitalization.words : TextCapitalization.none,
            autofillHints: hints,
            textInputAction: done != null ? TextInputAction.done : TextInputAction.next,
            onSubmitted: (_) => done != null ? done!() : next?.call(),
            style: NType.body(16, color: p.text),
            decoration: InputDecoration(
              hintText: tr(label),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: const EdgeInsets.symmetric(vertical: 17),
            ),
          ),
        ),
        ?trailing,
      ]),
    );
  }
}

/// How strong a new password is, as four bars that fill and change colour.
class _Strength extends StatelessWidget {
  const _Strength({required this.password});
  final String password;

  /// 0 too short, 1 weak, 2 fair, 3 good, 4 strong: longer, and more kinds of character, is stronger.
  static int score(String s) {
    if (s.length < 6) return 0;
    final kinds = [RegExp(r'[a-z]'), RegExp(r'[A-Z]'), RegExp(r'\d'), RegExp(r'[^A-Za-z0-9]')]
        .where((r) => r.hasMatch(s))
        .length;
    if (s.length >= 16 || (s.length >= 12 && kinds >= 3)) return 4;
    if (s.length >= 10 && kinds >= 3) return 3;
    if (s.length >= 8 && kinds >= 2) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final n = score(password);
    final (label, colour) = switch (n) {
      0 => (password.isEmpty ? 'At least 6 characters' : 'Too short', KJPalette.danger),
      1 => ('Weak', KJPalette.orange),
      2 => ('Fair', KJPalette.yellow),
      3 => ('Good', KJPalette.green),
      _ => ('Strong', KJPalette.green),
    };
    return Row(key: const Key('auth-strength'), children: [
      for (var i = 0; i < 4; i++) ...[
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            height: 5,
            decoration: BoxDecoration(
              color: i < n || (n == 0 && i == 0 && password.isNotEmpty) ? colour : p.surfaceHigh,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        const SizedBox(width: 6),
      ],
      const SizedBox(width: 4),
      SizedBox(
        width: 150,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(n == 0 ? label : tc(label, 'password'),
              key: ValueKey(label),
              textAlign: TextAlign.end,
              style: NType.body(12.5, color: password.isEmpty ? p.textDim : colour, weight: 600)),
        ),
      ),
    ]);
  }
}

/// A wide blue button that folds into a spinning circle while it works.
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.label, required this.working, required this.onPressed});
  final String label;
  final bool working;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => Center(
          child: GestureDetector(
            key: const Key('auth-submit'),
            onTap: onPressed == null
                ? null
                : () {
                    Sounds.tap();
                    onPressed!();
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              width: working ? 54 : c.maxWidth,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(27),
                gradient: const LinearGradient(colors: [Color(0xFF3D9BFF), KJPalette.blue]),
                boxShadow: [BoxShadow(color: KJPalette.blue.withValues(alpha: 0.28), blurRadius: 16, offset: const Offset(0, 6))],
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: working
                    ? const SizedBox.square(
                        key: ValueKey('spin'),
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                      )
                    : Text(label,
                        key: ValueKey(label),
                        maxLines: 1,
                        style: NType.body(17, color: Colors.white, weight: 600)),
              ),
            ),
          ),
        ),
      );
}

/// Over the screen once signed in: a circle springs up and a tick draws itself, with a welcome.
class _Success extends StatelessWidget {
  const _Success({required this.tick, required this.name, required this.created, required this.email});
  final Animation<double> tick;
  final String name;
  final bool created;
  final String email;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final first = name.split(' ').first;
    return AnimatedBuilder(
      key: const Key('auth-success'),
      animation: tick,
      builder: (context, _) {
        final t = tick.value;
        final pop = Curves.elasticOut.transform((t / 0.7).clamp(0.0, 1.0));
        final stroke = Curves.easeOutCubic.transform(((t - 0.25) / 0.5).clamp(0.0, 1.0));
        final words = Curves.easeOut.transform(((t - 0.35) / 0.5).clamp(0.0, 1.0));
        final veil = Curves.easeOut.transform((t / 0.25).clamp(0.0, 1.0));
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18 * veil, sigmaY: 18 * veil),
          child: Container(
            color: p.background.withValues(alpha: 0.94 * veil),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Transform.scale(
                scale: pop,
                child: Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: KJPalette.green,
                    boxShadow: [BoxShadow(color: KJPalette.green.withValues(alpha: 0.4), blurRadius: 30, offset: const Offset(0, 10))],
                  ),
                  child: CustomPaint(painter: _TickPainter(stroke)),
                ),
              ),
              const SizedBox(height: 24),
              Opacity(
                opacity: words,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - words)),
                  child: Column(children: [
                    Text(
                      first.isEmpty ? (created ? 'Welcome!' : 'Welcome back!') : (created ? 'Welcome, $first!' : 'Welcome back, $first!'),
                      key: const Key('auth-welcome'),
                      textAlign: TextAlign.center,
                      style: NType.display(28, color: p.text),
                    ),
                    if (created) ...[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text('We sent a link to $email to confirm it.',
                            textAlign: TextAlign.center, style: NType.body(15, color: p.textDim)),
                      ),
                    ],
                  ]),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final path = Path()
      ..moveTo(size.width * 0.29, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.66)
      ..lineTo(size.width * 0.72, size.height * 0.37);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t), paint);
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.t != t;
}

/// For tests: what [_Strength] makes of a password, 0 (too short) to 4.
int passwordStrength(String s) => _Strength.score(s);
