import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../cloud/cloud_sync.dart';
import '../../state/app_settings.dart';
import '../../state/backup_files.dart';
import '../../state/home_store.dart';
import '../../state/scenes_widget.dart';
import '../../theme/app_theme.dart';
import '../../util/clock_text.dart';
import '../nav.dart';
import '../widgets/dialogs.dart';
import '../widgets/kj_widgets.dart';
import 'account_sheet.dart';
import 'backup_restore.dart';
import 'help_sheet.dart';
import 'home_screen.dart';
import 'homes_sheet.dart';

Future<void> openSettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

/// Everything that is set once: the account, homes, how the app looks and behaves, backups.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final settings = context.watch<AppSettings>();
    final cloud = context.watch<CloudSync>();
    final backups = context.watch<BackupFiles>();
    final p = context.palette;

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
                    key: const Key('settings-back'),
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(child: DisplayText('Settings', size: 34)),
                ]),
              ),
              Expanded(
                child: ListView(
                  key: const Key('settings-list'),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  children: [
                    if (cloud.available) ...[
                      const SectionLabel('Account', accent: true),
                      const AccountCard(),
                    ],
                    const SectionLabel('Homes'),
                    NCard(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(children: [
                        ListTile(
                          key: const Key('settings-homes'),
                          leading: const Icon(Icons.home_work_outlined),
                          title: const Text('Homes'),
                          subtitle: Text(store.homes.length == 1
                              ? 'Add another home, like a holiday house or an office'
                              : '${store.homes.length} homes · ${store.homeName} is open'),
                          onTap: () => showHomesSheet(context),
                        ),
                        ListTile(
                          leading: const Icon(Icons.tune),
                          title: const Text('Home screen'),
                          subtitle: const Text('Choose and order favourites and rooms'),
                          onTap: () => showHomeEditor(context),
                        ),
                        ListTile(
                          leading: const Icon(Icons.grid_view_outlined),
                          title: const Text('Floor plan'),
                          subtitle: const Text('Draw rooms and place devices'),
                          onTap: () {
                            final nav = context.read<AppNav>();
                            Navigator.pop(context);
                            nav.openMap(edit: true);
                          },
                        ),
                      ]),
                    ),
                    const SectionLabel('Look'),
                    NCard(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(children: [
                        _Choices(
                          icon: Icons.contrast,
                          title: 'Theme',
                          choices: [
                            for (final m in const ['dark', 'light', 'system'])
                              (m[0].toUpperCase() + m.substring(1), store.themeMode == m, () => store.themeMode = m),
                          ],
                        ),
                        _Choices(
                          icon: Icons.schedule,
                          title: 'Clock',
                          choices: [
                            ('24-hour', settings.clock24, () => settings.clock24 = true),
                            ('12-hour', !settings.clock24, () => settings.clock24 = false),
                          ],
                        ),
                        _Choices(
                          icon: Icons.open_in_new,
                          title: 'Open the app on',
                          choices: [
                            for (final (i, name) in const ['Home', 'Map', 'Devices'].indexed)
                              (name, settings.startTab == i, () => settings.startTab = i),
                          ],
                        ),
                      ]),
                    ),
                    const SectionLabel('Devices'),
                    NCard(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(children: [
                        _Choices(
                          icon: Icons.sync,
                          title: 'Check devices every',
                          note: 'More often shows changes sooner but uses more battery.',
                          choices: [
                            for (final s in AppSettings.checkChoices)
                              (
                                s < 60 ? '$s s' : '${s ~/ 60} min',
                                settings.checkSeconds == s,
                                () {
                                  settings.checkSeconds = s;
                                  store.pollInterval = settings.checkEvery;
                                },
                              ),
                          ],
                        ),
                        SwitchListTile(
                          key: const Key('settings-haptics'),
                          secondary: const Icon(Icons.vibration),
                          title: const Text('Vibration'),
                          subtitle: const Text('A light click while sliding, dragging and holding'),
                          value: settings.haptics,
                          onChanged: (v) => settings.haptics = v,
                        ),
                        ListTile(
                          leading: const Icon(Icons.refresh),
                          title: const Text('Refresh all devices'),
                          subtitle: const Text('Ask every device what it is doing now'),
                          onTap: () {
                            store.refreshAll();
                            store.toast('Checking every device...');
                          },
                        ),
                        if (store.sampleDevices.isNotEmpty)
                          ListTile(
                            leading: const Icon(Icons.blur_off),
                            title: const Text('Remove sample home'),
                            subtitle: const Text('Deletes the example devices and their empty rooms'),
                            onTap: () async {
                              if (await confirm(context,
                                  title: 'Remove the sample home?',
                                  body: 'The example devices go away. Your own devices, rooms and connections stay.',
                                  action: 'Remove')) {
                                store.removeSampleHome();
                                store.toast('Sample devices removed.');
                              }
                            },
                          ),
                      ]),
                    ),
                    if (ScenesWidget.supported) ...[
                      const SectionLabel('Shortcuts'),
                      NCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(children: [
                          ListTile(
                            key: const Key('settings-widget'),
                            leading: const Icon(Icons.widgets_outlined),
                            title: const Text('Widget for your home screen'),
                            subtitle: const Text('Your first four scenes and All off, without opening the app'),
                            onTap: () async {
                              if (!await const ScenesWidget().pin().catchError((_) => false)) {
                                store.toast('Hold an empty spot on your home screen, tap Widgets and pick SmartHomeKJ.');
                              }
                            },
                          ),
                          ListTile(
                            key: const Key('settings-tile'),
                            leading: const Icon(Icons.power_settings_new),
                            title: const Text('All off in Quick Settings'),
                            subtitle: const Text('Switch everything off from the pull-down menu'),
                            onTap: () async {
                              if (!await const ScenesWidget().addTile().catchError((_) => false)) {
                                store.toast('Pull down Quick Settings twice, tap the pencil and drag All off in.');
                              }
                            },
                          ),
                        ]),
                      ),
                    ],
                    const SectionLabel('Backup'),
                    NCard(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(children: [
                        if (backups.available) ...[
                          SwitchListTile(
                            key: const Key('settings-backup-file'),
                            secondary: const Icon(Icons.save_outlined),
                            title: const Text('Keep a backup file'),
                            subtitle: Text(settings.autoBackup
                                ? '${switch ((backups.failed, backups.savedAt)) {
                                    (true, _) => 'Could not be saved just now.',
                                    (_, final at?) => 'Saved at ${clockText(at, settings.clock24)}.',
                                    _ => 'Saved after every change.',
                                  }} Every home, in Downloads/SmartHomeKJ. It stays when the app is uninstalled, and '
                                    'includes your connection passwords.'
                                : 'Every home, in Downloads/SmartHomeKJ, so a new install can take them back'),
                            value: settings.autoBackup,
                            onChanged: (v) => settings.autoBackup = v,
                          ),
                          ListTile(
                            key: const Key('settings-restore-file'),
                            leading: const Icon(Icons.settings_backup_restore),
                            title: const Text('Restore from a file'),
                            subtitle: const Text('Take your homes back after the app was reinstalled'),
                            onTap: () => restoreFromFile(context),
                          ),
                        ],
                        ListTile(
                          leading: const Icon(Icons.ios_share),
                          title: Text(backups.available ? 'Copy home as text' : 'Back up home'),
                          subtitle: Text('Copies ${store.homeName}: rooms, devices and connections, as text'),
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: store.exportJson()));
                            store.toast('Backup copied. Paste it somewhere safe. It includes your connection passwords.');
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.download_outlined),
                          title: const Text('Restore backup'),
                          subtitle: Text('Paste a backup to replace ${store.homeName}'),
                          onTap: () async {
                            final raw = await promptText(context, title: 'Paste backup', action: 'Restore');
                            if (raw == null || raw.isEmpty) return;
                            try {
                              await store.importJson(raw);
                              store.toast('Home restored.');
                            } catch (e) {
                              store.toast('That backup could not be read.');
                            }
                          },
                        ),
                      ]),
                    ),
                    const SectionLabel('About'),
                    NCard(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(children: [
                        ListTile(
                          leading: const Icon(Icons.help_outline),
                          title: const Text('Help'),
                          subtitle: const Text('How to add devices, draw rooms and more'),
                          onTap: () => showHelpSheet(context),
                        ),
                        ListTile(
                          leading: const Icon(Icons.code),
                          title: const Text('Source code'),
                          subtitle: Text('${appSourceUrl.replaceFirst('https://', '')} · tap to copy the link'),
                          onTap: () async {
                            await Clipboard.setData(const ClipboardData(text: appSourceUrl));
                            store.toast('Link copied.');
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: const Text('Licences'),
                          subtitle: const Text('The open-source parts SmartHomeKJ is built with'),
                          onTap: () =>
                              showLicensePage(context: context, applicationName: 'SmartHomeKJ', applicationVersion: appVersion),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                          child:
                              Text('SMARTHOMEKJ $appVersion · FREE · LOCAL-FIRST', style: NType.label(color: p.textDim)),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A setting with a few choices in a row of chips.
class _Choices extends StatelessWidget {
  const _Choices({required this.icon, required this.title, required this.choices, this.note});
  final IconData icon;
  final String title;
  final String? note;
  final List<(String label, bool selected, VoidCallback onTap)> choices;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon)),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: NType.body(15, color: p.text, weight: 500)),
            if (note != null) Text(note!, style: NType.body(13, color: p.textDim)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in choices) NChip(key: Key('choice-${c.$1}'), label: c.$1, selected: c.$2, onTap: c.$3),
            ]),
          ]),
        ),
      ]),
    );
  }
}
