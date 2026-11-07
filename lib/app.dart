import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'cloud/cloud_sync.dart';
import 'state/app_settings.dart';
import 'state/backup_files.dart';
import 'state/history.dart';
import 'state/home_store.dart';
import 'state/updates.dart';
import 'theme/app_theme.dart';
import 'ui/screens/connect_screen.dart';
import 'ui/screens/devices_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/nav.dart';
import 'ui/screens/map_screen.dart';
import 'ui/screens/welcome_screen.dart';
import 'ui/widgets/kj_widgets.dart';
import 'ui/widgets/launch_curtain.dart';
import 'ui/widgets/motion.dart';
import 'util/sounds.dart';
import 'l10n/text.dart';

class SmartMenuApp extends StatelessWidget {
  SmartMenuApp(
      {super.key,
      required this.store,
      CloudSync? cloud,
      AppSettings? settings,
      BackupFiles? backups,
      UpdateCheck? updates,
      this.poll = true,
      this.intro = false})
      : cloud = cloud ?? CloudSync.disabled(store),
        settings = settings ?? AppSettings(),
        backups = backups ?? BackupFiles(),
        updates = updates ?? UpdateCheck.off(),
        history = store.history ?? _memoryHistory(store);
  final HomeStore store;
  final HomeHistory history;
  final UpdateCheck updates;

  /// A home opened without one (as in tests) keeps its history in memory.
  static HomeHistory _memoryHistory(HomeStore store) {
    final h = HomeHistory(storage: MemoryHistoryStorage(), saveAfter: Duration.zero);
    unawaited(store.keepHistory(h));
    return h;
  }

  final CloudSync cloud;
  final AppSettings settings;
  final BackupFiles backups;
  final bool poll;

  /// The opening animation, and the welcome screens on a new install. Off in tests.
  final bool intro;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: cloud),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: backups),
        ChangeNotifierProvider.value(value: history),
        ChangeNotifierProvider.value(value: updates),
        ChangeNotifierProvider.value(value: store.weather),
        ChangeNotifierProvider(create: (_) => AppNav()),
      ],
      child: Consumer2<HomeStore, AppSettings>(
        builder: (context, store, settings, _) => L10nScope(
          code: L10n.code,
          child: MaterialApp(
            title: 'SmartHomeKJ',
            debugShowCheckedModeBanner: false,
            locale: Locale(L10n.code),
            supportedLocales: const [Locale('en'), Locale('bg')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            scrollBehavior: const _AppleScroll(),
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: switch (store.themeMode) {
              'dark' => ThemeMode.dark,
              'system' => ThemeMode.system,
              _ => ThemeMode.light,
            },
            builder: intro ? (context, child) => LaunchCurtain(child: child!) : null,
            home: _Start(intro: intro, poll: poll, initialTab: settings.startTab),
          ),
        ),
      ),
    );
  }
}

/// The welcome screens the first time, then the app, which zooms in as they go.
class _Start extends StatelessWidget {
  const _Start({required this.intro, required this.poll, required this.initialTab});
  final bool intro;
  final bool poll;
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    final welcome = intro && !context.select<AppSettings, bool>((s) => s.welcomed);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: child),
      ),
      child: welcome
          ? WelcomeScreen(key: const ValueKey('start-welcome'), onDone: () => context.read<AppSettings>().welcomed = true)
          : AppShell(key: const ValueKey('start-app'), poll: poll, initialTab: initialTab),
    );
  }
}

/// iOS scrolling everywhere: lists stretch and bounce back at their ends.
class _AppleScroll extends MaterialScrollBehavior {
  const _AppleScroll();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

class _Tab {
  const _Tab(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const _tabs = [
  _Tab('Home', CupertinoIcons.house, CupertinoIcons.house_fill),
  _Tab('Map', CupertinoIcons.square_grid_2x2, CupertinoIcons.square_grid_2x2_fill),
  _Tab('Devices', CupertinoIcons.lightbulb, CupertinoIcons.lightbulb_fill),
  _Tab('Connect', CupertinoIcons.antenna_radiowaves_left_right, CupertinoIcons.antenna_radiowaves_left_right),
];

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.poll = true, this.initialTab = 0});
  final bool poll;
  final int initialTab;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  var _mapKey = GlobalKey<MapScreenState>();
  String? _homeId;

