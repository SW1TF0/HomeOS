import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/scene.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';

const sceneIcons = <String, IconData>{
  'auto': Icons.auto_awesome_outlined,
  'morning': Icons.wb_sunny_outlined,
  'movie': Icons.movie_outlined,
  'night': Icons.bedtime_outlined,
  'away': Icons.directions_walk,
  'dinner': Icons.restaurant_outlined,
  'focus': Icons.center_focus_strong_outlined,
  'party': Icons.celebration_outlined,
  'relax': Icons.spa_outlined,
  'home': Icons.home_outlined,
};

IconData sceneIcon(String key) => sceneIcons[key] ?? Icons.auto_awesome_outlined;

/// What a scene will do to one device, in a few words.
String describeAction(Device d, DeviceCommand c) {
  if (c.locked != null) return c.locked! ? 'Locked' : 'Unlocked';
  if (c.on == false) return 'Off';
  final parts = <String>[
    if (c.position != null) c.position! <= 0.01 ? 'Closed' : 'Open ${(c.position! * 100).round()}%',
    if (c.on == true) 'On',
    if (c.brightness != null) '${(c.brightness! * 100).round()}%',
    if (c.colorTempK != null) '${c.colorTempK}K',
    if (c.color != null) 'colour',
    if (c.targetTemp != null) '${c.targetTemp!.toStringAsFixed(1)}°',
    if (c.volume != null) 'vol ${(c.volume! * 100).round()}',
  ];
  return parts.isEmpty ? 'As it was' : parts.join(' · ');
}

/// Devices a scene can set.
List<Device> sceneCandidates(HomeStore store) => store.devices
    .where((d) => [
          Capability.onOff,
          Capability.brightness,
          Capability.position,
          Capability.targetTemp,
          Capability.lock,
          Capability.volume,
        ].any(d.has))
    .toList();

String _sceneSubtitle(Scene s) {
  final n = s.actions.length;
  final devices = '$n device${n == 1 ? '' : 's'}';
  return s.schedule == null ? devices : '$devices · ${s.schedule!.time}';
}

/// A row of scene cards for the home screen, ending with "New scene".
class ScenesRow extends StatefulWidget {
  const ScenesRow({super.key});

  @override
  State<ScenesRow> createState() => _ScenesRowState();
}

class _ScenesRowState extends State<ScenesRow> {
  String? _running;

