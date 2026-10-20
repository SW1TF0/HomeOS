import SwiftUI
import SmartMenuCore

/// The floor plan. Rooms are drawn on a dot grid; devices sit in them as dots that light up when on. Tap a device to
/// switch it, hold it for its controls. In edit mode rooms and devices can be dragged, rooms resized from their corner.
struct MapView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    @State private var prompt: NamePrompt?
    @State private var promptText = ""

    enum NamePrompt: Identifiable {
        case room, floor, renameFloor(Floor)
        var id: String {
            switch self {
            case .room: "room"
            case .floor: "floor"
            case .renameFloor(let f): f.id
            }
        }
    }

    var body: some View {
        let d = store.data
        let floor = d.floors.first { $0.id == nav.mapFloor } ?? d.floors.first
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Map") {
                HStack(spacing: 8) {
                    if nav.mapEdit && store.canUndo {
                        Button { store.undoLayout() } label: { Image(systemName: "arrow.uturn.backward").foregroundStyle(p.text).padding(8) }
                            .buttonStyle(.plain)
                    }
                    NChip(label: nav.mapEdit ? "Done" : "Edit", selected: nav.mapEdit, icon: nav.mapEdit ? "checkmark" : "pencil") { nav.mapEdit.toggle() }
                    ProfileButton()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(d.floors) { f in
                        NChip(label: f.name, selected: f.id == floor?.id) { nav.mapFloor = f.id }
                            .contextMenu {
                                Button("Rename") { promptText = f.name; prompt = .renameFloor(f) }
                                if d.floors.count > 1 { Button("Remove floor", role: .destructive) { store.removeFloor(f.id); nav.mapFloor = nil } }
                            }
                    }
                    NChip(label: "Floor", icon: "plus") { promptText = "Floor \(d.floors.count + 1)"; prompt = .floor }
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
            }
            if let floor {
                let rooms = d.rooms(on: floor.id)
                let placed = d.devices.filter { $0.floorId == floor.id && $0.mapPos != nil }
                let unplaced = d.devices.filter { dev in dev.mapPos == nil || !d.floors.contains { $0.id == dev.floorId } }
                if nav.mapEdit {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            NChip(label: "Room", icon: "plus.square") { promptText = ""; prompt = .room }
                            if !unplaced.isEmpty { Text("Tap to place:").font(NType.body(12)).foregroundStyle(p.textDim) }
                            ForEach(unplaced.prefix(40)) { dev in
                                NChip(label: dev.name, icon: deviceIcon(dev.kind)) {
                                    let room = d.room(dev.roomId).flatMap { $0.floorId == floor.id ? $0 : nil } ?? rooms.first
                                    store.moveDevice(dev.id, floorId: floor.id, room.map { HomeStore.freeSpot(d, $0) } ?? MapPos(2, 2))
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 6)
                    }
                }
                FloorPlan(floor: floor, rooms: rooms, devices: placed).id(floor.id)
            }
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }

    private var promptTitle: String {
        switch prompt {
        case .room: "New room"
        case .floor: "New floor"
        case .renameFloor: "Floor name"
        case nil: ""
        }
    }

    private func save() {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        let floor = store.data.floors.first { $0.id == nav.mapFloor } ?? store.data.floors.first
        switch prompt {
        case .room: if let floor { store.addRoom(floor.id, text) }
        case .floor: nav.mapFloor = store.addFloor(text).id
        case .renameFloor(let f): store.renameFloor(f.id, text)
        case nil: break
        }
        prompt = nil
    }
}