  HomeStore get _store => context.read<HomeStore>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialTab != 0) context.read<AppNav>().tab = widget.initialTab;
    if (widget.poll) WidgetsBinding.instance.addPostFrameCallback((_) => _store.startPolling());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.poll) return;
    final cloud = context.read<CloudSync>();
    if (state == AppLifecycleState.resumed) {
      _store.startPolling();
      cloud.resumed();
      unawaited(context.read<UpdateCheck>().check());
    } else if (state == AppLifecycleState.paused) {
      // A device keeping the home online goes on watching its devices in the background.
      if (!cloud.isHub) _store.stopPolling();
      _store.saveNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final nav = context.watch<AppNav>();
    // Another home opened: every screen starts over, so none holds on to the old home's floors or rooms.
    final homeId = context.select<HomeStore, String>((s) => s.homeId);
    if (homeId != _homeId) {
      if (_homeId != null) _mapKey = GlobalKey<MapScreenState>();
      _homeId = homeId;
    }
    if (nav.hasMapRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final r = nav.takeMapRequest();
        if (r != null) _mapKey.currentState?.show(edit: r.edit, roomId: r.roomId);
      });
    }
    final pages = [
      const HomeScreen(),
      MapScreen(key: _mapKey),
      DevicesScreen(onOpenConnect: () => nav.go(AppNav.connect)),
      const ConnectScreen(),
    ];
    final body = ToastListener(
      message: context.read<HomeStore>().message,
      child: KeyedSubtree(
          key: ValueKey(homeId), child: _TabFade(index: nav.tab, child: IndexedStack(index: nav.tab, children: pages))),
    );

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 840;
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Row(children: [
              Container(
                width: 92,
                decoration: BoxDecoration(
                    color: p.isDark ? p.surface : Colors.white,
                    border: Border(right: BorderSide(color: p.border, width: 0.5))),
                child: Column(children: [
                  const SizedBox(height: 22),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF4DA3FF), Color(0xFF007AFF)]),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(CupertinoIcons.house_fill, color: Colors.white, size: 24),
                  ),
                  const SizedBox(height: 6),
                  const DisplayText('KJ', size: 15),
                  const SizedBox(height: 22),
                  for (var i = 0; i < _tabs.length; i++)
                    _RailItem(tab: _tabs[i], selected: i == nav.tab, onTap: () => nav.go(i)),
                ]),
              ),
              Expanded(child: body),
            ]),
          ),
        );
      }
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: _BottomBar(selected: nav.tab, onTap: nav.go),
      );
    });
  }
}

/// The tab just opened fades and settles in.
class _TabFade extends StatefulWidget {
  const _TabFade({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_TabFade> createState() => _TabFadeState();
}

class _TabFadeState extends State<_TabFade> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 280), value: 1);

  @override
  void didUpdateWidget(_TabFade old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && Motion.on(context)) _c.forward(from: 0);
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
          final t = Curves.easeOutCubic.transform(_c.value);
          if (t >= 1) return child!;
          return Opacity(
            opacity: 0.35 + 0.65 * t,
            child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
          );
        },
      );
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.tab, required this.selected, required this.onTap});
  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(children: [
          Icon(selected ? tab.activeIcon : tab.icon, color: selected ? KJPalette.accent : p.textDim),
          const SizedBox(height: 6),
          Text(tab.label,
              style: NType.body(11, color: selected ? KJPalette.accent : p.textDim, weight: selected ? 600 : 500)),
        ]),
      ),
    );
  }
}

/// The iOS tab bar: frosted, a hairline on top, filled icons for the open tab.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.selected, required this.onTap});
  final int selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
              color: p.isDark ? const Color(0xE6161618) : const Color(0xF2FFFFFF),
              border: Border(top: BorderSide(color: p.isDark ? const Color(0x33FFFFFF) : const Color(0x4D000000), width: 0.33))),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 56,
              child: Row(children: [
                for (var i = 0; i < _tabs.length; i++)
                  Expanded(
                    child: GestureDetector(
                      key: Key('tab-${_tabs[i].label.toLowerCase()}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (i != selected) Sounds.tick();
                        onTap(i);
                      },
                      child: Semantics(
                        button: true,
                        selected: i == selected,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          AnimatedScale(
                            scale: i == selected ? 1.08 : 1,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutBack,
                            child: Icon(i == selected ? _tabs[i].activeIcon : _tabs[i].icon,
                                size: 25, color: i == selected ? KJPalette.accent : const Color(0xFF8E8E93)),
                          ),
                          const SizedBox(height: 3),
                          Text(_tabs[i].label,
                              style: NType.body(10.5,
                                  color: i == selected ? KJPalette.accent : const Color(0xFF8E8E93), weight: 500)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
