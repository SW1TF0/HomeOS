import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../cloud/cloud_sync.dart';
import '../../models/device.dart';
import '../../models/home.dart';
import '../../state/app_settings.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../../util/text.dart';
import '../nav.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import 'account_sheet.dart';
import 'device_sheet.dart';
import 'homes_sheet.dart';
import 'profile_menu.dart';
import 'room_sheet.dart';
import 'automations.dart';
import 'scenes.dart';

/// Overview: clock, what's going on, scenes, favourites and rooms.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final nav = context.read<AppNav>();
    final p = context.palette;
    final favorites = store.favorites;
    final active = store.activeCount;

    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / 190).floor().clamp(2, 6);
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            sliver: SliverList.list(children: [
              Row(children: [
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: InkWell(
                        key: const Key('home-switch'),
                        onTap: () => showHomesSheet(context),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Flexible(
                              child: Text(store.homeName.toUpperCase(),
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.label(color: p.text)),
                            ),
                            const SizedBox(width: 8),
                            Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(color: NothingPalette.red, shape: BoxShape.circle)),
                            const SizedBox(width: 4),
                            Icon(Icons.unfold_more, size: 16, color: p.textDim),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      key: const Key('home-edit'),
                      onPressed: () => showHomeEditor(context),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('Edit home'),
                    ),
                  ]),
                ),
                const ProfileButton(),
              ]),
              const SizedBox(height: 8),
              const _Clock(),
              const SizedBox(height: 8),
              Text(
                active == 0 ? 'Everything is off.' : '$active of ${store.devices.length} devices active.',
                style: NType.body(16, color: p.textDim),
              ),
              const SizedBox(height: 14),
              const _StatusStrip(),
              const _AwayCard(),
            ]),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.list(children: [
              if (store.showSampleCleanup) ...[
                const SizedBox(height: 18),
                NCard(
                  key: const Key('sample-cleanup'),
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                  child: Row(children: [
                    const Icon(Icons.blur_on),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text('Your real devices are here. Remove the sample home?',
                          style: NType.body(14, color: p.text, weight: 500)),
                    ),
                    TextButton(
                      key: const Key('sample-remove'),
                      onPressed: () {
                        store.removeSampleHome();
                        store.toast('Sample devices removed.');
                      },
                      child: const Text('Remove'),
                    ),
                  ]),
                ),
              ],
              SectionLabel('Scenes',
                  trailing: _HeaderAction(
                      key: const Key('automations-open'),
                      label: store.automations.isEmpty ? 'Automations' : 'Automations · ${store.automations.length}',
                      onTap: () => showAutomations(context))),
              const ScenesRow(),
              SectionLabel('Favourites',
                  accent: true,
                  trailing: _HeaderAction(
                      key: const Key('favourites-edit'), label: 'Edit', onTap: () => showHomeEditor(context))),
              if (favorites.isEmpty)
                NCard(
                  key: const Key('favourites-empty'),
                  onTap: () => pickFavorites(context),
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    const Icon(Icons.star_border),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text('Pick the devices you use most to keep them here.',
                          style: NType.body(14, color: p.textDim)),
                    ),
                    const Icon(Icons.add),
                  ]),
                ),
            ]),
          ),
          if (favorites.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: columns,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.05,
                children: [for (final d in favorites) DeviceCard(device: d, subtitle: _withRoom(store, d))],
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverToBoxAdapter(
              child: SectionLabel('Rooms',
                  trailing: _HeaderAction(
                      key: const Key('rooms-edit'),
                      label: 'Edit',
                      onTap: () => nav.openMap(edit: true))),
            ),
          ),
          if (store.rooms.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverToBoxAdapter(
                child: NCard(
                  onTap: () => nav.openMap(edit: true),
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    const Icon(Icons.add_home_outlined),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Text('Draw your rooms on the map to group your devices.',
                            style: NType.body(14, color: p.textDim))),
                    const Icon(Icons.arrow_outward, size: 18),
                  ]),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            sliver: SliverGrid.count(
              crossAxisCount: (columns / 1.5).ceil().clamp(1, 4),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.6,
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

/// Off the home Wi-Fi with nothing at home passing commands on: says why nothing answers and what fixes it.
class _AwayCard extends StatelessWidget {
  const _AwayCard();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final cloud = context.watch<CloudSync>();
    final p = context.palette;
    if (!store.offHomeNetwork || cloud.online || !store.devices.any(store.networked)) return const SizedBox.shrink();
    final home = store.homeName;
    final (text, action) = !cloud.available
        ? ('Your devices only answer on your home Wi-Fi.', null)
        : !cloud.signedIn
            ? (
                'Your devices only answer on your home Wi-Fi. To switch them from here, sign in and keep a second '
                    'device at home online.',
                'Set up'
              )
            : cloud.isHub
                ? (
                    'This phone is the one keeping $home online, but it has left the home Wi-Fi. Turn that on on a '
                        'device that stays at home instead.',
                    'Account'
                  )
                : cloud.hubSeen != null
                    ? (
                        '${cloud.hubName ?? 'The device at home'} is not answering, so $home cannot be reached from '
                            'here. Check that it is on, plugged in and on the Wi-Fi, with SmartMenuKJ open.',
                        'Details'
                      )
                    : (
                        'Your devices only answer on your home Wi-Fi. To switch them from here, keep a second phone, '
                            'tablet or computer at home online with this account.',
                        'How'
                      );
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: NCard(
        key: const Key('away-card'),
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(children: [
          const Icon(Icons.wifi_off, color: NothingPalette.red),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AWAY FROM HOME', style: NType.label(color: p.text)),
              const SizedBox(height: 4),
              Text(text, style: NType.body(14, color: p.textDim)),
            ]),
          ),
          if (action != null)
            TextButton(key: const Key('away-set-up'), onPressed: () => showAccountSheet(context), child: Text(action)),
        ]),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(label.toUpperCase(), style: NType.label(color: context.palette.text)),
        ),
      );
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
    final clock24 = context.select<AppSettings, bool>((s) => s.clock24);
    final hour = clock24 ? _now.hour : (_now.hour % 12 == 0 ? 12 : _now.hour % 12);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DotText('${two(hour)}:${two(_now.minute)}', key: const Key('home-clock'), size: 76),
      const SizedBox(height: 4),
      Text(
          '${days[_now.weekday - 1]} ${_now.day} ${months[_now.month - 1]}${clock24 ? '' : ' · ${_now.hour < 12 ? 'AM' : 'PM'}'}',
          style: NType.label(color: p.textDim)),
    ]);
  }
}

