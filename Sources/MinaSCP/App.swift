import SwiftUI
import AppKit

final class MinaAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.propertyEditor?.busy == true { Dialogs.info("屬性操作仍在進行", detail: "請等逐項讀回完成後再結束。"); return .terminateCancel }
        if model.commands.activeCount > 0 || model.crossSite.activeCount > 0 { Dialogs.info("進階工作仍在進行", detail: "請先從工作清單停止命令或暫停跨站台複製，再結束程式。"); return .terminateCancel }
        model.saveWorkspace(); model.savePreferences()
        guard model.queue.activeCount > 0 else { model.tabs.forEach { $0.disconnect() }; return .terminateNow }
        guard Dialogs.confirm("仍有傳輸進行中", detail: "結束會暫停傳輸並保留部分檔案；重啟後可手動恢復。") else { return .terminateCancel }
        for record in model.queue.records where [.running,.waiting,.decision].contains(record.state) { model.queue.stop(record.id, pause: true) }
        Task { for _ in 0..<100 { if model.queue.activeCount == 0 { break }; try? await Task.sleep(for: .milliseconds(100)) }; model.tabs.forEach { $0.disconnect() }; sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main struct MinaSCPApp: App {
    @NSApplicationDelegateAdaptor(MinaAppDelegate.self) var delegate
    @StateObject private var model = BrowserModel()
    var body: some Scene {
        Window("MinaSCP", id: "main") { ContentView(model: model).preferredColorScheme(.light).frame(minWidth: 1000, minHeight: 680).onAppear { delegate.model = model } }
            .defaultSize(width: 1320, height: 850)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("站台管理…") { model.showConnection = true }.keyboardShortcut("n", modifiers: .command)
                    Button("重新整理") { model.refreshLocal(); model.refreshRemote() }.keyboardShortcut("r", modifiers: .command)
                    Toggle("顯示隱藏檔案", isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 })).keyboardShortcut(".", modifiers: [.command,.shift])
                }
                CommandMenu("檔案操作") { ForEach(FileCommand.allCases, id: \.self) { command in Button(command.rawValue) { model.execute(command) }.disabled(model.current.map { !CommandContext(tab: $0).allows(command) } ?? true) } }
                CommandMenu("分頁") {
                    Button("新分頁／站台管理…") { model.newSite() }.keyboardShortcut("t", modifiers: .command)
                    Button("重複目前分頁") { if let tab = model.current { model.performTab(.duplicate, id: tab.id) } }.keyboardShortcut("d", modifiers: [.command,.shift])
                    Button("關閉目前分頁") { if let tab = model.current { model.performTab(.close, id: tab.id) } }.keyboardShortcut("w", modifiers: [.command,.shift])
                    Divider()
                    if let tab = model.current { TabActionsMenu(model: model, tab: tab) }
                }
                CommandGroup(replacing: .appSettings) { Button("偏好設定…") { model.showPreferences = true }.keyboardShortcut(",", modifiers: .command) }
            }
    }
}
struct ContentView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Label { Text("MinaSCP") } icon: { Image(nsImage: NSImage(named: "AppIcon") ?? NSImage()).resizable().scaledToFit().frame(width: 24, height: 24) }.font(.headline).foregroundStyle(.blue).padding(.top, 12)
                HStack { Text("站台").font(.caption).foregroundStyle(.secondary); Spacer(); Button { model.newSite() } label: { Image(systemName: "plus") }.buttonStyle(.plain) }
                TextField("搜尋站台", text: $model.siteSearch).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(siteGroups, id: \.self) { group in
                            DisclosureGroup(isExpanded: .constant(true)) {
                                ForEach(model.sites.filter { $0.group == group && (model.siteSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.siteSearch) || $0.host.localizedCaseInsensitiveContains(model.siteSearch)) }) { site in
                                    HStack(spacing: 5) { Circle().fill(siteColor(site.color)).frame(width: 6,height: 6); Text(site.name).font(.system(size: 12)).lineLimit(1); Spacer() }.padding(.vertical, 4).contentShape(Rectangle())
                                        .onTapGesture(count: 2) { model.openSite(site) }

                                        .contextMenu { Button("開啟新分頁") { model.openSite(site) }; Button("編輯站台") { model.selectSite(site) }; Button("複製站台") { model.duplicateSite(site) }; Button("移除站台") { model.deleteSite(site) } }
                                }
                            } label: { Label(group.isEmpty ? "未分組" : group, systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Spacer(minLength: 4)
                Button { model.showConnection = true } label: { Label("站台管理", systemImage: "server.rack") }
                Button { model.showEdits = true } label: { Label("遠端編輯 · \(model.edits.records.count)", systemImage: "square.and.pencil") }
                Button { model.crossSite.showJobs = true } label: { Label("跨站台工作", systemImage: "arrow.left.arrow.right") }
                Button { model.commands.showJobs = true } label: { Label("指令工作", systemImage: "terminal") }
                Button { model.showPreferences = true } label: { Label("偏好設定", systemImage: "slider.horizontal.3") }
                Label("SFTP · OpenSSH", systemImage: "lock.shield").font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
            }.buttonStyle(.plain).padding(16).frame(width: 195).background(.ultraThinMaterial)
            Divider()
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(model.tabs) { tab in WorkspaceTabChip(model: model, tab: tab) }
                        Button { model.newSite() } label: { Image(systemName: "plus") }.buttonStyle(.plain).padding(8)
                    }.padding(.horizontal, 12).padding(.vertical, 7)
                }.background(.thinMaterial)
                HStack(spacing: 14) {
                    ForEach([FileCommand.preview,.edit,.copy,.mkdir,.rename,.delete], id: \.self) { command in
                        Button { model.execute(command) } label: { Label(command.rawValue, systemImage: command.symbol) }.disabled(model.current.map { !CommandContext(tab: $0).allows(command) } ?? true)
                    }
                    Spacer(minLength: 0)
                    Button { model.refreshLocal(); model.refreshRemote() } label: { Image(systemName: "arrow.clockwise") }.help("重新整理 ⌘R")
                    Button { if let tab = model.current, tab.connected { model.sync.configure(tab, exclusions: model.preferences.exclusions); model.showSync = true } } label: { Label("比較／同步", systemImage: "arrow.triangle.2.circlepath") }.disabled(!model.connected)
                    Button { model.reconnect() } label: { Image(systemName: "bolt.horizontal") }.help("連線／重新連線").disabled(model.current?.state.profile.host.isEmpty != false || model.connecting)
                }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 11)
                if let tab = model.current {
                    HSplitView { FilePane(model: model, tab: tab, remote: false); FilePane(model: model, tab: tab, remote: true) }.padding(.horizontal, 10).id(tab.id)
                    if let error = tab.error { ErrorBanner(text: error) { tab.error = nil } }
                }
                TransferQueueView(model: model)
                if let error = model.error ?? model.queue.persistenceError ?? model.authentication.error ?? model.edits.error { ErrorBanner(text: error) { model.error = nil; model.queue.persistenceError = nil; model.authentication.error = nil; model.edits.error = nil } }
                HStack { Text("F3 預覽   F4 編輯   F5 複製   F6 移動   F7 建目錄   F8 刪除"); Spacer(); Text("Tab 切換面板 · ⇧⌘. 隱藏檔") }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            }.background(Color(red: 0.955, green: 0.97, blue: 0.985))
        }.sheet(isPresented: Binding(get: { hasSheet }, set: { if !$0 { dismissSheets() } })) {
            PresentationView(model: model).interactiveDismissDisabled(!model.authentication.prompts.isEmpty || !model.queue.conflicts.isEmpty || model.propertyEditor?.busy == true)
        }
    }
    var siteGroups: [String] { Array(Set(model.sites.map(\.group))).sorted() }
    var hasSheet: Bool { !model.authentication.prompts.isEmpty || !model.queue.conflicts.isEmpty || model.showPreferences || model.showImport || model.showSync || model.showEdits || model.showSearch || model.preview != nil || model.propertyEditor != nil || model.copyContext != nil || model.commands.preview != nil || model.commands.showManager || model.commands.showJobs || model.crossSite.showJobs }
    func dismissSheets() { model.showConnection = false; model.showPreferences = false; model.showImport = false; model.showSync = false; model.showEdits = false; model.showSearch = false; model.preview = nil; model.propertyEditor = nil; model.copyContext = nil; model.commands.preview = nil; model.commands.showManager = false; model.commands.showJobs = false; model.crossSite.showJobs = false }
}
func siteColor(_ name: String) -> Color { switch name { case "red": return .red; case "orange": return .orange; case "green": return .green; case "purple": return .purple; default: return .blue } }
struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View { HStack { Image(systemName: "exclamationmark.triangle"); Text(text).lineLimit(3).textSelection(.enabled); Spacer(); Button("詳情") { Dialogs.info("操作訊息", detail: text) }; Button(action: dismiss) { Image(systemName: "xmark") } }.font(.caption).foregroundStyle(.red).padding(10).background(.red.opacity(0.05)) }
}
struct FilePane: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: TabBrowser
    let remote: Bool
    @State private var pathInput = ""
    var panel: PanelState { remote ? tab.state.remote : tab.state.local }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: remote ? "server.rack" : "laptopcomputer").foregroundStyle(siteColor(tab.state.color))
                Text(remote ? tab.state.profile.host.isEmpty ? "遠端伺服器" : tab.state.profile.host : "本機").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if remote && tab.connecting { ProgressView().controlSize(.small) }
                Toggle("隱藏檔", isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 })).toggleStyle(.checkbox).font(.caption2)
                Menu { ForEach(FileSort.allCases, id: \.self) { sort in Button(sort.rawValue) { if remote { tab.state.remote.sort = sort } else { tab.state.local.sort = sort } } }; Button("反向排序") { if remote { tab.state.remote.ascending.toggle() } else { tab.state.local.ascending.toggle() } } } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).frame(width: 20)
            }.padding(10).background(tab.state.activeSide == (remote ? .remote : .local) ? Color.blue.opacity(0.07) : Color.clear)
            HStack(spacing: 9) {
                Button { model.history(-1, remote: remote, tab: tab) } label: { Image(systemName: "chevron.left") }.disabled(panel.historyIndex <= 0)
                Button { model.history(1, remote: remote, tab: tab) } label: { Image(systemName: "chevron.right") }.disabled(panel.historyIndex + 1 >= panel.history.count)
                Button { model.up(remote: remote, tab: tab) } label: { Image(systemName: "arrow.up") }
                Button { Task { let path = remote ? (try? await tab.session?.canonical(".")) ?? "/" : FileManager.default.homeDirectoryForCurrentUser.path; await tab.navigate(path, side: remote ? .remote : .local) } } label: { Image(systemName: "house") }
                TextField("路徑", text: $pathInput).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).onAppear { pathInput = panel.path }.onChange(of: panel.path) { _, path in pathInput = path }.onSubmit { Task { await tab.navigate(pathInput, side: remote ? .remote : .local); pathInput = panel.path; model.saveWorkspace() } }
                Menu {
                    Button("加入書籤") { if remote { if !tab.state.remote.bookmarks.contains(panel.path) { tab.state.remote.bookmarks.append(panel.path) } } else { if !tab.state.local.bookmarks.contains(panel.path) { tab.state.local.bookmarks.append(panel.path) } }; model.saveWorkspace() }
                    ForEach(panel.bookmarks, id: \.self) { path in Button(path) { Task { await tab.navigate(path, side: remote ? .remote : .local) } } }
                    Divider(); ForEach(Array(panel.history.suffix(10).enumerated()), id: \.offset) { _, path in Button(path) { Task { await tab.navigate(path, side: remote ? .remote : .local) } } }
                } label: { Image(systemName: "star") }.menuStyle(.borderlessButton).frame(width: 20)
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 8)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("篩選這一欄", text: Binding(get: { panel.filter }, set: { if remote { tab.state.remote.filter = $0 } else { tab.state.local.filter = $0 } })).textFieldStyle(.plain); if !panel.filter.isEmpty { Button { if remote { tab.state.remote.filter = "" } else { tab.state.local.filter = "" } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) } }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 7).background(.gray.opacity(0.035))
            Divider()
            ZStack {
                FileTable(model: model, tab: tab, remote: remote)
                if remote && !tab.connected {
                    VStack(spacing: 12) { Image(systemName: "server.rack").font(.system(size: 32, weight: .light)).foregroundStyle(.blue); Text(tab.connecting ? "正在連線…" : "尚未連線").font(.headline); Text("站台設定已保存，連線後即可操作檔案").font(.caption).foregroundStyle(.secondary); Button(tab.state.profile.host.isEmpty ? "選擇站台" : "連線") { if tab.state.profile.host.isEmpty { model.showConnection = true } else { model.reconnect(tab) } }.disabled(tab.connecting) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
                }
            }
            Divider()
            HStack { Text("\(tab.visible(remote: remote, hidden: model.showHidden).count) 個項目 · 已選 \(panel.selection.count)"); Spacer(); if remote { Toggle("同步瀏覽", isOn: $tab.synchronizedBrowsing).toggleStyle(.checkbox) } }.font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
        }.frame(minWidth: 320).background(.white).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.15)))
    }
}
struct TransferQueueView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.preferences.queueExpanded.toggle(); model.savePreferences() } label: { Image(systemName: model.preferences.queueExpanded ? "chevron.down" : "chevron.right") }.buttonStyle(.plain)
                Label("傳輸佇列 \(model.queue.records.count)", systemImage: "arrow.left.arrow.right").font(.caption.weight(.semibold))
                Spacer(); Text("總進度 \(model.queue.records.filter { $0.state == .complete }.count)/\(model.queue.records.count)").font(.caption2)
                Text("並行 \(model.queue.activeCount)/\(model.preferences.concurrentTransfers)").font(.caption2).foregroundStyle(.secondary)
                Button("全部暫停") { for record in model.queue.records where [.running,.waiting,.decision].contains(record.state) { model.queue.stop(record.id, pause: true) } }.font(.caption2)
                Button("清除完成") { model.queue.clearCompleted() }.font(.caption2)
            }.padding(10)
            if model.preferences.queueExpanded {
                Divider()
                if model.queue.records.isEmpty { Text("拖曳檔案開始傳輸 · 支援進度、取消、重試與內容校驗").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 70) }
                else { ScrollView { LazyVStack(spacing: 8) { ForEach(model.queue.records) { record in
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 10) {
                            Image(systemName: record.direction == .upload ? "arrow.up.doc" : "arrow.down.doc").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(record.name).lineLimit(1); Text(record.operationLabel).foregroundStyle(.secondary); Spacer(); Text(record.state.rawValue).foregroundStyle(record.state == .failed ? .red : record.state == .complete ? .green : .secondary) }
                                ProgressView(value: record.state == .complete ? 1 : Double(min(record.transferred,record.total)) / Double(max(1,record.total)))
                                if record.state == .running, let size = record.currentFileSize, let bytes = record.currentFileBytes { Text("目前檔案：\(Int(min(100, Double(bytes) / Double(max(1,size)) * 100)))%").font(.caption2).foregroundStyle(.secondary) }
                                HStack { if record.sameSideOperation != .move { Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: record.transferred), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: record.total), countStyle: .file))") }; if model.queue.speed(record) > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.queue.speed(record)), countStyle: .file))/s · 剩餘 \(Int(Double(record.total > record.transferred ? record.total - record.transferred : 0) / model.queue.speed(record))) 秒") }; Spacer(); if !record.message.isEmpty { Text(record.message).lineLimit(1).help(record.message) } }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if [.running,.waiting,.decision].contains(record.state) { Button { model.queue.stop(record.id, pause: true) } label: { Image(systemName: "pause") }; Button { model.queue.stop(record.id, pause: false) } label: { Image(systemName: "xmark") } }
                            else if record.state != .complete && record.crossSiteJobID == nil { Button { model.queue.retry(record.id) } label: { Image(systemName: "arrow.clockwise") } }
                            Button { Dialogs.info(record.name, detail: "\(record.source)\n→ \(record.destination)\n\(record.message)\n" + record.checkpoints.values.filter { !$0.completed }.map { "保留暫存：" + $0.staging }.joined(separator: "\n")) } label: { Image(systemName: "info.circle") }
                        }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 10)
                    }
                } }.padding(.vertical, 8) }.frame(height: 125) }
            }
        }.background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.12))).padding(.horizontal, 10).padding(.top, 8)
    }
}
