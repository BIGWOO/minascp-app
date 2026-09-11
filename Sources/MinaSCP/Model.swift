import SwiftUI
import AppKit
import Combine

@MainActor final class BrowserModel: ObservableObject {
    @Published var sites: [SavedSite] = []
    @Published var draft = SavedSite(name: "", host: "", user: NSUserName())
    @Published var tabs: [TabBrowser] = []
    @Published var selectedTabID: UUID?
    // Live view geometry for in-app tab reordering; never persisted.
    var tabFrames: [UUID: CGRect] = [:]
    @Published var showConnection = false { didSet { if showConnection { presentSiteWindow() } else { siteWindow?.orderOut(nil) } } }
    @Published var showPreferences = false
    @Published var showImport = false
    @Published var importCandidates: [ImportCandidate] = []
    @Published var siteSearch = ""
    @Published var error: String?
    @Published var propertyEditor: FilePropertyEditor?
    @Published var connectionInspector: ConnectionInspector?
    var connectionInfoWindow: NSWindow?
    var reportTabBlock: (String) -> Void = { Dialogs.info("分頁工作尚未完成", detail: $0) }
    var confirmTabBackground: (String) -> Bool = { Dialogs.confirm("背景工作仍會繼續", detail: $0 + "\n只關閉／中斷瀏覽分頁，不停止這些工作；可從各工作清單處理。") }
    @Published var preview: PreviewDocument?
    @Published var searchResults: [Entry] = []
    @Published var showSearch = false
    @Published var searching = false
    @Published var preferences = Preferences()
    @Published var showSync = false
    @Published var showEdits = false
    let commands: CommandManager
    let crossSite: CrossSiteManager
    @Published var copyContext: CommandContext?
    let sync = SyncManager()
    let edits: RemoteEditManager
    let queue: TransferQueue
    let authentication = AuthenticationCenter()
    let siteStore: SiteStore
    private var siteWindow: NSWindow?
    private var siteStoreReadable = true
    private var workspaceReadable = true
    private var preferencesReadable = true
    private var appearanceSaveTask: Task<Void, Never>?
    private var appearanceNeedsSave = false
    private var managesAppAppearance = false
    private var subscriptions = Set<AnyCancellable>()
    private var tabSubscriptions = Set<AnyCancellable>()
    private let workspaceStore: AtomicStore<WorkspaceDocument>
    private let preferencesStore: AtomicStore<Preferences>
    var current: TabBrowser? { tabs.first { $0.id == selectedTabID } ?? tabs.first }
    var showHidden: Bool { get { preferences.showHidden } set { preferences.showHidden = newValue; savePreferences() } }
    var connected: Bool { current?.connected == true }
    var connecting: Bool { current?.connecting == true }
    // Editable connection fields belong to the draft, never to a live session.
    var connection: Connection { get { draft.connection } set { draft.host = newValue.host; draft.user = newValue.user; draft.port = newValue.port; draft.identity = newValue.identity; draft.jumpHost = newValue.jumpHost } }
    var siteName: String { get { draft.name } set { draft.name = newValue } }
    var selectedSiteID: UUID? { get { sites.contains { $0.id == draft.id } ? draft.id : nil } set { if let newValue { draft.id = newValue } } }
    var localPath: String { get { draft.localPath } set { draft.localPath = newValue } }
    var remotePath: String { get { draft.remotePath } set { draft.remotePath = newValue } }
    init(siteStore: SiteStore = SiteStore()) {
        self.siteStore = siteStore
        let directory = siteStore.url.deletingLastPathComponent()
        workspaceStore = AtomicStore(url: directory.appendingPathComponent("workspace-v1.json"))
        preferencesStore = AtomicStore(url: directory.appendingPathComponent("preferences-v1.json"))
        edits = RemoteEditManager(root: directory.appendingPathComponent("editing"))
        queue = TransferQueue(url: directory.appendingPathComponent("transfers.json"))
        commands = CommandManager(root: directory)
        crossSite = CrossSiteManager(root: directory, queue: queue)
        do { sites = try siteStore.load() } catch { siteStoreReadable = false; self.error = "無法讀取站台：" + error.localizedDescription }
        do { preferences = try preferencesStore.load() ?? Preferences(); guard preferences.version == 1 else { throw TransferError.message("不支援的偏好設定版本") } } catch { preferencesReadable = false; self.error = "無法讀取偏好設定，已保留原檔：" + error.localizedDescription }
        if preferences.restoreWorkspace {
            do {
                if let document = try workspaceStore.load() {
                    guard document.version == 1 else { throw TransferError.message("不支援的工作區版本") }
                    tabs = document.tabs.map { TabBrowser($0) }; selectedTabID = document.selected
                }
            } catch { workspaceReadable = false; self.error = "無法讀取工作區，已保留原檔：" + error.localizedDescription }
        }
        if tabs.isEmpty { let tab = TabBrowser(WorkspaceTab(profile: SavedSite(name: "本機", host: "", user: NSUserName()))); tabs = [tab]; selectedTabID = tab.id }
        observeTabs()
        commands.authenticate = { [weak self] c in try self?.authentication.prepare(c) ?? c }
        crossSite.authenticate = { [weak self] c in try self?.authentication.prepare(c) ?? c }
        crossSite.sites = { [weak self] in self?.sites ?? [] }
        commands.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        crossSite.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        sync.authenticate = { [weak self] c in guard let self else { return c }; return try self.authentication.prepare(c) }
        sync.enqueue = { [weak self] record in guard let self else { throw CancellationError() }; try await self.queue.perform(record) }
        sync.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        edits.authenticate = { [weak self] c in guard let self else { return c }; return try self.authentication.prepare(c) }
        edits.openEditor = { [weak self] url in self?.openEditor(url) }
        edits.onUpload = { [weak self] in self?.refreshRemote() }
        edits.onIssue = { [weak self] message in self?.error = "遠端編輯：" + message + "（可從側欄開啟遠端編輯清單處理）" }
        edits.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        queue.concurrency = preferences.concurrentTransfers
        queue.authenticate = { [weak self] c in guard let self else { return c }; return try self.authentication.prepare(c) }
        queue.onChange = { [weak self] in guard let self else { return }; if self.preferences.notifyCompletion { NSSound(named: "Glass")?.play() }; for tab in self.tabs { tab.refreshLocal(); Task { await tab.refreshRemote() } } }
        queue.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        authentication.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    func observeTabs() {
        tabSubscriptions.removeAll()
        for tab in tabs {
            tab.change = { [weak self] in self?.saveWorkspace() }
            tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &tabSubscriptions)
        }
    }
    func saveWorkspace() {
        guard workspaceReadable else { return }
        do { try workspaceStore.save(WorkspaceDocument(tabs: tabs.map(\.state), selected: selectedTabID)) } catch { self.error = "保存工作區失敗：" + error.localizedDescription }
    }
    func savePreferences() {
        appearanceSaveTask?.cancel(); appearanceSaveTask = nil
        guard preferencesReadable else { error = "偏好設定讀取失敗，禁止覆寫原檔"; return }
        preferences.concurrentTransfers = max(1, min(8, preferences.concurrentTransfers)); preferences.speedLimit = max(0, preferences.speedLimit)
        preferences.glassTransparency = Preferences.normalizedTransparency(preferences.glassTransparency)
        do {
            try preferencesStore.save(preferences); appearanceNeedsSave = false
            if queue.concurrency != preferences.concurrentTransfers { queue.concurrency = preferences.concurrentTransfers; queue.pump() }
        } catch { self.error = error.localizedDescription }
    }
    func activateAppAppearance() {
        managesAppAppearance = true
        applyAppAppearance()
    }
    private func applyAppAppearance() {
        guard managesAppAppearance, NSApp != nil else { return }
        NSApp.appearance = preferences.appearanceMode.nsAppearance
    }
    func updateAppearance(mode: AppearanceMode? = nil, transparency: Double? = nil) {
        if let mode { preferences.appearanceMode = mode }
        if let transparency { preferences.glassTransparency = Preferences.normalizedTransparency(transparency) }
        applyAppAppearance()
        appearanceNeedsSave = true
        appearanceSaveTask?.cancel()
        appearanceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flushAppearancePreferences()
        }
    }
    func resetAppearance() { updateAppearance(mode: .light, transparency: 50) }
    func flushAppearancePreferences() {
        appearanceSaveTask?.cancel(); appearanceSaveTask = nil
        guard appearanceNeedsSave else { return }
        guard preferencesReadable else { error = "偏好設定讀取失敗，禁止覆寫原檔"; return }
        do { try preferencesStore.save(preferences); appearanceNeedsSave = false }
        catch { self.error = "保存外觀失敗：" + error.localizedDescription }
    }
    func requestPaneFocus(_ target: PaneFocusTarget) {
        guard let tab = current else { return }
        NotificationCenter.default.post(name: .minaPaneFocus, object: PaneFocusRequest(tabID: tab.id, side: tab.state.activeSide, target: target))
    }
    private func presentSiteWindow() {
        guard NSApp != nil else { return }
        if siteWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MinaSCP — 站台管理"; window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SiteManagerView(model: self).minaWindowAppearance(model: self))
            window.center(); siteWindow = window
        }
        siteWindow?.makeKeyAndOrderFront(nil)
    }
    func newSite() { draft = SavedSite(name: "", host: "", user: NSUserName()); showConnection = true }
    func selectSite(_ site: SavedSite) { draft = site; showConnection = true }
    @discardableResult func saveSite() -> Bool {
        guard siteStoreReadable else { error = "站台檔讀取失敗，禁止覆寫原始資料"; return false }
        guard !draft.host.isEmpty else { error = "請填寫主機"; return false }
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = draft.host }
        var updated = sites
        if let i = updated.firstIndex(where: { $0.id == draft.id }) { updated[i] = draft } else { updated.append(draft) }
        do { try siteStore.save(updated); sites = updated; return true } catch { self.error = error.localizedDescription; return false }
    }
    func deleteSite(_ site: SavedSite) {
        guard siteStoreReadable else { error = "站台檔讀取失敗，禁止覆寫"; return }
        let updated = sites.filter { $0.id != site.id }
        do { try siteStore.save(updated); sites = updated } catch { self.error = error.localizedDescription }
    }
    func reorderSites(_ sites: [SavedSite]) { guard siteStoreReadable else { return }; do { try siteStore.save(sites); self.sites = sites } catch { self.error = error.localizedDescription } }
    func duplicateSite(_ site: SavedSite) { draft = site; draft.id = UUID(); draft.name += " 副本"; showConnection = true }
    func connect() { if saveSite() { openSite(draft) } }
    func openSite(_ site: SavedSite) {
        guard site.validationIssues.isEmpty else { error = site.validationIssues.joined(separator: "\n"); draft = site; showConnection = true; return }
        let tab = TabBrowser(WorkspaceTab(profile: site))
        if tabs.count == 1, tabs[0].state.profile.host.isEmpty { tabs = [tab] } else { tabs.append(tab) }
        selectedTabID = tab.id; observeTabs(); saveWorkspace(); showConnection = false
        Task { guard tabs.contains(where: { $0.id == tab.id }) else { return }; await tab.connect(authentication: authentication) }
    }
    func reconnect(_ tab: TabBrowser? = nil) { guard let tab = tab ?? current else { return }; performTab(tab.connected ? .reconnect : .connect, id: tab.id) }
    func disconnect() { if let tab = current { performTab(tab.connecting ? .cancelConnection : .disconnect, id: tab.id) } }
    func closeTab(_ tab: TabBrowser) { performTab(.close, id: tab.id) }
    func refreshLocal() { current?.refreshLocal() }
    func refreshRemote() { guard let tab = current else { return }; Task { await tab.refreshRemote() } }
    func options(for tab: TabBrowser) -> TransferOptions {
        if tab.state.profile.overrideTransferSettings { return tab.state.profile.transferOptions }
        return TransferOptions(policy: preferences.defaultCollision, preserveTime: preferences.preserveTime, preservePermissions: preferences.preservePermissions, speedLimit: preferences.speedLimit)
    }
    func upload(_ urls: [URL], directory: String? = nil, tab: TabBrowser? = nil) {
        guard let tab = tab ?? current, tab.connected, let connection = tab.connection else { showConnection = true; return }
        let target = directory ?? tab.state.remote.path, batchID = UUID()
        if preferences.confirmTransfers, !Dialogs.confirm("上傳 \(urls.count) 個項目？", detail: "\(connection.host):\(target)") { return }
        for url in urls { var task = TransferTask(batchID: batchID, connection: connection, direction: .upload, source: url.path, destination: RemotePath.join(target, url.lastPathComponent)); task.originTabID = tab.id; task.options = options(for: tab); queue.enqueue(task) }
    }
    func download(_ entries: [Entry], to directory: URL, tab: TabBrowser? = nil) {
        guard let tab = tab ?? current, let connection = tab.connection else { return }
        let batchID = UUID()
        for entry in entries { var task = TransferTask(batchID: batchID, connection: connection, direction: .download, source: entry.path, destination: directory.appendingPathComponent(entry.name).path); task.originTabID = tab.id; task.options = options(for: tab); queue.enqueue(task) }
    }
    func promiseDownload(_ entry: Entry, connection: Connection, to destination: URL, originTabID: UUID? = nil, completion: @escaping (Error?) -> Void) {
        var task = TransferTask(connection: connection, direction: .download, source: entry.path, destination: destination.path)
        task.originTabID = originTabID
        task.options = TransferOptions(policy: .ask, preserveTime: preferences.preserveTime, preservePermissions: preferences.preservePermissions, speedLimit: preferences.speedLimit)
        queue.enqueue(task, completion: completion)
    }
    func copyLocal(_ urls: [URL], directory: String? = nil, tab: TabBrowser? = nil) {
        guard let tab = tab ?? current else { return }
        let path = directory ?? tab.state.local.path
        for url in urls {
            let target = URL(fileURLWithPath: path).appendingPathComponent(url.lastPathComponent).path
            guard target != url.path, !target.hasPrefix(url.path + "/") else { error = "不能複製到來源本身或子目錄"; continue }
            var task = TransferTask(connection: Connection(), direction: .local, source: url.path, destination: target); task.originTabID = tab.id; task.options = options(for: tab); queue.enqueue(task)
        }
    }
    func navigate(_ entry: Entry, remote: Bool, tab: TabBrowser? = nil) {
        guard let tab = tab ?? current else { return }
        if entry.directory { Task { await tab.navigate(entry.path, side: remote ? .remote : .local); if tab.synchronizedBrowsing { let other = remote ? tab.state.local.path : tab.state.remote.path; await tab.navigate(RemotePath.join(other, entry.name), side: remote ? .local : .remote) } } }
        else { if remote { editRemote(entry, tab: tab) } else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) } }
    }
    func up(remote: Bool, tab: TabBrowser? = nil) { guard let tab = tab ?? current else { return }; Task { await tab.navigate(RemotePath.parent(remote ? tab.state.remote.path : tab.state.local.path), side: remote ? .remote : .local) } }
    func history(_ delta: Int, remote: Bool, tab: TabBrowser) {
        if remote { tab.state.remote.back(delta) } else { tab.state.local.back(delta) }
        Task { await tab.navigate(remote ? tab.state.remote.path : tab.state.local.path, side: remote ? .remote : .local, history: false) }
    }
    func selectedEntries(_ tab: TabBrowser) -> [Entry] { let remote = tab.state.activeSide == .remote; let selected = remote ? tab.state.remote.selection : tab.state.local.selection; return (remote ? tab.remoteEntries : tab.localEntries).filter { selected.contains($0.id) } }
    func execute(_ command: FileCommand, tab: TabBrowser? = nil) {
        guard let tab = tab ?? current else { return }; execute(command, context: CommandContext(tab: tab))
    }
    func execute(_ command: FileCommand, context c: CommandContext) {
        guard c.allows(command) else { return }
        let tab = c.tab, session = c.session, remote = c.remote, entries = c.entries, directory = c.directory
        if handleContextCommand(command, context: c) { return }
        switch command {
        case .copy: promptTransfer(c); return
        case .move: if Dialogs.confirm("移動 \(entries.count) 個項目至另一端？", detail: "傳輸成功並校驗後刪除來源。\n目的地：" + (remote ? tab.state.local.path : tab.state.remote.path), destructive: true) { moveBetween(entries, tab: tab, remote: remote) }; return
        case .edit: if let entry = entries.first { if remote { editRemote(entry, tab: tab) } else { openEditor(URL(fileURLWithPath: entry.path)) } }; return
        case .preview: if let entry = entries.first { previewFile(entry, tab: tab, remote: remote) }; return
        case .search: search(tab: tab); return
        default: break
        }
        Task {
            do {
                switch command {
                case .mkdir:
                    guard let name = Dialogs.text("新增資料夾", detail: directory) else { return }; try LocalFiles.safeName(name)
                    let path = RemotePath.join(directory, name)
                    if remote { try await session!.mkdir(path) } else { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
                case .rename:
                    guard entries.count == 1, let entry = entries.first, let name = Dialogs.text("重新命名", detail: entry.path, value: entry.name) else { return }; try LocalFiles.safeName(name)
                    let target = RemotePath.join(directory, name)
                    if remote { try await session!.rename(entry.path, to: target) } else { try LocalFiles.atomicRename(entry.path, to: target, overwrite: false) }
                case .delete:
                    guard !entries.isEmpty, Dialogs.confirm(remote ? "永久刪除遠端項目？" : "移至垃圾桶？", detail: "\(remote ? tab.state.profile.name + " · " + tab.state.profile.host : "本機")\n\(entries.count) 個項目\n" + entries.map(\.path).joined(separator: "\n"), destructive: true) else { return }
                    for entry in entries {
                        if remote { try await session!.removeTree(entry.path) } else { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
                    }
                case .properties,.permissions,.ownership:
                    showProperties(c)
                case .symlink:
                    guard let name = Dialogs.text("連結名稱"), let target = Dialogs.text("連結目標路徑") else { return }; try LocalFiles.safeName(name)
                    if remote { try await session!.symlink(target, at: RemotePath.join(directory, name)) } else { try FileManager.default.createSymbolicLink(atPath: RemotePath.join(directory, name), withDestinationPath: target) }
                case .copyTo,.moveTo: promptSameSide(command, context: c)
                default: break
                }
                tab.refreshLocal(); await tab.refreshRemote()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func moveBetween(_ entries: [Entry], tab: TabBrowser, remote: Bool) {
        guard let c = tab.connection, !entries.isEmpty else { return }
        for entry in entries {
            let target = RemotePath.join(remote ? tab.state.local.path : tab.state.remote.path, entry.name)
            var task = TransferTask(connection: c, direction: remote ? .download : .upload, source: entry.path, destination: target); task.originTabID = tab.id; task.options = options(for: tab); task.sourceRemovalPending = true
            let taskID = task.id
            queue.enqueue(task) { [weak self] error in
                guard error == nil, let self, let result = self.queue.records.first(where: { $0.id == taskID }) else { return }
                Task {
                    do {
                        try await MoveSafety.validate(result)
                        guard Dialogs.confirm("複製與校驗完成，移除來源？", detail: "\(remote ? c.host : "本機")\n\(entry.path)\n目的地：\(target)\n遠端來源將永久刪除；本機來源移至垃圾桶。", destructive: true) else { return }
                        try await MoveSafety.validate(result)
                        if remote { let session = try await SFTPSession.open(c); do { try await session.removeTree(entry.path); await session.close() } catch { await session.close(); throw error } }
                        else { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
                        self.queue.sourceRemoved(taskID); tab.refreshLocal(); await tab.refreshRemote()
                    } catch { self.error = "來源已保留：" + error.localizedDescription }
                }
            }
        }
    }
    func importSites(url: URL) { do { importCandidates = try SiteImporter.preview(url); showConnection = false; NSApp?.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil); showImport = true } catch { self.error = error.localizedDescription } }
    func applyImport() {
        guard siteStoreReadable else { return }
        var updated = sites
        for candidate in importCandidates where candidate.selected { var site = candidate.site; if updated.contains(where: { $0.id == site.id }) { site.id = UUID() }; updated.append(site) }
        do { try siteStore.save(updated); sites = updated; showImport = false } catch { self.error = error.localizedDescription }
    }
    func exportSites() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MinaSCP-sites.json"
        if panel.runModal() == .OK, let url = panel.url { do { try AtomicStore<SiteEnvelope>(url: url).save(SiteEnvelope(sites: sites)) } catch { self.error = error.localizedDescription } }
    }
    private func search(tab: TabBrowser) {
        guard let pattern = Dialogs.text("尋找檔案", detail: "依名稱包含文字遞迴搜尋，不跟隨符號連結。") else { return }
        searching = true; searchResults = []; showSearch = true
        let session = tab.session
        let remote = tab.state.activeSide == .remote, root = remote ? tab.state.remote.path : tab.state.local.path
        Task {
            do {
                @MainActor func scan(_ path: String) async throws {
                    let entries = remote ? try await session!.list(path) : try LocalFiles.list(path)
                    for entry in entries { if entry.name.localizedCaseInsensitiveContains(pattern) { searchResults.append(entry) }; if entry.directory { try await scan(entry.path) }; if searchResults.count > 10000 { throw TransferError.message("已達 10,000 筆結果，請縮小搜尋目錄") } }
                }
                try await scan(root)
            } catch { self.error = "搜尋未完整完成：" + error.localizedDescription }
            searching = false
        }
    }
    func openEditor(_ url: URL) {
        let editor = URL(fileURLWithPath: preferences.editorPath)
        guard FileManager.default.fileExists(atPath: editor.path) else { error = "找不到編輯器，請在偏好設定指定 App"; return }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in if let error { Task { @MainActor in self.error = error.localizedDescription } } }
    }
    func editRemote(_ entry: Entry, tab: TabBrowser) { /* connected by RemoteEditing extension */ startRemoteEdit(entry, tab: tab) }
    func previewFile(_ entry: Entry, tab: TabBrowser, remote: Bool) { startPreview(entry, tab: tab, remote: remote) }
}
struct PreviewDocument: Identifiable { let id = UUID(); let title: String; let text: String; var fileURL: URL? = nil }