struct FloorPlan: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var floor: Floor
    var rooms: [Room]
    var devices: [Device]
    @State private var cell: CGFloat = 0
    @State private var pan = CGSize(width: 8, height: 8)
    @State private var baseCell: CGFloat?
    @State private var basePan: CGSize?

    var body: some View {
        GeometryReader { g in
            let c = cell > 0 ? cell : fitCell(g.size.width)
            ZStack(alignment: .topLeading) {
                DotGrid(color: p.dot, spacing: c, radius: 0.8)
                    .offset(x: pan.width.truncatingRemainder(dividingBy: c), y: pan.height.truncatingRemainder(dividingBy: c))
                    .frame(width: g.size.width + c * 2, height: g.size.height + c * 2)
                    .offset(x: -c, y: -c)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture()
                        .onChanged { v in
                            let b = basePan ?? pan
                            basePan = b
                            pan = CGSize(width: b.width + v.translation.width, height: b.height + v.translation.height)
                        }
                        .onEnded { _ in basePan = nil })
                ForEach(rooms) { r in
                    RoomBox(room: r, cell: c, pan: pan, editing: nav.mapEdit, on: devices.filter { $0.roomId == r.id && $0.countsAsOn }.count)
                }
                ForEach(devices) { dev in DeviceDot(device: dev, floorId: floor.id, cell: c, pan: pan, editing: nav.mapEdit) }
                if rooms.isEmpty && !nav.mapEdit {
                    VStack(spacing: 10) {
                        Text("No rooms on this floor yet.").font(NType.body(15)).foregroundStyle(p.textDim)
                        PrimaryButton(label: "Draw rooms") { nav.mapEdit = true }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
            .clipped()
            .simultaneousGesture(MagnificationGesture()
                .onChanged { z in
                    let b = baseCell ?? c
                    baseCell = b
                    cell = min(max(b * z, 10), 160)
                }
                .onEnded { _ in baseCell = nil })
            .onAppear { if cell == 0 { cell = fitCell(g.size.width) } }
        }
    }

    private func fitCell(_ width: CGFloat) -> CGFloat {
        let right = max(rooms.map(\.right).max() ?? 20, 10)
        return min(max((width - 32) / CGFloat(right + 1), 12), 120)
    }
}

struct RoomBox: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var room: Room
    var cell: CGFloat
    var pan: CGSize
    var editing: Bool
    var on: Int
    // While dragging, the room follows the finger exactly; the store snaps it to the grid.
    @State private var drag: CGSize?
    @State private var grow: CGSize?

    var body: some View {
        let r = room
        let w = max(CGFloat(r.width) * cell + (grow?.width ?? 0), cell * 2)
        let h = max(CGFloat(r.height) * cell + (grow?.height ?? 0), cell * 2)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(on > 0 ? p.surfaceHigh : p.surface.opacity(0.85))
            shape.stroke(editing ? p.text : p.border, lineWidth: editing ? 1.5 : 1)
            Text(r.name).font(NType.label).foregroundStyle(on > 0 ? p.text : p.textDim).lineLimit(1).padding(8)
            if on > 0 { Circle().fill(Palette.accent).frame(width: 6, height: 6).frame(maxWidth: .infinity, alignment: .trailing).padding(9) }
            if editing {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)).foregroundStyle(p.text)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .gesture(DragGesture()
                        .onChanged { v in
                            if grow == nil { store.beginLayoutChange() }
                            grow = v.translation
                        }
                        .onEnded { v in
                            store.setRoomRect(r.id, x: r.x, y: r.y, w: r.width + v.translation.width / cell, h: r.height + v.translation.height / cell, record: false)
                            grow = nil
                        })
            }
        }
        .frame(width: w, height: h)
        .contentShape(shape)
        .onTapGesture { nav.sheet = .room(r.id) }
        .gesture(DragGesture()
            .onChanged { v in
                if drag == nil { store.beginLayoutChange() }
                drag = v.translation
            }
            .onEnded { v in
                store.setRoomRect(r.id, x: r.x + v.translation.width / cell, y: r.y + v.translation.height / cell, w: r.width, h: r.height, record: false)
                drag = nil
            }, including: editing ? .all : .subviews)
        .offset(x: CGFloat(r.x) * cell + pan.width + (drag?.width ?? 0), y: CGFloat(r.y) * cell + pan.height + (drag?.height ?? 0))
    }
}

struct DeviceDot: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var device: Device
    var floorId: String
    var cell: CGFloat
    var pan: CGSize
    var editing: Bool
    @State private var drag: CGSize?

    var body: some View {
        let dev = device
        let pos = dev.mapPos ?? MapPos(0, 0)
        let active = dev.state.isActive && dev.state.reachable
        let glow = Describe.lightColor(dev)?.color
        Image(systemName: deviceIcon(dev.kind, active: active)).font(.system(size: 15))
            .foregroundStyle(active ? .black : p.text)
            .frame(width: 34, height: 34)
            .background(Circle().fill(active ? (glow ?? p.text) : p.surfaceHigh))
            .overlay(Circle().stroke(!dev.state.reachable ? Palette.red : (active ? .clear : p.border), lineWidth: 1))
            .contentShape(Circle())
            .onTapGesture {
                if !editing && Describe.tapToggles(dev) { store.toggle(dev.id) } else { nav.sheet = .device(dev.id) }
            }
            .onLongPressGesture { nav.sheet = .device(dev.id) }
            .gesture(DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    store.moveDevice(dev.id, floorId: floorId, MapPos(HomeStore.snap(pos.x + v.translation.width / cell),
                                                                     HomeStore.snap(pos.y + v.translation.height / cell)))
                    drag = nil
                }, including: editing ? .all : .subviews)
            .offset(x: CGFloat(pos.x) * cell + pan.width - 17 + (drag?.width ?? 0), y: CGFloat(pos.y) * cell + pan.height - 17 + (drag?.height ?? 0))
    }
}
