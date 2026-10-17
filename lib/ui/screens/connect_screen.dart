import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../integrations/catalog.dart';
import '../../integrations/integration.dart';
import '../../integrations/lan/net.dart';
import '../../integrations/matter/matter_driver.dart';
import '../../integrations/network_scan.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../../util/text.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import 'account_sheet.dart';
import 'homes_sheet.dart';
import 'matter_sheet.dart';

/// Connections (hubs, brokers, device families), network scan and settings.
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / 260).floor().clamp(1, 4);
      return CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          sliver: SliverList.list(children: [
            const DotText('CONNECT', size: 34),
            const SizedBox(height: 4),
            Text('Everything runs on your network. An account is optional and free.', style: NType.body(14, color: p.textDim)),
            const SizedBox(height: 18),
            NCard(
              key: const Key('scan-network'),
              inverted: true,
              onTap: () => openScanSheet(context),
              child: Row(children: [
                Icon(Icons.wifi_tethering, color: p.background, size: 28),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Scan network', style: NType.body(17, color: p.background, weight: 600)),
                    Text('Find TVs, speakers, plugs, lights, hubs and anything else on your Wi-Fi',
                        style: NType.body(13, color: p.background.withValues(alpha: 0.65))),
                  ]),
                ),
                Icon(Icons.arrow_forward, color: p.background),
              ]),
            ),
            const AccountCard(),
            if (store.integrations.isNotEmpty) const SectionLabel('Your connections', accent: true),
            for (final cfg in store.integrations) ...[
              _IntegrationCard(config: cfg),
              const SizedBox(height: 10),
            ],
            const SectionLabel('Add a connection'),
          ]),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverGrid.count(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: columns == 1 ? 4.2 : 2.6,
            children: [
              for (final spec in integrationCatalog)
                NCard(
                  key: Key('spec-${spec.type}'),
                  padding: const EdgeInsets.all(14),
                  onTap: () => spec.type == matterType ? openMatterSheet(context) : openIntegrationSheet(context, spec: spec),
                  child: Row(children: [
                    Icon(spec.icon, size: 26),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(spec.name, style: NType.body(15, color: p.text, weight: 600)),
                        Text(spec.tagline, maxLines: 2, overflow: TextOverflow.ellipsis, style: NType.body(12.5, color: p.textDim)),
                      ]),
                    ),
                  ]),
                ),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          sliver: SliverList.list(children: const [
            SectionLabel('Settings'),
            _SettingsCard(),
          ]),
        ),
      ]);
    });
  }
}

class _IntegrationCard extends StatelessWidget {
  const _IntegrationCard({required this.config});
  final IntegrationConfig config;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final spec = specFor(config.type);
    final st = store.status[config.id];
    final count = store.devices.where((d) => d.integrationId == config.id).length;
    final ok = st?.ok ?? true;
    return NCard(
      onTap: () => openIntegrationSheet(context, spec: spec!, config: config),
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Icon(spec?.icon ?? Icons.extension, size: 26),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(config.name, style: NType.body(16, color: p.text, weight: 600)),
            const SizedBox(height: 2),
            Text(
              ok ? '${counted(count, 'device')}${st?.message != null && !st!.message!.endsWith('devices') ? ' · ${st.message}' : ''}' : st!.message ?? 'Error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: NType.body(13, color: ok ? p.textDim : NothingPalette.red),
            ),
          ]),
        ),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: ok ? p.text : NothingPalette.red),
        ),
      ]),
    );
  }
}

Future<void> openIntegrationSheet(BuildContext context,
        {required IntegrationSpec spec, IntegrationConfig? config, Map<String, dynamic>? prefill}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => IntegrationSheet(spec: spec, configId: config?.id, prefill: prefill),
    );

/// Set up, pair, sync or remove one connection.
class IntegrationSheet extends StatefulWidget {
  const IntegrationSheet({super.key, required this.spec, this.configId, this.prefill});
  final IntegrationSpec spec;
  final String? configId;
  final Map<String, dynamic>? prefill;

