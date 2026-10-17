import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/scene.dart';
import '../../state/home_store.dart';
import '../../state/scene_alarms.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/controls.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import 'device_sheet.dart';

const sceneIcons = <String, IconData>{
  'auto': Icons.auto_awesome_outlined,
  'off': Icons.power_settings_new,
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
    if (c.action != null)
      switch (c.action!) {
        DeviceAction.start => d.kind == DeviceKind.mower ? 'Mow' : 'Clean',
        DeviceAction.dock => 'Go home',
        DeviceAction.armHome => 'Arm home',
        DeviceAction.armAway => 'Arm away',
        DeviceAction.armNight => 'Arm night',
        DeviceAction.armVacation => 'Arm vacation',
        final a => modeLabel(a.name),
      },
    if (c.position != null) c.position! <= 0.01 ? 'Closed' : 'Open ${(c.position! * 100).round()}%',
    if (c.on == true) 'On',
    if (c.brightness != null) '${(c.brightness! * 100).round()}%',
    if (c.colorTempK != null) '${c.colorTempK}K',
    if (c.color != null) 'colour',
    if (c.targetTemp != null) '${c.targetTemp!.toStringAsFixed(1)}°',
    if (c.volume != null) 'vol ${(c.volume! * 100).round()}',
    if (c.speed != null) 'speed ${(c.speed! * 100).round()}%',
    if (c.targetHumidity != null) '${c.targetHumidity!.round()}% humidity',
    if (c.mode != null) modeLabel(c.mode!),
  ];
  return parts.isEmpty ? 'As it was' : parts.join(' · ');
}

/// Devices a scene can set.
List<Device> sceneCandidates(HomeStore store) => store.devices
    .where((d) =>
        [
          Capability.onOff,
          Capability.brightness,
          Capability.position,
          Capability.targetTemp,
          Capability.lock,
          Capability.volume,
          Capability.alarm,
        ].any(d.has) ||
        (d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower)))
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
                Text('Turn things off or on', maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(12, color: p.textDim)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a name, what the scene does and which devices, then saves it.
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
  final allOff = template.$2 == 'off';
  final does = allOff
      ? sceneChoices.first
      : await pickOne<(String, IconData, bool?)>(
          context,
          title: 'What should it do?',
          options: sceneChoices,
          label: (c) => c.$1,
          icon: (c) => c.$2,
        );
  if (does == null || !context.mounted) return null;
  final turnOn = does.$3;
  SceneAction step(Device d) => (turnOn == null ? null : SceneAction.turn(d, turnOn)) ?? SceneAction.capture(d);
  final options = turnOn == null ? candidates : candidates.where((d) => SceneAction.turn(d, turnOn) != null).toList();
  final active = options.where((d) => d.state.isActive).toSet();
  final picked = await pickMany<Device>(
    context,
    title: 'Which devices?',
    options: options,
    label: (d) => d.name,
    subtitle: (d) => 'In this scene: ${describeAction(d, step(d).command)}',
    icon: (d) => deviceIcon(d.kind),
    // Turning off is usually about what is on now, or what "All off" switches (not heating, doors or blinds).
    initial: allOff || (turnOn == false && active.isEmpty) ? options.where(HomeStore.switchedTogether).toSet() : active,
    action: 'Save scene',
  );
  if (picked == null || picked.isEmpty) return null;
  final s = store.addScene(name, picked, icon: template.$2, turnOn: turnOn);
  store.toast(turnOn == null
      ? 'Saved "${s.name}". Tap it to bring these devices back to how they are now. Hold it to change it.'
      : 'Saved "${s.name}". Tap it to turn ${picked.length == 1 ? 'it' : 'them'} ${turnOn ? 'on' : 'off'}. Hold it to change what each device does.');
  return s;
}

/// What a new scene does to the devices picked for it.
const sceneChoices = <(String, IconData, bool?)>[
  ('Turn them off', Icons.power_settings_new, false),
  ('Turn them on', Icons.lightbulb_outline, true),
  ('Keep them how they are now', Icons.save_outlined, null),
];

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
        if (store.device(a.deviceId) != null) (store.device(a.deviceId)!, a),
    ];
    void setAll(bool on) {
      for (final (d, _) in devices) {
        final a = SceneAction.turn(d, on);
        if (a != null) s.actions[s.actions.indexWhere((x) => x.deviceId == d.id)] = a;
      }
      store.updateScene(s);
    }

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
              for (final (d, a) in devices)
                ListTile(
                  key: Key('scene-step-${d.name}'),
                  leading: Icon(deviceIcon(d.kind, active: !a.isOff)),
                  title: Text(d.name),
                  subtitle: Text(describeAction(d, a.command)),
                  trailing: SceneAction.turn(d, true) != null && SceneAction.turn(d, false) != null
                      ? Switch(
                          key: Key('step-switch-${d.name}'),
                          value: !a.isOff,
                          activeTrackColor: NothingPalette.red,
                          onChanged: (on) => store.setSceneStep(s, SceneAction.turn(d, on)!),
                        )
                      : Icon(Icons.chevron_right, color: p.textDim),
                  onTap: () => showSceneStepSheet(context, s, d),
                ),
              if (devices.isEmpty)
                const ListTile(title: Text('No devices yet')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text('Tap a device to choose exactly what it does, like a brightness.',
                style: NType.body(12.5, color: p.textDim)),
          ),
          if (devices.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('scene-all-off'),
                  onPressed: () => setAll(false),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('All off'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('scene-all-on'),
                  onPressed: () => setAll(true),
                  icon: const Icon(Icons.lightbulb_outline),
                  label: const Text('All on'),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 8),
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
            label: const Text('Add or remove devices'),
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
        Text(
            SceneAlarms.supported
                ? 'Runs at this time even when SmartMenuKJ is closed.'
                : 'Runs at this time while SmartMenuKJ is open.',
            style: NType.body(12.5, color: p.textDim)),
      ]),
    );
  }
}

