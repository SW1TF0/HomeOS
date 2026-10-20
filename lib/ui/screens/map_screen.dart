import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../../util/haptics.dart';
import '../widgets/dialogs.dart';
import '../widgets/kj_widgets.dart';
import 'device_sheet.dart';
import 'profile_menu.dart';
import 'room_sheet.dart';

/// Ready-made rooms for Add room: name, icon, width and height in map cells.
const roomTemplates = <(String, IconData, double, double)>[
  ('Living room', Icons.weekend_outlined, 8, 6),
  ('Kitchen', Icons.kitchen_outlined, 6, 5),
  ('Bedroom', Icons.bed_outlined, 6, 5),
  ('Bathroom', Icons.bathtub_outlined, 4, 4),
  ('Hall', Icons.door_front_door_outlined, 6, 3),
  ('Office', Icons.desk_outlined, 5, 4),
  ('Dining room', Icons.dining_outlined, 6, 5),
  ('Kids room', Icons.child_care_outlined, 5, 5),
  ('Garage', Icons.garage_outlined, 6, 6),
  ('Garden', Icons.yard_outlined, 10, 6),
  ('Balcony', Icons.balcony_outlined, 6, 2),
  ('Laundry', Icons.local_laundry_service_outlined, 3, 3),
  ('Stairs', Icons.stairs_outlined, 3, 4),
];

/// A finger on a room: moving it, or resizing it from one corner.
class _RoomDrag {
  _RoomDrag(this.rect, this.corner);

  /// Where the room would be right now, in map units, not yet snapped.
  Rect rect;

  /// The corner being dragged, or null when the whole room moves.
  final Alignment? corner;
}

