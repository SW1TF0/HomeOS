import 'package:flutter/material.dart';

import '../../models/device.dart';
import '../../theme/nothing_theme.dart';
import '../../util/haptics.dart';

/// Remote keys a device supports, from what its connection reported.
Set<RemoteKey> remoteKeysOf(Device d) {
  final names = (d.props['keys'] as List?)?.map((e) => '$e').toSet();
  if (names == null) return RemoteKey.values.toSet();
  return RemoteKey.values.where((k) => names.contains(k.name)).toSet();
}

/// A TV remote in the Nothing style: a ringed direction pad, then rows of round keys.
class RemotePad extends StatelessWidget {
  const RemotePad({super.key, required this.keys, required this.onKey});
  final Set<RemoteKey> keys;
  final ValueChanged<RemoteKey> onKey;

  bool _has(RemoteKey k) => keys.contains(k);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasPad = [RemoteKey.up, RemoteKey.down, RemoteKey.left, RemoteKey.right, RemoteKey.ok].any(_has);
    final nav = [RemoteKey.back, RemoteKey.home, RemoteKey.menu, RemoteKey.source].where(_has).toList();
    final media = [RemoteKey.rewind, RemoteKey.playPause, RemoteKey.stop, RemoteKey.forward].where(_has).toList();
    final vol = _has(RemoteKey.volumeUp) || _has(RemoteKey.volumeDown);
    final ch = _has(RemoteKey.channelUp) || _has(RemoteKey.channelDown);

    return Column(children: [
      if (hasPad) ...[
        SizedBox(
          width: 228,
          height: 228,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.border), color: p.surface),
            ),
            if (_has(RemoteKey.up)) Align(alignment: Alignment.topCenter, child: _arrow(RemoteKey.up, Icons.keyboard_arrow_up)),
            if (_has(RemoteKey.down))
              Align(alignment: Alignment.bottomCenter, child: _arrow(RemoteKey.down, Icons.keyboard_arrow_down)),
            if (_has(RemoteKey.left))
              Align(alignment: Alignment.centerLeft, child: _arrow(RemoteKey.left, Icons.keyboard_arrow_left)),
            if (_has(RemoteKey.right))
              Align(alignment: Alignment.centerRight, child: _arrow(RemoteKey.right, Icons.keyboard_arrow_right)),
            if (_has(RemoteKey.ok))
              _Key(
                remoteKey: RemoteKey.ok,
                onKey: onKey,
                size: 84,
                filled: true,
                child: Text('OK', style: NType.dot(26, color: p.background)),
              ),
          ]),
        ),
        const SizedBox(height: 18),
      ],
      if (nav.isNotEmpty) ...[
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          for (final k in nav) _Key(remoteKey: k, onKey: onKey, icon: _icons[k]),
        ]),
        const SizedBox(height: 18),
      ],
      if (vol || ch || _has(RemoteKey.mute))
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          if (vol) _Rocker(label: 'VOL', up: RemoteKey.volumeUp, down: RemoteKey.volumeDown, onKey: onKey),
          if (_has(RemoteKey.mute)) _Key(remoteKey: RemoteKey.mute, onKey: onKey, icon: Icons.volume_off_outlined),
          if (ch) _Rocker(label: 'CH', up: RemoteKey.channelUp, down: RemoteKey.channelDown, onKey: onKey),
        ]),
      if (media.isNotEmpty) ...[
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          for (final k in media) _Key(remoteKey: k, onKey: onKey, icon: _icons[k]),
        ]),
      ],
    ]);
  }

  Widget _arrow(RemoteKey k, IconData icon) => Padding(
        padding: const EdgeInsets.all(6),
        child: _Key(remoteKey: k, onKey: onKey, icon: icon, size: 52, bare: true),
      );

  static const _icons = {
    RemoteKey.back: Icons.arrow_back,
    RemoteKey.home: Icons.home_outlined,
    RemoteKey.menu: Icons.menu,
    RemoteKey.source: Icons.input,
    RemoteKey.rewind: Icons.fast_rewind_outlined,
    RemoteKey.playPause: Icons.play_arrow_outlined,
    RemoteKey.stop: Icons.stop_outlined,
    RemoteKey.forward: Icons.fast_forward_outlined,
  };
}

const _labels = {
  RemoteKey.power: 'Power',
  RemoteKey.volumeUp: 'Volume up',
  RemoteKey.volumeDown: 'Volume down',
  RemoteKey.mute: 'Mute',
  RemoteKey.channelUp: 'Channel up',
  RemoteKey.channelDown: 'Channel down',
  RemoteKey.up: 'Up',
  RemoteKey.down: 'Down',
  RemoteKey.left: 'Left',
  RemoteKey.right: 'Right',
  RemoteKey.ok: 'OK',
  RemoteKey.back: 'Back',
  RemoteKey.home: 'Home',
  RemoteKey.menu: 'Menu',
  RemoteKey.playPause: 'Play or pause',
  RemoteKey.stop: 'Stop',
  RemoteKey.rewind: 'Rewind',
  RemoteKey.forward: 'Forward',
  RemoteKey.source: 'Input',
};

class _Key extends StatelessWidget {
  const _Key({
    required this.remoteKey,
    required this.onKey,
    this.icon,
    this.child,
    this.size = 58,
    this.filled = false,
    this.bare = false,
  });

  final RemoteKey remoteKey;
  final ValueChanged<RemoteKey> onKey;
  final IconData? icon;
  final Widget? child;
  final double size;
  final bool filled;
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: _labels[remoteKey],
      child: InkResponse(
        key: Key('remote-${remoteKey.name}'),
        radius: size / 2 + 4,
        onTap: () {
          Haptics.selectionClick();
          onKey(remoteKey);
        },
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: bare
              ? null
              : BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? p.text : p.surface,
                  border: Border.all(color: filled ? p.text : p.border),
                ),
          child: child ?? Icon(icon, color: filled ? p.background : p.text, size: bare ? 30 : 24),
        ),
      ),
    );
  }
}

/// A tall pill with + on top and - below, like a remote's volume rocker.
class _Rocker extends StatelessWidget {
  const _Rocker({required this.label, required this.up, required this.down, required this.onKey});
  final String label;
  final RemoteKey up;
  final RemoteKey down;
  final ValueChanged<RemoteKey> onKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: p.border),
        color: p.surface,
      ),
      child: Column(children: [
        _Key(remoteKey: up, onKey: onKey, icon: Icons.add, size: 54, bare: true),
        Text(label, style: NType.label(color: p.textDim)),
        _Key(remoteKey: down, onKey: onKey, icon: Icons.remove, size: 54, bare: true),
      ]),
    );
  }
}