/// Pills that sum up the home: smoke or a leak first, then lights on, inside
/// temperature, locks, the alarm, blinds, what is playing, robots at work,
/// what is not answering. Each opens those devices.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final cloud = context.watch<CloudSync>();
    final all = store.devices;
    List<Device> ofKind(DeviceKind k) => all.where((d) => d.kind == k).toList();
    final lights = ofKind(DeviceKind.light);
    final litCount = lights.where((d) => d.state.on == true && d.state.reachable).length;
    final temp = averageTemperature(all);
    final locks = ofKind(DeviceKind.lock);
    final unlocked = locks.where((d) => d.state.locked == false).length;
    final covers = ofKind(DeviceKind.cover);
    final open = covers.where((d) => (d.state.position ?? 0) > 0.01).length;
    final media = ofKind(DeviceKind.media);
    final playing = media.where((d) => d.state.on == true).toList();
    final offline = all.where((d) => !d.state.reachable).length;
    final alarms = ofKind(DeviceKind.alarm);
    final sounding = alarms.where((d) => const {Activity.triggered, Activity.pending}.contains(d.state.activity)).toList();
    final armed = alarms.where((d) => d.state.isActive).toList();
    bool isRobot(Device d) => d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower;
    final working = all
        .where((d) => isRobot(d) && const {Activity.running, Activity.returning, Activity.paused, Activity.error}.contains(d.state.activity))
        .toList();
    final stuck = working.where((d) => d.state.activity == Activity.error).toList();
    // Sensors say "Smoke!", "CO!" or "Leak!" when something is wrong.
    bool alarming(Device d) => d.state.readings.values.any((v) => v.endsWith('!'));
    final danger = all.where(alarming).toList();

    final anyOn = store.activeCount > 0;
    final pills = <Widget>[
      if (danger.isNotEmpty)
        _Pill(
          key: const Key('status-danger'),
          icon: Icons.warning_amber_rounded,
          label: '${danger.first.name}: ${danger.first.state.readings.values.firstWhere((v) => v.endsWith('!'))}'
              '${danger.length > 1 ? ' +${danger.length - 1}' : ''}',
          alert: true,
          onTap: () => danger.length == 1
              ? showDeviceSheet(context, danger.first)
              : showDeviceListSheet(context, title: 'WARNINGS', select: (s) => s.devices.where(alarming).toList()),
        ),
      if (cloud.away)
        _Pill(
          key: const Key('status-away'),
          icon: Icons.public,
          label: 'Away · through ${cloud.hubName ?? 'home device'}',
          onTap: () => showAccountSheet(context),
        ),
      _Pill(
        key: const Key('home-all-off'),
        icon: Icons.power_settings_new,
        label: 'All off',
        filled: anyOn,
        onTap: anyOn ? store.allOff : null,
      ),
      if (lights.isNotEmpty)
        _Pill(
          key: const Key('status-lights'),
          icon: litCount > 0 ? Icons.lightbulb : Icons.lightbulb_outline,
          label: litCount == 0 ? 'Lights off' : '$litCount light${litCount == 1 ? '' : 's'} on',
          onTap: () => showDeviceListSheet(context,
              title: 'LIGHTS',
              select: (s) => s.devices.where((d) => d.kind == DeviceKind.light).toList()
                ..sort((a, b) => (b.state.on == true ? 1 : 0).compareTo(a.state.on == true ? 1 : 0)),
              actionLabel: 'All lights off',
              action: (s, list) => s.setPower(list, false)),
        ),
      if (temp != null)
        _Pill(
          key: const Key('status-temp'),
          icon: Icons.device_thermostat,
          label: '${temp.toStringAsFixed(1)}° inside',
          onTap: () => showDeviceListSheet(context,
              title: 'CLIMATE', select: (s) => s.devices.where((d) => temperatureOf(d) != null || d.kind == DeviceKind.climate).toList()),
        ),
      if (locks.isNotEmpty)
        _Pill(
          key: const Key('status-locks'),
          icon: unlocked > 0 ? Icons.lock_open : Icons.lock_outline,
          label: unlocked == 0 ? (locks.length == 1 ? 'Locked' : 'All locked') : '$unlocked unlocked',
          alert: unlocked > 0,
          onTap: () => showDeviceListSheet(context,
              title: 'LOCKS',
              select: (s) => s.devices.where((d) => d.kind == DeviceKind.lock).toList(),
              actionLabel: 'Lock all',
              actionIcon: Icons.lock_outline,
              action: (s, list) => Future.wait(list.map((d) => s.command(d, const DeviceCommand(locked: true))))),
        ),
      if (alarms.isNotEmpty)
        _Pill(
          key: const Key('status-alarm'),
          icon: sounding.isNotEmpty ? Icons.notifications_active : (armed.isEmpty ? Icons.shield_outlined : Icons.shield),
          label: sounding.isNotEmpty
              ? '${sounding.first.name}: ${activityLabel(DeviceKind.alarm, sounding.first.state.activity)}'
              : armed.isEmpty
                  ? 'Alarm off'
                  : (alarms.length == 1 ? activityLabel(DeviceKind.alarm, armed.first.state.activity) : '${armed.length} armed'),
          alert: sounding.isNotEmpty,
          onTap: () => alarms.length == 1
              ? showDeviceSheet(context, alarms.first)
              : showDeviceListSheet(context, title: 'ALARM', select: (s) => s.devices.where((d) => d.kind == DeviceKind.alarm).toList()),
        ),
      if (covers.isNotEmpty)
        _Pill(
          key: const Key('status-blinds'),
          icon: open > 0 ? Icons.blinds : Icons.blinds_closed,
          label: open == 0 ? 'Blinds closed' : '$open blind${open == 1 ? '' : 's'} open',
          onTap: () => showDeviceListSheet(context,
              title: 'BLINDS',
              select: (s) => s.devices.where((d) => d.kind == DeviceKind.cover).toList(),
              actionLabel: 'Close all',
              actionIcon: Icons.blinds_closed,
              action: (s, list) => Future.wait(list.map((d) => s.command(d, const DeviceCommand(position: 0))))),
        ),
      if (playing.isNotEmpty)
        _Pill(
          key: const Key('status-media'),
          icon: Icons.tv,
          label: playing.length == 1 ? '${playing.first.name} on' : '${playing.length} playing',
          onTap: () => showDeviceListSheet(context,
              title: 'MEDIA',
              select: (s) => s.devices.where((d) => d.kind == DeviceKind.media).toList(),
              actionLabel: 'All off',
              action: (s, list) => s.setPower(list, false)),
        ),
      if (working.isNotEmpty)
        _Pill(
          key: const Key('status-robots'),
          icon: deviceIcon(working.first.kind),
          label: stuck.isNotEmpty
              ? '${stuck.first.name} needs help'
              : (working.length == 1
                  ? '${working.first.name}: ${activityLabel(working.first.kind, working.first.state.activity).toLowerCase()}'
                  : '${working.length} robots at work'),
          alert: stuck.isNotEmpty,
          onTap: () => showDeviceListSheet(context,
              title: 'ROBOTS',
              select: (s) => s.devices.where(isRobot).toList(),
              actionLabel: 'All go home',
              actionIcon: Icons.home_outlined,
              action: (s, list) => Future.wait(list
                  .where((d) => d.has(Capability.dock))
                  .map((d) => s.command(d, const DeviceCommand(action: DeviceAction.dock))))),
        ),
      if (offline > 0)
        _Pill(
          key: const Key('status-offline'),
          icon: Icons.wifi_off,
          label: '$offline not responding',
          alert: true,
          onTap: () => showDeviceListSheet(context,
              title: 'NOT RESPONDING',
              select: (s) => s.devices.where((d) => !d.state.reachable).toList(),
              empty: 'Everything is answering again.'),
        ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(children: [
        for (final pill in pills) ...[pill, const SizedBox(width: 8)],
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(
      {super.key, required this.icon, required this.label, required this.onTap, this.alert = false, this.filled = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool alert;

  /// Drawn inverted, for the one action pill (All off).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = filled
        ? p.background
        : (alert ? NothingPalette.red : (onTap == null ? p.textDim : p.text));
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: filled ? p.text : p.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: filled ? p.text : (alert ? NothingPalette.red : p.border)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 7),
            Text(label, style: NType.body(13, color: color, weight: 500)),
          ]),
        ),
      ),
    );
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
    final switchable = store.switchablesIn(room.id);
    final on = devices.where((d) => d.countsAsOn).length;
    final anyOn = switchable.any((d) => d.state.on == true);
    final temp = averageTemperature(devices);
    return NCard(
      key: Key('room-card-${room.id}'),
      onTap: () => showRoomSheet(context, room.id),
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DotText(room.name, size: 22, maxLines: 1),
            ),
          ),
          if (switchable.isNotEmpty)
            Semantics(
              button: true,
              toggled: anyOn,
              label: anyOn ? 'Turn ${room.name} off' : 'Turn ${room.name} lights on',
              child: GestureDetector(
                key: Key('room-power-${room.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => store.toggleRoom(room.id),
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: anyOn ? p.text : Colors.transparent,
                      border: Border.all(color: anyOn ? p.text : p.border),
                    ),
                    child: Icon(Icons.power_settings_new, size: 17, color: anyOn ? p.background : p.text),
                  ),
                ),
              ),
            ),
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
                color: !devices[i].state.reachable
                    ? NothingPalette.red
                    : (devices[i].state.isActive ? p.text : p.border),
              ),
            ),
        ]),
        const SizedBox(height: 6),
        Text(
          [
            devices.isEmpty ? 'No devices' : '$on on · ${counted(devices.length, 'device')}',
            if (temp != null) '${temp.toStringAsFixed(1)}°',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NType.body(12.5, color: p.textDim),
        ),
      ]),
    );
  }
}

