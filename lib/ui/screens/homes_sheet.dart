import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../cloud/cloud_sync.dart';
import '../../cloud/firebase.dart';
import '../../state/home_store.dart';
import '../../state/repository.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';

Future<void> showHomesSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const HomesSheet(),
    );

/// Every home on this device: open one, add, rename, reorder or delete.
class HomesSheet extends StatelessWidget {
  const HomesSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final cloud = context.watch<CloudSync>();
    final p = context.palette;
    final homes = store.homes;

    Future<void> open(HomeEntry h) async {
      Navigator.pop(context);
      if (h.id == store.homeId) return;
      await store.openHome(h.id);
      store.toast('${h.name} is open.');
    }

    Future<void> remove(HomeEntry h) async {
      if (await confirm(context,
          title: 'Delete ${h.name}?',
          body: h.cloudId != null && cloud.signedIn
              ? 'Its rooms, devices, connections and scenes are deleted from your account and every device. Your other homes stay.'
              : 'Its rooms, devices, connections and scenes are deleted from this device. Your other homes stay.')) {
        try {
          await cloud.forget(h);
        } on CloudException catch (e) {
          store.toast('${h.name} was not deleted: ${e.message}');
          return;
        }
        await store.removeHome(h);
        store.toast('${h.name} deleted.');
      }
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          const DotText('HOMES', size: 30),
          const SizedBox(height: 6),
          Text('Each home has its own floor plan, devices, connections and scenes. Tap one to open it.',
              style: NType.body(14, color: p.textDim)),
          const SizedBox(height: 16),
          NCard(
            padding: EdgeInsets.zero,
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              proxyDecorator: (child, _, _) =>
                  Material(color: p.surfaceHigh, borderRadius: BorderRadius.circular(16), child: child),
              onReorderItem: store.moveHome,
              children: [
                for (var i = 0; i < homes.length; i++)
                  ListTile(
                    key: ValueKey('home-row-${homes[i].id}'),
                    contentPadding: const EdgeInsets.only(left: 16, right: 4),
                    onTap: () => open(homes[i]),
                    leading: homes[i].id == store.homeId
                        ? const Icon(Icons.radio_button_checked, color: NothingPalette.red)
                        : Icon(Icons.radio_button_unchecked, color: p.textDim),
                    title: Row(children: [
                      Flexible(child: Text(homes[i].name, overflow: TextOverflow.ellipsis)),
                      if (homes[i].cloudId != null && cloud.signedIn) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.cloud_done_outlined, size: 16, color: p.textDim),
                      ],
                    ]),
                    subtitle: homes[i].id == store.homeId
                        ? Text('Open · ${store.devices.length} devices · ${store.rooms.length} rooms')
                        : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Rename home',
                        onPressed: () async {
                          final name = await promptText(context, title: 'Rename home', initial: homes[i].name);
                          if (name != null && name.isNotEmpty) await store.renameHome(homes[i], name);
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      if (homes.length > 1)
                        IconButton(
                          key: ValueKey('home-delete-${homes[i].id}'),
                          tooltip: 'Delete home',
                          onPressed: () => remove(homes[i]),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ReorderableDragStartListener(
                        index: i,
                        child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.drag_indicator, color: p.textDim)),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('home-add'),
            onPressed: () async {
              final name = await promptText(context, title: 'New home', hint: 'Holiday house', action: 'Add');
              if (name == null || name.isEmpty || !context.mounted) return;
              Navigator.pop(context);
              final home = await store.addHome(name);
              store.toast('${home.name} added. Connect its devices on the Connect tab.');
            },
            icon: const Icon(Icons.add_home_outlined, size: 18),
            label: const Text('Add home'),
          ),
        ],
      ),
    );
  }
}
