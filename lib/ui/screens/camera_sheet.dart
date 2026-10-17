import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../integrations/camera/camera_setup.dart';
import '../../integrations/camera/onvif.dart';
import '../../integrations/integration.dart';
import '../../integrations/network_scan.dart';
import '../../models/device.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/nothing_widgets.dart';

/// Asks for a camera's address, brand and login, then finds its live video. Without [device] the camera is added.
/// Returns the camera once it is set up.
Future<Device?> showCameraSetup(BuildContext context, {Device? device}) => showModalBottomSheet<Device>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => CameraSetupSheet(deviceId: device?.id),
    );

/// A brand guessed from a camera's name, so the right hint and addresses come first.
String guessCameraBrand(String? name) {
  final n = (name ?? '').toLowerCase();
  if (n.contains('tapo') || n.contains('tp-ipc') || n.contains('tp-link')) return 'tapo';
  if (n.contains('reolink')) return 'reolink';
  if (n.contains('hik') || n.contains('ezviz')) return 'hikvision';
  if (n.contains('dahua') || n.contains('imou') || n.contains('amcrest') || n.contains('lechange')) return 'dahua';
  return 'other';
}

class CameraSetupSheet extends StatefulWidget {
  const CameraSetupSheet({super.key, this.deviceId, this.search});
  final String? deviceId;

  /// Looks for cameras on the Wi-Fi. Tests pass their own.
  final Future<List<OnvifCamera>> Function()? search;

  @override
  State<CameraSetupSheet> createState() => _CameraSetupSheetState();
}

class _CameraSetupSheetState extends State<CameraSetupSheet> {
  late final Device? _device = widget.deviceId == null ? null : context.read<HomeStore>().device(widget.deviceId!);
  late final _host = TextEditingController(text: '${_device?.props['host'] ?? ''}');
  late String _brand = _device?.props['cameraBrand'] as String? ?? guessCameraBrand(_device?.name);
  late final _user = TextEditingController(text: _brand == 'tapo' ? '' : 'admin');
  final _pass = TextEditingController();
  final _link = TextEditingController();
  bool _showLink = false;
  bool _hidden = true;
  bool _busy = false;
  String? _problem;
  List<OnvifCamera> _found = const [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    if (_device == null) _search();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    List<OnvifCamera> found;
    try {
      found = await (widget.search ?? () => withMulticast(onvifProbe))();
    } catch (_) {
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _found = found;
      _searching = false;
      if (found.length == 1 && _host.text.isEmpty) _pick(found.single);
    });
  }

  void _pick(OnvifCamera c) {
    _host.text = c.host;
    final brand = guessCameraBrand(c.name);
    if (brand != 'other') _setBrand(brand);
  }

  void _setBrand(String id) {
    // Tapo has no default user; the others are usually admin.
    if (id == 'tapo' && _user.text == 'admin') _user.clear();
    if (id != 'tapo' && _user.text.isEmpty) _user.text = 'admin';
    _brand = id;
  }

  Future<void> _connect() async {
    final store = context.read<HomeStore>();
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final d = await store.setUpCamera(
        device: _device,
        host: _host.text,
        user: _user.text,
        pass: _pass.text,
        brand: _brand,
        link: _showLink ? _link.text : null,
      );
      store.toast(store.liveStream(d) == null
          ? '${d.name} sends pictures, not video. It shows a new one every few seconds.'
          : 'Connected to ${d.name}.');
      if (mounted) Navigator.pop(context, d);
    } on CameraSetupException catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_host, _user, _pass, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final d = _device;
    final brand = brandOf(_brand);
    final set = d != null && CameraStream.fromProps(d.props) != null;
    final added = {for (final x in store.devices) x.props['host']};
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scroll) => ListView(
        key: const Key('camera-setup'),
        controller: scroll,
        padding: EdgeInsets.fromLTRB(24, 0, 24, 32 + MediaQuery.viewInsetsOf(context).bottom),
        children: [
          DotText(d == null ? 'ADD CAMERA' : 'LIVE VIDEO', size: 30),
          const SizedBox(height: 6),
          Text(
              'SmartMenuKJ plays the camera\'s own video straight over your Wi-Fi. Nothing goes through a cloud, '
              'so it is quick and free.',
              style: NType.body(14, color: p.textDim)),
          if (d == null) ...[
            SectionLabel('On your Wi-Fi',
                trailing: _searching
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : GestureDetector(
                        onTap: _search, child: Text('SEARCH AGAIN', style: NType.label(color: p.textDim)))),
            if (_found.isEmpty)
              Text(
                  _searching
                      ? 'Looking for cameras...'
                      : 'No camera answered. Type its address below: the camera\'s app or your router shows it.',
                  style: NType.body(13, color: p.textDim))
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in _found)
                  NChip(
                    key: Key('found-camera-${c.host}'),
                    icon: Icons.videocam_outlined,
                    label: '${c.name ?? 'Camera'} · ${c.host}${added.contains(c.host) ? ' · added' : ''}',
                    selected: _host.text == c.host,
                    onTap: () => setState(() => _pick(c)),
                  ),
              ]),
          ],
          const SectionLabel('Address'),
          TextField(
            key: const Key('camera-host'),
            controller: _host,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(hintText: 'e.g. 192.168.1.30'),
            onChanged: (_) => setState(() {}),
          ),
          const SectionLabel('Brand'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in cameraBrands)
              NChip(key: Key('brand-${b.id}'), label: b.name, selected: b.id == _brand, onTap: () => setState(() => _setBrand(b.id))),
          ]),
          const SectionLabel('Camera login', accent: true),
          TextField(
            key: const Key('camera-user'),
            controller: _user,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'User'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('camera-pass'),
            controller: _pass,
            obscureText: _hidden,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              ),
            ),
            onSubmitted: (_) => _busy ? null : _connect(),
          ),
          if (brand.hint != null) ...[
            const SizedBox(height: 10),
            Text(brand.hint!, key: const Key('camera-hint'), style: NType.body(12.5, color: p.textDim)),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('camera-link-toggle'),
              onPressed: () => setState(() => _showLink = !_showLink),
              child: Text(_showLink ? 'Find the video for me' : 'I have the video link'),
            ),
          ),
          if (_showLink)
            TextField(
              key: const Key('camera-link'),
              controller: _link,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Video link', hintText: 'rtsp://192.168.1.30:554/stream1 or http://.../video.mjpg'),
            ),
          if (_problem != null) ...[
            const SizedBox(height: 14),
            Text(_problem!, key: const Key('camera-problem'), style: NType.body(14, color: NothingPalette.red)),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('camera-connect'),
            onPressed: _busy ? null : _connect,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.videocam_outlined),
            label: Text(_busy ? 'Looking for the video...' : (d == null ? 'Add camera' : 'Connect')),
          ),
          if (set) ...[
            const SizedBox(height: 8),
            TextButton(
              key: const Key('camera-forget'),
              onPressed: () {
                store.clearCamera(d);
                Navigator.pop(context);
              },
              child: const Text('Forget the login', style: TextStyle(color: NothingPalette.red)),
            ),
          ],
          const SizedBox(height: 18),
          Text(
              'Ring, Arlo, Nest, Blink, Wyze and most Xiaomi cameras only stream to their own cloud, so no other app '
              'can play them over Wi-Fi. Add them through Home Assistant to see them here.',
              style: NType.body(12.5, color: p.textDim)),
        ],
      ),
    );
  }
}