// ---- Edit home ----------------------------------------------------------------------

/// Lets the user pick which devices are favourites, and saves the choice.
Future<void> pickFavorites(BuildContext context) async {
  final store = context.read<HomeStore>();
  if (store.devices.isEmpty) {
    store.toast('Add some devices first.');
    return;
  }
  final picked = await pickMany<Device>(
    context,
    title: 'Favourites',
    options: store.devices,
    label: (d) => d.name,
    subtitle: (d) => store.room(d.roomId)?.name ?? 'No room',
    icon: (d) => deviceIcon(d.kind),
    initial: store.favorites.toSet(),
    action: 'Save',
  );
  if (picked != null) store.setFavorites(picked);
}

Future<void> showHomeEditor(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const HomeEditor(),
    );

/// Edit the home screen and the home itself: favourites and their order,
/// the order of rooms and scenes, and a way into the floor plan editor.
class HomeEditor extends StatelessWidget {
  const HomeEditor({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final favorites = store.favorites;
    final rooms = store.rooms;
    final scenes = store.scenes;
    Widget handle(int i) => ReorderableDragStartListener(
          index: i,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.drag_indicator, color: p.textDim),
          ),
        );
    Widget proxy(Widget child, int index, Animation<double> a) => Material(
          color: p.surfaceHigh,
          borderRadius: BorderRadius.circular(16),
          child: child,
        );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          const DotText('EDIT HOME', size: 30),
          const SizedBox(height: 6),
          Text('Change what the home screen shows, and in which order. Drag the handles to reorder.',
              style: NType.body(14, color: p.textDim)),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('edit-floor-plan'),
            onPressed: () {
              Navigator.pop(context);
              context.read<AppNav>().openMap(edit: true);
            },
            icon: const Icon(Icons.grid_view, size: 18),
            label: const Text('Edit rooms and floor plan'),
          ),
          SectionLabel('Favourites',
              accent: true,
              trailing: _HeaderAction(key: const Key('favourites-pick'), label: 'Choose', onTap: () => pickFavorites(context))),
          if (favorites.isEmpty)
            Text('No favourites yet. Tap Choose, or the star on any device.', style: NType.body(13.5, color: p.textDim)),
          NCard(
            padding: EdgeInsets.zero,
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              proxyDecorator: proxy,
              onReorderItem: store.moveFavorite,
              children: [
                for (var i = 0; i < favorites.length; i++)
                  ListTile(
                    key: ValueKey('fav-${favorites[i].id}'),
                    contentPadding: const EdgeInsets.only(left: 16, right: 4),
                    leading: Icon(deviceIcon(favorites[i].kind)),
                    title: Text(favorites[i].name),
                    subtitle: Text(store.room(favorites[i].roomId)?.name ?? 'No room'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Remove from favourites',
                        onPressed: () => store.updateDevice(favorites[i], favorite: false),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      handle(i),
                    ]),
                  ),
              ],
            ),
          ),
          SectionLabel('Rooms',
              trailing: Text('${rooms.length}', style: NType.label(color: p.textDim))),
          if (rooms.isEmpty)
            Text('No rooms yet. Draw them on the floor plan.', style: NType.body(13.5, color: p.textDim)),
          NCard(
            padding: EdgeInsets.zero,
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              proxyDecorator: proxy,
              onReorderItem: store.moveRoom,
              children: [
                for (var i = 0; i < rooms.length; i++)
                  ListTile(
                    key: ValueKey('room-row-${rooms[i].id}'),
                    contentPadding: const EdgeInsets.only(left: 16, right: 4),
                    leading: const Icon(Icons.meeting_room_outlined),
                    title: Text(rooms[i].name),
                    subtitle: Text([
                      counted(store.devicesIn(rooms[i].id).length, 'device'),
                      if (store.floors.length > 1)
                        store.floors.where((f) => f.id == rooms[i].floorId).firstOrNull?.name ?? '',
                    ].join(' · ')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Rename room',
                        onPressed: () async {
                          final name = await promptText(context, title: 'Rename room', initial: rooms[i].name);
                          if (name != null && name.isNotEmpty) store.renameRoom(rooms[i], name);
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      handle(i),
                    ]),
                  ),
              ],
            ),
          ),
          if (scenes.isNotEmpty) ...[
            SectionLabel('Scenes', trailing: Text('${scenes.length}', style: NType.label(color: p.textDim))),
            NCard(
              padding: EdgeInsets.zero,
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                proxyDecorator: proxy,
                onReorderItem: store.moveScene,
                children: [
                  for (var i = 0; i < scenes.length; i++)
                    ListTile(
                      key: ValueKey('scene-row-${scenes[i].id}'),
                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      leading: Icon(sceneIcon(scenes[i].icon)),
                      title: Text(scenes[i].name),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Edit scene',
                          onPressed: () => showSceneSheet(context, scenes[i]),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        handle(i),
                      ]),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
