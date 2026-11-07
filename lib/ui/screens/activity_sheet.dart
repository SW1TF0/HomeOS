import 'package:clock/clock.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../state/app_settings.dart';
import '../../state/history.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../util/clock_text.dart';
import '../widgets/dialogs.dart';
import '../widgets/history_chart.dart';
import '../widgets/kj_widgets.dart';
import '../../l10n/text.dart';
import 'automations.dart';

/// Opens what happened in the home, newest first; of one device when [deviceId] is given.
Future<void> showActivitySheet(BuildContext context, {String? deviceId}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => ActivitySheet(deviceId: deviceId),
    );

/// "Turned on", "Motion: Detected", "Stopped answering"...
String eventText(HomeEvent e) => switch (e.type) {
      EventType.turnedOn => 'Turned on',
      EventType.turnedOff => 'Turned off',
      EventType.opened => 'Opened',
      EventType.closed => 'Closed',
      EventType.locked => 'Locked',
      EventType.unlocked => 'Unlocked',
      EventType.reading => e.label == 'Error' ? 'Problem: ${e.value}' : '${e.label}: ${e.value}',
      EventType.activity => activityLabel(e.kind ?? DeviceKind.other, e.value),
      EventType.offline => 'Stopped answering',
      EventType.online => 'Answering again',
      EventType.scene => 'Scene ran',
      EventType.automation => 'Automation ran',
    };

/// Who made it happen, or null when the device did it by itself (or someone used its own app or switch).
String? byText(HomeStore store, HomeEvent e) {
  final by = e.by;
  if (by == null) return null;
  if (by == 'app') return 'From the app';
  if (by == 'remote') return 'From another phone';
  if (by.startsWith('scene:')) {
    final name = store.scene(by.substring(6))?.name;
    return name == null ? 'By a scene' : 'By the scene $name';
  }
  if (by.startsWith('automation:')) return 'By an automation';
  if (by == 'timer') return 'By a timer';
  return null;
}

/// The name shown for [e]: the device as it is called now, or the scene or automation.
String _title(HomeStore store, HomeEvent e) {
  switch (e.type) {
    case EventType.scene:
      return store.scene(e.value ?? '')?.name ?? e.name ?? 'Scene';
    case EventType.automation:
      final a = store.automations.where((a) => a.id == e.value).firstOrNull;
      if (a != null) return whenText(store, a.trigger);
      return e.name == null ? 'Automation' : trf('When {0} {1}', [e.name!, tr(e.label ?? '')]).trim();
    default:
      return store.device(e.deviceId ?? '')?.name ?? e.name ?? 'Removed device';
  }
}

(IconData, Color) _look(HomeEvent e) => switch (e.type) {
      EventType.scene => (CupertinoIcons.sparkles, KJPalette.orange),
      EventType.automation => (CupertinoIcons.gear_alt_fill, KJPalette.indigo),
      EventType.offline => (CupertinoIcons.wifi_exclamationmark, KJPalette.danger),
      EventType.online => (CupertinoIcons.wifi, KJPalette.green),
      _ when e.isProblem => (CupertinoIcons.exclamationmark_triangle_fill, KJPalette.danger),
      EventType.reading when (e.value ?? '').endsWith('!') => (CupertinoIcons.exclamationmark_triangle_fill, KJPalette.danger),
      _ => (
          deviceIcon(e.kind ?? DeviceKind.other, active: e.type == EventType.turnedOn || e.type == EventType.opened),
          kindColor(e.kind ?? DeviceKind.other)
        ),
    };

/// "Today", "Yesterday", "Mon 3 Nov".
String dayText(DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final back = today.difference(day).inDays;
  if (back == 0) return 'Today';
  if (back == 1) return 'Yesterday';
  return '${weekdayShort(t.weekday)} ${t.day} ${monthShort(t.month)}';
}

