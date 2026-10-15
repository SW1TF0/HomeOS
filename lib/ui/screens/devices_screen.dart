import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../state/seed.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import 'device_sheet.dart';

/// Every device, grouped by room, with search and add.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.onOpenConnect});
  final VoidCallback onOpenConnect;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  String _query = '';
  DeviceKind? _kind;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final q = _query.toLowerCase();
    final shown = store.devices
        .where((d) => _kind == null || d.kind == _kind)
        .where((d) => q.isEmpty || d.name.toLowerCase().contains(q) || (store.room(d.roomId)?.name.toLowerCase().contains(q) ?? false))
        .toList();
    final groups = <String?, List<Device>>{};
    for (final r in store.rooms) {
      final list = shown.where((d) => d.roomId == r.id).toList();
      if (list.isNotEmpty) groups[r.id] = list;
    }
    final loose = shown.where((d) => store.room(d.roomId) == null).toList();
    if (loose.isNotEmpty) groups[null] = loose;
    final kinds = store.devices.map((d) => d.kind).toSet().toList()..sort((a, b) => a.index.compareTo(b.index));

    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / 190).floor().clamp(2, 6);
      return CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          sliver: SliverList.list(children: [
            Row(children: [
              const Expanded(child: DotText('DEVICES', size: 34)),
              FilledButton.icon(
                key: const Key('add-device'),
                onPressed: () => _addDevice(context, store),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ]),
            const SizedBox(height: 4),
            Text('${store.devices.length} devices · ${store.integrations.length} connections',
                style: NType.body(14, color: p.textDim)),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search devices or rooms'),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                NChip(label: 'All', selected: _kind == null, onTap: () => setState(() => _kind = null)),
                for (final k in kinds) ...[
                  const SizedBox(width: 8),
                  NChip(
                      label: k.label,
                      icon: deviceIcon(k),
                      selected: _kind == k,
                      onTap: () => setState(() => _kind = _kind == k ? null : k)),
                ],
              ]),
            ),
          ]),
        ),
        if (shown.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const DotText('NO DEVICES', size: 26),
                  const SizedBox(height: 8),
                  Text(store.devices.isEmpty ? 'Connect a hub or add a device to get started.' : 'Nothing matches that search.',
                      textAlign: TextAlign.center, style: NType.body(14, color: p.textDim)),
                ]),
              ),
            ),
          ),
        for (final entry in groups.entries) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverToBoxAdapter(
              child: SectionLabel(store.room(entry.key)?.name ?? 'No room', trailing: Text('${entry.value.length}', style: NType.label(color: p.textDim))),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverGrid.count(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.05,
              children: [
                for (final d in entry.value)
                  DeviceTile(device: d, onTap: () => store.toggle(d), onLongPress: () => showDeviceSheet(context, d)),
              ],
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ]);
    });
  }

  Future<void> _addDevice(BuildContext context, HomeStore store) async {
    final mqtt = store.integrations.where((i) => i.type == 'mqtt').toList();
    final choice = await pickOne<String>(
      context,
      title: 'Add a device',
      options: ['connect', 'virtual', if (mqtt.isNotEmpty) 'mqtt'],
      label: (o) => switch (o) {
        'connect' => 'From a hub or the network (Hue, Home Assistant, Shelly...)',
        'virtual' => 'Virtual device (for planning or trying the app)',
        _ => 'MQTT device by topic',
      },
      icon: (o) => switch (o) {
        'connect' => Icons.wifi_tethering,
        'virtual' => Icons.blur_on,
        _ => Icons.podcasts,
      },
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'connect') {
      widget.onOpenConnect();
    } else if (choice == 'virtual') {
      await _addVirtual(context, store);
    } else {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => MqttDeviceForm(integration: mqtt.first),
      );
    }
  }

  Future<void> _addVirtual(BuildContext context, HomeStore store) async {
    final kind = await pickOne<DeviceKind>(context,
        title: 'What is it?', options: DeviceKind.values, label: (k) => k.label, icon: deviceIcon);
    if (kind == null || !context.mounted) return;
    final name = await promptText(context, title: 'Name', initial: kind.label, action: 'Add');
    if (name == null || name.isEmpty) return;
    var demo = store.integration(demoIntegrationId) ?? store.integrations.where((i) => i.type == 'demo').firstOrNull;
    demo ??= store.addIntegration('demo');
    store.addVirtualDevice(demo.id, name, kind);
    store.toast('Added $name. Place it on the map in Edit mode.');
  }
}

/// Adds a device that is controlled by typed MQTT topics.
class MqttDeviceForm extends StatefulWidget {
  const MqttDeviceForm({super.key, required this.integration});
  final IntegrationConfig integration;

  @override
  State<MqttDeviceForm> createState() => _MqttDeviceFormState();
}

class _MqttDeviceFormState extends State<MqttDeviceForm> {
  final _name = TextEditingController(text: 'MQTT switch');
  final _cmd = TextEditingController();
  final _state = TextEditingController();
  final _on = TextEditingController(text: 'ON');
  final _off = TextEditingController(text: 'OFF');
  String _component = 'switch';

  @override
  void dispose() {
    for (final c in [_name, _cmd, _state, _on, _off]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<HomeStore>();
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const DotText('MQTT DEVICE', size: 26),
          const SizedBox(height: 6),
          Text('On ${widget.integration.name}. Payloads are sent as plain text.',
              style: NType.body(13, color: context.palette.textDim)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in const ['switch', 'light', 'sensor', 'binary_sensor'])
              NChip(label: c.replaceAll('_', ' '), selected: _component == c, onTap: () => setState(() => _component = c)),
          ]),
          const SizedBox(height: 16),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 12),
          if (!_component.contains('sensor')) ...[
            TextField(controller: _cmd, decoration: const InputDecoration(labelText: 'Command topic', hintText: 'cmnd/plug/POWER')),
            const SizedBox(height: 12),
          ],
          TextField(controller: _state, decoration: const InputDecoration(labelText: 'State topic', hintText: 'stat/plug/POWER')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _on, decoration: const InputDecoration(labelText: 'On payload'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _off, decoration: const InputDecoration(labelText: 'Off payload'))),
          ]),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_name.text.trim().isEmpty || (_state.text.trim().isEmpty && _cmd.text.trim().isEmpty)) return;
              final kind = switch (_component) {
                'light' => DeviceKind.light,
                'sensor' || 'binary_sensor' => DeviceKind.sensor,
                _ => DeviceKind.outlet,
              };
              store.addVirtualDevice(widget.integration.id, _name.text.trim(), kind, props: {
                'component': _component,
                if (_cmd.text.trim().isNotEmpty) 'command_topic': _cmd.text.trim(),
                if (_state.text.trim().isNotEmpty) 'state_topic': _state.text.trim(),
                'payload_on': _on.text,
                'payload_off': _off.text,
                'name': _name.text.trim(),
              });
              Navigator.pop(context);
            },
            child: const Text('Add device'),
          ),
        ]),
      ),
    );
  }
}
