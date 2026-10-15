import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../integrations/catalog.dart';
import '../../integrations/lan/lan_driver.dart';
import '../../integrations/lan/wol.dart';
import '../../integrations/network_scan.dart';
import '../../models/device.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../../util/color_math.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import '../widgets/remote_pad.dart';

Future<void> showDeviceSheet(BuildContext context, Device device) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => DeviceSheet(deviceId: device.id),
    );

/// Full controls for one device, plus rename / room / delete.
class DeviceSheet extends StatelessWidget {
  const DeviceSheet({super.key, required this.deviceId});
  final String deviceId;

  static const swatches = [0xFFFFFF, 0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x00C7BE, 0x007AFF, 0x5856D6, 0xFF2D55];

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final d = store.device(deviceId);
    if (d == null) return const SizedBox(height: 120, child: Center(child: Text('Device removed')));
    final p = context.palette;
    final s = d.state;
    final room = store.room(d.roomId);
    final integration = store.integration(d.integrationId);
    final spec = integration == null ? null : specFor(integration.type);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DotText(d.name, size: 30, maxLines: 2),
                    const SizedBox(height: 6),
                    Text(
                      [room?.name ?? 'No room', d.kind.label, spec?.name ?? 'Unknown'].join(' · ').toUpperCase(),
                      style: NType.label(color: p.textDim),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: d.favorite ? 'Remove from favourites' : 'Add to favourites',
                onPressed: () => store.updateDevice(d, favorite: !d.favorite),
                icon: Icon(d.favorite ? Icons.star : Icons.star_border, color: d.favorite ? NothingPalette.red : p.text),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Center(child: _Hero(device: d)),
          const SizedBox(height: 10),
          Center(
            child: Text(describeState(d),
                style: NType.body(15, color: s.reachable ? p.textDim : NothingPalette.red, weight: 500)),
          ),
          if (d.has(Capability.brightness)) ...[
            const SectionLabel('Brightness'),
            DotSlider(
              semanticLabel: 'Brightness',
              value: s.on == false ? 0 : (s.brightness ?? 1),
              onChangeEnd: (v) => store.command(d, v <= 0.01 ? const DeviceCommand(on: false) : DeviceCommand(brightness: v)),
            ),
          ],
          if (d.has(Capability.colorTemp)) ...[
            const SectionLabel('White'),
            DotSlider(
              semanticLabel: 'Colour temperature',
              value: ((s.colorTempK ?? 3500) - 2000) / 4500,
              colorAt: (t) => Color(0xFF000000 | kelvinToRgb((2000 + t * 4500).round())),
              onChangeEnd: (v) => store.command(d, DeviceCommand(colorTempK: (2000 + v * 4500).round())),
            ),
          ],
          if (d.has(Capability.color)) ...[
            const SectionLabel('Colour'),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in swatches)
                  GestureDetector(
                    onTap: () => store.command(d, DeviceCommand(color: c)),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Color(0xFF000000 | c),
                        shape: BoxShape.circle,
                        border: Border.all(color: s.color == c ? p.text : p.border, width: s.color == c ? 2.5 : 1),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (d.has(Capability.position)) ...[
            const SectionLabel('Position'),
            DotSlider(
              semanticLabel: 'Position',
              value: s.position ?? 0,
              onChangeEnd: (v) => store.command(d, DeviceCommand(position: v)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => store.command(d, const DeviceCommand(position: 0)), child: const Text('Close'))),
              const SizedBox(width: 12),
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => store.command(d, const DeviceCommand(position: 1)), child: const Text('Open'))),
            ]),
          ],
          if (d.has(Capability.volume)) ...[
            const SectionLabel('Volume'),
            Row(children: [
              IconButton(
                key: const Key('mute-toggle'),
                tooltip: s.muted == true ? 'Unmute' : 'Mute',
                onPressed: () => store.command(d, DeviceCommand(muted: !(s.muted ?? false))),
                icon: Icon(s.muted == true ? Icons.volume_off : Icons.volume_up_outlined,
                    color: s.muted == true ? NothingPalette.red : p.text),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DotSlider(
                  semanticLabel: 'Volume',
                  value: s.volume ?? 0,
                  onChangeEnd: (v) => store.command(d, DeviceCommand(volume: v)),
                ),
              ),
            ]),
          ],
          if (d.has(Capability.remote)) ...[
            const SectionLabel('Remote'),
            RemotePad(keys: remoteKeysOf(d), onKey: (k) => store.command(d, DeviceCommand(key: k))),
          ],
          if (d.has(Capability.targetTemp)) ...[
            const SectionLabel('Target temperature'),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundButton(
                    icon: Icons.remove,
                    onTap: () => store.command(d, DeviceCommand(targetTemp: ((s.targetTemp ?? 21) - 0.5).clamp(5, 35)))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: DotText('${(s.targetTemp ?? 21).toStringAsFixed(1)}°', size: 52),
                ),
                _RoundButton(
                    icon: Icons.add,
                    onTap: () => store.command(d, DeviceCommand(targetTemp: ((s.targetTemp ?? 21) + 0.5).clamp(5, 35)))),
              ],
            ),
          ],
          if (s.readings.isNotEmpty) ...[
            const SectionLabel('Readings'),
            NCard(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Column(
                children: [
                  for (final e in s.readings.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(child: Text(e.key, style: NType.body(14, color: p.textDim))),
                        Text(e.value, style: NType.dot(20, color: p.text)),
                      ]),
                    ),
                ],
              ),
            ),
          ],
          const SectionLabel('Device'),
          NCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Rename'),
                  onTap: () async {
                    final name = await promptText(context, title: 'Rename', initial: d.name);
                    if (name != null && name.isNotEmpty) store.updateDevice(d, name: name);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.meeting_room_outlined),
                  title: const Text('Room'),
                  subtitle: Text(room?.name ?? 'None'),
                  onTap: () async {
                    final picked = await pickOne<String>(
                      context,
                      title: 'Move to room',
                      options: ['', ...store.rooms.map((r) => r.id)],
                      label: (id) => id.isEmpty ? 'No room' : store.room(id)!.name,
                    );
                    if (picked == null) return;
                    picked.isEmpty ? store.updateDevice(d, clearRoom: true) : store.updateDevice(d, roomId: picked);
                  },
                ),
                ListTile(
                  leading: Icon(deviceIcon(d.kind)),
                  title: const Text('Type'),
                  subtitle: Text(d.kind.label),
                  onTap: () async {
                    final k = await pickOne<DeviceKind>(context,
                        title: 'Device type', options: DeviceKind.values, label: (k) => k.label, icon: deviceIcon);
                    if (k != null) store.updateDevice(d, kind: k);
                  },
                ),
                if (integration?.type == lanType) ..._networkTiles(context, store, d),
                if (d.mapPos != null)
                  ListTile(
                    leading: const Icon(Icons.location_off_outlined),
                    title: const Text('Take off the map'),
                    onTap: () => store.unplaceDevice(d),
                  ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: NothingPalette.red),
                  title: const Text('Remove device', style: TextStyle(color: NothingPalette.red)),
                  onTap: () async {
                    if (await confirm(context,
                        title: 'Remove ${d.name}?',
                        body: 'It disappears from SmartMenuKJ. The device itself is not changed, and syncing its connection brings it back.')) {
                      store.removeDevice(d);
                      if (context.mounted) Navigator.pop(context);
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Address, Wake-on-LAN and per-device settings of a network device.
List<Widget> _networkTiles(BuildContext context, HomeStore store, Device d) {
  final driver = store.driverFor(d.integrationId);
  final mac = normalizeMac(d.props['mac'] as String?);
  final protocol = '${d.props['protocol'] ?? 'generic'}';
  final model = '${d.props['model'] ?? ''}';
  return [
    ListTile(
      leading: const Icon(Icons.lan_outlined),
      title: const Text('Address'),
      subtitle: Text([
        '${d.props['host']}',
        FoundService.protocolLabels[protocol] ?? protocol,
        if (model.isNotEmpty) model,
      ].join(' · ')),
    ),
    ListTile(
      key: const Key('device-mac'),
      leading: const Icon(Icons.power_settings_new),
      title: const Text('Wake-on-LAN'),
      subtitle: Text(mac ?? 'Add the MAC address so the app can switch it on'),
      onTap: () async {
        final raw = await promptText(context,
            title: 'MAC address', initial: mac ?? '', hint: 'AA:BB:CC:DD:EE:FF (in the device\'s network settings)');
        if (raw == null) return;
        if (raw.isEmpty) return store.setDeviceProp(d, 'mac', null);
        final m = normalizeMac(raw);
        m == null ? store.toast('That is not a MAC address.') : store.setDeviceProp(d, 'mac', m);
      },
    ),
    if (mac != null)
      ListTile(
        leading: const Icon(Icons.bolt_outlined),
        title: const Text('Wake up now'),
        onTap: () => store.wake(d),
      ),
    if (driver is LanDriver)
      for (final f in driver.fields(d))
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: Text(f.label),
          subtitle: Text(d.props[f.key] == null ? (f.defaultValue ?? 'Not set') : (f.secret ? '••••' : '${d.props[f.key]}')),
          onTap: () async {
            final v = await promptText(context, title: f.label, initial: '${d.props[f.key] ?? ''}', hint: f.hint);
            if (v != null) store.setDeviceProp(d, f.key, v);
          },
        ),
    if (protocol == 'samsung' || protocol == 'webos')
      ListTile(
        leading: const Icon(Icons.link),
        title: const Text('Pair again'),
        subtitle: const Text('Shows the allow prompt on the TV'),
        onTap: () => store.pairNetworkDevice(d),
      ),
  ];
}

class _Hero extends StatelessWidget {
  const _Hero({required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    final store = context.read<HomeStore>();
    final d = device;
    final s = d.state;
    if (d.has(Capability.lock)) {
      return PowerOrb(
        on: s.locked == false,
        icon: s.locked == false ? Icons.lock_open : Icons.lock_outline,
        onTap: () => store.toggle(d),
      );
    }
    if (d.has(Capability.onOff)) {
      return PowerOrb(on: s.on == true, icon: deviceIcon(d.kind, active: s.on == true), onTap: () => store.toggle(d));
    }
    if (d.has(Capability.position)) {
      return DotText('${((s.position ?? 0) * 100).round()}%', size: 72);
    }
    if (d.kind == DeviceKind.sensor && s.readings.isNotEmpty) {
      return DotText(s.readings.values.first, size: 56);
    }
    return Icon(deviceIcon(d.kind), size: 72, color: context.palette.textDim);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkResponse(
        onTap: onTap,
        radius: 32,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: context.palette.border)),
          child: Icon(icon),
        ),
      );
}
