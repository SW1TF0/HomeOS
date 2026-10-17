import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation.dart';
import '../../models/device.dart';
import '../../models/scene.dart';
import '../../state/app_settings.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../../util/clock_text.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import 'scenes.dart';

/// Opens the list of automations.
Future<void> showAutomations(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AutomationsScreen()));

/// "When Hall sensor detects motion".
String whenText(HomeStore store, AutomationTrigger t) {
  final name = store.device(t.deviceId)?.name;
  return 'When ${name ?? 'a removed device'} ${t.eventFor(name ?? '')}';
}

/// "Turn Hall light on, off again after 5 min", "Run Movie night".
String thenText(HomeStore store, AutomationStep step) {
  if (step.sceneId case final id?) return 'Run ${store.scene(id)?.name ?? 'a removed scene'}';
  final name = store.device(step.deviceId ?? '')?.name ?? 'a removed device';
  final after = step.offAfter == null ? '' : ', off again after ${_minutes(step.offAfter!)}';
  return 'Turn $name ${step.on ? 'on' : 'off'}$after';
}

String _minutes(int m) => m < 60 ? '$m min' : '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}';

String hoursText(Automation a, bool h24) {
  if (a.anyTime) return 'Any time';
  DateTime at(int m) => DateTime(2000, 1, 1, m ~/ 60, m % 60);
  return 'Only ${clockText(at(a.from!), h24)} – ${clockText(at(a.to!), h24)}';
}

/// Devices an automation can switch: things that turn on and off, open and close, or go out and come home.
List<Device> _switchable(HomeStore store, bool on) =>
    store.devices.where((d) => SceneAction.turn(d, on) != null).toList();

/// Asks for the device and the change to wait for. Null when cancelled.
Future<AutomationTrigger?> pickTrigger(BuildContext context) async {
  final store = context.read<HomeStore>();
  final d = await pickOne<Device>(
    context,
    title: 'When which device…',
    options: store.devices,
    label: (d) => d.name,
    icon: (d) => deviceIcon(d.kind),
  );
  if (d == null || !context.mounted) return null;
  var t = await pickOne<AutomationTrigger>(
    context,
    title: '${d.name}…',
    options: AutomationTrigger.choicesFor(d),
    label: (t) => t.eventFor(d.name),
    icon: (t) => switch (t.kind) {
      TriggerKind.turnsOn || TriggerKind.opens || TriggerKind.unlocks => Icons.toggle_on_outlined,
      TriggerKind.turnsOff || TriggerKind.closes || TriggerKind.locks => Icons.toggle_off_outlined,
      TriggerKind.above => Icons.north_east,
      TriggerKind.below => Icons.south_east,
      TriggerKind.offline || TriggerKind.online => Icons.wifi_tethering,
      _ => Icons.sensors,
    },
  );
  if (t == null || !context.mounted) return null;
  if (t.needsNumber) {
    final now = AutomationTrigger.numberOf(d.state, t.label);
    final typed = await promptText(
      context,
      title: '${t.label} ${t.kind == TriggerKind.above ? 'above' : 'below'}',
      initial: now == null ? '' : now.round().toString(),
      hint: t.label == 'Battery' || t.label == 'Humidity' ? 'Percent, e.g. 20' : 'A number, e.g. 25',
      action: 'Next',
    );
    final n = double.tryParse((typed ?? '').trim().replaceAll(',', '.'));
    if (n == null) return null;
    t = t.copyWith(number: n);
  }
  return t;
}

/// Asks what to do: run a scene, or turn a device on or off. Null when cancelled.
Future<AutomationStep?> pickStep(BuildContext context) async {
  final store = context.read<HomeStore>();
  final what = await pickOne<String>(
    context,
    title: 'Then…',
    options: [if (store.scenes.isNotEmpty) 'scene', 'on', 'off'],
    label: (w) => switch (w) {
      'scene' => 'Run a scene',
      'on' => 'Turn something on',
      _ => 'Turn something off',
    },
    icon: (w) => switch (w) {
      'scene' => Icons.auto_awesome_outlined,
      'on' => Icons.lightbulb_outline,
      _ => Icons.power_settings_new,
    },
  );
  if (what == null || !context.mounted) return null;
  if (what == 'scene') {
    final s = await pickOne<Scene>(
      context,
      title: 'Run which scene?',
      options: store.scenes,
      label: (s) => s.name,
      icon: (s) => sceneIcon(s.icon),
    );
    return s == null ? null : AutomationStep.scene(s.id);
  }
  final on = what == 'on';
  final d = await pickOne<Device>(
    context,
    title: on ? 'Turn on…' : 'Turn off…',
    options: _switchable(store, on),
    label: (d) => d.name,
    icon: (d) => deviceIcon(d.kind),
  );
  return d == null ? null : AutomationStep.device(d.id, on: on);
}

