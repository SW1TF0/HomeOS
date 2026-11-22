import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as m show Text;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../cloud/cloud_sync.dart';
import '../../models/device.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../platform/platform.dart';
import '../../util/app_log.dart';
import '../widgets/kj_widgets.dart';
import '../widgets/motion.dart';
import '../../l10n/text.dart';

Future<void> openDiagnostics(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()));

/// The system the app is running on, in one line per fact. Kept apart so tests can check it on every platform.
List<(String, String)> systemFacts(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  final size = media?.size;
  return [
    ('App', 'SmartHomeKJ $appVersion'),
    ('Mode', kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')),
    ('Platform', AppPlatform.current.label),
    ('OS version', AppPlatform.current.osVersion),
    ('Dart', AppPlatform.current.dartVersion),
    ('Look', defaultTargetPlatform.name),
    if (AppPlatform.pretending case final os?) ('Pretending', os.name),
    ('Language', L10n.code),
    if (size != null)
      ('Screen', '${size.width.round()} × ${size.height.round()} @${media!.devicePixelRatio.toStringAsFixed(1)}x'),
    if (media != null) ('Text size', '${(media.textScaler.scale(10) * 10).round()}%'),
    ('Animations', Motion.on(context) ? 'on' : 'off'),
  ];
}

/// Everything someone fixing a problem wants to see, as plain text: the system, the connections, devices that
/// failed and the log.
String diagnosticsReport(BuildContext context) {
  final store = context.read<HomeStore>();
  final cloud = context.read<CloudSync>();
  final b = StringBuffer('SmartHomeKJ diagnostics\n');
  for (final (k, v) in systemFacts(context)) {
    b.writeln('$k: $v');
  }
  b.writeln('Account: ${cloud.signedIn ? 'signed in' : 'signed out'}${cloud.problem == null ? '' : ' (${cloud.problem})'}');
  b.writeln('Off home Wi-Fi: ${store.offHomeNetwork}');
  b.writeln('\nConnections (${store.integrations.length})');
  for (final c in store.integrations) {
    final st = store.status[c.id];
    b.writeln('- ${c.type} "${c.name}" ${c.enabled ? '' : '(off) '}'
        '${st == null ? 'starting' : (st.ok ? 'ok' : 'FAILED')}${st?.message == null ? '' : ': ${st!.message}'}');
  }
  final problems = problemDevices(store);
  b.writeln('\nDevices: ${store.devices.length}, with problems: ${problems.length}');
  for (final d in problems) {
    final e = store.lastErrors[d.id];
    b.writeln('- ${d.name} [${d.kind.name}] ${d.integrationId}/${d.externalId}'
        '${d.state.reachable ? '' : ' NOT ANSWERING'}${e == null ? '' : ' last error ${e.at.toIso8601String()}: ${e.error}'}');
  }
  b.writeln('\nLog (${AppLog.instance.entries.length} lines)');
  b.write(AppLog.instance.dump());
  return b.toString();
}

/// Devices that are not answering, or failed the last time they were sent something.
List<Device> problemDevices(HomeStore store) =>
    store.devices.where((d) => !d.state.reachable || store.lastErrors.containsKey(d.id)).toList();

/// Settings > Diagnostics: the system, connections, devices with problems and the app's log, with a button that
/// copies all of it for a bug report.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  LogLevel _min = LogLevel.info;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final log = context.watch<AppLog>();
    final p = context.palette;
    final problems = problemDevices(store);
    final lines = log.entries.where((e) => e.level.index >= _min.index).toList().reversed.toList();
    final mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
        fontSize: 12, height: 1.35, color: p.text);

    return PageScaffold(
      title: 'Diagnostics',
      backKey: const Key('diagnostics-back'),
      children: [
        Text('What the app knows about itself, its connections and what went wrong. Copy it into a bug report.',
            style: NType.body(14, color: p.textDim)),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('diagnostics-copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: diagnosticsReport(context)));
            store.toast('Diagnostics copied.');
          },
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy report'),
        ),
        const SectionLabel('System'),
        NCard(
          key: const Key('diagnostics-system'),
          child: Column(children: [
            for (final (k, v) in systemFacts(context))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 110, child: Text(k, style: NType.body(14, color: p.textDim))),
                  Expanded(child: m.Text(v, style: NType.body(14, color: p.text, weight: 500))),
                ]),
              ),
          ]),
        ),
        // Only in debug and profile builds: see on a Mac how the app looks and behaves on Windows, and so on.
        if (!kReleaseMode) ...[
          const SectionLabel('Pretend to be'),
          Text('Draws the app the way another system does: scrolling, menus, text selection, the profile in '
              'lib/platform/. What only the real system can do (its own video player, background service) stays.',
              style: NType.body(13.5, color: p.textDim)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            NChip(
              key: const Key('pretend-none'),
              label: 'Itself',
              selected: AppPlatform.pretending == null,
              onTap: () => AppPlatform.pretend(null),
            ),
            for (final os in AppOS.values.where((o) => o != AppOS.web))
              NChip(
                key: Key('pretend-${os.name}'),
                label: AppPlatform.of(os).label,
                selected: AppPlatform.pretending == os,
                onTap: () {
                  AppLog.info('app', 'Pretending to be ${os.name}');
                  AppPlatform.pretend(os);
                },
              ),
          ]),
        ],
        SectionLabel('Connections', trailing: Text('${store.integrations.length}', style: NType.label(color: p.textDim))),
        if (store.integrations.isEmpty) Text('No connections yet.', style: NType.body(14, color: p.textDim)),
        for (final c in store.integrations)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: NCard(
              key: Key('diagnostics-connection-${c.id}'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(children: [
                StatusDot(ok: store.status[c.id]?.ok, size: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    m.Text(c.name, style: NType.body(15, color: p.text, weight: 600)),
                    m.Text(
                        [
                          c.type,
                          '${store.devices.where((d) => d.integrationId == c.id).length} ${tr('devices')}',
                          if (!c.enabled) tr('off'),
                          ?store.status[c.id]?.message,
                        ].join(' · '),
                        style: NType.body(13, color: store.status[c.id]?.ok == false ? KJPalette.danger : p.textDim)),
                  ]),
                ),
              ]),
            ),
          ),
        SectionLabel('Devices with problems', trailing: Text('${problems.length}', style: NType.label(color: p.textDim))),
        if (problems.isEmpty)
          Text('Every device answered the last time it was asked.', style: NType.body(14, color: p.textDim)),
        for (final d in problems)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: NCard(
              key: Key('diagnostics-device-${d.id}'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              onTap: () => showRawDevice(context, d),
              child: Row(children: [
                Icon(deviceIcon(d.kind), color: d.state.reachable ? p.text : KJPalette.danger),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    m.Text(d.name, style: NType.body(15, color: p.text, weight: 600)),
                    m.Text(
                        [
                          if (!d.state.reachable) tr('Not responding'),
                          if (store.lastErrors[d.id] case final e?) e.error,
                        ].join(' · '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: NType.body(13, color: KJPalette.danger)),
                  ]),
                ),
                Icon(Icons.data_object, size: 18, color: p.textDim),
              ]),
            ),
          ),
        SectionLabel('Log',
            trailing: TextButton(
              key: const Key('diagnostics-clear'),
              onPressed: log.entries.isEmpty ? null : log.clear,
              child: const Text('Clear'),
            )),
        Wrap(spacing: 8, children: [
          for (final (level, label) in const [
            (LogLevel.debug, 'Everything'),
            (LogLevel.info, 'Messages'),
            (LogLevel.warning, 'Problems'),
            (LogLevel.error, 'Errors'),
          ])
            NChip(
                key: Key('log-${level.name}'),
                label: label,
                selected: _min == level,
                onTap: () => setState(() => _min = level)),
        ]),
        const SizedBox(height: 10),
        NCard(
          key: const Key('diagnostics-log'),
          padding: const EdgeInsets.all(12),
          child: lines.isEmpty
              ? Text('Nothing logged yet.', style: NType.body(14, color: p.textDim))
              : SelectionArea(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final e in lines.take(200))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: m.Text('$e',
                            style: mono.copyWith(
                                color: switch (e.level) {
                              LogLevel.error => KJPalette.danger,
                              LogLevel.warning => KJPalette.orange,
                              LogLevel.debug => p.textDim,
                              LogLevel.info => p.text,
                            })),
                      ),
                  ]),
                ),
        ),
      ],
    );
  }
}

