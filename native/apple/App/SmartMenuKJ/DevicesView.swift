import SwiftUI
import SmartMenuCore

struct DevicesView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    @State private var query = ""
    @State private var kind: DeviceKind?
    private let columns = [GridItem(.adaptive(minimum: 165), spacing: 10)]

    var body: some View {
        let d = store.data
        let shown = d.devices.filter { (kind == nil || $0.kind == kind) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        let groups: [(String, [Device])] = (d.rooms.map { r in (r.name, shown.filter { $0.roomId == r.id }) }
            + [("No room", shown.filter { d.room($0.roomId) == nil })]).filter { !$0.1.isEmpty }
        let kinds = DeviceKind.allCases.filter { k in d.devices.contains { $0.kind == k } }
        VStack(spacing: 0) {
            ScreenTitle(title: "Devices") {
                HStack(spacing: 8) {
                    NChip(label: "Add", icon: "plus") { nav.sheet = .addDevice }
                    ProfileButton()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(p.textDim)
                        TextField("Search", text: $query).textFieldStyle(.plain).font(NType.body(15)).foregroundStyle(p.text)
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: 16).fill(p.surface))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            NChip(label: "All", selected: kind == nil) { kind = nil }
                            ForEach(kinds, id: \.self) { k in NChip(label: k.label, selected: kind == k, icon: deviceIcon(k)) { kind = kind == k ? nil : k } }
                        }
                    }
                    .padding(.top, 12)
                    if d.devices.isEmpty {
                        NCard(padding: 16) {
                            Text("No devices yet. Connect them on the Connect tab, or add a virtual one to plan your home.")
                                .font(NType.body(14)).foregroundStyle(p.textDim)
                        }
                        .padding(.top, 18)
                    }
                    ForEach(groups, id: \.0) { name, list in
                        SectionLabel("\(name) · \(list.count)")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(list) { dev in DeviceTile(device: dev, roomName: nil) { nav.sheet = .device(dev.id) } }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
        }
    }
}