/// "Just now", "5 min ago", "2 h ago", "Yesterday".
String agoText(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return dayText(t, now);
}

/// The latest thing that happened, short enough for the pill on the home screen: "Front door · 5 min ago".
String latestText(HomeStore store, HomeEvent? e, DateTime now) {
  if (e == null) return 'Nothing yet';
  var name = _title(store, e);
  if (name.length > 18) name = '${name.substring(0, 17).trimRight()}…';
  return '$name · ${agoText(e.at, now)}';
}

enum _Filter { all, security, power, problems }

class ActivitySheet extends StatefulWidget {
  const ActivitySheet({super.key, this.deviceId});
  final String? deviceId;

  @override
  State<ActivitySheet> createState() => _ActivitySheetState();
}

class _ActivitySheetState extends State<ActivitySheet> {
  var _filter = _Filter.all;

  bool _keep(HomeEvent e) => switch (_filter) {
        _Filter.all => true,
        _Filter.security => e.isSecurity,
        _Filter.power => e.type == EventType.turnedOn || e.type == EventType.turnedOff,
        _Filter.problems => e.isProblem,
      };

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final history = context.watch<HomeHistory>();
    final p = context.palette;
    final h24 = context.select<AppSettings, bool>((s) => s.clock24);
    final now = clock.now();
    final device = widget.deviceId == null ? null : store.device(widget.deviceId!);
    final events = history.latest(deviceId: widget.deviceId).where(_keep).toList();

    final rows = <Widget>[];
    String? day;
    for (final e in events) {
      final d = dayText(e.at, now);
      if (d != day) {
        day = d;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(d, style: NType.body(15, color: p.textDim, weight: 600)),
        ));
      }
      rows.add(ActivityRow(event: e, h24: h24, showName: widget.deviceId == null));
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Row(children: [
            Expanded(child: DisplayText(device == null ? 'Activity' : device.name, size: 30, maxLines: 2)),
            if (history.events.isNotEmpty && widget.deviceId == null)
              TextButton(
                key: const Key('activity-clear'),
                onPressed: () async {
                  final ok = await confirm(context,
                      title: 'Clear activity?',
                      body: 'Everything the app noted about ${store.homeName} on this phone goes, charts too.',
                      action: tc('Clear', 'action'));
                  if (ok) await history.clear();
                },
                child: Text(tc('Clear', 'action')),
              ),
          ]),
          const SizedBox(height: 4),
          Text(
            device == null ? 'What happened in ${store.homeName}, as this phone saw it.' : 'What happened to it, as this phone saw it.',
            style: NType.body(14, color: p.textDim),
          ),
          if (widget.deviceId == null) ...[
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final (f, label) in const [
                  (_Filter.all, 'All'),
                  (_Filter.security, 'Doors & sensors'),
                  (_Filter.power, 'On & off'),
                  (_Filter.problems, 'Problems'),
                ]) ...[
                  NChip(
                    key: Key('activity-filter-${f.name}'),
                    label: label,
                    selected: _filter == f,
                    onTap: () => setState(() => _filter = f),
                  ),
                  const SizedBox(width: 8),
                ],
              ]),
            ),
          ],
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
              child: Column(children: [
                Icon(CupertinoIcons.clock, size: 40, color: p.textDim),
                const SizedBox(height: 12),
                Text(
                  history.events.isEmpty
                      ? 'Nothing yet. Whatever your devices do while the app is open shows up here: lights going on and '
                          'off, doors, motion, scenes and devices that stop answering.'
                      : 'Nothing like that yet.',
                  key: const Key('activity-empty'),
                  textAlign: TextAlign.center,
                  style: NType.body(14, color: p.textDim),
                ),
              ]),
            )
          else
            ...rows,
        ],
      ),
    );
  }
}

