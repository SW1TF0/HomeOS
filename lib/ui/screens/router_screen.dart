import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../integrations/integration.dart';
import '../../integrations/lan/mac_vendor.dart';
import '../../integrations/lan/routeros.dart';
import '../../models/device.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/kj_widgets.dart';

Future<void> openRouterScreen(BuildContext context, Device d) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RouterScreen(deviceId: d.id)));

/// Opens a device's own web page in the browser.
Future<void> openWebPage(HomeStore store, String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  store.toast('Open $url in a browser.');
}

/// A MikroTik router: how it is doing, its Wi-Fi, what is connected, its ports, and restarting it.
class RouterScreen extends StatefulWidget {
  const RouterScreen({super.key, required this.deviceId});
  final String deviceId;

  @override
  State<RouterScreen> createState() => _RouterScreenState();
}

class _RouterScreenState extends State<RouterScreen> {
  MikroTik? _router;
  RouterSnapshot? _snap;
  String? _error;
  bool _needsLogin = false;
  bool _loading = true;
  final _user = TextEditingController();
  final _password = TextEditingController();

  HomeStore get _store => context.read<HomeStore>();
  Device? get _device => _store.device(widget.deviceId);

  @override
  void initState() {
    super.initState();
    final d = _device;
    _user.text = '${d?.props['username'] ?? 'admin'}';
    _connect();
  }

