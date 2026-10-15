import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/nothing_widgets.dart';
import 'device_sheet.dart';

/// Overview: clock, what's on, favourites and rooms.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onOpenMap});
  final VoidCallback onOpenMap;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final favorites = store.favorites;
    final active = store.activeCount;

    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / 190).floor().clamp(2, 6);
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverList.list(children: [
              Row(children: [
                Text('SMARTMENUKJ', style: NType.label(color: p.textDim)),
                const Spacer(),
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: NothingPalette.red, shape: BoxShape.circle)),
              ]),
              const SizedBox(height: 18),
              const _Clock(),
              const SizedBox(height: 8),
              Text(
                active == 0 ? 'Everything is off.' : '$active of ${store.devices.length} devices active.',
                style: NType.body(16, color: p.textDim),
              ),
              const SizedBox(height: 18),
              Wrap(spacing: 10, runSpacing: 10, children: [
                OutlinedButton.icon(
                  onPressed: active == 0 ? null : store.allOff,
                  icon: const Icon(Icons.power_settings_new, size: 18),
                  label: const Text('All off'),
                ),
                OutlinedButton.icon(
                  onPressed: onOpenMap,
                  icon: const Icon(Icons.grid_view, size: 18),
                  label: const Text('Open map'),
                ),
              ]),
            ]),
          ),
          if (favorites.isNotEmpty) ...[
            const SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: 20), sliver: SliverToBoxAdapter(child: SectionLabel('Favourites', accent: true))),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: columns,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.05,
                children: [
                  for (final d in favorites)
                    DeviceTile(
                      device: d,
                      subtitle: _withRoom(store, d),
                      onTap: () => store.toggle(d),
                      onLongPress: () => showDeviceSheet(context, d),
                    ),
                ],
              ),
            ),
          ],
          const SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: 20), sliver: SliverToBoxAdapter(child: SectionLabel('Rooms'))),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            sliver: SliverGrid.count(
              crossAxisCount: (columns / 1.5).ceil().clamp(1, 4),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.9,
              children: [for (final r in store.rooms) _RoomCard(room: r)],
            ),
          ),
        ],
      );
    });
  }

  static String _withRoom(HomeStore store, Device d) {
    final room = store.room(d.roomId);
    return room == null ? describeState(d) : '${room.name} · ${describeState(d)}';
  }
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int v) => v.toString().padLeft(2, '0');
    const days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    final p = context.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DotText('${two(_now.hour)}:${two(_now.minute)}', size: 76),
      const SizedBox(height: 4),
      Text('${days[_now.weekday - 1]} ${_now.day} ${months[_now.month - 1]}', style: NType.label(color: p.textDim)),
    ]);
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({required this.room});
  final Room room;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final devices = store.devicesIn(room.id);
    final on = devices.where((d) => d.state.isActive && d.kind != DeviceKind.lock).length;
    final temp = devices
        .map((d) => d.state.currentTemp?.toStringAsFixed(1) ?? d.state.readings['Temperature']?.split(' ').first)
        .whereType<String>()
        .firstOrNull;
    return NCard(
      onTap: () => _showRoom(context, room),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: DotText(room.name, size: 22, maxLines: 1)),
          if (temp != null) Text('$temp°', style: NType.body(14, color: p.textDim)),
        ]),
        const Spacer(),
        Row(children: [
          for (var i = 0; i < devices.length && i < 12; i++)
            Container(
              margin: const EdgeInsets.only(right: 4),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: devices[i].state.isActive ? p.text : p.border,
              ),
            ),
        ]),
        const SizedBox(height: 6),
        Text(devices.isEmpty ? 'No devices' : '$on on · ${devices.length} devices', style: NType.body(12.5, color: p.textDim)),
      ]),
    );
  }

  static void _showRoom(BuildContext context, Room room) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: 720),
        builder: (_) => RoomSheet(roomId: room.id),
      );
}

/// Devices in one room, with all on / all off.
class RoomSheet extends StatelessWidget {
  const RoomSheet({super.key, required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final room = store.room(roomId);
    if (room == null) return const SizedBox(height: 100);
    final devices = store.devicesIn(roomId);
    final switchable = devices.where((d) => d.has(Capability.onOff));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          DotText(room.name, size: 32),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: OutlinedButton(
                    onPressed: switchable.isEmpty ? null : () => store.setPower(switchable, false), child: const Text('All off'))),
            const SizedBox(width: 12),
            Expanded(
                child: FilledButton(
                    onPressed: switchable.isEmpty ? null : () => store.setPower(switchable, true), child: const Text('All on'))),
          ]),
          const SizedBox(height: 16),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No devices yet. Drag some into this room on the map.',
                  textAlign: TextAlign.center, style: NType.body(14, color: context.palette.textDim)),
            ),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.15,
            children: [
              for (final d in devices)
                DeviceTile(device: d, onTap: () => store.toggle(d), onLongPress: () => showDeviceSheet(context, d)),
            ],
          ),
        ],
      ),
    );
  }
}
