import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../theme/nothing_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/nothing_widgets.dart';
import 'device_sheet.dart';

/// The floor plan. View mode: tap a device to switch it, hold for controls.
/// Edit mode: drag rooms to move them, drag the corner to resize, drag
/// devices anywhere (they join the room they are dropped in).
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  static const cell = 28.0;

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen> {
  static const cell = MapScreen.cell;

  String? _floorId;
  bool editing = false;
  String? _selectedRoom;
  final _transform = TransformationController();
  Size _viewport = Size.zero;
  String? _fittedFloor;

  /// Live rectangles of rooms being dragged, in map units (not yet snapped).
  final Map<String, Rect> _roomDrag = {};

  /// Live positions of devices being dragged, in map units.
  final Map<String, Offset> _deviceDrag = {};

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  static double _snap(double v, [double step = 1]) => (v / step).round() * step;

  Floor _floor(HomeStore store) {
    final floors = store.floors;
    return floors.firstWhere((f) => f.id == _floorId, orElse: () => floors.first);
  }

  Size _canvasSize(List<Room> rooms, List<Device> devices) {
    var w = 40.0, h = 30.0;
    for (final r in rooms) {
      w = math.max(w, r.x + r.width + 12);
      h = math.max(h, r.y + r.height + 12);
    }
    for (final d in devices) {
      w = math.max(w, d.mapPos!.dx + 12);
      h = math.max(h, d.mapPos!.dy + 12);
    }
    return Size(w * cell, h * cell);
  }

  /// Zooms so the whole floor fits on screen.
  void fit(HomeStore store) {
    final floor = _floor(store);
    final rooms = store.roomsOn(floor.id);
    if (_viewport.isEmpty) return;
    Rect bounds = rooms.isEmpty
        ? const Rect.fromLTWH(0, 0, 20, 14)
        : rooms.map((r) => r.rect).reduce((a, b) => a.expandToInclude(b));
    for (final d in store.placedOn(floor.id)) {
      bounds = bounds.expandToInclude(Rect.fromCenter(center: d.mapPos!, width: 1, height: 1));
    }
    bounds = Rect.fromLTRB(bounds.left - 1, bounds.top - 1, bounds.right + 1, bounds.bottom + 1.5);
    final px = Rect.fromLTRB(bounds.left * cell, bounds.top * cell, bounds.right * cell, bounds.bottom * cell);
    final scale = math.min(1.6, math.min(_viewport.width / px.width, _viewport.height / px.height));
    final dx = (_viewport.width - px.width * scale) / 2 - px.left * scale;
    final dy = (_viewport.height - px.height * scale) / 2 - px.top * scale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// The map point at the centre of the screen, in map units.
  Offset _viewCenter() {
    final scene = _transform.toScene(Offset(_viewport.width / 2, _viewport.height / 2));
    return Offset(_snap(scene.dx / cell, 0.5), _snap(scene.dy / cell, 0.5));
  }

  Future<void> _addRoom(HomeStore store) async {
    final name = await promptText(context, title: 'New room', hint: 'Living room', action: 'Add');
    if (name == null) return;
    final c = _viewCenter();
    final room = store.addRoom(_floor(store).id,
        name: name.isEmpty ? null : name, x: math.max(0, c.dx - 4).roundToDouble(), y: math.max(0, c.dy - 3).roundToDouble());
    setState(() => _selectedRoom = room.id);
  }

  Future<void> _placeDevice(HomeStore store) async {
    final unplaced = store.unplaced;
    if (unplaced.isEmpty) {
      store.toast('Every device is already on the map. Add more on the Devices tab.');
      return;
    }
    final d = await pickOne<Device>(context,
        title: 'Put on the map', options: unplaced, label: (d) => d.name, icon: (d) => deviceIcon(d.kind));
    if (d == null) return;
    final room = store.room(_selectedRoom);
    store.placeDevice(d, _floor(store).id, room != null && room.floorId == _floor(store).id ? room.rect.center : _viewCenter());
  }

  Future<void> _floorMenu(HomeStore store, Floor f) async {
    final action = await pickOne<String>(context,
        title: f.name,
        options: ['rename', if (store.floors.length > 1) 'delete'],
        label: (a) => a == 'rename' ? 'Rename floor' : 'Delete floor',
        icon: (a) => a == 'rename' ? Icons.edit_outlined : Icons.delete_outline);
    if (!mounted) return;
    if (action == 'rename') {
      final name = await promptText(context, title: 'Rename floor', initial: f.name);
      if (name != null && name.isNotEmpty) store.renameFloor(f, name);
    } else if (action == 'delete') {
      if (await confirm(context, title: 'Delete ${f.name}?', body: 'Its rooms are deleted and its devices are taken off the map.')) {
        store.removeFloor(f);
        setState(() => _floorId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final floor = _floor(store);
    final rooms = store.roomsOn(floor.id);
    final devices = store.placedOn(floor.id);
    final selected = store.room(_selectedRoom);

    return Column(
      children: [
        SizedBox(
          height: 56,
          child: Row(children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  for (final f in store.floors) ...[
                    NChip(
                      label: f.name,
                      selected: f.id == floor.id,
                      onTap: () => setState(() {
                        _floorId = f.id;
                        _selectedRoom = null;
                      }),
                      onLongPress: () => _floorMenu(store, f),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (editing)
                    NChip(
                      label: 'Floor',
                      icon: Icons.add,
                      selected: false,
                      onTap: () async {
                        final name = await promptText(context, title: 'New floor', hint: 'First floor', action: 'Add');
                        if (name != null && name.isNotEmpty) {
                          final f = store.addFloor(name);
                          setState(() => _floorId = f.id);
                        }
                      },
                    ),
                ],
              ),
            ),
            IconButton(tooltip: 'Fit to screen', onPressed: () => fit(store), icon: const Icon(Icons.fit_screen_outlined)),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: editing
                  ? FilledButton(
                      key: const Key('map-done'),
                      style: FilledButton.styleFrom(backgroundColor: NothingPalette.red, foregroundColor: Colors.white),
                      onPressed: () => setState(() {
                        editing = false;
                        _selectedRoom = null;
                      }),
                      child: const Text('Done'),
                    )
                  : OutlinedButton.icon(
                      key: const Key('map-edit'),
                      onPressed: () => setState(() => editing = true),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit'),
                    ),
            ),
          ]),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            _viewport = c.biggest;
            if (_fittedFloor != floor.id) {
              _fittedFloor = floor.id;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) fit(store);
              });
            }
            final size = _canvasSize(rooms, devices);
            return ClipRect(
              child: Stack(children: [
                // The dot grid fills the whole screen and follows pan and zoom.
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _transform,
                    builder: (context, _) {
                      final m = _transform.value;
                      final scale = m.getMaxScaleOnAxis();
                      final t = m.getTranslation();
                      return CustomPaint(
                        painter: DotGridPainter(
                            color: p.dot, spacing: cell * scale, radius: 1.3, origin: Offset(t.x, t.y)),
                      );
                    },
                  ),
                ),
                InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.3,
                  maxScale: 3,
                  boundaryMargin: const EdgeInsets.all(400),
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedRoom = null),
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: Stack(clipBehavior: Clip.none, children: [
                        for (final r in rooms) _buildRoom(store, r),
                        for (final d in devices) _buildDevice(store, d),
                      ]),
                    ),
                  ),
                ),
                if (rooms.isEmpty && devices.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const DotText('EMPTY FLOOR', size: 28),
                        const SizedBox(height: 8),
                        Text(editing ? 'Tap Add room to draw your first room.' : 'Tap Edit, then Add room to draw your home.',
                            textAlign: TextAlign.center, style: NType.body(14, color: p.textDim)),
                      ]),
                    ),
                  ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: editing ? _editBar(store, selected) : _hint(p),
                ),
              ]),
            );
          }),
        ),
      ],
    );
  }

  Widget _hint(NothingPalette p) => IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: p.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: p.border),
            ),
            child: Text('TAP TO SWITCH · HOLD FOR CONTROLS', style: NType.label(color: p.textDim)),
          ),
        ),
      );

  Widget _editBar(HomeStore store, Room? selected) {
    final p = context.palette;
    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: p.border),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (selected == null) ...[
              FilledButton.icon(
                  key: const Key('map-add-room'),
                  onPressed: () => _addRoom(store),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add room')),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                  key: const Key('map-add-device'),
                  onPressed: () => _placeDevice(store),
                  icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                  label: const Text('Place device')),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DotText(selected.name, size: 18, maxLines: 1),
              ),
              IconButton(
                tooltip: 'Rename room',
                onPressed: () async {
                  final name = await promptText(context, title: 'Rename room', initial: selected.name);
                  if (name != null && name.isNotEmpty) store.renameRoom(selected, name);
                },
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Place a device here',
                onPressed: () => _placeDevice(store),
                icon: const Icon(Icons.add_location_alt_outlined),
              ),
              IconButton(
                tooltip: 'Delete room',
                onPressed: () async {
                  if (await confirm(context,
                      title: 'Delete ${selected.name}?', body: 'Devices in it stay on the map without a room.')) {
                    store.removeRoom(selected);
                    setState(() => _selectedRoom = null);
                  }
                },
                icon: const Icon(Icons.delete_outline, color: NothingPalette.red),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Rect _roomRect(Room r) {
    final live = _roomDrag[r.id];
    if (live == null) return r.rect;
    return Rect.fromLTWH(_snap(live.left), _snap(live.top), math.max(HomeStore.minRoomSize, _snap(live.width)),
        math.max(HomeStore.minRoomSize, _snap(live.height)));
  }

  Widget _buildRoom(HomeStore store, Room r) {
    final p = context.palette;
    final rect = _roomRect(r);
    final isSelected = editing && _selectedRoom == r.id;
    final count = store.devicesIn(r.id).length;
    final active = store.devicesIn(r.id).where((d) => d.state.isActive && d.kind != DeviceKind.lock).length;

    Widget body = Container(
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: isSelected ? 0.95 : 0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isSelected ? NothingPalette.red : p.border, width: isSelected ? 2 : 1.2),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      alignment: Alignment.topLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(r.name.toUpperCase(),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.dot(15, color: p.text, weight: 800, spacing: 0.5)),
        if (rect.height >= 3)
          Text(count == 0 ? '' : '$active/$count ON', style: NType.label(color: p.textDim).copyWith(fontSize: 9.5)),
      ]),
    );

    if (editing) {
      body = GestureDetector(
        key: Key('room-${r.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _selectedRoom = r.id),
        onPanStart: (_) => setState(() {
          _selectedRoom = r.id;
          _roomDrag[r.id] = r.rect;
        }),
        onPanUpdate: (d) => setState(() => _roomDrag[r.id] = _roomDrag[r.id]!.translate(d.delta.dx / cell, d.delta.dy / cell)),
        onPanEnd: (_) => _commitRoom(store, r),
        onPanCancel: () => setState(() => _roomDrag.remove(r.id)),
        child: body,
      );
    }

    return Positioned(
      left: rect.left * cell,
      top: rect.top * cell,
      width: rect.width * cell,
      height: rect.height * cell,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: body),
        if (isSelected)
          Positioned(
            right: -12,
            bottom: -12,
            child: GestureDetector(
              key: Key('room-resize-${r.id}'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => setState(() => _roomDrag[r.id] = r.rect),
              onPanUpdate: (d) => setState(() {
                final cur = _roomDrag[r.id]!;
                _roomDrag[r.id] = Rect.fromLTWH(cur.left, cur.top, cur.width + d.delta.dx / cell, cur.height + d.delta.dy / cell);
              }),
              onPanEnd: (_) => _commitRoom(store, r, moveDevices: false),
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                      color: NothingPalette.red, borderRadius: BorderRadius.circular(4), border: Border.all(color: p.background, width: 2)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  void _commitRoom(HomeStore store, Room r, {bool moveDevices = true}) {
    if (!_roomDrag.containsKey(r.id)) return;
    final rect = _roomRect(r);
    setState(() => _roomDrag.remove(r.id));
    store.setRoomRect(r,
        x: math.max(0, rect.left), y: math.max(0, rect.top), width: rect.width, height: rect.height, moveDevices: moveDevices);
  }

  Offset _devicePos(Device d) {
    final live = _deviceDrag[d.id];
    if (live != null) return Offset(_snap(live.dx, 0.5), _snap(live.dy, 0.5));
    final roomLive = d.roomId == null ? null : _roomDrag[d.roomId];
    final room = context.read<HomeStore>().room(d.roomId);
    if (roomLive != null && room != null) {
      final moved = _roomRect(room);
      // Only a move (same size) carries devices along.
      if ((moved.width - room.width).abs() < 0.01 && (moved.height - room.height).abs() < 0.01) {
        return d.mapPos!.translate(moved.left - room.x, moved.top - room.y);
      }
    }
    return d.mapPos!;
  }

  Widget _buildDevice(HomeStore store, Device d) {
    final p = context.palette;
    final pos = _devicePos(d);
    final active = d.state.isActive && d.state.reachable;
    final glow = lightColor(d);
    const size = 40.0;
    const labelWidth = 96.0;

    final marker = Column(mainAxisSize: MainAxisSize.min, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? p.text : p.surface,
          border: Border.all(
            color: !d.state.reachable ? NothingPalette.red : (active ? p.text : p.border),
            width: _deviceDrag.containsKey(d.id) ? 2.5 : 1.4,
          ),
          boxShadow: glow == null ? null : [BoxShadow(color: glow.withValues(alpha: 0.55), blurRadius: 22, spreadRadius: 2)],
        ),
        child: Icon(deviceIcon(d.kind, active: active), size: 20, color: active ? p.background : p.text),
      ),
      const SizedBox(height: 3),
      Text(d.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: NType.body(10, color: p.textDim, weight: 500)),
    ]);

    return Positioned(
      left: pos.dx * cell - labelWidth / 2,
      top: pos.dy * cell - size / 2,
      width: labelWidth,
      child: Center(
        child: GestureDetector(
          key: Key('marker-${d.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: editing ? () => showDeviceSheet(context, d) : () => store.toggle(d),
          onLongPress: editing ? null : () => showDeviceSheet(context, d),
          onPanStart: editing ? (_) => setState(() => _deviceDrag[d.id] = d.mapPos!) : null,
          onPanUpdate: editing
              ? (u) => setState(() => _deviceDrag[d.id] = _deviceDrag[d.id]!.translate(u.delta.dx / cell, u.delta.dy / cell))
              : null,
          onPanEnd: editing
              ? (_) {
                  final at = _devicePos(d);
                  setState(() => _deviceDrag.remove(d.id));
                  store.placeDevice(d, d.floorId!, Offset(math.max(0, at.dx), math.max(0, at.dy)));
                }
              : null,
          child: Semantics(label: '${d.name}, ${describeState(d)}', button: true, child: marker),
        ),
      ),
    );
  }
}
