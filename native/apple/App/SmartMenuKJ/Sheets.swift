import SwiftUI
import SmartMenuCore

/// A room: its devices, an all-off switch, rename and remove.
struct RoomSheet: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var roomId: String
    @State private var renaming = false
    @State private var name = ""
    @State private var confirm = false

    var body: some View {
        NSheet {
            if let room = store.data.room(roomId) {
                let devices = store.data.devices(in: roomId)
                let on = devices.filter(\.countsAsOn).count
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        DotText(room.name, 28)
                        Text(on == 0 ? "\(devices.count) devices, all off" : "\(on) of \(devices.count) on").font(NType.body(14)).foregroundStyle(p.textDim)
                    }
                    Spacer()
                    Button {
                        for d in devices { if let a = SceneAction.turn(d, on == 0) { store.command(d.id, a.command) } }
                    } label: {
                        Image(systemName: "power").font(.system(size: 20, weight: .medium)).foregroundStyle(on > 0 ? p.background : p.text)
                            .frame(width: 56, height: 56).background(Circle().fill(on > 0 ? p.text : p.surfaceHigh))
                    }
                    .buttonStyle(.plain)
                }
                if devices.isEmpty {
                    Text("No devices here yet. Open a device and pick this room, or drag it into the room on the map.")
                        .font(NType.body(14)).foregroundStyle(p.textDim).padding(.top, 16)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(devices) { d in DeviceTile(device: d, roomName: nil) { nav.sheet = .device(d.id) } }
                }
                .padding(.top, 16)
                if renaming {
                    NTextField(label: "Room name", text: $name).padding(.top, 18)
                    PrimaryButton(label: "Save") { store.renameRoom(roomId, name); renaming = false }.padding(.top, 10)
                } else {
                    HStack(spacing: 8) {
                        NChip(label: "Rename", icon: "pencil") { name = room.name; renaming = true }
                        NChip(label: "Show on map", icon: "square.grid.3x3") { dismiss(); nav.openMap(floorId: room.floorId) }
                        NChip(label: confirm ? "Tap again" : "Remove", icon: "trash") {
                            if confirm { store.removeRoom(roomId); dismiss() } else { confirm = true }
                        }
                    }
                    .padding(.top, 18)
                }
            }
        }
    }
}

/// The list of homes: switch, add, rename, remove.
struct HomesSheet: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    @State private var adding = false
    @State private var renaming: String?
    @State private var name = ""

    var body: some View {
        NSheet {
            DotText("Homes", 28).padding(.bottom, 12)
            ForEach(store.homes) { h in
                SettingRow(title: h.name, subtitle: h.id == store.homeId ? "Open now" : nil) {
                    HStack(spacing: 4) {
                        if h.id == store.homeId { Circle().fill(Palette.accent).frame(width: 8, height: 8) }
                        Button { renaming = h.id; name = h.name } label: { Image(systemName: "pencil").foregroundStyle(p.textDim).padding(8) }
                            .buttonStyle(.plain)
                        if store.homes.count > 1 {
                            Button { store.removeHome(h.id) } label: { Image(systemName: "trash").foregroundStyle(p.textDim).padding(8) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.switchHome(h.id); dismiss() }
            }
            if adding || renaming != nil {
                NTextField(label: renaming != nil ? "New name" : "Name of the home", text: $name).padding(.top, 12)
                HStack(spacing: 10) {
                    PrimaryButton(label: renaming != nil ? "Rename" : "Add home") {
                        if let r = renaming { store.renameHome(r, name) } else { store.addHome(name); dismiss() }
                        adding = false; renaming = nil; name = ""
                    }
                    SecondaryButton(label: "Cancel") { adding = false; renaming = nil }
                }
                .padding(.top, 10)
            } else {
                SecondaryButton(label: "Add a home") { adding = true; name = "" }.padding(.top, 12)
            }
        }
    }
}

/// A device that lives only in the app.
struct AddVirtualDeviceSheet: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    @State private var name = ""
    @State private var kind = DeviceKind.light
    @State private var roomId: String?

    var body: some View {
        NSheet {
            DotText("Virtual device", 26)
            Text("It lives only in the app. Use it to plan a room or try scenes before the hardware arrives.")
                .font(NType.body(14)).foregroundStyle(p.textDim).padding(.top, 6)
            VStack(alignment: .leading, spacing: 14) {
                NTextField(label: "Name", text: $name, hint: kind.label)
                Labeled("Kind") {
                    FlowRow {
                        ForEach(DeviceKind.allCases.filter { $0 != .other }, id: \.self) { k in
                            NChip(label: k.label, selected: kind == k, icon: deviceIcon(k)) { kind = k }
                        }
                    }
                }
                Labeled("Room") {
                    FlowRow {
                        NChip(label: "No room", selected: roomId == nil) { roomId = nil }
                        ForEach(store.data.rooms) { r in NChip(label: r.name, selected: roomId == r.id) { roomId = r.id } }
                    }
                }
                PrimaryButton(label: "Add") { store.addVirtualDevice(name, kind, roomId: roomId); dismiss() }
            }
            .padding(.top, 16)
        }
    }
}