Future<void> showSceneStepSheet(BuildContext context, Scene s, Device d) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => SceneStepSheet(sceneId: s.id, deviceId: d.id),
    );

/// What one device does in a scene. Changing it here does not touch the device until the scene runs.
class SceneStepSheet extends StatelessWidget {
  const SceneStepSheet({super.key, required this.sceneId, required this.deviceId});
  final String sceneId;
  final String deviceId;

  static String _pct(double v) => v <= 0.005 ? 'OFF' : '${(v * 100).round()}%';
  static String _open(double v) => v <= 0.01 ? 'CLOSED' : (v >= 0.99 ? 'OPEN' : '${(v * 100).round()}%');

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final s = store.scene(sceneId);
    final d = store.device(deviceId);
    final a = s?.actions.where((x) => x.deviceId == deviceId).firstOrNull;
    if (s == null || d == null || a == null) {
      return const SizedBox(height: 120, child: Center(child: Text('Not in the scene any more')));
    }
    final p = context.palette;
    final c = a.command;
    final lit = c.on != false;
    final robot = d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower);

    // Changes go through the saved form, so a field can be dropped as well as set.
    void edit(void Function(Map<String, dynamic> j) change) {
      final j = a.toJson();
      change(j);
      store.setSceneStep(s, SceneAction.fromJson(j));
    }

    void only(Map<String, dynamic> fields) => store.setSceneStep(s, SceneAction.fromJson({'deviceId': d.id, ...fields}));
    void lightUp(Map<String, dynamic> j) {
      if (d.has(Capability.onOff)) j['on'] = true;
    }

    Widget chip(String key, String label, bool selected, VoidCallback onTap) =>
        PresetChip(key: Key('step-$key'), label: label, selected: selected, onTap: onTap);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scroll) => ListView(
        key: const Key('scene-step-sheet'),
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Row(children: [
            Icon(deviceIcon(d.kind, active: !a.isOff), size: 30),
            const SizedBox(width: 12),
            Expanded(child: DotText(d.name.toUpperCase(), size: 26, maxLines: 2)),
          ]),
          const SizedBox(height: 6),
          Text('In ${s.name}: ${describeAction(d, c)}', style: NType.body(14, color: p.textDim)),
          if (d.has(Capability.onOff)) ...[
            const SectionLabel('Power'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              chip('off', 'Off', c.on == false, () => only({'on': false})),
              chip('on', 'On', c.on == true, () => edit((j) => j['on'] = true)),
            ]),
          ],
          if (lit && d.has(Capability.brightness))
            LevelControl(
              label: 'Brightness',
              value: c.brightness ?? d.state.brightness ?? 1,
              display: _pct,
              presets: DeviceSheet.brightnessPresets,
              onChangeEnd: (v) => v <= 0.01
                  ? only({'on': false})
                  : edit((j) => j
                    ..['brightness'] = v
                    ..addAll({if (d.has(Capability.onOff)) 'on': true})),
            ),
          if (lit && d.has(Capability.colorTemp)) ...[
            SectionLabel('White', trailing: c.color != null ? Text('COLOUR', style: NType.dot(18, color: p.text)) : null),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (label, k) in const [('Warm', 2700), ('Neutral', 4000), ('Cool', 5000), ('Daylight', 6500)])
                chip('white-$k', label, c.color == null && c.colorTempK == k, () => edit((j) {
                      lightUp(j);
                      j['colorTempK'] = k;
                      j.remove('color');
                    })),
            ]),
          ],
          if (lit && d.has(Capability.color)) ...[
            const SectionLabel('Colour'),
            Center(
              child: ColorRing(
                size: 200,
                color: c.color ?? d.state.color ?? 0xFFFFFF,
                onChangeEnd: (col) => edit((j) {
                  lightUp(j);
                  j['color'] = col;
                  j.remove('colorTempK');
                }),
              ),
            ),
          ],
          if (lit && d.has(Capability.targetTemp)) ...[
            SectionLabel('Temperature',
                trailing: Text('${(c.targetTemp ?? d.state.targetTemp ?? 21).toStringAsFixed(1)}°',
                    style: NType.dot(18, color: p.text))),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final (label, t) in const [('Eco', 18.0), ('Comfort', 21.0), ('Warm', 23.0)])
                chip('temp-${t.round()}', '$label ${t.round()}°', c.targetTemp == t, () => edit((j) {
                      lightUp(j);
                      j['targetTemp'] = t;
                    })),
              for (final (key, icon, step) in const [('down', Icons.remove, -0.5), ('up', Icons.add, 0.5)])
                IconButton.outlined(
                  key: Key('step-temp-$key'),
                  onPressed: () => edit((j) {
                    lightUp(j);
                    j['targetTemp'] = ((c.targetTemp ?? d.state.targetTemp ?? 21) + step).clamp(5, 35).toDouble();
                  }),
                  icon: Icon(icon, size: 18),
                ),
            ]),
          ],
          if (lit && d.has(Capability.speed))
            LevelControl(
              label: 'Speed',
              value: c.speed ?? d.state.speed ?? 1,
              display: _pct,
              presets: DeviceSheet.speedPresets,
              onChangeEnd: (v) => v <= 0.01
                  ? only({'on': false})
                  : edit((j) {
                      lightUp(j);
                      j['speed'] = v;
                    }),
            ),
          if (lit && d.has(Capability.volume))
            LevelControl(
              label: 'Volume',
              value: c.volume ?? d.state.volume ?? 0.2,
              display: (v) => '${(v * 100).round()}',
              presets: const [('10', 0.1), ('20', 0.2), ('40', 0.4)],
              onChangeEnd: (v) => edit((j) => j['volume'] = v),
            ),
          if (d.has(Capability.position))
            LevelControl(
              label: 'Position',
              value: c.position ?? d.state.position ?? 0,
              display: _open,
              presets: const [('Closed', 0.0), ('Half', 0.5), ('Open', 1.0)],
              onChangeEnd: (v) => edit((j) => j['position'] = v),
            ),
          if (d.has(Capability.lock)) ...[
            const SectionLabel('Lock'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              chip('lock', 'Lock', c.locked == true, () => only({'locked': true})),
              chip('unlock', 'Unlock', c.locked == false, () => only({'locked': false})),
              chip('lock-leave', 'Leave as it is', c.locked == null, () => edit((j) => j.remove('locked'))),
            ]),
          ],
          if (robot) ...[
            SectionLabel(d.kind == DeviceKind.mower ? 'Mowing' : 'Cleaning'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              chip('start', d.kind == DeviceKind.mower ? 'Mow' : 'Clean', c.action == DeviceAction.start,
                  () => edit((j) => j['action'] = DeviceAction.start.name)),
              if (d.has(Capability.dock))
                chip('dock', 'Go home', c.action == DeviceAction.dock, () => only({'action': DeviceAction.dock.name})),
              chip('robot-leave', 'Leave as it is', c.action == null, () => edit((j) => j.remove('action'))),
            ]),
          ],
          if (d.has(Capability.alarm)) ...[
            const SectionLabel('Alarm'),
            if (d.props['codeArmRequired'] == true)
              Text('This alarm needs its code to arm, so scenes leave it as it is.',
                  style: NType.body(13, color: p.textDim))
            else ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final arm in alarmArms(d))
                  chip('arm-${arm.name}', 'Arm ${alarmArmLabel(arm).toLowerCase()}', c.action == arm,
                      () => only({'action': arm.name})),
                chip('alarm-leave', 'Leave as it is', c.action == null, () => edit((j) => j.remove('action'))),
              ]),
              const SizedBox(height: 8),
              Text('Scenes never disarm an alarm. That needs its code.', style: NType.body(12.5, color: p.textDim)),
            ],
          ],
          if (d.has(Capability.mode) && d.modes.isNotEmpty && (lit || robot)) ...[
            SectionLabel(modeTitle(d)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in d.modes)
                chip('mode-$m', modeLabel(m), c.mode == m, () => edit((j) {
                      lightUp(j);
                      j['mode'] = m;
                    })),
              chip('mode-leave', 'Leave as it is', c.mode == null, () => edit((j) => j.remove('mode'))),
            ]),
          ],
          const SizedBox(height: 26),
          FilledButton.icon(
            key: const Key('step-try'),
            onPressed: () async {
              if (await store.command(d, c)) store.toast('${d.name} is now how ${s.name} sets it.');
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Try it on the device'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('step-capture'),
            onPressed: () {
              store.setSceneStep(s, SceneAction.capture(d));
              store.toast('Saved how ${d.name} is now.');
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('Use how it is now'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('step-remove'),
            onPressed: () {
              store.removeSceneStep(s, d.id);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.remove_circle_outline, color: NothingPalette.red),
            label: const Text('Take out of this scene', style: TextStyle(color: NothingPalette.red)),
          ),
        ],
      ),
    );
  }
}
