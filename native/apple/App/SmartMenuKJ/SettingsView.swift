import SwiftUI
import UniformTypeIdentifiers
import SmartMenuCore

struct SettingsView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var toasts: Toasts
    @AppStorage("clock24") private var clock24 = true
    @AppStorage("checkSeconds") private var checkSeconds = 10
    @State private var importing = false
    @State private var exporting = false
    @State private var backup = BackupFile(text: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { nav.settings = false } label: { Image(systemName: "chevron.left").foregroundStyle(p.text).padding(10) }
                        .buttonStyle(.plain)
                    DotText("Settings", 30)
                }
                .padding(.top, 8)
                SectionLabel("Look")
                HStack(spacing: 8) {
                    ForEach([("dark", "Dark"), ("light", "Light"), ("system", "Like the device")], id: \.0) { mode, label in
                        NChip(label: label, selected: store.data.themeMode == mode) { store.setTheme(mode) }
                    }
                }
                SettingRow(title: "24-hour clock") { Toggle("", isOn: $clock24).labelsHidden().tint(Palette.accent) }
                SectionLabel("Devices")
                Text("Check devices every").font(NType.body(14)).foregroundStyle(p.textDim).padding(.bottom, 8)
                HStack(spacing: 8) {
                    ForEach([5, 10, 30, 60], id: \.self) { s in NChip(label: "\(s) s", selected: checkSeconds == s) { checkSeconds = s } }
                }
                SectionLabel("Your homes")
                Button { importing = true } label: {
                    SettingRow(title: "Bring your home from the other app",
                               subtitle: "Open a SmartMenuKJ backup file from the Android, Flutter or Mac app") {
                        Image(systemName: "doc.badge.arrow.up").foregroundStyle(p.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { backup = BackupFile(text: store.exportAll()); exporting = true } label: {
                    SettingRow(title: "Save a copy", subtitle: "Every home in one file") {
                        Image(systemName: "square.and.arrow.down").foregroundStyle(p.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { nav.sheet = .homes } label: {
                    SettingRow(title: "Homes", subtitle: "\(store.homes.count) · \(store.home?.name ?? "")") {
                        Image(systemName: "house").foregroundStyle(p.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                SectionLabel("About")
                SettingRow(title: "SmartMenuKJ native \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
                           subtitle: "Swift and SwiftUI. Free, and everything stays on your device.") { EmptyView() }
                Text("How it works: tap a device to switch it, hold it for all its controls, drag sideways across a tile to dim. "
                     + "On the map, tap Edit to draw rooms, drag them, and resize them from the corner.")
                    .font(NType.body(13)).foregroundStyle(p.textDim).padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.bottom, 28)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { toasts.show("Could not read that file."); return }
            do {
                let n = try store.importAll(text)
                toasts.show(n == 1 ? "Your home is back." : "\(n) homes are back.")
            } catch {
                toasts.show("\(error)")
            }
        }
        .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "SmartMenuKJ-backup.json") { result in
            if case .success = result { toasts.show("Saved a copy of every home.") }
        }
    }
}

struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