/// Asks for a change and what to do then, saves it and opens it for the finer points.
Future<Automation?> createAutomation(BuildContext context) async {
  final store = context.read<HomeStore>();
  if (store.devices.isEmpty) {
    store.toast('Add some devices first, then make an automation.');
    return null;
  }
  final trigger = await pickTrigger(context);
  if (trigger == null || !context.mounted) return null;
  final step = await pickStep(context);
  if (step == null || !context.mounted) return null;
  final a = Automation(id: store.newId('auto'), trigger: trigger, then: step);
  store.addAutomation(a);
  await showAutomationSheet(context, a);
  return a;
}

class AutomationsScreen extends StatelessWidget {
  const AutomationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final h24 = context.select<AppSettings, bool>((s) => s.clock24);
    final p = context.palette;
    final list = store.automations;
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
                    key: const Key('automations-back'),
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(child: DotText('AUTOMATIONS', size: 30)),
                ]),
              ),
              Expanded(
                child: ListView(
                  key: const Key('automations-list'),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                      child: Text(
                          'When something happens at home, SmartMenuKJ does something. Automations run while the app '
                          'is open, and all the time on a phone or tablet that keeps your home online.',
                          style: NType.body(13.5, color: p.textDim)),
                    ),
                    FilledButton.icon(
                      key: const Key('automation-add'),
                      onPressed: () => createAutomation(context),
                      icon: const Icon(Icons.add),
                      label: const Text('New automation'),
                    ),
                    SectionLabel(list.isEmpty ? 'Ideas' : 'Yours',
                        trailing: list.isEmpty ? null : Text('${list.length}', style: NType.label(color: p.textDim))),
                    if (list.isEmpty)
                      NCard(
                        key: const Key('automations-empty'),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          for (final idea in const [
                            'When the hall sensor sees motion, turn the hall light on and off again after 5 minutes',
                            'When the TV turns on, run Movie night',
                            'When it gets colder than 18°, turn the heating on',
                            'When the front door unlocks after dark, turn the porch light on',
                          ])
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 7, right: 10),
                                  child: SizedBox(
                                      width: 5,
                                      height: 5,
                                      child: DecoratedBox(
                                          decoration: BoxDecoration(color: NothingPalette.red, shape: BoxShape.circle))),
                                ),
                                Expanded(child: Text(idea, style: NType.body(14, color: p.text))),
                              ]),
                            ),
                        ]),
                      ),
                    for (final a in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: NCard(
                          key: Key('automation-${a.id}'),
                          onTap: () => showAutomationSheet(context, a),
                          padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
                          child: Row(children: [
                            Icon(deviceIcon(store.device(a.trigger.deviceId)?.kind ?? DeviceKind.other),
                                color: a.enabled ? p.text : p.textDim),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(whenText(store, a.trigger),
                                    style: NType.body(14.5, color: a.enabled ? p.text : p.textDim, weight: 500)),
                                const SizedBox(height: 3),
                                Text(thenText(store, a.then), style: NType.body(13.5, color: p.textDim)),
                                const SizedBox(height: 3),
                                Text(
                                    [
                                      hoursText(a, h24),
                                      if (store.automationRuns[a.id] case final at?) 'Ran ${clockText(at, h24)}',
                                    ].join(' · ').toUpperCase(),
                                    style: NType.label(color: p.textDim)),
                              ]),
                            ),
                            Switch(
                              key: Key('automation-switch-${a.id}'),
                              value: a.enabled,
                              activeTrackColor: NothingPalette.red,
                              onChanged: (v) {
                                a.enabled = v;
                                store.automationChanged(a);
                              },
                            ),
                          ]),
                        ),
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

Future<void> showAutomationSheet(BuildContext context, Automation a) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => AutomationSheet(automationId: a.id),
    );

