import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../nav.dart';
import '../widgets/controls.dart';
import '../widgets/dialogs.dart';
import '../widgets/kj_widgets.dart';
import 'device_sheet.dart';

Future<void> showRoomSheet(BuildContext context, String roomId) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => RoomSheet(roomId: roomId),
    );

/// One room: its lights at a glance, all off / lights on, every device.
class RoomSheet extends StatelessWidget {
  const RoomSheet({super.key, required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final room = store.room(roomId);
    if (room == null) return const SizedBox(height: 100);
    final devices = store.devicesIn(roomId);
    final switchable = store.switchablesIn(roomId);
    final dimmable = devices.where((d) => d.kind == DeviceKind.light && d.has(Capability.brightness)).toList();
    final lit = dimmable.where((d) => d.state.on == true).toList();
    final level = lit.isEmpty ? 0.0 : lit.map((d) => d.state.brightness ?? 1).reduce((a, b) => a + b) / lit.length;
    final on = devices.where((d) => d.countsAsOn).length;
    final temp = averageTemperature(devices);
    final nav = context.read<AppNav>();

    void toMap({bool edit = false}) {
      Navigator.pop(context);
      nav.openMap(edit: edit, roomId: roomId);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          Row(children: [
            Expanded(child: DisplayText(room.name, size: 32, maxLines: 2)),
            IconButton(
              key: const Key('room-rename'),
              tooltip: 'Rename room',
              onPressed: () async {
                final name = await promptText(context, title: 'Rename room', initial: room.name);
                if (name != null && name.isNotEmpty) store.renameRoom(room, name);
              },
              icon: const Icon(Icons.edit_outlined),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              devices.isEmpty ? 'No devices' : '$on of ${devices.length} on',
              if (temp != null) '${temp.toStringAsFixed(1)}°',
              store.floors.length > 1 ? (store.floors.where((f) => f.id == room.floorId).firstOrNull?.name ?? '') : '',
            ].where((t) => t.isNotEmpty).join(' · '),
            style: NType.label(color: p.textDim),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('room-all-off'),
                onPressed: switchable.any((d) => d.state.on == true) ? () => store.setPower(switchable, false) : null,
                icon: const Icon(Icons.power_settings_new, size: 18),
                label: const Text('All off'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const Key('room-lights-on'),
                onPressed: switchable.isEmpty
                    ? null
                    : () {
                        final lights = switchable.where((d) => d.kind == DeviceKind.light);
                        store.setPower(lights.isEmpty ? switchable : lights, true);
                      },
                icon: const Icon(Icons.lightbulb_outline, size: 18),
                label: const Text('Lights on'),
              ),
            ),
          ]),
          if (dimmable.isNotEmpty)
            LevelControl(
              key: const Key('room-lights'),
              label: 'Lights',
              value: level,
              display: (v) => v <= 0.005 ? 'OFF' : '${(v * 100).round()}%',
              presets: const [('25%', 0.25), ('50%', 0.5), ('75%', 0.75), ('100%', 1.0)],
              onLive: (v) => store.setBrightness(dimmable, v),
              onChangeEnd: (v) => store.setBrightness(dimmable, v),
            ),
          SectionLabel('Devices', trailing: Text('${devices.length}', style: NType.label(color: p.textDim))),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No devices yet. Drag some into this room on the map.',
                  textAlign: TextAlign.center, style: NType.body(14, color: p.textDim)),
            ),
          DeviceGrid(devices: devices, aspect: 1.1),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('room-show-map'),
                onPressed: () => toMap(),
                icon: const Icon(Icons.grid_view, size: 18),
                label: const Text('On the map'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('room-edit-map'),
                onPressed: () => toMap(edit: true),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit room'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// A grid of device tiles that fits its width, for sheets.
class DeviceGrid extends StatelessWidget {
  const DeviceGrid({super.key, required this.devices, this.aspect = 1.05});
  final List<Device> devices;
  final double aspect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        return GridView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: deviceGridDelegate(c.maxWidth),
          children: [for (final d in devices) DeviceCard(device: d)],
        );
      });
}

Future<void> showDeviceListSheet(
  BuildContext context, {
  required String title,
  required List<Device> Function(HomeStore store) select,
  String? actionLabel,
  IconData actionIcon = Icons.power_settings_new,
  Future<void> Function(HomeStore store, List<Device> devices)? action,
  String empty = 'Nothing here right now.',
}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => _DeviceListSheet(
          title: title, select: select, actionLabel: actionLabel, actionIcon: actionIcon, action: action, empty: empty),
    );

/// A live list of devices picked from the whole home, like "lights that are on".
class _DeviceListSheet extends StatelessWidget {
  const _DeviceListSheet({
    required this.title,
    required this.select,
    required this.actionLabel,
    required this.actionIcon,
    required this.action,
    required this.empty,
  });

  final String title;
  final List<Device> Function(HomeStore store) select;
  final String? actionLabel;
  final IconData actionIcon;
  final Future<void> Function(HomeStore store, List<Device> devices)? action;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final devices = select(store);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          DisplayText(title, size: 30, maxLines: 2),
          const SizedBox(height: 4),
          Text('${devices.length} DEVICE${devices.length == 1 ? '' : 'S'}', style: NType.label(color: p.textDim)),
          if (action != null && actionLabel != null && devices.isNotEmpty) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('list-action'),
              onPressed: () => action!(store, devices),
              icon: Icon(actionIcon, size: 18),
              label: Text(actionLabel!),
            ),
          ],
          const SizedBox(height: 16),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(empty, textAlign: TextAlign.center, style: NType.body(14, color: p.textDim)),
            )
          else
            DeviceGrid(devices: devices),
        ],
      ),
    );
  }
}