  Future<void> _run(HomeStore store, Scene s) async {
    setState(() => _running = s.id);
    await store.runScene(s);
    if (mounted) setState(() => _running = null);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    return SizedBox(
      height: 120,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in store.scenes) ...[
            SizedBox(
              width: 150,
              child: NCard(
                key: Key('scene-${s.id}'),
                inverted: _running == s.id,
                padding: const EdgeInsets.all(14),
                onTap: () => _run(store, s),
                onLongPress: () => showSceneSheet(context, s),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(sceneIcon(s.icon), color: _running == s.id ? p.background : p.text),
                  const Spacer(),
                  Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NType.body(15, color: _running == s.id ? p.background : p.text, weight: 600)),
                  Text(_sceneSubtitle(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NType.body(12, color: _running == s.id ? p.background.withValues(alpha: 0.7) : p.textDim)),
                ]),
              ),
            ),
            const SizedBox(width: 10),
          ],
          SizedBox(
            width: 150,
            child: NCard(
              key: const Key('scene-new'),
              padding: const EdgeInsets.all(14),
              onTap: () => createScene(context),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.add),
                const Spacer(),
                Text('New scene', style: NType.body(15, color: p.text, weight: 600)),
                Text('Saves what is on', maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(12, color: p.textDim)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a name and devices, then saves their current state as a scene.
Future<Scene?> createScene(BuildContext context) async {
  final store = context.read<HomeStore>();
  final candidates = sceneCandidates(store);
  if (candidates.isEmpty) {
    store.toast('Add some devices first, then save a scene.');
    return null;
  }
  final template = await pickOne<(String, String)>(
    context,
    title: 'New scene',
    options: [...sceneTemplates, ('', 'auto')],
    label: (t) => t.$1.isEmpty ? 'Something else...' : t.$1,
    icon: (t) => t.$1.isEmpty ? Icons.edit_outlined : sceneIcon(t.$2),
  );
  if (template == null || !context.mounted) return null;
  var name = template.$1;
  if (name.isEmpty) {
    name = await promptText(context, title: 'Scene name', hint: 'e.g. Reading', action: 'Next') ?? '';
  }
  if (name.isEmpty || !context.mounted) return null;
  final picked = await pickMany<Device>(
    context,
    title: 'Which devices?',
    options: candidates,
    label: (d) => d.name,
    subtitle: (d) => 'Will be saved as: ${describeAction(d, SceneAction.capture(d).command)}',
    icon: (d) => deviceIcon(d.kind),
    initial: candidates.where((d) => d.state.isActive).toSet(),
    action: 'Save scene',
  );
  if (picked == null || picked.isEmpty) return null;
  final s = store.addScene(name, picked, icon: template.$2);
  store.toast('Saved "${s.name}". Tap it to bring these devices back to how they are now.');
  return s;
}

Future<void> showSceneSheet(BuildContext context, Scene s) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => SceneSheet(sceneId: s.id),
    );

/// Edit a scene: rename, icon, devices, schedule, delete.
class SceneSheet extends StatelessWidget {
  const SceneSheet({super.key, required this.sceneId});
  final String sceneId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final s = store.scene(sceneId);
    if (s == null) return const SizedBox(height: 120, child: Center(child: Text('Scene removed')));
    final p = context.palette;
    final devices = [
      for (final a in s.actions)
        if (store.device(a.deviceId) != null) (store.device(a.deviceId)!, a.command),
    ];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Row(children: [
            Icon(sceneIcon(s.icon), size: 30),
            const SizedBox(width: 12),
            Expanded(child: DotText(s.name.toUpperCase(), size: 28, maxLines: 2)),
          ]),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('scene-run'),
            onPressed: () => store.runScene(s),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run now'),
          ),
          const SectionLabel('Icon'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in sceneIcons.entries)
              InkResponse(
                onTap: () => store.updateScene(s, icon: e.key),
                radius: 26,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: s.icon == e.key ? p.text : Colors.transparent,
                    border: Border.all(color: s.icon == e.key ? p.text : p.border),
                  ),
                  child: Icon(e.value, size: 20, color: s.icon == e.key ? p.background : p.text),
                ),
              ),
          ]),
          SectionLabel('Devices', trailing: Text('${devices.length}', style: NType.label(color: p.textDim))),
          NCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (final (d, c) in devices)
                ListTile(
                  leading: Icon(deviceIcon(d.kind)),
                  title: Text(d.name),
                  subtitle: Text(describeAction(d, c)),
                ),
              if (devices.isEmpty)
                const ListTile(title: Text('No devices yet')),
            ]),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('scene-recapture'),
            onPressed: () {
              store.updateScene(s, capture: devices.map((e) => e.$1));
              store.toast('Saved how these devices are now.');
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save how they are now'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final candidates = sceneCandidates(store);
              final picked = await pickMany<Device>(
                context,
                title: 'Which devices?',
                options: candidates,
                label: (d) => d.name,
                subtitle: (d) => describeState(d),
                icon: (d) => deviceIcon(d.kind),
                initial: devices.map((e) => e.$1).toSet(),
                action: 'Save',
              );
              if (picked == null) return;
              // Keep what was saved for devices that stay; capture the new ones as they are now.
              final kept = {for (final a in s.actions) a.deviceId: a};
              s.actions = [for (final d in picked) kept[d.id] ?? SceneAction.capture(d)];
              store.updateScene(s);
            },
            icon: const Icon(Icons.checklist),
            label: const Text('Change devices'),
          ),
          const SectionLabel('Schedule'),
          _ScheduleCard(scene: s),
          const SectionLabel('Scene'),
          NCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () async {
                  final name = await promptText(context, title: 'Rename', initial: s.name);
                  if (name != null && name.isNotEmpty) store.updateScene(s, name: name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: NothingPalette.red),
                title: const Text('Delete scene', style: TextStyle(color: NothingPalette.red)),
                onTap: () async {
                  if (await confirm(context, title: 'Delete ${s.name}?', body: 'Your devices are not changed.')) {
                    store.removeScene(s);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.scene});
  final Scene scene;

  @override
  Widget build(BuildContext context) {
    final store = context.read<HomeStore>();
    final p = context.palette;
    final sch = scene.schedule;
    Future<void> pickTime() async {
      final t = await showTimePicker(
        context: context,
        initialTime: sch == null ? const TimeOfDay(hour: 7, minute: 0) : TimeOfDay(hour: sch.hour, minute: sch.minute),
      );
      if (t == null) return;
      store.updateScene(scene, schedule: SceneSchedule(hour: t.hour, minute: t.minute, days: sch?.days));
    }

    return NCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: pickTime,
              child: DotText(sch?.time ?? '--:--', size: 44),
            ),
          ),
          Switch(
            key: const Key('scene-schedule'),
            value: sch != null,
            activeTrackColor: NothingPalette.red,
            onChanged: (on) => on ? pickTime() : store.updateScene(scene, clearSchedule: true),
          ),
        ]),
        if (sch != null) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (var d = 1; d <= 7; d++)
              NChip(
                label: const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][d - 1],
                selected: sch.days.contains(d),
                onTap: () {
                  final days = {...sch.days};
                  days.contains(d) ? days.remove(d) : days.add(d);
                  if (days.isEmpty) return;
                  store.updateScene(scene, schedule: SceneSchedule(hour: sch.hour, minute: sch.minute, days: days));
                },
              ),
          ]),
          const SizedBox(height: 8),
          Text(sch.daysLabel, style: NType.body(13, color: p.textDim)),
        ],
        const SizedBox(height: 8),
        Text('Runs while SmartMenuKJ is open. Android may pause it when the app is closed.',
            style: NType.body(12.5, color: p.textDim)),
      ]),
    );
  }
}
