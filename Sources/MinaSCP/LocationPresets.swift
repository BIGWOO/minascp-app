import SwiftUI
import AppKit

struct LocationPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var localPath: String
    var remotePath: String
    var siteID: UUID?
}

struct LocationPresetsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: TabBrowser
    let remote: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var localPath = ""
    @State private var remotePath = ""
    @State private var presets: [LocationPreset] = []
    @State private var shared = false
    @State private var selection: UUID?
    @State private var name = ""
    @State private var error: String?
    @State private var loadFailed = false
    @State private var navigating = false
    @FocusState private var focused: PanelSide?
    private let store = AtomicStore<[LocationPreset]>(url: AppStoragePaths.root.appendingPathComponent("location-presets.json"))
    private var visible: [LocationPreset] { presets.filter { $0.siteID == (shared ? nil : tab.state.profile.id) } }
    private var valid: Bool { !localPath.isEmpty && !remotePath.isEmpty && !localPath.contains("\0") && !remotePath.contains("\0") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("位置設定組合").font(.title2.bold())
            Text("本機目錄")
            HStack {
                TextField("本機完整路徑", text: $localPath).focused($focused, equals: .local)
                Menu("最近") { ForEach(Array(Set(tab.state.local.history)).sorted(), id: \.self) { path in Button(path) { localPath = path } } }
                Button("瀏覽…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: localPath)
                    if panel.runModal() == .OK, let url = panel.url { localPath = url.path }
                }
            }
            Text("遠端目錄")
            HStack {
                TextField("遠端完整路徑", text: $remotePath).focused($focused, equals: .remote)
                Menu("最近") { ForEach(Array(Set(tab.state.remote.history)).sorted(), id: \.self) { path in Button(path) { remotePath = path } } }
            }
            Picker("範圍", selection: $shared) {
                Text("站台位置設定組合").tag(false)
                Text("共用位置設定組合").tag(true)
            }.pickerStyle(.segmented).onChange(of: shared) { _, _ in selection = nil }
            HStack(alignment: .top) {
                List(selection: $selection) {
                    ForEach(visible) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.name)
                            Text(preset.localPath + " ↔ " + preset.remotePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(preset.id)
                    }
                }.frame(minHeight: 190)
                VStack {
                    Button("加入") { mutate { presets.append(LocationPreset(name: name, localPath: localPath, remotePath: remotePath, siteID: shared ? nil : tab.state.profile.id)); selection = presets.last?.id } }.disabled(!valid || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("重新命名") { mutate { if let i = presets.firstIndex(where: { $0.id == selection }) { presets[i].name = name } } }.disabled(selection == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("移除") { mutate { presets.removeAll { $0.id == selection }; selection = nil } }.disabled(selection == nil)
                    Button("移上") { move(-1) }.disabled(!canMove(-1))
                    Button("移下") { move(1) }.disabled(!canMove(1))
                }.disabled(loadFailed)
            }
            TextField("組合名稱", text: $name)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("選取組合後按「前往」，即可切換兩側目錄。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(navigating ? "開啟中…" : "前往") { go() }.keyboardShortcut(.defaultAction).disabled(!valid || navigating)
            }
        }.padding(22).frame(width: 690)
            .onAppear {
                localPath = tab.state.local.path; remotePath = tab.state.remote.path
                do { presets = try store.load() ?? [] } catch { self.error = error.localizedDescription; loadFailed = true }
                focused = remote ? .remote : .local
            }
            .onChange(of: selection) { _, id in
                if let preset = presets.first(where: { $0.id == id }) { localPath = preset.localPath; remotePath = preset.remotePath; name = preset.name }
            }
    }
    private func mutate(_ action: () -> Void) {
        let previous = presets
        action()
        do { try store.save(presets); error = nil } catch { presets = previous; self.error = error.localizedDescription }
    }
    private func canMove(_ delta: Int) -> Bool {
        guard let i = visible.firstIndex(where: { $0.id == selection }) else { return false }
        return visible.indices.contains(i + delta)
    }
    private func move(_ delta: Int) {
        guard canMove(delta), let i = visible.firstIndex(where: { $0.id == selection }),
              let a = presets.firstIndex(where: { $0.id == visible[i].id }),
              let b = presets.firstIndex(where: { $0.id == visible[i + delta].id }) else { return }
        mutate { presets.swapAt(a, b) }
    }
    private func go() {
        navigating = true; error = nil
        Task { @MainActor in
            defer { navigating = false }
            do {
                let local = (localPath as NSString).expandingTildeInPath
                _ = try LocalFiles.list(local)
                if remotePath != tab.state.remote.path || tab.connected {
                    guard let session = tab.session, tab.connected else { throw TransferError.message("請先連線，再切換遠端目錄") }
                    _ = try await session.list(try await session.canonical(remotePath))
                    tab.error = nil
                    await tab.navigate(remotePath, side: .remote)
                    if let message = tab.error { throw TransferError.message(message) }
                }
                tab.error = nil
                await tab.navigate(local, side: .local)
                if let message = tab.error { throw TransferError.message(message) }
                model.saveWorkspace(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