/// One line of activity: what, which device, who did it, and when.
class ActivityRow extends StatelessWidget {
  const ActivityRow({super.key, required this.event, required this.h24, this.showName = true});
  final HomeEvent event;
  final bool h24;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final store = context.read<HomeStore>();
    final p = context.palette;
    final (icon, color) = _look(event);
    final by = byText(store, event);
    final what = eventText(event);
    final name = _title(store, event);
    final scene = event.type == EventType.scene || event.type == EventType.automation;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: NCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        radius: 16,
        onTap: event.deviceId != null && store.device(event.deviceId!) != null && showName
            ? () => showActivitySheet(context, deviceId: event.deviceId)
            : null,
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Icon(icon, size: 19, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (showName || scene)
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.body(15, color: p.text, weight: 600)),
              if (!scene || !showName)
                Text(what,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: showName ? NType.body(14, color: p.textDim) : NType.body(15, color: p.text, weight: 600)),
              if (by != null) Text(by, maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(12.5, color: p.textDim)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(clockText(event.at, h24), style: NType.body(13, color: p.textDim)),
        ]),
      ),
    );
  }
}

/// Under a device's controls: its readings over the last day or week, and the last things that happened to it.
class DeviceHistory extends StatefulWidget {
  const DeviceHistory({super.key, required this.device});
  final Device device;

  @override
  State<DeviceHistory> createState() => _DeviceHistoryState();
}

class _DeviceHistoryState extends State<DeviceHistory> {
  String? _picked;
  var _week = false;

  @override
  Widget build(BuildContext context) {
    final history = context.watch<HomeHistory>();
    final h24 = context.select<AppSettings, bool>((s) => s.clock24);
    final p = context.palette;
    final d = widget.device;
    final charts = history.seriesOf(d.id);
    final events = history.latest(deviceId: d.id, limit: 4);
    if (charts.isEmpty && events.isEmpty) return const SizedBox.shrink();
    final series = charts.where((s) => s.label == _picked).firstOrNull ?? charts.firstOrNull;
    final now = clock.now();
    final from = now.subtract(_week ? const Duration(days: 7) : const Duration(hours: 24));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('History',
          trailing: events.isEmpty
              ? null
              : GestureDetector(
                  key: const Key('history-all'),
                  onTap: () => showActivitySheet(context, deviceId: d.id),
                  child: Text('All activity', style: NType.body(17, color: KJPalette.accent)),
                )),
      if (series != null)
        NCard(
          key: const Key('history-chart'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<bool>(
                key: const Key('history-range'),
                groupValue: _week,
                children: {
                  false: Text('24 h', style: NType.body(13, color: p.text, weight: 500)),
                  true: Text('7 days', style: NType.body(13, color: p.text, weight: 500)),
                },
                onValueChanged: (v) => setState(() => _week = v ?? false),
              ),
            ),
            if (charts.length > 1) ...[
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final s in charts) ...[
                    NChip(
                      key: Key('history-series-${s.label}'),
                      label: s.label,
                      selected: s == series,
                      onTap: () => setState(() => _picked = s.label),
                    ),
                    const SizedBox(width: 6),
                  ],
                ]),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Text(series.label, style: NType.label(color: p.textDim)),
            ],
            const SizedBox(height: 12),
            HistoryChart(
              key: ValueKey('${series.label}-$_week'),
              series: series,
              from: from,
              to: now,
              color: _colorFor(series.label, d),
              h24: h24,
            ),
          ]),
        ),
      if (events.isNotEmpty) ...[
        const SizedBox(height: 10),
        for (final e in events) ActivityRow(event: e, h24: h24, showName: false),
      ],
    ]);
  }

  static Color _colorFor(String label, Device d) => switch (label) {
        'Temperature' => KJPalette.orange,
        'Humidity' => KJPalette.teal,
        'Battery' => KJPalette.green,
        'Power' || 'Current' || 'Voltage' => KJPalette.yellow,
        'CPU' || 'Memory' => KJPalette.indigo,
        _ => kindColor(d.kind),
      };
}
