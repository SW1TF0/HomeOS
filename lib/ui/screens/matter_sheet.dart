import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../integrations/network_scan.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../widgets/kj_widgets.dart';

Future<void> openMatterSheet(BuildContext context, {String? name}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => MatterSheet(name: name),
    );

/// Adds a Matter device with its pairing code.
class MatterSheet extends StatefulWidget {
  const MatterSheet({super.key, this.name});

  /// The device's name, when the network scan found it.
  final String? name;

  @override
  State<MatterSheet> createState() => _MatterSheetState();
}

class _MatterSheetState extends State<MatterSheet> {
  final _code = TextEditingController();
  final _address = TextEditingController();
  bool _busy = false;
  bool _showAddress = false;
  String? _step;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final store = context.read<HomeStore>();
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Type the pairing code first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _step = null;
    });
    try {
      final address = _address.text.trim();
      final added = await withMulticast(() => store.pairMatter(code,
          address: address.isEmpty ? null : address, onProgress: (s) => mounted ? setState(() => _step = s) : null));
      if (!mounted) return;
      store.toast(added.isEmpty
          ? 'Added. It has nothing SmartHomeKJ can control yet.'
          : 'Added ${added.map((d) => d.name).join(', ')}. Place it on the map in Edit mode.');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Text(n, style: NType.label(color: KJPalette.accent))),
            Expanded(child: Text(text, style: NType.body(14, color: p.textDim))),
          ]),
        );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.join_inner, size: 30),
            const SizedBox(width: 12),
            Expanded(child: DisplayText(widget.name == null ? 'Add Matter' : widget.name!, size: 24, maxLines: 2)),
          ]),
          const SizedBox(height: 10),
          Text('Matter devices join SmartHomeKJ directly, with no hub or account. The device needs to be on your Wi-Fi.',
              style: NType.body(14, color: p.textDim)),
          const SizedBox(height: 14),
          step('1', 'If it is set up in Google Home, Apple Home, SmartThings or Alexa, open it there and choose '
              'Linked Matter apps or Turn on pairing mode. That gives a new pairing code.'),
          step('2', 'Otherwise use the code on the device or its box, under the QR code.'),
          step('3', 'Type the code here while the pairing window is open (a few minutes).'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('matter-code'),
            controller: _code,
            enabled: !_busy,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _add(),
            decoration: const InputDecoration(labelText: 'Pairing code', hintText: '3497-011-2332 or MT:...'),
          ),
          if (_showAddress) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('matter-address'),
              controller: _address,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Device address', hintText: 'Only if it is not found, e.g. 192.168.1.40'),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => setState(() => _showAddress = true), child: const Text('Type its address')),
            ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_step ?? 'Starting', style: NType.body(13, color: p.textDim)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: NType.body(14, color: KJPalette.danger)),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('matter-add'),
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add_link),
            label: const Text('Add device'),
          ),
          const SizedBox(height: 14),
          Text('A brand-new device that has never been set up joins Wi-Fi over Bluetooth, which SmartHomeKJ cannot do yet: '
              'set it up once in another Matter app, then share it here.',
              style: NType.body(12.5, color: p.textDim)),
        ]),
      ),
    );
  }
}
