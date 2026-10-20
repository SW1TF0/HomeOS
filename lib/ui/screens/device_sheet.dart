import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../integrations/catalog.dart';
import '../../integrations/integration.dart';
import '../../integrations/lan/lan_driver.dart';
import '../../integrations/lan/wol.dart';
import '../../integrations/matter/matter_driver.dart';
import '../../integrations/network_scan.dart';
import '../../models/device.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../util/color_math.dart';
import '../nav.dart';
import '../../integrations/camera/playback.dart';
import 'camera_playback.dart';
import 'camera_sheet.dart';
import '../widgets/camera_live.dart';
import '../widgets/controls.dart';
import '../widgets/dialogs.dart';
import '../widgets/kj_widgets.dart';
import '../widgets/remote_pad.dart';

Future<void> showDeviceSheet(BuildContext context, Device device) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => DeviceSheet(deviceId: device.id),
    );

/// A device tile wired to the store: tap switches it (or opens the controls
/// of devices a tap cannot simply switch), a sideways drag sets its level,
/// the arrow (or holding it) opens all its controls.
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
      onTap: () => HomeStore.tapControls(d) ? store.toggle(d) : showDeviceSheet(context, d),
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
  static const speedPresets = [('Low', 0.33), ('Medium', 0.66), ('High', 1.0)];
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
    // Humidifiers get the same dial as thermostats, in percent.
    final humidity = d.has(Capability.humidity) && !d.has(Capability.targetTemp);
    final dial = (d.has(Capability.targetTemp) || humidity) && s.reachable;
    final (hMin, hMax) = humidityRange(d);
    Future<bool> send(DeviceCommand c) => store.command(d, c);
    Future<bool> nudge(int steps) => humidity
        ? send(DeviceCommand(targetHumidity: ((s.targetHumidity ?? 50) + steps * 5).clamp(hMin, hMax).toDouble()))
        : send(DeviceCommand(targetTemp: ((s.targetTemp ?? 21) + steps * 0.5).clamp(5, 35)));

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
                    DisplayText(d.name, size: 30, maxLines: 2),
                    const SizedBox(height: 6),
                    Text(
                      [room?.name ?? 'No room', d.kind.label, spec?.name ?? 'Unknown'].join(' · '),
                      style: NType.label(color: p.textDim),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: d.favorite ? 'Remove from favourites' : 'Add to favourites',
                onPressed: () => store.updateDevice(d, favorite: !d.favorite),
                icon: Icon(d.favorite ? Icons.star : Icons.star_border, color: d.favorite ? KJPalette.accent : p.text),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(child: _Hero(device: d)),
          if (!dial) ...[
            const SizedBox(height: 10),
            Center(
              child: Text(describeState(d),
                  style: NType.body(15, color: s.reachable ? p.textDim : KJPalette.danger, weight: 500)),
            ),
          ],
          if (dial) ...[
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _RoundButton(key: Key(humidity ? 'humidity-down' : 'temp-down'), icon: Icons.remove, onTap: () => nudge(-1)),
              if (d.has(Capability.onOff)) ...[
                const SizedBox(width: 18),
                PowerOrb(size: 56, on: s.on == true, onTap: () => store.toggle(d)),
              ],
              const SizedBox(width: 18),
              _RoundButton(key: Key(humidity ? 'humidity-up' : 'temp-up'), icon: Icons.add, onTap: () => nudge(1)),
            ]),
            const SizedBox(height: 16),
            Center(
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (humidity)
                  for (final (label, h) in const [('Dry', 40.0), ('Comfort', 50.0), ('Humid', 60.0)])
                    PresetChip(
                      label: '$label ${h.round()}%',
                      selected: s.targetHumidity == h,
                      onTap: () => send(DeviceCommand(targetHumidity: h)),
                    )
                else
                  for (final (label, t) in const [('Eco', 18.0), ('Comfort', 21.0), ('Warm', 23.0)])
                    PresetChip(
                      label: '$label ${t.toStringAsFixed(0)}°',
                      selected: s.targetTemp == t,
                      onTap: () => send(DeviceCommand(targetTemp: t)),
                    ),
              ]),
            ),
          ],
          if (d.has(Capability.run) || d.has(Capability.dock) || d.has(Capability.locate)) ...[
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (d.has(Capability.dock))
                _ActionButton(
                  key: const Key('robot-dock'),
                  icon: Icons.home_outlined,
                  label: 'Home',
                  selected: const {Activity.returning, Activity.docked, Activity.charging}.contains(s.activity),
                  onTap: () => send(const DeviceCommand(action: DeviceAction.dock)),
                ),
              if (d.has(Capability.run) && d.kind != DeviceKind.mower && d.props['noStop'] != true)
                _ActionButton(
                  key: const Key('robot-stop'),
                  icon: Icons.stop,
                  label: 'Stop',
                  onTap: () => send(const DeviceCommand(action: DeviceAction.stop)),
                ),
              if (d.has(Capability.locate))
                _ActionButton(
                  key: const Key('robot-locate'),
                  icon: Icons.my_location,
                  label: 'Find',
                  onTap: () async {
                    if (await send(const DeviceCommand(action: DeviceAction.locate))) store.toast('${d.name} is beeping.');
                  },
                ),
            ]),
          ],
          if (d.has(Capability.alarm)) ...[
            const SizedBox(height: 22),
            Center(
              child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                for (final arm in alarmArms(d))
                  PresetChip(
                    key: Key('arm-${arm.name}'),
                    label: alarmArmLabel(arm),
                    selected: s.activity == arm.alarmState,
                    onTap: () => _alarm(context, store, d, arm),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            Center(
              child: OutlinedButton.icon(
                key: const Key('alarm-disarm'),
                onPressed: s.activity == Activity.disarmed ? null : () => _alarm(context, store, d, DeviceAction.disarm),
                icon: const Icon(Icons.shield_outlined, size: 18),
                label: const Text('Disarm'),
              ),
            ),
          ],
          if (d.has(Capability.mode) && d.modes.isNotEmpty) ...[
            SectionLabel(modeTitle(d),
                trailing: s.mode == null ? null : Text(modeLabel(s.mode!), style: NType.display(18, color: p.text))),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in d.modes)
                PresetChip(key: Key('mode-$m'), label: modeLabel(m), selected: s.mode == m, onTap: () => send(DeviceCommand(mode: m))),
            ]),
          ],
          if (d.has(Capability.speed))
            LevelControl(
              label: 'Speed',
              value: s.on == false ? 0 : (s.speed ?? 1),
              display: _pct,
              presets: speedPresets,
              onChangeEnd: (v) => send(v <= 0.01 ? const DeviceCommand(on: false) : DeviceCommand(speed: v)),
            ),
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
              display: (v) => s.color != null && v == _kelvinT(s.colorTempK ?? 3500).clamp(0.0, 1.0) ? 'Colour' : '${_tKelvin(v)} K',
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
                trailing: Text(_openLabel(s.position ?? 0), style: NType.display(18, color: p.text))),
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
                trailing: Text(s.muted == true ? 'Muted' : '${((s.volume ?? 0) * 100).round()}',
                    style: NType.display(18, color: s.muted == true ? KJPalette.danger : p.text))),
            Row(children: [
              IconButton(
                key: const Key('mute-toggle'),
                tooltip: s.muted == true ? 'Unmute' : 'Mute',
                onPressed: () => send(DeviceCommand(muted: !(s.muted ?? false))),
                icon: Icon(s.muted == true ? Icons.volume_off : Icons.volume_up_outlined,
                    color: s.muted == true ? KJPalette.danger : p.text),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LevelSlider(
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
                        Text(e.key,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.label(color: p.textDim)),
                        const SizedBox(height: 8),
                        Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.display(22, color: p.text)),
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
                if (d.kind == DeviceKind.camera)
                  ListTile(
                    key: const Key('camera-setup-tile'),
                    leading: const Icon(Icons.videocam_outlined),
                    title: const Text('Live video'),
                    subtitle: Text(CameraStream.fromProps(d.props) != null
                        ? 'Set up · tap to change the login'
                        : 'Enter the camera\'s login to watch it live'),
                    onTap: () => showCameraSetup(context, device: d),
                  ),
                if (d.kind == DeviceKind.camera && (!d.has(Capability.snapshot) || d.props['snapshotUrl'] != null))
                  ListTile(
                    key: const Key('camera-url'),
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('Picture address'),
                    subtitle: Text(d.props['snapshotUrl'] == null ? 'Add the camera\'s snapshot link to see it here' : 'Set'),
                    onTap: () async {
                      final url = await promptText(context,
                          title: 'Picture address',
                          initial: '${d.props['snapshotUrl'] ?? ''}',
                          hint: 'http://user:password@192.168.1.50/snapshot.jpg');
                      if (url != null) store.setSnapshotUrl(d, url);
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
                  leading: const Icon(Icons.delete_outline, color: KJPalette.danger),
                  title: const Text('Remove device', style: TextStyle(color: KJPalette.danger)),
                  onTap: () async {
                    final lastMatterPart = integration?.type == matterType &&
                        !store.devices.any((o) => o.id != d.id && o.integrationId == d.integrationId && o.props['node'] == d.props['node']);
                    if (await confirm(context,
                        title: 'Remove ${d.name}?',
                        body: lastMatterPart
                            ? 'It disappears from SmartMenuKJ and the device forgets SmartMenuKJ. To add it again you need a new pairing code.'
                            : 'It disappears from SmartMenuKJ. The device itself is not changed, and syncing its connection brings it back.')) {
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

String _openLabel(double pos) => pos <= 0.01 ? 'Closed' : (pos >= 0.99 ? 'Open' : '${(pos * 100).round()}%');

/// The humidity a humidifier can be set to, in percent.
(double, double) humidityRange(Device d) =>
    ((d.props['minHumidity'] as num?)?.toDouble() ?? 30, (d.props['maxHumidity'] as num?)?.toDouble() ?? 80);

/// What the modes of [d] are called on its controls.
String modeTitle(Device d) =>
    d.props['modeTitle'] as String? ??
    switch (d.kind) {
      DeviceKind.vacuum => 'Suction',
      DeviceKind.media => 'Input',
      DeviceKind.fan || DeviceKind.purifier => 'Preset',
      DeviceKind.appliance => 'Program',
      _ => 'Mode',
    };

/// The ways [d] can be armed, from its `props['arms']` (home, away, night, vacation).
List<DeviceAction> alarmArms(Device d) {
  final names = (d.props['arms'] as List?)?.map((e) => '$e').toList() ?? const ['home', 'away'];
  return [
    for (final n in names)
      ?switch (n) {
        'home' => DeviceAction.armHome,
        'away' => DeviceAction.armAway,
        'night' => DeviceAction.armNight,
        'vacation' => DeviceAction.armVacation,
        _ => null,
      },
  ];
}

String alarmArmLabel(DeviceAction a) => switch (a) {
      DeviceAction.armHome => 'Home',
      DeviceAction.armAway => 'Away',
      DeviceAction.armNight => 'Night',
      DeviceAction.armVacation => 'Vacation',
      _ => 'Disarm',
    };

/// Arms or disarms an alarm, asking for its code when it needs one. The code is sent once and never saved.
Future<void> _alarm(BuildContext context, HomeStore store, Device d, DeviceAction a) async {
  final format = d.props['codeFormat'] as String?;
  final needsCode = format != null && (a == DeviceAction.disarm || d.props['codeArmRequired'] == true);
  String? code;
  if (needsCode) {
    code = await promptText(context,
        title: a == DeviceAction.disarm ? 'Code to disarm' : 'Code to arm', action: 'OK', secret: true, number: format == 'number');
    if (code == null || code.isEmpty) return;
  } else if (a == DeviceAction.disarm) {
    if (!await confirm(context, title: 'Disarm ${d.name}?', body: 'It stops guarding the home.', action: 'Disarm')) return;
  }
  await store.command(d, DeviceCommand(action: a, code: code));
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
    if (d.has(Capability.run)) {
      final running = s.activity == Activity.running;
      return RobotOrb(
        key: const Key('robot-orb'),
        running: running,
        battery: s.battery,
        onTap: s.reachable ? () => store.command(d, DeviceCommand(action: running ? DeviceAction.pause : DeviceAction.start)) : null,
      );
    }
    if (d.kind == DeviceKind.camera || d.has(Capability.snapshot)) return CameraPanel(device: d);
    if (d.has(Capability.alarm)) {
      return PowerOrb(
        key: const Key('alarm-orb'),
        on: s.isActive,
        icon: s.activity == Activity.triggered ? Icons.notifications_active : deviceIcon(d.kind, active: s.isActive),
        onTap: null,
      );
    }
    if (d.has(Capability.press)) {
      return PowerOrb(key: const Key('press-orb'), on: false, icon: deviceIcon(d.kind), onTap: () => store.press(d));
    }
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
    if (d.has(Capability.humidity) && s.reachable) {
      final (lo, hi) = humidityRange(d);
      return TempDial(
        key: const Key('humidity-dial'),
        target: (s.targetHumidity ?? 50).clamp(lo, hi),
        current: s.currentHumidity,
        min: lo,
        max: hi,
        step: 1,
        unit: '%',
        decimals: 0,
        semanticLabel: 'Target humidity',
        off: s.on == false,
        onChangeEnd: (v) => store.command(d, DeviceCommand(targetHumidity: v)),
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
        Text(first.key, style: NType.label(color: context.palette.textDim)),
        const SizedBox(height: 6),
        DisplayText(first.value, size: 56),
      ]);
    }
    return Icon(deviceIcon(d.kind), size: 72, color: context.palette.textDim);
  }
}

/// A round button with a word under it, for robots: Home, Stop, Find.
class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.icon, required this.label, required this.onTap, this.selected = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Semantics(
        button: true,
        label: label,
        selected: selected,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onTap,
          radius: 34,
          child: Column(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? p.text : Colors.transparent,
                border: Border.all(color: selected ? p.text : p.border),
              ),
              child: Icon(icon, color: selected ? p.background : p.text),
            ),
            const SizedBox(height: 6),
            Text(label, style: NType.label(color: p.textDim)),
          ]),
        ),
      ),
    );
  }
}

