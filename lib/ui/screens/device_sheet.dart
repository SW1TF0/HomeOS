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
import '../nav.dart';
import '../widgets/controls.dart';
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

/// A device tile wired to the store: tap switches it, a sideways drag sets
/// its level, the arrow (or holding it) opens all its controls.
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.device, this.subtitle});
  final Device device;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final store = context.read<HomeStore>();
    final d = device;
    return DeviceTile(
      device: d,
      subtitle: subtitle,
      onTap: () => store.toggle(d),
      onLongPress: () => showDeviceSheet(context, d),
      onOpen: () => showDeviceSheet(context, d),
      onLevel: sendsLive(d) ? (v) => store.command(d, levelCommand(d, v)) : null,
      onLevelEnd: (v) => store.command(d, levelCommand(d, v)),
    );
  }
}

String _pct(double v) => v <= 0.005 ? 'OFF' : '${(v * 100).round()}%';

double _kelvinT(int k) => (k - 2000) / 4500;
int _tKelvin(double t) => ((2000 + t * 4500) / 50).round() * 50;

/// Full controls for one device, plus rename / room / delete.
class DeviceSheet extends StatelessWidget {
  const DeviceSheet({super.key, required this.deviceId});
  final String deviceId;

  static const brightnessPresets = [('10%', 0.1), ('25%', 0.25), ('50%', 0.5), ('75%', 0.75), ('100%', 1.0)];
  static final whitePresets = [
    ('Warm', _kelvinT(2700)),
    ('Neutral', _kelvinT(4000)),
    ('Cool', _kelvinT(5000)),
    ('Daylight', _kelvinT(6500)),
  ];

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
    final dial = d.has(Capability.targetTemp) && s.reachable;
    Future<bool> send(DeviceCommand c) => store.command(d, c);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
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
          const SizedBox(height: 24),
          Center(child: _Hero(device: d)),
          if (!dial) ...[
            const SizedBox(height: 10),
            Center(
              child: Text(describeState(d),
                  style: NType.body(15, color: s.reachable ? p.textDim : NothingPalette.red, weight: 500)),
            ),
          ],
          if (dial) ...[
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _RoundButton(
                key: const Key('temp-down'),
                icon: Icons.remove,
                onTap: () => send(DeviceCommand(targetTemp: ((s.targetTemp ?? 21) - 0.5).clamp(5, 35))),
              ),
              if (d.has(Capability.onOff)) ...[
                const SizedBox(width: 18),
                PowerOrb(size: 56, on: s.on == true, onTap: () => store.toggle(d)),
              ],
              const SizedBox(width: 18),
              _RoundButton(
                key: const Key('temp-up'),
                icon: Icons.add,
                onTap: () => send(DeviceCommand(targetTemp: ((s.targetTemp ?? 21) + 0.5).clamp(5, 35))),
              ),
            ]),
            const SizedBox(height: 16),
            Center(
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, t) in const [('Eco', 18.0), ('Comfort', 21.0), ('Warm', 23.0)])
                  PresetChip(
                    label: '$label ${t.toStringAsFixed(0)}°',
                    selected: s.targetTemp == t,
                    onTap: () => send(DeviceCommand(targetTemp: t)),
                  ),
              ]),
            ),
          ],
          if (d.has(Capability.brightness))
            LevelControl(
              label: 'Brightness',
              value: s.on == false ? 0 : (s.brightness ?? 1),
              display: _pct,
              presets: brightnessPresets,
              onLive: (v) => send(levelCommand(d, v)),
              onChangeEnd: (v) => send(levelCommand(d, v)),
            ),
          if (d.has(Capability.colorTemp))
            LevelControl(
              label: 'White',
              value: _kelvinT(s.colorTempK ?? 3500).clamp(0.0, 1.0),
              display: (v) => s.color != null && v == _kelvinT(s.colorTempK ?? 3500).clamp(0.0, 1.0) ? 'COLOUR' : '${_tKelvin(v)} K',
              colorAt: (t) => Color(0xFF000000 | kelvinToRgb(_tKelvin(t))),
              presets: whitePresets,
              onLive: (v) => send(DeviceCommand(colorTempK: _tKelvin(v))),
              onChangeEnd: (v) => send(DeviceCommand(colorTempK: _tKelvin(v))),
            ),
          if (d.has(Capability.color)) ...[
            const SectionLabel('Colour'),
            Center(
              child: ColorRing(
                key: const Key('color-ring'),
                color: s.color,
                center: s.colorTempK == null ? null : Color(0xFF000000 | kelvinToRgb(s.colorTempK!)),
                onLive: (c) => send(DeviceCommand(color: c)),
                onChangeEnd: (c) => send(DeviceCommand(color: c)),
              ),
            ),
            if (s.color != null)
              LevelControl(
                label: 'Saturation',
                value: rgbToHsv(s.color!)[1],
                display: (v) => '${(v * 100).round()}%',
                colorAt: (t) => Color(0xFF000000 | hsvToRgb(rgbToHsv(s.color!)[0], t, 1)),
                onChangeEnd: (v) => send(DeviceCommand(color: hsvToRgb(rgbToHsv(s.color!)[0], v.clamp(0.05, 1.0), 1))),
              ),
          ],
          if (d.has(Capability.position)) ...[
            SectionLabel('Position',
                trailing: Text(_openLabel(s.position ?? 0), style: NType.dot(18, color: p.text))),
            Row(children: [
              Expanded(
                  child: OutlinedButton.icon(
                      key: const Key('blind-close'),
                      onPressed: () => send(const DeviceCommand(position: 0)),
                      icon: const Icon(Icons.blinds_closed, size: 18),
                      label: const Text('Close'))),
              const SizedBox(width: 12),
              Expanded(
                  child: OutlinedButton.icon(
                      key: const Key('blind-open'),
                      onPressed: () => send(const DeviceCommand(position: 1)),
                      icon: const Icon(Icons.blinds, size: 18),
                      label: const Text('Open'))),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final v in const [0.25, 0.5, 0.75])
                PresetChip(
                  label: '${(v * 100).round()}% open',
                  selected: ((s.position ?? 0) - v).abs() < 0.02,
                  onTap: () => send(DeviceCommand(position: v)),
                ),
            ]),
          ],
          if (d.has(Capability.volume)) ...[
            SectionLabel('Volume',
                trailing: Text(s.muted == true ? 'MUTED' : '${((s.volume ?? 0) * 100).round()}',
                    style: NType.dot(18, color: s.muted == true ? NothingPalette.red : p.text))),
            Row(children: [
              IconButton(
                key: const Key('mute-toggle'),
                tooltip: s.muted == true ? 'Unmute' : 'Mute',
                onPressed: () => send(DeviceCommand(muted: !(s.muted ?? false))),
                icon: Icon(s.muted == true ? Icons.volume_off : Icons.volume_up_outlined,
                    color: s.muted == true ? NothingPalette.red : p.text),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DotSlider(
                  semanticLabel: 'Volume',
                  value: s.volume ?? 0,
                  onChangeEnd: (v) => send(DeviceCommand(volume: v)),
                ),
              ),
            ]),
          ],
          if (d.has(Capability.remote)) ...[
            const SectionLabel('Remote'),
            RemotePad(keys: remoteKeysOf(d), onKey: (k) => send(DeviceCommand(key: k))),
          ],
          if (s.readings.isNotEmpty && !(d.kind == DeviceKind.sensor && s.readings.length == 1)) ...[
            const SectionLabel('Readings'),
            LayoutBuilder(builder: (context, c) {
              final w = (c.maxWidth - 12) / 2;
              return Wrap(spacing: 12, runSpacing: 12, children: [
                for (final e in s.readings.entries)
                  SizedBox(
                    width: w,
                    child: NCard(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      radius: 20,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.key.toUpperCase(),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.label(color: p.textDim)),
                        const SizedBox(height: 8),
                        Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.dot(22, color: p.text)),
                      ]),
                    ),
                  ),
              ]);
            }),
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
                    leading: const Icon(Icons.grid_view),
                    title: const Text('Show on the map'),
                    onTap: () {
                      Navigator.pop(context);
                      context.read<AppNav>().openMap(roomId: d.roomId);
                    },
                  ),
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