  @override
  State<IntegrationSheet> createState() => _IntegrationSheetState();
}

class _IntegrationSheetState extends State<IntegrationSheet> {
  late final Map<String, TextEditingController> _fields;
  late final TextEditingController _name;
  String? _configId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<HomeStore>();
    final cfg = widget.configId == null ? null : store.integration(widget.configId!);
    _configId = cfg?.id;
    _name = TextEditingController(text: cfg?.name ?? widget.spec.name);
    _fields = {
      for (final f in widget.spec.fields)
        f.key: TextEditingController(
            text: '${widget.prefill?[f.key] ?? cfg?.settings[f.key] ?? f.defaultValue ?? ''}'),
    };
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _settings => {for (final e in _fields.entries) e.key: e.value.text.trim()};

  /// Saves the form. Creates the connection the first time.
  Future<IntegrationConfig?> _save() async {
    final store = context.read<HomeStore>();
    for (final f in widget.spec.fields) {
      if (f.required && _fields[f.key]!.text.trim().isEmpty && !(widget.spec.canPair && f.key == 'username')) {
        store.toast('${f.label} is needed.');
        return null;
      }
    }
    if (_configId == null) {
      final cfg = store.addIntegration(widget.spec.type, name: _name.text.trim(), settings: _settings);
      setState(() => _configId = cfg.id);
      return cfg;
    }
    final cfg = store.integration(_configId!)!;
    await store.updateIntegration(cfg, name: _name.text, settings: _settings);
    return cfg;
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() => _busy = true);
    try {
      await task();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final spec = widget.spec;
    final cfg = _configId == null ? null : store.integration(_configId!);
    final st = cfg == null ? null : store.status[cfg.id];
    final count = cfg == null ? 0 : store.devices.where((d) => d.integrationId == cfg.id).length;
    final paired = cfg?.setting('username').isNotEmpty ?? false;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(spec.icon, size: 30),
            const SizedBox(width: 12),
            Expanded(child: DotText(spec.name.toUpperCase(), size: 24, maxLines: 2)),
          ]),
          const SizedBox(height: 10),
          Text(spec.description, style: NType.body(14, color: p.textDim)),
          if (st != null && !st.ok) ...[
            const SizedBox(height: 12),
            Text(st.message ?? 'Not connected', style: NType.body(13, color: NothingPalette.red)),
          ],
          const SizedBox(height: 18),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          for (final f in spec.fields) ...[
            const SizedBox(height: 12),
            TextField(
              key: Key('field-${f.key}'),
              controller: _fields[f.key],
              obscureText: f.secret,
              minLines: f.multiline ? 3 : 1,
              maxLines: f.multiline ? 6 : 1,
              decoration: InputDecoration(labelText: f.label, hintText: f.hint.isEmpty ? null : f.hint),
            ),
          ],
          if (_busy) ...[const SizedBox(height: 16), const LinearProgressIndicator()],
          const SizedBox(height: 20),
          if (spec.type == matterType) ...[
            OutlinedButton.icon(
              key: const Key('matter-pair'),
              onPressed: _busy
                  ? null
                  : () {
                      Navigator.pop(context);
                      openMatterSheet(context);
                    },
              icon: const Icon(Icons.add_link),
              label: const Text('Add a Matter device'),
            ),
            const SizedBox(height: 10),
          ],
          if (spec.canPair) ...[
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        final c = await _save();
                        if (c == null) return;
                        if (await store.pair(c)) {
                          _fields['username']!.text = c.setting('username');
                          await store.sync(c);
                        }
                      }),
              icon: const Icon(Icons.link),
              label: Text(paired ? 'Pair again' : 'Pair (press the bridge button first)'),
            ),
            const SizedBox(height: 10),
          ],
          FilledButton.icon(
            key: const Key('integration-save'),
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final c = await _save();
                      if (c == null) return;
                      if (spec.fields.isEmpty && spec.type != matterType) {
                        if (context.mounted) Navigator.pop(context);
                        return;
                      }
                      if (spec.canPair && c.setting('username').isEmpty) {
                        store.toast('Saved. Press the link button on the bridge, then tap Pair.');
                        return;
                      }
                      await store.sync(c);
                    }),
            icon: const Icon(Icons.sync),
            label: Text(cfg == null ? (spec.fields.isEmpty ? 'Add' : 'Save and find devices') : 'Save and sync devices'),
          ),
          if (cfg != null) ...[
            const SizedBox(height: 10),
            Text(
              '$count devices${st?.lastSync != null ? ' · synced ${TimeOfDay.fromDateTime(st!.lastSync!).format(context)}' : ''}',
              textAlign: TextAlign.center,
              style: NType.body(13, color: p.textDim),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: NothingPalette.red),
              onPressed: () async {
                if (await confirm(context,
                    title: 'Remove ${cfg.name}?', body: 'Its $count devices are removed from SmartMenuKJ too.')) {
                  await store.removeIntegration(cfg);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove connection'),
            ),
          ],
        ]),
      ),
    );
  }
}