/// What a camera shows: live video once it is set up, else its latest picture, else how to set it up.
class CameraPanel extends StatelessWidget {
  const CameraPanel({super.key, required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    final store = context.read<HomeStore>();
    final d = device;
    final live = store.liveStream(d);
    final onLan = store.integration(d.integrationId)?.type == lanType;
    if (live != null && (live.mjpeg != null || rtspPlays)) {
      if (store.offHomeNetwork && onLan) {
        return _CameraNote(
          key: const Key('camera-away'),
          icon: Icons.wifi_off,
          text: 'Live video plays on your home Wi-Fi. Connect to it to watch ${d.name}.',
        );
      }
      final view = LiveCameraView(key: const Key('camera-live'), stream: live, name: d.name, client: store.client);
      if (!rtspPlays || CameraPlayback.of(d.props) == null) return view;
      return Column(children: [
        view,
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('camera-playback'),
            onPressed: () => showCameraPlayback(context, d),
            icon: const Icon(Icons.history),
            label: const Text('Recordings'),
          ),
        ),
      ]);
    }
    final appOnly = live != null ? 'Live video from ${d.name} plays in the Android app.' : null;
    if (d.has(Capability.snapshot)) {
      return Column(children: [
        CameraView(key: const Key('camera-view'), device: d),
        if (appOnly != null)
          Text('$appOnly Here it shows a new picture every few seconds.',
              textAlign: TextAlign.center, style: NType.body(12.5, color: context.palette.textDim)),
      ]);
    }
    if (appOnly != null) {
      return _CameraNote(
          icon: Icons.phone_android, text: '$appOnly On this device it can show pictures: add its picture address below.');
    }
    return _CameraNote(
      key: const Key('camera-setup-card'),
      icon: Icons.videocam_outlined,
      text: 'Enter the camera\'s login once to watch it live here.',
      action: FilledButton.icon(
        key: const Key('camera-setup-start'),
        onPressed: () => showCameraSetup(context, device: d),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Set up live video'),
      ),
    );
  }
}