  @override
  void dispose() {
    _router?.os.close();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final d = _device;
    if (d == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _router?.os.close();
      _router = null;
      final router = await _store.openRouter(d);
      final snap = await router.load();
      await MacVendors.load();
      if (!mounted) {
        await router.os.close();
        return;
      }
      final via = router.os is RouterOsApi ? 'api' : 'rest';
      if (d.props['api'] != via) _store.setDeviceProp(d, 'api', via);
      setState(() {
        _router = router;
        _snap = snap;
        _needsLogin = false;
      });
    } on RouterLoginException {
      if (mounted) setState(() => _needsLogin = true);
    } on IntegrationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The router does not answer. Check that this phone is on its Wi-Fi.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logIn() async {
    final d = _device;
    if (d == null) return;
    _store.setRouterLogin(d, _user.text, _password.text);
    await _connect();
    if (_needsLogin && mounted) _store.toast('The router did not accept that login.');
    if (!_needsLogin && _error == null) _store.refreshDevice(d);
  }

  DeviceGuess? _guess(RouterClient c) => guessDevice(vendor: MacVendors.loaded?.vendorOf(c.mac), mac: c.mac);

  /// What a connected device probably is, from its MAC.
  String? _whatIs(RouterClient c) {
    final vendor = MacVendors.loaded?.vendorOf(c.mac);
    return _guess(c)?.what ?? (vendor == null ? null : '$vendor device');
  }

  /// Does [change] on the router, then shows how it looks now.
  Future<void> _change(Future<void> Function(MikroTik r) change, {String? done}) async {
    final router = _router;
    if (router == null) return;
    setState(() => _loading = true);
    try {
      await change(router);
      if (done != null) _store.toast(done);
      final snap = await router.load();
      if (mounted) setState(() => _snap = snap);
    } on IntegrationException catch (e) {
      _store.toast(e.message);
      // The API connection may have dropped; open it again.
      if (router.os is RouterOsApi) await _connect();
    } catch (_) {
      _store.toast('The router did not answer.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<HomeStore>().device(widget.deviceId);
    final p = context.palette;
    final snap = _snap;
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(children: [
                  IconButton(
                    key: const Key('router-back'),
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(CupertinoIcons.back, color: KJPalette.accent, size: 28),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: DisplayText(snap?.identity.isNotEmpty == true ? snap!.identity : (d?.name ?? 'Router'), size: 30, maxLines: 1)),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else
                    IconButton(tooltip: 'Refresh', onPressed: _connect, icon: const Icon(Icons.refresh)),
                ]),
              ),
              Expanded(
                child: ListView(
                  key: const Key('router-list'),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  children: [
                    if (_needsLogin) _login(p),
                    if (_error != null && !_needsLogin)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(_error!, style: NType.body(14, color: KJPalette.danger)),
                      ),
                    if (snap != null && !_needsLogin) ..._content(context, d, snap, p),
                    if (d != null) ...[
                      const SectionLabel('Router'),
                      NCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(children: [
                          if (snap != null && !_needsLogin) ...[
                            ListTile(
                              key: const Key('router-rename'),
                              leading: const Icon(Icons.edit_outlined),
                              title: const Text('Rename the router'),
                              subtitle: Text(snap.identity),
                              onTap: () async {
                                final name = await promptText(context, title: 'Router name', initial: snap.identity);
                                if (name == null || name.trim().isEmpty) return;
                                await _change((r) => r.rename(name.trim()), done: 'Renamed to ${name.trim()}.');
                              },
                            ),
                            ListTile(
                              key: const Key('router-login'),
                              leading: const Icon(Icons.key_outlined),
                              title: const Text('Change the login used here'),
                              subtitle: Text('${d.props['username'] ?? 'admin'}'),
                              onTap: () => setState(() => _needsLogin = true),
                            ),
                          ],
                          ListTile(
                            key: const Key('router-webfig'),
                            leading: const Icon(Icons.open_in_browser),
                            title: const Text('Every other setting'),
                            subtitle: const Text('Opens the router\'s own settings page (WebFig) in the browser'),
                            onTap: () => openWebPage(_store, 'http://${d.props['host']}/'),
                          ),
                          if (snap != null && !_needsLogin)
                            ListTile(
                              key: const Key('router-reboot'),
                              leading: const Icon(Icons.restart_alt),
                              title: const Text('Restart the router'),
                              subtitle: const Text('The internet and Wi-Fi go away for about a minute'),
                              onTap: () async {
                                if (!await confirm(context,
                                    title: 'Restart ${snap.identity}?',
                                    body: 'The internet and Wi-Fi go away for about a minute, for everyone at home.',
                                    action: 'Restart')) {
                                  return;
                                }
                                await _change((r) => r.reboot(), done: 'The router is restarting.');
                              },
                            ),
                        ]),
                      ),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _login(KJPalette p) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: NCard(
          key: const Key('router-login-form'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Log in to the router', style: NType.body(17, color: p.text, weight: 600)),
            const SizedBox(height: 4),
            Text('The same user and password as in WinBox or the router\'s web page. A new MikroTik has the password '
                'on a sticker underneath; older ones have user admin and no password.',
                style: NType.body(13, color: p.textDim)),
            const SizedBox(height: 12),
            TextField(
              key: const Key('router-user'),
              controller: _user,
              decoration: const InputDecoration(labelText: 'User'),
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('router-password'),
              controller: _password,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              autocorrect: false,
              onSubmitted: (_) => _logIn(),
            ),
            const SizedBox(height: 14),
            FilledButton(key: const Key('router-log-in'), onPressed: _loading ? null : _logIn, child: const Text('Log in')),
          ]),
        ),
      );

  List<Widget> _content(BuildContext context, Device? d, RouterSnapshot snap, KJPalette p) {
    final online = snap.clients.where((c) => c.online).length;
    Widget stat(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: NType.label(color: p.textDim)),
            const SizedBox(height: 4),
            Text(value.isEmpty ? '–' : value, maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.display(19, color: p.text)),
          ]),
        );
    return [
      const SizedBox(height: 4),
      NCard(
        key: const Key('router-status'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text([if (snap.model.isNotEmpty) 'MikroTik ${snap.model}', if (snap.version.isNotEmpty) 'RouterOS ${snap.version}'].join(' · '),
              style: NType.body(13, color: p.textDim)),
          const SizedBox(height: 14),
          Row(children: [stat('Running for', snap.uptime), stat('CPU', snap.cpu), stat('Memory', snap.memory)]),
          const SizedBox(height: 14),
          Row(children: [
            stat('Connected', '$online'),
            stat('Wi-Fi', snap.wifi.isEmpty ? '' : '${snap.wifi.where((w) => w.enabled).length} of ${snap.wifi.length} on'),
            stat('Ports up', '${snap.ports.where((i) => i['running'] == 'true').length}'),
          ]),
        ]),
      ),
      if (snap.wifi.isNotEmpty) ...[
        const SectionLabel('Wi-Fi'),
        NCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            for (final w in snap.wifi) ...[
              SwitchListTile(
                key: Key('wifi-${w.name}'),
                secondary: Icon(w.enabled ? Icons.wifi : Icons.wifi_off),
                title: Text(w.ssid ?? w.name),
                subtitle: Text([bandLabel(w.band), w.name].where((s) => s.isNotEmpty).join(' · ')),
                value: w.enabled,
                onChanged: _loading
                    ? null
                    : (on) async {
                        if (!on &&
                            !await confirm(context,
                                title: 'Switch off ${w.ssid ?? w.name}?',
                                body: 'Everything on this Wi-Fi loses its connection, this phone too if it uses it. '
                                    'Switch it back on from another Wi-Fi, a cable or WinBox.',
                                action: 'Switch off')) {
                          return;
                        }
                        await _change((r) => r.setEnabled(w.menu, w.id, on), done: on ? 'Wi-Fi on.' : 'Wi-Fi off.');
                      },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(60, 0, 16, 8),
                child: Row(children: [
                  TextButton(
                    key: Key('wifi-name-${w.name}'),
                    style: _compact,
                    onPressed: _loading
                        ? null
                        : () async {
                            final name = await promptText(context, title: 'Wi-Fi name', initial: w.ssid ?? '');
                            if (name == null || name.trim().isEmpty) return;
                            await _change((r) => r.setWifiName(w, name.trim()),
                                done: 'Wi-Fi renamed. Connect your phones to ${name.trim()}.');
                          },
                    child: const Text('Name'),
                  ),
                  TextButton(
                    key: Key('wifi-password-${w.name}'),
                    style: _compact,
                    onPressed: _loading
                        ? null
                        : () async {
                            final pass = await promptText(context,
                                title: 'New Wi-Fi password', hint: 'At least 8 characters', secret: true);
                            if (pass == null || pass.isEmpty) return;
                            await _change((r) => r.setWifiPassword(w, pass),
                                done: 'Password changed. Phones on this Wi-Fi need the new one.');
                          },
                    child: const Text('Password'),
                  ),
                ]),
              ),
            ],
          ]),
        ),
      ],
      if (snap.clients.isNotEmpty) ...[
        SectionLabel('Connected devices · $online'),
        NCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            for (final c in snap.clients.take(80))
              ListTile(
                key: Key('client-${c.address}'),
                leading: Icon(iconForGuess('${_guess(c)?.what} ${c.name}', _guess(c)?.kind.name), color: c.online ? null : p.textDim),
                title: Text(c.name == c.address ? _whatIs(c) ?? c.name : c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    [c.address, MacVendors.loaded?.vendorOf(c.mac) ?? (c.mac.isEmpty ? null : c.mac), c.online ? 'Online' : 'Offline']
                        .nonNulls
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                trailing: PopupMenuButton<String>(
                  key: Key('client-menu-${c.address}'),
                  tooltip: 'More',
                  onSelected: (what) async {
                    if (what == 'add') {
                      final name = c.name == c.address ? _whatIs(c) : c.name;
                      await _store.addNetworkDevice(c.address,
                          hints: {'name': ?name, if (c.mac.isNotEmpty) 'mac': c.mac});
                    } else if (what == 'keep') {
                      await _change((r) => r.keepAddress(c), done: '${c.name} keeps ${c.address} from now on.');
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'add', child: Text('Add to my home')),
                    if (c.dynamic) const PopupMenuItem(value: 'keep', child: Text('Always give it this address')),
                  ],
                ),
              ),
          ]),
        ),
      ],
      if (snap.ports.isNotEmpty) ...[
        const SectionLabel('Ports and connections'),
        NCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            for (final i in snap.ports)
              SwitchListTile(
                key: Key('port-${i['name']}'),
                secondary: Icon(i['running'] == 'true' ? Icons.cable : Icons.power_off_outlined),
                title: Text(i['comment']?.isNotEmpty == true ? '${i['name']} · ${i['comment']}' : '${i['name']}'),
                subtitle: Text(i['disabled'] == 'true' ? 'Switched off' : (i['running'] == 'true' ? 'Connected' : 'Nothing plugged in')),
                value: i['disabled'] != 'true',
                onChanged: _loading
                    ? null
                    : (on) async {
                        if (!on &&
                            !await confirm(context,
                                title: 'Switch off ${i['name']}?',
                                body: 'Whatever is on this port loses its connection. If it is the internet or the '
                                    'port this phone reaches the router through, switch it back on with WinBox.',
                                action: 'Switch off')) {
                          return;
                        }
                        await _change((r) => r.setEnabled('/interface', i['.id'] ?? '', on));
                      },
              ),
          ]),
        ),
      ],
    ];
  }
}

final _compact = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: const EdgeInsets.symmetric(horizontal: 12),
);

/// "2ghz-ax" as "2.4 GHz".
String bandLabel(String? band) {
  final b = (band ?? '').toLowerCase();
  if (b.startsWith('2')) return '2.4 GHz';
  if (b.startsWith('5')) return '5 GHz';
  if (b.startsWith('6')) return '6 GHz';
  return '';
}