Future<void> openScanSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const ScanSheet(),
    );

/// Asks for an address and adds whatever answers there.
Future<void> addByAddress(BuildContext context) async {
  final store = context.read<HomeStore>();
  final address = await promptText(context,
      title: 'Device address', hint: 'e.g. 192.168.1.50 (see your router or the device\'s network settings)', action: 'Add');
  if (address == null || address.isEmpty) return;
  store.toast('Looking at $address...');
  await store.addNetworkDevice(address);
}

/// Live list of what the network scan finds.
class ScanSheet extends StatefulWidget {
  const ScanSheet({super.key, this.scanner});
  final NetworkScanner? scanner;

  @override
  State<ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<ScanSheet> {
  final Map<String, FoundService> _found = {};
  final Set<String> _adding = {};
  StreamSubscription<FoundService>? _sub;
  bool _scanning = false;
  bool _noWifi = false;

  @override
  void initState() {
    super.initState();
    _scan();
    localNetworks().then((nets) {
      if (mounted) setState(() => _noWifi = nets.isEmpty);
    }, onError: (_) {});
  }

  void _scan() {
    _sub?.cancel();
    setState(() {
      _found.clear();
      _scanning = true;
    });
    _sub = (widget.scanner ?? NetworkScanner()).scan(timeout: const Duration(seconds: 5)).listen(
          (s) => setState(() => _found[s.key] = s),
          onDone: () => mounted ? setState(() => _scanning = false) : null,
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// What to show: a device that has its own connection is not listed twice.
  List<FoundService> get _visible {
    final store = context.read<HomeStore>();
    final family = _found.values.where((s) => !s.isLan && s.integrationType != null).map((s) => s.host).toSet();
    // A Matter device on SmartMenuKJ and in other apps announces itself once per app: show it once, as added.
    final ownMatter = _found.values.where((s) => s.integrationType == matterType && _isAdded(store, s)).map((s) => s.host).toSet();
    final list = _found.values
        .where((s) => !s.isLan || !family.contains(s.host))
        .where((s) => s.integrationType != matterType || !ownMatter.contains(s.host) || _isAdded(store, s))
        .toList();
    // Hubs first, then the best-known network devices.
    list.sort((a, b) {
      if (a.isLan != b.isLan) return a.isLan ? 1 : -1;
      final r = b.rank.compareTo(a.rank);
      return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  bool _isAdded(HomeStore store, FoundService s) {
    if (s.integrationType == matterType) {
      return store.integrations.any((i) => i.type == matterType &&
          switch (store.driverFor(i.id)) { final MatterDriver m => m.owns(s.hints['instance'] ?? ''), _ => false });
    }
    return s.isLan
        ? store.devices.any((d) => d.props['host'] == s.host && store.integration(d.integrationId)?.type == lanType)
        : store.integrations.any((i) => i.type == s.integrationType &&
            (parseHosts(i.setting('hosts')).contains(s.address) || i.setting('host') == s.address || i.setting('url') == s.address));
  }

  Future<void> _add(FoundService s) async {
    final store = context.read<HomeStore>();
    final type = s.integrationType;
    if (type == null) return;
    if (type == matterType) {
      Navigator.pop(context);
      await openMatterSheet(context, name: s.name == 'Matter device' ? null : s.name);
      return;
    }
    if (s.isLan) {
      setState(() => _adding.add(s.key));
      try {
        await store.addNetworkDevice(s.host, hints: {...s.hints, if (s.name != s.host) 'name': s.name});
      } finally {
        if (mounted) setState(() => _adding.remove(s.key));
      }
      return;
    }
    final spec = specFor(type)!;
    if (spec.fields.any((f) => f.key == 'hosts')) {
      await store.addToFamily(type, s.address);
      return;
    }
    if (!mounted) return;
    final existing = store.integrations.where((i) => i.type == type).firstOrNull;
    final prefill = switch (type) {
      'homeassistant' => {'url': s.address},
      'mqtt' => {'host': s.address, 'port': '${s.port}'},
      _ => {'host': s.address},
    };
    Navigator.pop(context);
    await openIntegrationSheet(context, spec: spec, config: existing, prefill: prefill);
  }

  /// Found entries that can be added without asking anything (no pairing, no token).
  List<FoundService> _addable(HomeStore store) => _visible
      .where((s) =>
          !_isAdded(store, s) &&
          (s.isLan || (specFor(s.integrationType ?? '')?.fields.any((f) => f.key == 'hosts') ?? false)))
      .toList();

  Future<void> _addAll() async {
    final store = context.read<HomeStore>();
    final todo = _addable(store);
    for (final s in todo) {
      if (!mounted) return;
      await _add(s);
    }
    store.toast('Added ${todo.length} devices. Find them on the Devices tab.');
  }

  String _subtitle(FoundService s) {
    if (s.integrationType == matterType) {
      return s.service == '_matter._tcp'
          ? 'Matter · set up in an app'
          : (s.hints['pairing'] == '0' ? 'Matter · not in pairing mode' : 'Matter · ready to pair');
    }
    final what = s.integrationType == null
        ? 'Device'
        : s.isLan
            ? (FoundService.protocolLabels[s.protocol] ?? 'Network device')
            : specFor(s.integrationType!)?.name;
    return '$what · ${s.host}';
  }

  IconData _icon(FoundService s) {
    if (s.integrationType == null) return Icons.hub;
    if (!s.isLan) return specFor(s.integrationType!)?.icon ?? Icons.devices;
    return switch (s.protocol) {
      'roku' || 'samsung' || 'webos' || 'sony' || 'cast' => Icons.tv,
      'upnp' => Icons.speaker_outlined,
      'kasa' || 'wemo' => Icons.power_outlined,
      'yeelight' => Icons.lightbulb_outline,
      _ => Icons.devices_other,
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final visible = _visible;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        children: [
          Row(children: [
            Expanded(child: DotText(_scanning ? 'SCANNING' : 'FOUND ${visible.length}', size: 28)),
            if (_scanning)
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            else
              TextButton(onPressed: _scan, child: const Text('Scan again')),
          ]),
          const SizedBox(height: 6),
          Text('Everything on this Wi-Fi that answers: TVs, speakers, plugs, lights, hubs, printers and more. '
              'Tap Add on anything you want in SmartMenuKJ.',
              style: NType.body(13, color: p.textDim)),
          if (_addable(store).length > 1 && _adding.isEmpty) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('add-all'),
              onPressed: _addAll,
              icon: const Icon(Icons.playlist_add),
              label: Text('Add all ${_addable(store).length}'),
            ),
          ],
          const SizedBox(height: 14),
          NCard(
            key: const Key('add-by-address'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onTap: () => addByAddress(context),
            child: Row(children: [
              const Icon(Icons.lan_outlined, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Add by IP address', style: NType.body(15, color: p.text, weight: 600)),
                  Text('For a device that does not show up here', style: NType.body(12.5, color: p.textDim)),
                ]),
              ),
              const Icon(Icons.add),
            ]),
          ),
          const SizedBox(height: 14),
          if (_noWifi)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text('This phone is not on a Wi-Fi network. Connect it to the same Wi-Fi as your devices and scan again.',
                  style: NType.body(14, color: NothingPalette.red)),
            ),
          if (_scanning && visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('Checking every address on your Wi-Fi. This takes about 15 seconds.',
                  textAlign: TextAlign.center, style: NType.body(14, color: p.textDim)),
            ),
          if (!_scanning && visible.isEmpty && !_noWifi)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('Nothing answered. Check that this phone is on the same Wi-Fi as your devices (not a guest network), '
                  'or add a device by its address.',
                  textAlign: TextAlign.center, style: NType.body(14, color: p.textDim)),
            ),
          for (final s in visible) ...[
            NCard(
              key: Key('found-${s.key}'),
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
              child: Row(children: [
                Icon(_icon(s), size: 24),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(15, color: p.text, weight: 600)),
                    Text(_subtitle(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(12.5, color: p.textDim)),
                  ]),
                ),
                if (_adding.contains(s.key))
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (_isAdded(store, s))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('ADDED', style: NType.label(color: p.textDim)),
                  )
                else
                  TextButton(onPressed: () => _add(s), child: Text(s.integrationType == null ? 'How?' : 'Add')),
              ]),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    return NCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Wrap(spacing: 8, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Icon(Icons.contrast),
            const SizedBox(width: 8),
            Text('Theme', style: NType.body(15, color: p.text, weight: 500)),
            const SizedBox(width: 8),
            for (final m in const ['dark', 'light', 'system'])
              NChip(label: m[0].toUpperCase() + m.substring(1), selected: store.themeMode == m, onTap: () => store.themeMode = m),
          ]),
        ),
        ListTile(
          key: const Key('settings-homes'),
          leading: const Icon(Icons.home_work_outlined),
          title: const Text('Homes'),
          subtitle: Text(store.homes.length == 1
              ? 'Add another home, like a holiday house or an office'
              : '${store.homes.length} homes · ${store.homeName} is open'),
          onTap: () => showHomesSheet(context),
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('Back up home'),
          subtitle: const Text('Copies rooms, devices and connections as text'),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: store.exportJson()));
            store.toast('Backup copied. Paste it somewhere safe. It includes your connection passwords.');
          },
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Restore backup'),
          subtitle: const Text('Paste a backup to replace this home'),
          onTap: () async {
            final raw = await promptText(context, title: 'Paste backup', action: 'Restore');
            if (raw == null || raw.isEmpty) return;
            try {
              await store.importJson(raw);
              store.toast('Home restored.');
            } catch (e) {
              store.toast('That backup could not be read.');
            }
          },
        ),
        if (store.sampleDevices.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.blur_off),
            title: const Text('Remove sample home'),
            subtitle: const Text('Deletes the example devices and their empty rooms'),
            onTap: () async {
              if (await confirm(context,
                  title: 'Remove the sample home?',
                  body: 'The example devices go away. Your own devices, rooms and connections stay.',
                  action: 'Remove')) {
                store.removeSampleHome();
                store.toast('Sample devices removed.');
              }
            },
          ),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('Refresh all devices'),
          onTap: store.refreshAll,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Text('SMARTMENUKJ 1.6 · FREE · LOCAL-FIRST', style: NType.label(color: p.textDim)),
        ),
      ]),
    );
  }
}