/// One automation: what sets it off, what it does, for how long, and in which hours.
class AutomationSheet extends StatelessWidget {
  const AutomationSheet({super.key, required this.automationId});
  final String automationId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final h24 = context.select<AppSettings, bool>((s) => s.clock24);
    final a = store.automations.where((x) => x.id == automationId).firstOrNull;
    if (a == null) return const SizedBox(height: 120, child: Center(child: Text('Automation removed')));
    final p = context.palette;
    final when = store.device(a.trigger.deviceId);
    final step = a.then;
    final target = step.deviceId == null ? null : store.device(step.deviceId!);

    Future<void> pickHours() async {
      final from = await showTimePicker(
        context: context,
        helpText: 'FROM',
        initialTime: TimeOfDay(hour: (a.from ?? 22 * 60) ~/ 60, minute: (a.from ?? 0) % 60),
      );
      if (from == null || !context.mounted) return;
      final to = await showTimePicker(
        context: context,
        helpText: 'UNTIL',
        initialTime: TimeOfDay(hour: (a.to ?? 6 * 60) ~/ 60, minute: (a.to ?? 0) % 60),
      );
      if (to == null) return;
      a
        ..from = from.hour * 60 + from.minute
        ..to = to.hour * 60 + to.minute;
      store.automationChanged(a);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scroll) => ListView(
        key: const Key('automation-sheet'),
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Row(children: [
            const Icon(Icons.bolt, size: 30),
            const SizedBox(width: 12),
            const Expanded(child: DotText('AUTOMATION', size: 28)),
            Switch(
              key: const Key('automation-enabled'),
              value: a.enabled,
              activeTrackColor: NothingPalette.red,
              onChanged: (v) {
                a.enabled = v;
                store.automationChanged(a);
              },
            ),
          ]),
          const SectionLabel('When', accent: true),
          NCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              key: const Key('automation-when'),
              leading: Icon(deviceIcon(when?.kind ?? DeviceKind.other)),
              title: Text(when?.name ?? 'A removed device'),
              subtitle: Text(a.trigger.eventFor(when?.name ?? '')),
              trailing: Icon(Icons.chevron_right, color: p.textDim),
              onTap: () async {
                final t = await pickTrigger(context);
                if (t == null) return;
                a.trigger = t;
                store.automationChanged(a);
              },
            ),
          ),
          const SectionLabel('Then'),
          NCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              key: const Key('automation-then'),
              leading: Icon(step.sceneId != null
                  ? sceneIcon(store.scene(step.sceneId!)?.icon ?? 'auto')
                  : deviceIcon(target?.kind ?? DeviceKind.other, active: step.on)),
              title: Text(thenText(store, step.withoutOff)),
              trailing: Icon(Icons.chevron_right, color: p.textDim),
              onTap: () async {
                final s = await pickStep(context);
                if (s == null) return;
                a.then = s;
                store.automationChanged(a);
              },
            ),
          ),
          if (step.deviceId != null && step.on) ...[
            const SectionLabel('Turn it off again'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in const [0, 1, 5, 15, 30, 60])
                NChip(
                  key: Key('off-after-$m'),
                  label: m == 0 ? 'Never' : 'After ${_minutes(m)}',
                  selected: (step.offAfter ?? 0) == m,
                  onTap: () {
                    a.then = step.withOffAfter(m);
                    store.automationChanged(a);
                  },
                ),
            ]),
          ],
          const SectionLabel('Hours'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            NChip(
              key: const Key('hours-any'),
              label: 'Any time',
              selected: a.anyTime,
              onTap: () {
                a
                  ..from = null
                  ..to = null;
                store.automationChanged(a);
              },
            ),
            NChip(
              key: const Key('hours-night'),
              label: 'At night',
              selected: a.from == 19 * 60 && a.to == 7 * 60,
              onTap: () {
                a
                  ..from = 19 * 60
                  ..to = 7 * 60;
                store.automationChanged(a);
              },
            ),
            NChip(
              key: const Key('hours-set'),
              label: a.anyTime || (a.from == 19 * 60 && a.to == 7 * 60) ? 'Pick hours' : hoursText(a, h24).substring(5),
              icon: Icons.schedule,
              selected: !a.anyTime && !(a.from == 19 * 60 && a.to == 7 * 60),
              onTap: pickHours,
            ),
          ]),
          const SizedBox(height: 26),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('automation-try'),
                onPressed: () => store.runAutomation(a),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Try it'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('automation-delete'),
                onPressed: () async {
                  final ok = await confirm(context,
                      title: 'Delete this automation?', body: '${whenText(store, a.trigger)}: ${thenText(store, a.then)}.');
                  if (!ok || !context.mounted) return;
                  store.removeAutomation(a);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
