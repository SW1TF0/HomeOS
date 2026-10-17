import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'cloud/cloud_sync.dart';
import 'state/app_settings.dart';
import 'state/backup_files.dart';
import 'state/home_store.dart';
import 'theme/nothing_theme.dart';
import 'ui/screens/connect_screen.dart';
import 'ui/screens/devices_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/nav.dart';
import 'ui/screens/map_screen.dart';
import 'ui/widgets/nothing_widgets.dart';

class SmartMenuApp extends StatelessWidget {
  SmartMenuApp(
      {super.key, required this.store, CloudSync? cloud, AppSettings? settings, BackupFiles? backups, this.poll = true})
      : cloud = cloud ?? CloudSync.disabled(store),
        settings = settings ?? AppSettings(),
        backups = backups ?? BackupFiles();
  final HomeStore store;
  final CloudSync cloud;
  final AppSettings settings;
  final BackupFiles backups;
  final bool poll;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: cloud),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: backups),
        ChangeNotifierProvider(create: (_) => AppNav()),
      ],
      child: Consumer<HomeStore>(
        builder: (context, store, _) => MaterialApp(
          title: 'SmartMenuKJ',
          debugShowCheckedModeBanner: false,
          theme: buildNothingTheme(Brightness.light),
          darkTheme: buildNothingTheme(Brightness.dark),
          themeMode: switch (store.themeMode) {
            'light' => ThemeMode.light,
            'system' => ThemeMode.system,
            _ => ThemeMode.dark,
          },
          home: AppShell(poll: poll, initialTab: settings.startTab),
        ),
      ),
    );
  }
}

class _Tab {
  const _Tab(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const _tabs = [
  _Tab('Home', Icons.circle_outlined, Icons.circle),
  _Tab('Map', Icons.grid_view_outlined, Icons.grid_view_rounded),
  _Tab('Devices', Icons.lightbulb_outline, Icons.lightbulb),
  _Tab('Connect', Icons.wifi_tethering, Icons.wifi_tethering),
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
      child: KeyedSubtree(key: ValueKey(homeId), child: IndexedStack(index: nav.tab, children: pages)),
    );

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 840;
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Row(children: [
              Container(
                width: 92,
                decoration: BoxDecoration(border: Border(right: BorderSide(color: p.border))),
                child: Column(children: [
                  const SizedBox(height: 22),
                  const DotText('KJ', size: 30),
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(color: NothingPalette.red, shape: BoxShape.circle),
                  ),
                  const SizedBox(height: 28),
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

class _RailItem extends StatelessWidget {
  const _RailItem({required this.tab, required this.selected, required this.onTap});
  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(children: [
          Icon(selected ? tab.activeIcon : tab.icon, color: selected ? p.text : p.textDim),
          const SizedBox(height: 6),
          Text(tab.label.toUpperCase(), style: NType.label(color: selected ? p.text : p.textDim).copyWith(fontSize: 10)),
        ]),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.selected, required this.onTap});
  final int selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(color: p.background, border: Border(top: BorderSide(color: p.border))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: InkWell(
                  key: Key('tab-${_tabs[i].label.toLowerCase()}'),
                  onTap: () => onTap(i),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(i == selected ? _tabs[i].activeIcon : _tabs[i].icon,
                        size: 22, color: i == selected ? p.text : p.textDim),
                    const SizedBox(height: 4),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (i == selected)
                        Container(
                          margin: const EdgeInsets.only(right: 5),
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(color: NothingPalette.red, shape: BoxShape.circle),
                        ),
                      Text(_tabs[i].label.toUpperCase(),
                          style: NType.label(color: i == selected ? p.text : p.textDim).copyWith(fontSize: 10)),
                    ]),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
