import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../cloud/cloud_sync.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../util/app_log.dart';
import '../../util/text.dart';
import '../widgets/kj_widgets.dart';
import 'account_sheet.dart';
import 'activity_sheet.dart';
import 'connect_screen.dart';
import 'devices_screen.dart';
import 'diagnostics_screen.dart';
import 'help_sheet.dart';
import 'homes_sheet.dart';
import 'profile_menu.dart';
import 'settings_screen.dart';
import 'weather_sheet.dart';
import '../../l10n/text.dart';

/// Opens the list of every device, with search, as a page.
Future<void> openDevices(BuildContext context) =>
    pushTabPage(context, DevicesScreen(onOpenConnect: () => openConnect(context)), backKey: const Key('devices-back'));

/// Opens adding devices and connections as a page.
Future<void> openConnect(BuildContext context) =>
    pushTabPage(context, const ConnectScreen(), backKey: const Key('connect-back'));

/// The More tab: everything that is not used every day, as one plain list.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final cloud = context.watch<CloudSync>();
    final log = context.watch<AppLog>();
    final p = context.palette;
    final offline = store.devices.where((d) => !d.state.reachable).length;
    final failed = store.integrations.where((c) => store.status[c.id]?.ok == false).length;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const Key('more-list'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            const Row(children: [Expanded(child: DisplayText('More', size: 34)), ProfileButton()]),
            const SectionLabel('Devices'),
            _Group(children: [
              _Row(
                key: const Key('more-connect'),
                icon: CupertinoIcons.add_circled_solid,
                color: KJPalette.accent,
                title: 'Add devices',
                subtitle: 'Scan your Wi-Fi, add a camera, Matter, hubs and more',
                onTap: () => openConnect(context),
              ),
              _Row(
                key: const Key('more-devices'),
                icon: CupertinoIcons.lightbulb_fill,
                color: KJPalette.yellow,
                title: 'All devices',
                subtitle: [
                  counted(store.devices.length, 'device'),
                  counted(store.integrations.length, 'connection'),
                  if (offline > 0) '$offline not responding',
                ].join(' · '),
                warn: offline > 0,
                onTap: () => openDevices(context),
              ),
              _Row(
                key: const Key('more-activity'),
                icon: CupertinoIcons.clock_fill,
                color: KJPalette.indigo,
                title: 'Activity',
                subtitle: 'What switched on and off, and when',
                onTap: () => showActivitySheet(context),
              ),
            ]),
            const SectionLabel('Home'),
            _Group(children: [
              _Row(
                key: const Key('more-homes'),
                icon: CupertinoIcons.house_fill,
                color: KJPalette.orange,
                title: 'Homes',
                subtitle: store.homes.length > 1 ? '${store.homes.length} homes · ${store.homeName} is open' : store.homeName,
                onTap: () => showHomesSheet(context),
              ),
              _Row(
                key: const Key('more-weather'),
                icon: CupertinoIcons.cloud_sun_fill,
                color: KJPalette.teal,
                title: 'Weather',
                subtitle: store.data.place?.name ?? 'Add your town',
                onTap: () => showWeatherSheet(context),
              ),
              _Row(
                key: const Key('more-account'),
                icon: CupertinoIcons.person_crop_circle_fill,
                color: KJPalette.green,
                title: 'Account',
                subtitle: cloud.signedIn ? cloud.account!.email : 'Optional: keep your homes on every device',
                warn: cloud.signedIn && cloud.problem != null,
                onTap: () => showAccountSheet(context),
              ),
            ]),
            const SectionLabel('App'),
            _Group(children: [
              _Row(
                key: const Key('more-settings'),
                icon: CupertinoIcons.gear_solid,
                color: const Color(0xFF8E8E93),
                title: 'Settings',
                subtitle: 'Theme, language, clock, backups',
                onTap: () => openSettings(context),
              ),
              _Row(
                key: const Key('more-help'),
                icon: CupertinoIcons.question_circle_fill,
                color: KJPalette.accent,
                title: 'Help',
                subtitle: 'How to add devices, draw rooms and more',
                onTap: () => showHelpSheet(context),
              ),
              _Row(
                key: const Key('more-diagnostics'),
                icon: CupertinoIcons.waveform_path_ecg,
                color: KJPalette.pink,
                title: 'Diagnostics',
                subtitle: log.errorCount + failed + offline == 0
                    ? 'Everything is working'
                    : [
                        if (failed > 0) counted(failed, 'failing connection'),
                        if (offline > 0) '$offline not responding',
                        if (log.errorCount > 0) counted(log.errorCount, 'error'),
                      ].join(' · '),
                warn: log.errorCount + failed + offline > 0,
                onTap: () => openDiagnostics(context),
              ),
            ]),
            const SizedBox(height: 18),
            Center(child: Text('SMARTHOMEKJ $appVersion · FREE', style: NType.label(color: p.textDim))),
          ],
        ),
      ),
    );
  }
}

/// Rows in one rounded card, with hairlines between them, as in iOS Settings.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return NCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Divider(height: 1, indent: 64, color: p.border.withValues(alpha: 0.6)),
          children[i],
        ],
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.warn = false,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: NType.body(16, color: p.text, weight: 500)),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NType.body(13.5, color: warn ? KJPalette.danger : p.textDim)),
              ]),
            ),
            Icon(CupertinoIcons.chevron_right, size: 16, color: p.textDim),
          ]),
        ),
      ),
    );
  }
}
