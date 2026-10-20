import SwiftUI
import SmartMenuCore

let newSceneId = "__new__"

struct HomeView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        let d = store.data
        let favorites = d.devices.filter(\.favorite)
        let active = d.devices.filter(\.countsAsOn).count
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    ClockView()
                    Spacer()
                    ProfileButton()
                }
                .padding(.top, 10)
                Button { nav.sheet = .homes } label: {
                    HStack(spacing: 6) {
                        Text(store.home?.name ?? HomeStore.defaultHome).font(NType.dot(34)).foregroundStyle(p.text).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.textDim)
                    }
                }
                .buttonStyle(.plain).padding(.top, 6)
                HStack(spacing: 8) {
                    Circle().fill(d.devices.contains { !$0.state.reachable } ? Palette.orange : Palette.green).frame(width: 8, height: 8)
                    Text(active == 0 ? "Everything is off." : "\(active) of \(d.devices.count) devices active.")
                        .font(NType.body(15)).foregroundStyle(p.textDim)
                }
                .padding(.top, 6)
                StatusStrip(data: d).padding(.top, 14)
                if Seed.isSample(d) {
                    NCard(padding: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: "circle.hexagongrid").foregroundStyle(p.text)
                            Text("This is a sample home to try. Connect your devices, or bring your home from the other SmartMenuKJ app in Settings.")
                                .font(NType.body(14)).foregroundStyle(p.text)
                        }
                        HStack(spacing: 8) {
                            NChip(label: "Connect devices", icon: "point.3.connected.trianglepath.dotted") { nav.tab = .connect }
                            NChip(label: "Start empty") { store.clearSample() }
                        }
                        .padding(.top, 10)
                    }
                    .padding(.top, 18)
                }
                SectionLabel(text: "Scenes") { HeaderAction(label: "All") { nav.tab = .scenes } }
                ScenesRow()
                SectionLabel(text: "Favourites", accent: true) { HeaderAction(label: "Devices") { nav.tab = .devices } }
                if favorites.isEmpty {
                    Button { nav.tab = .devices } label: {
                        NCard(padding: 16) {
                            HStack(spacing: 14) {
                                Image(systemName: "star").foregroundStyle(p.text)
                                Text("Star the devices you use most to keep them here.").font(NType.body(14)).foregroundStyle(p.textDim)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(favorites) { dev in
                        DeviceTile(device: dev, roomName: store.roomName(dev.roomId)) { nav.sheet = .device(dev.id) }
                    }
                }
                SectionLabel(text: "Rooms") { HeaderAction(label: "Edit") { nav.openMap(edit: true) } }
                if d.rooms.isEmpty {
                    Button { nav.openMap(edit: true) } label: {
                        NCard(padding: 16) {
                            HStack(spacing: 14) {
                                Image(systemName: "house.and.flag").foregroundStyle(p.text)
                                Text("Draw your rooms on the map to group your devices.").font(NType.body(14)).foregroundStyle(p.textDim)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(d.rooms) { r in
                        Button { nav.sheet = .room(r.id) } label: { RoomCard(data: d, room: r) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 28)
        }
    }
}

struct ClockView: View {
    @Environment(\.palette) var p
    @AppStorage("clock24") private var clock24 = true
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            HStack(spacing: 8) {
                Text(format(ctx.date, clock24 ? "HH:mm" : "h:mm a")).font(NType.body(15, .semibold)).foregroundStyle(p.text)
                Text(format(ctx.date, "EEE d MMM")).font(NType.body(15)).foregroundStyle(p.textDim)
            }
        }
    }
    private func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.dateFormat = pattern
        return f.string(from: d)
    }
}

/// Little facts about the home: temperature inside, lights on, doors locked.
struct StatusStrip: View {
    var data: HomeData
    var body: some View {
        let temp = Describe.averageTemperature(data.devices)
        let lights = data.devices.filter { $0.kind == .light && $0.state.on == true }.count
        let locks = data.devices.filter { $0.kind == .lock }
        let open = locks.filter { $0.state.locked == false }.count
        let offline = data.devices.filter { !$0.state.reachable }.count
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let temp { Pill(icon: "thermometer.medium", text: String(format: "%.1f°", temp)) }
                Pill(icon: "lightbulb", text: lights == 0 ? "Lights off" : "\(lights) lights on")
                if !locks.isEmpty { Pill(icon: open == 0 ? "lock" : "lock.open", text: open == 0 ? "All locked" : "\(open) unlocked", accent: open > 0) }
                if offline > 0 { Pill(icon: "wifi.slash", text: "\(offline) not responding", accent: true) }
            }
        }
    }
}

struct Pill: View {
    @Environment(\.palette) var p
    var icon: String
    var text: String
    var accent = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(accent ? Palette.accent : p.text)
            Text(text).font(NType.body(13, .medium)).foregroundStyle(p.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(p.surface))
    }
}

struct ScenesRow: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.data.scenes) { s in
                    NCard(radius: 20, padding: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: sceneIcon(s.icon)).font(.system(size: 15)).foregroundStyle(.white)
                                .frame(width: 32, height: 32).background(Circle().fill(sceneColor(s.icon)))
                            VStack(alignment: .leading) {
                                Text(s.name).font(NType.body(14, .medium)).foregroundStyle(p.text)
                                if let t = s.schedule { Text("\(t.time) · \(t.daysLabel)").font(NType.body(11)).foregroundStyle(p.textDim) }
                            }
                        }
                    }
                    .fixedSize()
                    .onTapGesture { store.runScene(s.id) }
                    .onLongPressGesture { nav.sheet = .scene(s.id) }
                }
                Button { nav.sheet = .scene(newSceneId) } label: {
                    NCard(radius: 20, padding: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").foregroundStyle(Palette.accent)
                            Text("New scene").font(NType.body(14, .medium)).foregroundStyle(p.textDim)
                        }
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RoomCard: View {
    @Environment(\.palette) var p
    var data: HomeData
    var room: Room
    var body: some View {
        let devices = data.devices(in: room.id)
        let on = devices.filter(\.countsAsOn).count
        let temp = Describe.averageTemperature(devices)
        NCard(padding: 16) {
            HStack(alignment: .top) {
                Text(room.name).font(NType.body(16, .medium)).foregroundStyle(p.text).lineLimit(1)
                Spacer()
                if on > 0 { Circle().fill(Palette.accent).frame(width: 8, height: 8).padding(.top, 6) }
            }
            Spacer(minLength: 14)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                DotText(temp.map { String(format: "%.0f°", $0) } ?? "\(devices.count)", 30)
                Text(on == 0 ? "\(devices.count) devices" : "\(on) on").font(NType.body(12)).foregroundStyle(p.textDim)
            }
        }
        .frame(minHeight: 110)
    }
}