/// Shows everything the app keeps about [d]: its connection, address, abilities and raw state, as JSON.
Future<void> showRawDevice(BuildContext context, Device d) {
  final store = context.read<HomeStore>();
  final json = const JsonEncoder.withIndent('  ').convert({
    ...d.toJson(),
    if (store.lastErrors[d.id] case final e?) 'lastError': {'at': e.at.toIso8601String(), 'error': e.error},
    'connectionStatus': switch (store.status[d.integrationId]) {
      null => 'starting',
      final s => {'ok': s.ok, 'message': s.message, 'lastSync': s.lastSync?.toIso8601String()},
    },
  });
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) {
      final p = context.palette;
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          key: const Key('raw-device'),
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Row(children: [
              Expanded(child: DisplayText(d.name, size: 26, maxLines: 1)),
              IconButton(
                tooltip: tr('Copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: json));
                  store.toast('Copied.');
                },
                icon: const Icon(Icons.copy_outlined),
              ),
            ]),
            const SizedBox(height: 10),
            NCard(
              padding: const EdgeInsets.all(14),
              child: SelectableText(json,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
                      fontSize: 12,
                      color: p.text)),
            ),
          ],
        ),
      );
    },
  );
}

/// A small coloured dot: green when [ok], red when not, grey while unknown.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.ok, this.size = 8});
  final bool? ok;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ok == null ? context.palette.textDim : (ok! ? KJPalette.green : KJPalette.danger),
        ),
      );
}