class _CameraNote extends StatelessWidget {
  const _CameraNote({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(color: p.surfaceHigh, borderRadius: BorderRadius.circular(22)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 32, color: p.textDim),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: NType.body(14, color: p.text)),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ]),
        ),
      ),
    );
  }
}

/// A camera's latest picture, refreshed every few seconds while it is open.
class CameraView extends StatefulWidget {
  const CameraView({super.key, required this.device});
  final Device device;

  static const every = Duration(seconds: 5);

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  Uint8List? _picture;
  DateTime? _at;
  String? _problem;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(CameraView.every, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final picture = await context.read<HomeStore>().snapshot(widget.device);
      if (!mounted) return;
      setState(() {
        if (picture != null) {
          _picture = picture;
          _at = DateTime.now();
        }
        _problem = picture == null ? 'No picture' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    String two(int v) => v.toString().padLeft(2, '0');
    final at = _at;
    return Column(children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: DecoratedBox(
            decoration: BoxDecoration(color: p.surfaceHigh),
            child: _picture == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text((_problem ?? 'Loading'),
                          textAlign: TextAlign.center, style: NType.label(color: _problem == null ? p.textDim : KJPalette.danger)),
                    ),
                  )
                : Image.memory(_picture!, fit: BoxFit.cover, gaplessPlayback: true, width: double.infinity),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: _problem == null && at != null ? KJPalette.danger : p.textDim, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(at == null ? 'No picture yet' : 'TAKEN ${two(at.hour)}:${two(at.minute)}:${two(at.second)}',
              style: NType.label(color: p.textDim)),
        ),
        IconButton(key: const Key('camera-refresh'), tooltip: 'New picture', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
    ]);
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