/// The floor plan.
/// View mode: tap a device to switch it, hold it for controls, tap a room to see it.
/// Edit mode: add or draw rooms, drag rooms to move them, drag a corner to
/// resize, drag devices anywhere (they join the room they land in), drag
/// devices from the tray onto the map, undo any step.
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
  bool _drawing = false;
  String? _selectedRoom;
  final _transform = TransformationController();
  final _viewportKey = GlobalKey();
  Size _viewport = Size.zero;
  String? _fittedFloor;

  final Map<String, _RoomDrag> _roomDrag = {};

  /// Live positions of devices being dragged, in map units.
  final Map<String, Offset> _deviceDrag = {};

  /// The two corners of a room being drawn, in map units.
  Offset? _drawFrom, _drawTo;

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

  // ---- Moving the view ----------------------------------------------------------

  /// Room the edit bars take at the bottom of the screen.
  double get _bottomInset => editing ? 140 : 56;

  void _zoomTo(Rect bounds, {double maxScale = 1.6}) {
    if (_viewport.isEmpty) return;
    final height = math.max(120.0, _viewport.height - _bottomInset);
    final px = Rect.fromLTRB(bounds.left * cell, bounds.top * cell, bounds.right * cell, bounds.bottom * cell);
    final scale = math.min(maxScale, math.min(_viewport.width / px.width, height / px.height));
    final dx = (_viewport.width - px.width * scale) / 2 - px.left * scale;
    final dy = (height - px.height * scale) / 2 - px.top * scale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// Zooms so the whole floor fits on screen.
  void fit(HomeStore store) {
    final floor = _floor(store);
    final rooms = store.roomsOn(floor.id);
    Rect bounds = rooms.isEmpty
        ? const Rect.fromLTWH(0, 0, 20, 14)
        : rooms.map((r) => r.rect).reduce((a, b) => a.expandToInclude(b));
    for (final d in store.placedOn(floor.id)) {
      bounds = bounds.expandToInclude(Rect.fromCenter(center: d.mapPos!, width: 1, height: 1));
    }
    _zoomTo(Rect.fromLTRB(bounds.left - 1, bounds.top - 1, bounds.right + 1, bounds.bottom + 1.5));
  }

  void focusRoom(Room r) => _zoomTo(r.rect.inflate(2.5), maxScale: 2);

  /// Fits the floor again if [r] is not fully on screen.
  void _keepInView(HomeStore store, Rect r) {
    final tl = MatrixUtils.transformPoint(_transform.value, r.topLeft * cell);
    final br = MatrixUtils.transformPoint(_transform.value, r.bottomRight * cell);
    final view = Rect.fromLTWH(0, 0, _viewport.width, _viewport.height - _bottomInset);
    if (!view.contains(tl) || !view.contains(br)) fit(store);
  }

  /// The map point at the centre of the screen, in map units.
  Offset _viewCenter() {
    final scene = _transform.toScene(Offset(_viewport.width / 2, (_viewport.height - _bottomInset) / 2));
    return Offset(_snap(scene.dx / cell, 0.5), _snap(scene.dy / cell, 0.5));
  }

  /// Shows a room (switching to its floor and zooming to it); with [edit],
  /// starts editing with that room selected.
  void show({bool edit = false, String? roomId}) {
    final store = context.read<HomeStore>();
    final room = store.room(roomId);
    setState(() {
      if (room != null) {
        _floorId = room.floorId;
        _fittedFloor = room.floorId;
      }
      if (edit && !editing) _beginEditing(store);
      _selectedRoom = edit ? room?.id : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && room != null) focusRoom(room);
    });
  }

  void _beginEditing(HomeStore store) {
    editing = true;
    _drawing = false;
    store.clearLayoutUndo();
  }

  void _endEditing(HomeStore store) {
    editing = false;
    _drawing = false;
    _selectedRoom = null;
    _roomDrag.clear();
    _deviceDrag.clear();
    store.clearLayoutUndo();
  }

  // ---- Edit actions ----------------------------------------------------------------

  /// Asks what kind of room. Returns its name and default size.
  Future<(String, double, double)?> _pickRoom({String title = 'Add a room'}) async {
    final picked = await pickOne<int>(
      context,
      title: title,
      options: [for (var i = 0; i < roomTemplates.length; i++) i, -1],
      label: (i) => i < 0 ? 'Other name...' : roomTemplates[i].$1,
      icon: (i) => i < 0 ? Icons.edit_outlined : roomTemplates[i].$2,
    );
    if (picked == null || !mounted) return null;
    if (picked >= 0) {
      final t = roomTemplates[picked];
      return (t.$1, t.$3, t.$4);
    }
    final name = await promptText(context, title: 'Room name', hint: 'e.g. Music room', action: 'Add');
    if (name == null || name.isEmpty) return null;
    return (name, 6.0, 5.0);
  }

  Future<void> _addRoom(HomeStore store) async {
    final t = await _pickRoom();
    if (t == null || !mounted) return;
    final floor = _floor(store);
    final at = store.freeSpot(floor.id, t.$2, t.$3, near: _viewCenter());
    final room = store.addRoom(floor.id, name: t.$1, x: at.dx, y: at.dy, width: t.$2, height: t.$3);
    setState(() => _selectedRoom = room.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keepInView(store, room.rect);
    });
  }

  Rect? get _drawnRect {
    final a = _drawFrom, b = _drawTo;
    if (a == null || b == null) return null;
    return Rect.fromLTRB(
      math.max(0, _snap(math.min(a.dx, b.dx))),
      math.max(0, _snap(math.min(a.dy, b.dy))),
      math.max(0, _snap(math.max(a.dx, b.dx))),
      math.max(0, _snap(math.max(a.dy, b.dy))),
    );
  }

  Future<void> _finishDrawing(HomeStore store) async {
    final r = _drawnRect;
    final floor = _floor(store);
    setState(() => _drawFrom = _drawTo = null);
    if (r == null) return;
    if (r.width < HomeStore.minRoomSize || r.height < HomeStore.minRoomSize) {
      store.toast('Drag a bit further to draw a room.');
      return;
    }
    final t = await _pickRoom(title: 'Name this room');
    if (t == null || !mounted) return;
    store.addRoom(floor.id, name: t.$1, x: r.left, y: r.top, width: r.width, height: r.height);
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
    _placeNear(store, d);
  }

  /// Puts a device in the selected room, or in the middle of the screen.
  void _placeNear(HomeStore store, Device d) {
    final floor = _floor(store);
    final room = store.room(_selectedRoom);
    if (room != null && room.floorId == floor.id) {
      // Spread devices out a little so they do not land on top of each other.
      final n = store.devicesIn(room.id).length;
      final spot = room.rect.center.translate((n % 3 - 1) * 1.5, (n ~/ 3 % 3 - 1) * 1.2);
      store.placeDevice(d, floor.id, room.contains(spot) ? spot : room.rect.center);
    } else {
      store.placeDevice(d, floor.id, _viewCenter());
    }
    Haptics.selectionClick();
  }

  /// A device dropped from the tray at [global] (a screen position).
  void _drop(HomeStore store, String id, Offset global) {
    final d = store.device(id);
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (d == null || box == null) return;
    final scene = _transform.toScene(box.globalToLocal(global));
    store.placeDevice(
        d, _floor(store).id, Offset(math.max(0, _snap(scene.dx / cell, 0.5)), math.max(0, _snap(scene.dy / cell, 0.5))));
    Haptics.selectionClick();
  }

  Future<void> _floorMenu(HomeStore store, Floor f) async {
    final action = await pickOne<String>(context,
        title: f.name,
        options: ['rename', 'add', if (store.floors.length > 1) 'delete'],
        label: (a) => switch (a) { 'rename' => 'Rename floor', 'add' => 'Add a floor', _ => 'Delete floor' },
        icon: (a) => switch (a) { 'rename' => Icons.edit_outlined, 'add' => Icons.add, _ => Icons.delete_outline });
    if (!mounted) return;
    if (action == 'rename') {
      final name = await promptText(context, title: 'Rename floor', initial: f.name);
      if (name != null && name.isNotEmpty) store.renameFloor(f, name);
    } else if (action == 'add') {
      await _addFloor(store);
    } else if (action == 'delete') {
      if (await confirm(context, title: 'Delete ${f.name}?', body: 'Its rooms are deleted and its devices are taken off the map.')) {
        store.removeFloor(f);
        setState(() => _floorId = null);
      }
    }
  }

  Future<void> _addFloor(HomeStore store) async {
    final name = await promptText(context, title: 'New floor', hint: 'First floor', action: 'Add');
    if (name == null || name.isEmpty || !mounted) return;
    final f = store.addFloor(name);
    setState(() {
      _floorId = f.id;
      _selectedRoom = null;
    });
  }

  // ---- Building ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final floor = _floor(store);
    final rooms = store.roomsOn(floor.id);
    final devices = store.placedOn(floor.id);
    final selected = store.room(_selectedRoom);
    final drawn = _drawnRect;

    return Column(
      children: [
        SizedBox(
          height: 56,
          // On a phone, adding a floor lives in the floor's own menu so the bar still fits.
          child: LayoutBuilder(builder: (context, bar) => Row(children: [
            Expanded(
              // Fades chips that run under the buttons, so the list reads as scrollable.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => LinearGradient(
                  colors: const [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, r.width <= 24 ? 0 : (r.width - 24) / r.width, 1],
                ).createShader(r),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
                  children: [
                    for (final f in store.floors) ...[
                      NChip(
                        key: Key('floor-${f.id}'),
                        label: f.name,
                        selected: f.id == floor.id,
                        trailingIcon: editing && f.id == floor.id ? Icons.expand_more : null,
                        onTap: () {
                          if (editing && f.id == floor.id) {
                            _floorMenu(store, f);
                            return;
                          }
                          setState(() {
                            _floorId = f.id;
                            _selectedRoom = null;
                          });
                        },
                        onLongPress: () => _floorMenu(store, f),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (editing && bar.maxWidth >= 560)
                      NChip(
                        key: const Key('map-add-floor'),
                        label: 'Floor',
                        icon: Icons.add,
                        selected: false,
                        onTap: () => _addFloor(store),
                      ),
                  ],
                ),
              ),
            ),
            if (editing)
              IconButton(
                key: const Key('map-undo'),
                tooltip: 'Undo',
                onPressed: store.canUndoLayout
                    ? () {
                        store.undoLayout();
                        setState(() {
                          if (store.room(_selectedRoom) == null) _selectedRoom = null;
                        });
                      }
                    : null,
                icon: const Icon(Icons.undo),
              ),
            IconButton(tooltip: 'Fit to screen', onPressed: () => fit(store), icon: const Icon(Icons.fit_screen_outlined)),
            Padding(
              padding: EdgeInsets.only(right: editing ? 12 : 4),
              child: editing
                  ? FilledButton(
                      key: const Key('map-done'),
                      style: FilledButton.styleFrom(backgroundColor: KJPalette.danger, foregroundColor: Colors.white),
                      onPressed: () => setState(() => _endEditing(store)),
                      child: const Text('Done'),
                    )
                  : OutlinedButton.icon(
                      key: const Key('map-edit'),
                      onPressed: () => setState(() => _beginEditing(store)),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit'),
                    ),
            ),
            if (!editing) const Padding(padding: EdgeInsets.only(right: 10), child: ProfileButton()),
          ])),
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
            return DragTarget<String>(
              onWillAcceptWithDetails: (_) => editing,
              onAcceptWithDetails: (d) => _drop(store, d.data, d.offset),
              builder: (context, incoming, _) => ClipRect(
                key: _viewportKey,
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
                    panEnabled: !_drawing,
                    boundaryMargin: const EdgeInsets.all(400),
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedRoom = null),
                      child: SizedBox(
                        width: size.width,
                        height: size.height,
                        child: Stack(clipBehavior: Clip.none, children: [
                          for (final r in rooms) _buildRoom(store, r),
                          for (final d in devices) _buildDevice(store, d),
                          if (_drawing)
                            Positioned.fill(
                              key: const ValueKey('draw-layer'),
                              child: GestureDetector(
                                key: const Key('map-draw-layer'),
                                behavior: HitTestBehavior.opaque,
                                dragStartBehavior: DragStartBehavior.down,
                                onPanStart: (d) => setState(() => _drawFrom = _drawTo = d.localPosition / cell),
                                onPanUpdate: (d) => setState(() => _drawTo = d.localPosition / cell),
                                onPanEnd: (_) => _finishDrawing(store),
                                onPanCancel: () => setState(() => _drawFrom = _drawTo = null),
                              ),
                            ),
                          // Drawn above the layer that catches the finger, and keyed, so
                          // adding it mid-drag never rebuilds that layer (which would drop the drag).
                          if (_drawing && drawn != null) _drawPreview(drawn),
                        ]),
                      ),
                    ),
                  ),
                  if (incoming.isNotEmpty)
                    Positioned.fill(
                      key: const ValueKey('drop-highlight'),
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(border: Border.all(color: KJPalette.accent, width: 2)),
                        ),
                      ),
                    ),
                  if (rooms.isEmpty && devices.isEmpty && !_drawing)
                    Center(
                      key: const ValueKey('empty-floor'),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(32, 32, 32, 120),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const DisplayText('Empty floor', size: 28),
                          const SizedBox(height: 8),
                          Text(
                              editing
                                  ? 'Tap Add room for a ready-made room, or Draw to drag one out.'
                                  : 'Tap Edit, then Add room or Draw to make your home.',
                              textAlign: TextAlign.center,
                              style: NType.body(14, color: p.textDim)),
                        ]),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('map-panel'),
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: editing ? _editPanel(store, selected) : _hint(p),
                  ),
                ]),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _hint(KJPalette p) => IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: p.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: p.border),
            ),
            // Two even lines on a phone rather than one word left over.
            child: Text('Tap to switch · hold for controls${_viewport.width < 600 ? '\n' : ' · '}tap a room to open it',
                textAlign: TextAlign.center, style: NType.label(color: p.textDim)),
          ),
        ),
      );

  Widget _drawPreview(Rect r) => Positioned(
        key: const ValueKey('draw-preview'),
        left: r.left * cell,
        top: r.top * cell,
        width: math.max(1, r.width) * cell,
        height: math.max(1, r.height) * cell,
        child: IgnorePointer(
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: KJPalette.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: KJPalette.accent, width: 2),
            ),
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: DisplayText('${r.width.round()} × ${r.height.round()}', size: 18, color: KJPalette.accent),
              ),
            ),
          ),
        ),
      );

  // ---- Edit panel at the bottom -------------------------------------------------------

  static final _compact = ButtonStyle(
    padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
    visualDensity: VisualDensity.compact,
  );

  Widget _bar(List<Widget> children) {
    final p = context.palette;
    return Center(
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: p.border),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }

  Widget _editPanel(HomeStore store, Room? selected) {
    final unplaced = store.unplaced;
    // Drops on the panel itself are ignored rather than landing under it.
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (_) {},
      builder: (context, _, _) => Column(mainAxisSize: MainAxisSize.min, children: [
        if (unplaced.isNotEmpty && !_drawing) ...[
          _tray(store, unplaced),
          const SizedBox(height: 8),
        ],
        if (_drawing)
          _drawBar()
        else if (selected != null)
          _roomBar(store, selected)
        else
          _toolsBar(store),
      ]),
    );
  }

  Widget _toolsBar(HomeStore store) => _bar([
        FilledButton.icon(
          key: const Key('map-add-room'),
          style: _compact,
          onPressed: () => _addRoom(store),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add room'),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          key: const Key('map-draw'),
          style: _compact,
          onPressed: () => setState(() {
            _drawing = true;
            _selectedRoom = null;
          }),
          icon: const Icon(Icons.draw_outlined, size: 18),
          label: const Text('Draw'),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          key: const Key('map-add-device'),
          style: _compact,
          onPressed: () => _placeDevice(store),
          icon: const Icon(Icons.add_location_alt_outlined, size: 18),
          label: const Text('Device'),
        ),
      ]);

  Widget _drawBar() {
    final p = context.palette;
    return _bar([
      const SizedBox(width: 10),
      const Icon(Icons.draw_outlined, size: 18, color: KJPalette.accent),
      const SizedBox(width: 8),
      Text('Drag on the map to draw a room', style: NType.label(color: p.text)),
      const SizedBox(width: 10),
      FilledButton(
        key: const Key('map-draw-stop'),
        style: _compact.copyWith(
          backgroundColor: WidgetStateProperty.all(KJPalette.accent),
          foregroundColor: WidgetStateProperty.all(Colors.white),
        ),
        onPressed: () => setState(() {
          _drawing = false;
          _drawFrom = _drawTo = null;
        }),
        child: const Text('Stop'),
      ),
    ]);
  }

  Widget _roomBar(HomeStore store, Room selected) {
    final p = context.palette;
    final rect = _roomRect(selected);
    return _bar([
      Padding(
        padding: const EdgeInsets.only(left: 12, right: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: DisplayText(selected.name, size: 18, maxLines: 1),
        ),
      ),
      Text('${rect.width.round()}×${rect.height.round()}', style: NType.label(color: p.textDim)),
      const SizedBox(width: 4),
      IconButton(
        tooltip: 'Rename room',
        visualDensity: VisualDensity.compact,
        onPressed: () async {
          final name = await promptText(context, title: 'Rename room', initial: selected.name);
          if (name != null && name.isNotEmpty) store.renameRoom(selected, name);
        },
        icon: const Icon(Icons.edit_outlined),
      ),
      IconButton(
        key: const Key('room-duplicate'),
        tooltip: 'Duplicate room',
        visualDensity: VisualDensity.compact,
        onPressed: () {
          final copy = store.duplicateRoom(selected);
          setState(() => _selectedRoom = copy.id);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _keepInView(store, copy.rect);
          });
        },
        icon: const Icon(Icons.content_copy),
      ),
      IconButton(
        tooltip: 'Place a device here',
        visualDensity: VisualDensity.compact,
        onPressed: () => _placeDevice(store),
        icon: const Icon(Icons.add_location_alt_outlined),
      ),
      IconButton(
        key: const Key('room-delete'),
        tooltip: 'Delete room',
        visualDensity: VisualDensity.compact,
        onPressed: () async {
          if (await confirm(context,
              title: 'Delete ${selected.name}?', body: 'Devices in it stay on the map without a room. Undo brings it back.')) {
            store.removeRoom(selected);
            setState(() => _selectedRoom = null);
          }
        },
        icon: const Icon(Icons.delete_outline, color: KJPalette.danger),
      ),
    ]);
  }

  /// Devices that are not on the map yet. Drag one up onto the map, or tap it.
  Widget _tray(HomeStore store, List<Device> unplaced) {
    final p = context.palette;
    return Container(
      key: const Key('map-tray'),
      height: 52,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border),
      ),
      child: Row(children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Text('OFF MAP\n${unplaced.length}', textAlign: TextAlign.center, style: NType.label(color: p.textDim)),
        ),
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
            itemCount: unplaced.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) => _trayChip(store, unplaced[i]),
          ),
        ),
      ]),
    );
  }

  Widget _trayChip(HomeStore store, Device d) {
    final p = context.palette;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.surfaceHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(deviceIcon(d.kind), size: 16),
        const SizedBox(width: 6),
        Text(d.name, style: NType.body(13, color: p.text, weight: 500)),
      ]),
    );
    return Draggable<String>(
      key: Key('tray-${d.id}'),
      data: d.id,
      affinity: Axis.vertical,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: Haptics.selectionClick,
      feedback: Transform.translate(
        offset: const Offset(-22, -22),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.text,
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12)],
            ),
            child: Icon(deviceIcon(d.kind), size: 20, color: p.background),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: GestureDetector(onTap: () => _placeNear(store, d), child: chip),
    );
  }

  // ---- Rooms ------------------------------------------------------------------------

  Rect _roomRect(Room r) {
    final drag = _roomDrag[r.id];
    if (drag == null) return r.rect;
    final live = drag.rect;
    const min = HomeStore.minRoomSize;
    final corner = drag.corner;
    if (corner == null) {
      return Rect.fromLTWH(math.max(0, _snap(live.left)), math.max(0, _snap(live.top)), r.width, r.height);
    }
    var left = _snap(live.left), top = _snap(live.top), right = _snap(live.right), bottom = _snap(live.bottom);
    if (corner.x < 0) {
      left = math.max(0, math.min(left, right - min));
    } else {
      right = math.max(right, left + min);
    }
    if (corner.y < 0) {
      top = math.max(0, math.min(top, bottom - min));
    } else {
      bottom = math.max(bottom, top + min);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _resize(String id, Offset delta) {
    final drag = _roomDrag[id];
    final c = drag?.corner;
    if (drag == null || c == null) return;
    final r = drag.rect;
    drag.rect = Rect.fromLTRB(
      c.x < 0 ? r.left + delta.dx : r.left,
      c.y < 0 ? r.top + delta.dy : r.top,
      c.x > 0 ? r.right + delta.dx : r.right,
      c.y > 0 ? r.bottom + delta.dy : r.bottom,
    );
  }

  void _commitRoom(HomeStore store, Room r) {
    final drag = _roomDrag[r.id];
    if (drag == null) return;
    final rect = _roomRect(r);
    setState(() => _roomDrag.remove(r.id));
    if (rect == r.rect) return;
    store.setRoomRect(r,
        x: rect.left, y: rect.top, width: rect.width, height: rect.height, moveDevices: drag.corner == null);
  }

  Widget _buildRoom(HomeStore store, Room r) {
    final p = context.palette;
    final rect = _roomRect(r);
    final isSelected = editing && _selectedRoom == r.id;
    final inside = store.devicesIn(r.id);
    final active = inside.where((d) => d.countsAsOn).length;
    final temp = averageTemperature(inside);
    final dragging = _roomDrag.containsKey(r.id);

    Widget body = Container(
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: isSelected ? 0.95 : 0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isSelected ? KJPalette.accent : p.border, width: isSelected ? 2 : 1.2),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      alignment: Alignment.topLeft,
      child: Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(r.name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.display(15, color: p.text, weight: 800, spacing: 0.5)),
          if (rect.height >= 3)
            Text(
              [
                if (inside.isNotEmpty) '$active/${inside.length} on',
                if (temp != null) '${temp.toStringAsFixed(1)}°',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: NType.label(color: p.textDim).copyWith(fontSize: 9.5),
            ),
        ]),
        if (isSelected || dragging)
          Align(
            alignment: Alignment.bottomRight,
            child: Text('${rect.width.round()}×${rect.height.round()}',
                style: NType.label(color: isSelected ? KJPalette.accent : p.textDim).copyWith(fontSize: 9.5)),
          ),
      ]),
    );

    body = GestureDetector(
      key: Key('room-${r.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: editing ? () => setState(() => _selectedRoom = r.id) : () => showRoomSheet(context, r.id),
      onPanStart: editing
          ? (_) => setState(() {
                _selectedRoom = r.id;
                _roomDrag[r.id] = _RoomDrag(r.rect, null);
              })
          : null,
      onPanUpdate: editing
          ? (d) => setState(() {
                final drag = _roomDrag[r.id];
                if (drag != null) drag.rect = drag.rect.translate(d.delta.dx / cell, d.delta.dy / cell);
              })
          : null,
      onPanEnd: editing ? (_) => _commitRoom(store, r) : null,
      onPanCancel: editing ? () => setState(() => _roomDrag.remove(r.id)) : null,
      child: body,
    );

    return Positioned(
      left: rect.left * cell,
      top: rect.top * cell,
      width: rect.width * cell,
      height: rect.height * cell,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: body),
        if (isSelected) ...[
          _handle(store, r, Alignment.topLeft, 'room-resize-tl-${r.id}'),
          _handle(store, r, Alignment.topRight, 'room-resize-tr-${r.id}'),
          _handle(store, r, Alignment.bottomLeft, 'room-resize-bl-${r.id}'),
          _handle(store, r, Alignment.bottomRight, 'room-resize-${r.id}'),
        ],
      ]),
    );
  }

  Widget _handle(HomeStore store, Room r, Alignment corner, String key) {
    final p = context.palette;
    return Positioned(
      left: corner.x < 0 ? -14 : null,
      right: corner.x > 0 ? -14 : null,
      top: corner.y < 0 ? -14 : null,
      bottom: corner.y > 0 ? -14 : null,
      child: GestureDetector(
        key: Key(key),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _roomDrag[r.id] = _RoomDrag(r.rect, corner)),
        onPanUpdate: (d) => setState(() => _resize(r.id, d.delta / cell)),
        onPanEnd: (_) => _commitRoom(store, r),
        onPanCancel: () => setState(() => _roomDrag.remove(r.id)),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: KJPalette.accent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: p.background, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Devices ------------------------------------------------------------------------

  Offset _devicePos(Device d) {
    final live = _deviceDrag[d.id];
    if (live != null) return Offset(_snap(live.dx, 0.5), _snap(live.dy, 0.5));
    final drag = d.roomId == null ? null : _roomDrag[d.roomId];
    final room = context.read<HomeStore>().room(d.roomId);
    // Only a move carries devices along; a resize leaves them where they are.
    if (drag != null && drag.corner == null && room != null) {
      final moved = _roomRect(room);
      return d.mapPos!.translate(moved.left - room.x, moved.top - room.y);
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
            color: !d.state.reachable ? KJPalette.danger : (active ? p.text : p.border),
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
          onTap: editing || !HomeStore.tapControls(d) ? () => showDeviceSheet(context, d) : () => store.toggle(d),
          onLongPress: editing ? null : () => showDeviceSheet(context, d),
          onPanStart: editing ? (_) => setState(() => _deviceDrag[d.id] = d.mapPos!) : null,
          onPanUpdate: editing
              ? (u) => setState(() {
                    final at = _deviceDrag[d.id];
                    if (at != null) _deviceDrag[d.id] = at.translate(u.delta.dx / cell, u.delta.dy / cell);
                  })
              : null,
          onPanEnd: editing
              ? (_) {
                  if (!_deviceDrag.containsKey(d.id)) return;
                  final at = _devicePos(d);
                  setState(() => _deviceDrag.remove(d.id));
                  final to = Offset(math.max(0, at.dx), math.max(0, at.dy));
                  if (to != d.mapPos) store.placeDevice(d, d.floorId!, to);
                }
              : null,
          onPanCancel: editing ? () => setState(() => _deviceDrag.remove(d.id)) : null,
          child: Semantics(label: '${d.name}, ${describeState(d)}', button: true, child: marker),
        ),
      ),
    );
  }
}
