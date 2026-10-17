import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';
import '../../state/backup_files.dart';
import '../../state/home_store.dart';
import '../../state/seed.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';

/// Lets the owner pick a backup file and takes its homes back. With [ask], it first says that the homes on this
/// device will be replaced.
Future<void> restoreFromFile(BuildContext context, {bool ask = true}) async {
  final store = context.read<HomeStore>();
  final backups = context.read<BackupFiles>();
  final settings = context.read<AppSettings>();
  if (ask &&
      !await confirm(context,
          title: 'Restore from a file?',
          body: 'Pick a SmartMenuKJ backup, usually in Downloads/SmartMenuKJ. '
              '${store.homes.length == 1 ? store.homeName : 'Every home on this device'} is replaced by the homes in it.',
          action: 'Pick file')) {
    return;
  }
  try {
    final count = await backups.restore(store);
    if (count == null) return;
    settings.restoreAsked = true;
    store.toast(count == 1 ? 'Home restored.' : '$count homes restored.');
  } on FormatException {
    store.toast('That file is not a SmartMenuKJ backup.');
  } catch (e) {
    store.toast('The file could not be opened.');
  }
}

/// Whether a new install should offer to take the homes back from a backup file.
bool offerRestore(HomeStore store, AppSettings settings, BackupFiles backups) =>
    backups.available && !settings.restoreAsked && store.homes.length == 1 && isSampleHome(store.data);

/// On a new install: "Had SmartMenuKJ before?", with the way back to the homes in the backup file.
class RestoreCard extends StatelessWidget {
  const RestoreCard({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return NCard(
      key: const Key('restore-backup'),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.settings_backup_restore),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Had SmartMenuKJ before?', style: NType.body(14, color: p.text, weight: 500)),
              const SizedBox(height: 2),
              Text('Take your home back from its backup file in Downloads/SmartMenuKJ.',
                  style: NType.body(13, color: p.textDim)),
            ]),
          ),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
            key: const Key('restore-later'),
            onPressed: () => context.read<AppSettings>().restoreAsked = true,
            child: const Text('No thanks'),
          ),
          FilledButton(
            key: const Key('restore-pick'),
            onPressed: () => restoreFromFile(context, ask: false),
            child: const Text('Restore'),
          ),
        ]),
      ]),
    );
  }
}