String _openLabel(double pos) => pos <= 0.01 ? 'CLOSED' : (pos >= 0.99 ? 'OPEN' : '${(pos * 100).round()}%');

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
      return HoldOrb(
        key: const Key('lock-orb'),
        locked: s.locked != false,
        onLock: () => store.command(d, const DeviceCommand(locked: true)),
        onUnlock: () => store.command(d, const DeviceCommand(locked: false)),
      );
    }
    if (d.has(Capability.targetTemp) && s.reachable) {
      return TempDial(
        key: const Key('temp-dial'),
        target: s.targetTemp ?? 21,
        current: s.currentTemp,
        off: s.on == false,
        onChangeEnd: (v) => store.command(d, DeviceCommand(targetTemp: v)),
      );
    }
    if (d.has(Capability.position)) {
      return BlindControl(
        key: const Key('blind'),
        position: s.position ?? 0,
        onChangeEnd: (v) => store.command(d, DeviceCommand(position: v)),
      );
    }
    if (d.has(Capability.onOff)) {
      return PowerOrb(on: s.on == true, icon: deviceIcon(d.kind, active: s.on == true), onTap: () => store.toggle(d));
    }
    if (d.kind == DeviceKind.sensor && s.readings.isNotEmpty) {
      final first = s.readings.entries.first;
      return Column(children: [
        Text(first.key.toUpperCase(), style: NType.label(color: context.palette.textDim)),
        const SizedBox(height: 6),
        DotText(first.value, size: 56),
      ]);
    }
    return Icon(deviceIcon(d.kind), size: 72, color: context.palette.textDim);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.onTap});
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
