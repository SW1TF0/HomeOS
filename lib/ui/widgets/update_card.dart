import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/home_store.dart';
import '../../state/updates.dart';
import '../../theme/app_theme.dart';
import '../../l10n/text.dart';
import 'kj_widgets.dart';

/// Opens [url] in the browser, which downloads the file; says so when nothing could open it.
Future<void> openDownload(BuildContext context, String url) async {
  final store = context.read<HomeStore>();
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  store.toast('Could not open the browser. The download is at $url');
}

/// On the home screen when a newer SmartHomeKJ is out: download it, or put it off until the next one.
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final u = context.watch<UpdateCheck>();
    final android = u.platform == UpdatePlatform.android;
    return NCard(
      key: const Key('update-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: KJPalette.accent.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: const Icon(CupertinoIcons.arrow_down_circle_fill, color: KJPalette.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SmartHomeKJ ${u.latest} is out', style: NType.body(15, color: p.text, weight: 600)),
              const SizedBox(height: 2),
              Text(
                android
                    ? 'You have ${u.current}. If Android will not install it over this one, uninstall SmartHomeKJ '
                        'first: your home comes back from its backup file.'
                    : 'You have ${u.current}. The download replaces this version; your homes stay.',
                style: NType.body(13, color: p.textDim),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(key: const Key('update-later'), onPressed: u.later, child: const Text('Later')),
          FilledButton(
            key: const Key('update-download'),
            onPressed: () => openDownload(context, u.downloadUrl),
            child: const Text('Download'),
          ),
        ]),
      ]),
    );
  }
}
