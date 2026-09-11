import SwiftUI
import AppKit
import PDFKit

struct PresentationView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        Group {
            if let prompt = model.authentication.prompts.first { AuthenticationView(center: model.authentication, prompt: prompt).id(prompt.id) }
            else if let conflict = model.queue.conflicts.first { ConflictView(queue: model.queue, conflict: conflict).id(conflict.id) }
            else if let request = model.commands.preview { CommandPreviewView(manager: model.commands, request: request) }
            else if let context = model.copyContext { CrossCopyView(model: model, context: context) }
            else if model.commands.showManager { CommandTemplatesView(manager: model.commands) }
            else if model.commands.showJobs { CommandJobsView(manager: model.commands) }
            else if model.crossSite.showJobs { CrossJobsView(manager: model.crossSite) }
            else if let editor = model.propertyEditor { FilePropertiesView(editor: editor) { model.propertyEditor = nil } }
            else if model.showImport { ImportSitesView(model: model) }
            else if let preview = model.preview { VStack(alignment: .leading, spacing: 12) {
                HStack { Text(preview.title).font(.headline); Spacer(); Button("關閉") { model.preview = nil } }
                if let url = preview.fileURL {
                    if url.pathExtension.lowercased() == "pdf" { DocumentPDFView(url: url) }
                    else if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { Text("無法解碼此圖片；請下載後使用對應 App。") }
                } else { ScrollView([.horizontal,.vertical]) { Text(preview.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            }.padding(20).frame(width: 850,height: 600) }
            else if model.showPreferences { PreferencesView(model: model) }
            else if model.showSync { SyncView(model: model, sync: model.sync) }
            else if model.showEdits { EditsView(model: model, edits: model.edits) }
            else if model.showSearch { VStack(alignment: .leading) { HStack { Text("搜尋結果").font(.headline); if model.searching { ProgressView().controlSize(.small) }; Spacer(); Button("關閉") { model.showSearch = false } }; List(model.searchResults) { entry in Button(entry.path) { if let tab = model.current { Task { await tab.navigate(RemotePath.parent(entry.path), side: tab.state.activeSide); model.showSearch = false } } } }; if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) } }.padding(20).frame(width: 750,height: 500) }
            else { SiteManagerView(model: model) }
        }.minaWindowAppearance(model: model)
    }
}
struct AuthenticationView: View {
    @ObservedObject var center: AuthenticationCenter
    let prompt: AuthPrompt
    @State private var secret = ""
    @State private var remember = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(prompt.confirmation ? "確認主機身分" : "SSH 驗證", systemImage: "lock.shield").font(.title2)
            Text("\(prompt.connection.user)@\(prompt.connection.host):\(prompt.connection.port)").font(.headline)
            Text(prompt.question).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !prompt.confirmation { SecureField("密碼／密語／驗證碼", text: $secret).textFieldStyle(.roundedBorder); if prompt.canRemember { Toggle("記住於此 Mac 的 Keychain", isOn: $remember) } }
            HStack { Spacer(); Button("取消") { center.answer(prompt.id, secret: nil, remember: false) }; Button(prompt.confirmation ? "信任並連線" : "繼續") { center.answer(prompt.id, secret: prompt.confirmation ? "yes" : secret, remember: remember); secret = "" }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 550)
    }
}
struct ConflictView: View {
    @ObservedObject var queue: TransferQueue
    let conflict: TransferConflict
    @State private var applyAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("目的地已有同名項目", systemImage: "doc.on.doc").font(.title2)
            Text("來源：\(conflict.source)\n\(conflict.sourceAttributes.size ?? 0) bytes\n\n目的地：\(conflict.destination)\n\(conflict.destinationAttributes.size ?? 0) bytes").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Toggle("套用到同一批傳輸", isOn: $applyAll)
            HStack { Button("取消傳輸") { queue.reject(conflict.id) }; Spacer(); ForEach(conflict.safeOnly ? [CollisionPolicy.skip,.rename] : [CollisionPolicy.skip,.rename,.newer,.overwrite], id: \.self) { policy in Button(policy.rawValue) { queue.resolve(conflict.id, policy: policy, applyToBatch: applyAll) } } }
        }.padding(24).frame(width: 650)
    }
}
struct SiteNode: Identifiable {
    let id: String
    var title: String
    var site: SavedSite?
    var children: [SiteNode]?
    static func tree(_ sites: [SavedSite]) -> [SiteNode] {
        func nodes(_ prefix: String, depth: Int) -> [SiteNode] {
            let direct = sites.filter { $0.group == prefix }
            let folders = Set(sites.compactMap { site -> String? in
                let parts = site.group.split(separator: "/").map(String.init)
                guard parts.count > depth, parts.prefix(depth).joined(separator: "/") == prefix else { return nil }
                return parts[depth]
            }).sorted()
            return folders.map { name in let full = prefix.isEmpty ? name : prefix + "/" + name; return SiteNode(id: "folder:" + full, title: name, children: nodes(full, depth: depth + 1)) } + direct.map { SiteNode(id: $0.id.uuidString, title: $0.name, site: $0) }
        }
        return nodes("", depth: 0)
    }
}
struct SiteManagerView: View {
    @ObservedObject var model: BrowserModel
    @State private var advanced = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label("站台管理", systemImage: "server.rack").font(.title2.weight(.semibold)); Spacer(); Button("新增") { model.newSite() }; Button("複製") { model.duplicateSite(model.draft) }; Button("關閉") { model.showConnection = false } }.padding(20)
            Divider()
            HSplitView {
                VStack {
                    TextField("搜尋名稱或主機", text: $model.siteSearch).textFieldStyle(.roundedBorder).padding(10)
                    List {
                        OutlineGroup(SiteNode.tree(model.sites.filter { model.siteSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.siteSearch) || $0.host.localizedCaseInsensitiveContains(model.siteSearch) }), children: \.children) { node in
                            if let site = node.site {
                                Label(site.name, systemImage: "server.rack").foregroundStyle(siteColor(site.color)).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).background(model.draft.id == site.id ? Color.blue.opacity(0.08) : .clear)
                                    .onTapGesture(count: 2) { model.openSite(site) }.onTapGesture { model.selectSite(site) }
                                    .contextMenu { Button("連線") { model.openSite(site) }; Button("複製") { model.duplicateSite(site) }; Button("上移") { reorder(site, delta: -1) }; Button("下移") { reorder(site, delta: 1) }; Button("移除站台") { model.deleteSite(site) } }
                            } else { Label(node.title, systemImage: "folder") }
                        }
                    }
                    HStack {
                        Menu("匯入") { Button("選擇 JSON…") { let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { model.importSites(url: url) } }; Button("舊版 MinaSCP 站台…") { model.importSites(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MinaSCP/sites.json")) } }
                        Button("匯出") { model.exportSites() }
                    }.padding(10)
                }.frame(minWidth: 220, idealWidth: 250)
                ScrollView {
                    Form {
                        TextField("站台名稱", text: $model.draft.name)
                        TextField("分組路徑", text: $model.draft.group).help("例如：公司／正式環境")
                        Picker("站台色彩", selection: $model.draft.color) { Text("藍色").tag("blue"); Text("紅色（正式機）").tag("red"); Text("橙色").tag("orange"); Text("綠色").tag("green"); Text("紫色").tag("purple") }
                        LabeledContent("協定", value: model.draft.protocolName.uppercased())
                        TextField("主機／SSH 別名", text: $model.draft.host)
                        TextField("連接埠", text: $model.draft.port)
                        TextField("使用者", text: $model.draft.user)
                        Picker("驗證方式", selection: $model.draft.authentication) { ForEach(AuthenticationMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if model.draft.authentication == .key { HStack { TextField("OpenSSH 私鑰", text: $model.draft.identity); Button("選擇…") { let panel = NSOpenPanel(); panel.showsHiddenFiles = true; if panel.runModal() == .OK { model.draft.identity = panel.url?.path ?? "" } } } }
                        TextField("本機起始目錄", text: $model.draft.localPath)
                        TextField("遠端起始目錄", text: $model.draft.remotePath)
                        DisclosureGroup("進階設定", isExpanded: $advanced) {
                            TextField("跳板機（user@host:port）", text: $model.draft.jumpHost)
                            Stepper("逾時：\(model.draft.timeout) 秒", value: $model.draft.timeout, in: 5...300, step: 5)
                            Stepper("Keepalive：\(model.draft.keepalive) 秒", value: $model.draft.keepalive, in: 0...120, step: 5)
                            Toggle("覆寫全域傳輸預設", isOn: $model.draft.overrideTransferSettings)
                            if model.draft.overrideTransferSettings { Picker("同名處理", selection: $model.draft.transferOptions.policy) { ForEach(CollisionPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }; Toggle("保留修改時間", isOn: $model.draft.transferOptions.preserveTime); Toggle("保留權限", isOn: $model.draft.transferOptions.preservePermissions); TextField("限速 bytes/s（0 不限）", value: $model.draft.transferOptions.speedLimit, format: .number) }
                            Button("清除此站台已存密碼／密語") { CredentialStore.remove(CredentialStore.account(model.draft.connection, question: "password")); CredentialStore.remove(CredentialStore.account(model.draft.connection, question: "passphrase")) }
                            Text("密碼在登入時詢問；只有勾選才保存到 Keychain。SSH config 與主機金鑰檢查仍生效。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.draft.validationIssues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }.formStyle(.grouped).padding(12)
                }.frame(minWidth: 500)
            }
            Divider()
            HStack { Text("雙擊站台開啟新分頁 · 分组使用 / 建立階層").font(.caption).foregroundStyle(.secondary); Spacer(); Button("儲存站台") { _ = model.saveSite() }; Button("儲存並登入") { model.connect() }.buttonStyle(.borderedProminent).disabled(!model.draft.validationIssues.isEmpty || model.draft.host.isEmpty) }.padding(16)
        }.frame(width: 900,height: 680)
    }
    func reorder(_ site: SavedSite, delta: Int) {
        guard let index = model.sites.firstIndex(where: { $0.id == site.id }), model.sites.indices.contains(index + delta) else { return }
        var sites = model.sites; sites.swapAt(index, index + delta)
        model.reorderSites(sites)
    }
}
struct ImportSitesView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("預覽站台匯入").font(.title2); Text("原始檔案不會修改；只匯入勾選項目，不自動連線或信任指紋。").font(.caption).foregroundStyle(.secondary)
            List($model.importCandidates) { $candidate in HStack(alignment: .top) { Toggle("", isOn: $candidate.selected).labelsHidden(); VStack(alignment: .leading, spacing: 4) { Text(candidate.site.name).font(.headline); Text("\(candidate.site.user)@\(candidate.site.host):\(candidate.site.port)").font(.caption); ForEach(candidate.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } } } }
            HStack { Button("全選") { for i in model.importCandidates.indices { model.importCandidates[i].selected = true } }; Spacer(); Button("取消") { model.showImport = false }; Button("匯入所選") { model.applyImport() }.buttonStyle(.borderedProminent).disabled(!model.importCandidates.contains { $0.selected }) }
        }.padding(20).frame(width: 760,height: 550)
    }
}
struct PreferencesView: View {
    @ObservedObject var model: BrowserModel
    @State private var search = ""
    @State private var section = "外觀"
    let sections = ["外觀","介面與面板","傳輸與背景","編輯器","網路與安全","通知與記錄"]
    var body: some View {
        VStack {
            HStack { Text("偏好設定").font(.title2); Button("自訂指令範本…") { model.commands.showManager = true }; Spacer(); Button("儲存並關閉") { model.savePreferences(); model.showPreferences = false } }.padding(16)
            HSplitView {
                VStack { TextField("搜尋設定", text: $search).textFieldStyle(.roundedBorder).padding(10); List(sections.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || keywords($0).localizedCaseInsensitiveContains(search) }, id: \.self, selection: $section) { Text($0) } }.frame(width: 180)
                Form {
                    if section == "外觀" {
                        AppearancePreferencesView(model: model)
                    } else if section == "介面與面板" {
                        Toggle("WinSCP／Commander 功能鍵", isOn: $model.preferences.commanderKeys)
                        Toggle("顯示隱藏檔案", isOn: $model.preferences.showHidden)
                        Toggle("重啟恢復工作區分頁（不自動連線）", isOn: $model.preferences.restoreWorkspace)
                        Toggle("展開傳輸佇列", isOn: $model.preferences.queueExpanded)
                        Text("欄寬與欄位順序由表格自動保存；外觀與透明度可在「外觀」調整。").font(.caption).foregroundStyle(.secondary)
                    } else if section == "傳輸與背景" {
                        Stepper("背景並行：\(model.preferences.concurrentTransfers)", value: $model.preferences.concurrentTransfers, in: 1...8)
                        TextField("限速 bytes/s（0 不限）", value: $model.preferences.speedLimit, format: .number)
                        Picker("同名預設", selection: $model.preferences.defaultCollision) { ForEach(CollisionPolicy.allCases,id: \.self) { Text($0.rawValue).tag($0) } }
                        Toggle("上傳前再次確認", isOn: $model.preferences.confirmTransfers)
                        Toggle("保留修改時間", isOn: $model.preferences.preserveTime)
                        Toggle("保留檔案權限", isOn: $model.preferences.preservePermissions)
                        TextField("同步排除規則（逗號分隔）", text: $model.preferences.exclusions)
                        Text("刪除一定確認；取消停止實際傳輸。續傳會重新校驗來源與部分檔案。").font(.caption).foregroundStyle(.secondary)
                    } else if section == "編輯器" {
                        TextField("外部編輯器 App", text: $model.preferences.editorPath)
                        Button("選擇編輯器…") { let p = NSOpenPanel(); p.allowedContentTypes = [.application]; if p.runModal() == .OK { model.preferences.editorPath = p.url?.path ?? model.preferences.editorPath } }
                        Text("遠端文字檔儲存後自動回傳；兩端同時變更時停止並提示衝突。工作副本在重啟後保留，需手動恢復監看。").font(.caption)
                    } else if section == "網路與安全" {
                        Text("每站台可設定跳板機、逾時與 Keepalive；繼承系統 OpenSSH 設定。已知主機指紋變更時禁止連線。").font(.callout)
                        Button("檢視 App 主機指紋") { let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/minascp_known_hosts"); model.preview = PreviewDocument(title: "App 信任的主機金鑰", text: (try? String(contentsOf: path)) ?? "尚無 App 新增的主機") }
                        Button("在 Finder 顯示設定位置") { NSWorkspace.shared.open(AppStoragePaths.root) }
                        Text("秘密僅保存於使用者選擇的 Keychain；JSON 只有金鑰路徑。舊站台與原始設定保留不動。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("傳輸完成後播放提示音", isOn: $model.preferences.notifyCompletion)
                        Button("預覽診斷摘要") { model.preview = PreviewDocument(title: "診斷摘要（無密碼與私鑰內容）", text: diagnostics) }
                        Button("匯出診斷摘要…") { let p = NSSavePanel(); p.nameFieldStringValue = "MinaSCP-diagnostics.txt"; if p.runModal() == .OK, let url = p.url { do { try diagnostics.write(to: url, atomically: true, encoding: .utf8) } catch { model.error = error.localizedDescription } } }
                        Text("診斷只列 App 版本、傳輸狀態與數量，不匯出驗證提示、主機位址、私鑰或完整路徑。").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped).frame(minWidth: 480)
            }
        }.frame(width: 800,height: 600).onDisappear { model.flushAppearancePreferences() }
    }
    func keywords(_ section: String) -> String { switch section { case "外觀": return "明亮 深色 系統 玻璃 透明度 主題"; case "介面與面板": return "快捷鍵 排序 隱藏 重啟 分頁"; case "傳輸與背景": return "速度 並行 同名 覆蓋 取消 排除"; case "編輯器": return "VS Code 自動儲存"; case "網路與安全": return "主機 指紋 密碼 Keychain 跳板"; default: return "通知 音效 日誌 記錄 匯出" } }
    var diagnostics: String { "MinaSCP 0.2\n站台數：\(model.sites.count)\n分頁數：\(model.tabs.count)\n" + TransferState.allStates.map { state in "\(state.rawValue)：\(model.queue.records.filter { $0.state == state }.count)" }.joined(separator: "\n") }
}
extension TransferState { static let allStates: [TransferState] = [.waiting,.running,.paused,.decision,.complete,.failed,.cancelled] }

struct SyncView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var sync: SyncManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("目錄同步").font(.headline); Spacer(); Button("關閉") { model.showSync = false } }
            Picker("方向", selection: $sync.direction) { ForEach(SyncDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.disabled(sync.busy || sync.watching)
            TextField("排除規則，以逗號分隔", text: $sync.exclusions).disabled(sync.busy || sync.watching)
            Toggle("列出目的端多餘項目供刪除（預設不勾選）", isOn: $sync.deleteExtra).disabled(sync.busy || sync.watching || sync.direction == .both)
            Text(sync.message).font(.caption).textSelection(.enabled)
            List($sync.actions) { $action in
                HStack {
                    Toggle("", isOn: $action.selected).labelsHidden().disabled(action.kind == .conflict || sync.busy)
                    Text(action.path).lineLimit(1).help(action.path)
                    Spacer()
                    if action.kind == .conflict {
                        Text("衝突").foregroundStyle(.orange)
                        if action.local?.kind == action.remote?.kind {
                            Button("以上傳解決") { action.kind = .upload; action.selected = true }
                            Button("以下載解決") { action.kind = .download; action.selected = true }
                        }
                    } else { Text(action.kind.rawValue).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("掃描差異") { sync.scan() }.disabled(sync.busy || sync.watching)
                Button("執行所選項目") { sync.execute() }.disabled(sync.busy || !sync.actions.contains { $0.selected && $0.kind != .conflict })
                Spacer()
                if sync.busy || sync.watching { Button("停止") { sync.cancel() } }
                else { Button("啟動本機變更監看") { sync.startWatching() } }
            }
            Text("監看只上傳新增與修改；不自動刪除。App 重啟後需手動啟動。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 860, height: 580)
    }
}
struct EditsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var edits: RemoteEditManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("遠端編輯工作副本").font(.headline); Spacer(); Button("關閉") { model.showEdits = false } }
            if let error = edits.error { Text(error).foregroundStyle(.red) }
            List(edits.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.connection.host + ":" + record.remotePath).font(.headline).textSelection(.enabled)
                    Text(record.state + " · " + record.message).font(.caption)
                    HStack {
                        Button("開啟工作副本") { edits.openEditor?(URL(fileURLWithPath: record.localPath)) }
                        Button(record.state == "監看中" ? "暫停監看" : "恢復監看") { edits.setWatching(record.id, active: record.state != "監看中") }.disabled(record.state == "上傳中" || record.state == "衝突")
                        Button("比較") { Task { do { let remote = try await edits.remoteText(record); let local = try TextFiles.read(URL(fileURLWithPath: record.localPath)); model.preview = PreviewDocument(title: "比較：" + record.remotePath, text: "===== 本機 =====\n" + local + "\n===== 遠端 =====\n" + remote) } catch { edits.error = error.localizedDescription } } }
                        Button("重新下載") { if Dialogs.confirm("重新下載遠端內容？", detail: "本機修改會另存 backup，監看暫停。") { Task { await edits.reload(record.id) } } }
                        Button("另存遠端") { if let path = Dialogs.text("另存遠端", detail: "輸入尚不存在的完整遠端路徑", value: record.remotePath + ".copy") { Task { await edits.upload(record.id, force: false, saveAs: path) } } }
                        Button("覆蓋遠端") { if Dialogs.confirm("覆蓋目前遠端內容？", detail: record.connection.host + ":" + record.remotePath, destructive: true) { Task { await edits.upload(record.id, force: true) } } }
                    }.disabled(record.state == "上傳中")
                }.padding(.vertical, 5)
            }
            Text("UTF-8 文字儲存穩定後自動回存；遠端內容變更會停止上傳並提示衝突。").font(.caption)
        }.padding(20).frame(width: 1050, height: 520)
    }
}

struct DocumentPDFView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view }
    func updateNSView(_ view: PDFView, context: Context) {}
}
