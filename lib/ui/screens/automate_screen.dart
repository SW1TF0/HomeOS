import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../models/scene.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../util/sounds.dart';
import '../widgets/kj_widgets.dart';
import 'automations.dart';
import 'profile_menu.dart';
import 'scenes.dart';
import '../../l10n/text.dart';

/// The Automate tab: scenes (many devices at once, by a tap or a schedule) and automations (when something
/// happens, do something), in one place.
class AutomateScreen extends StatelessWidget {
  const AutomateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final scenes = store.scenes;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          key: const Key('automate-list'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            const Row(children: [Expanded(child: DisplayText('Automate', size: 34)), ProfileButton()]),
            const SizedBox(height: 4),
            Text('Scenes set many devices at once. Automations run things for you when something happens.',
                style: NType.body(15, color: p.textDim)),
            SectionLabel('Scenes',
                trailing: TextButton.icon(
                  key: const Key('automate-new-scene'),
                  onPressed: () => createScene(context),
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('New'),
                )),
            if (scenes.isEmpty)
              NCard(
                key: const Key('automate-scenes-empty'),
                onTap: () => createScene(context),
                child: Row(children: [
                  const Icon(Icons.auto_awesome_outlined),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text('Make a scene like "Good night" to turn off the lights and lock the door with one tap.',
                        style: NType.body(14, color: p.textDim)),
                  ),
                ]),
              ),
            for (final s in scenes)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: _SceneRow(scene: s)),
            const SectionLabel('Automations'),
            ...automationItems(context),
          ],
        ),
      ),
    );
  }
}

/// A scene: its icon and what it does; tap to change it, Run to run it now.
class _SceneRow extends StatefulWidget {
  const _SceneRow({required this.scene});
  final Scene scene;

  @override
  State<_SceneRow> createState() => _SceneRowState();
}

class _SceneRowState extends State<_SceneRow> {
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    Sounds.scene();
    await context.read<HomeStore>().runScene(widget.scene);
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = widget.scene;
    final color = sceneColor(s.icon);
    return NCard(
      key: Key('automate-scene-${s.id}'),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      onTap: () => showSceneSheet(context, s),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(sceneIcon(s.icon),
              size: 21, color: color.computeLuminance() < 0.6 ? Colors.white : Colors.black),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(16, color: p.text, weight: 600)),
            const SizedBox(height: 2),
            Text(sceneSubtitle(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(13.5, color: p.textDim)),
          ]),
        ),
        _running
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 22),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : TextButton.icon(
                key: Key('automate-run-${s.id}'),
                onPressed: _run,
                icon: const Icon(CupertinoIcons.play_fill, size: 16),
                label: const Text('Run'),
              ),
      ]),
    );
  }
}
