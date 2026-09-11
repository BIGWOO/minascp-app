import SwiftUI

struct CommandTemplateDocument: Codable { var version = 1; var templates: [CommandTemplate] = [] }
struct CommandExecutionRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var site: String
    var directory: String
    var script: String
    var state = "等待執行"
    var stdout = ""
    var stderr = ""
    var exitCode: Int32?
    var staging: String?
    var date = Date()
}
struct CommandHistoryDocument: Codable { var version = 1; var records: [CommandExecutionRecord] = [] }
struct CommandPreview: Identifiable {
    let id = UUID()
    let context: CommandContext
    let title: String
    let scripts: [String]
    var timeout: Int
    var archive: ArchivePlan?
}
@MainActor final class CommandManager: ObservableObject {
    @Published var templates: [CommandTemplate] = []
    @Published var records: [CommandExecutionRecord] = []
    @Published var preview: CommandPreview?
    @Published var showManager = false
    @Published var showJobs = false
    @Published var error: String?
    @Published private(set) var probing = Set<UUID>()
    private var capabilities: [UUID: (SFTPSession, CommandCapabilities)] = [:]
    private var active: [UUID: RemoteCommandRunner] = [:]
    @Published private(set) var executionTabs: [UUID: UUID] = [:]
    func usesTab(_ id: UUID) -> Bool { executionTabs.values.contains(id) }
    private var readable = true, historyReadable = true
    private let templateStore: AtomicStore<CommandTemplateDocument>
    private let historyStore: AtomicStore<CommandHistoryDocument>
    var authenticate: ((Connection) throws -> Connection)?
    var activeCount: Int { executionTabs.count }
    init(root: URL) {
        templateStore = AtomicStore(url: root.appendingPathComponent("command-templates-v1.json"))
        historyStore = AtomicStore(url: root.appendingPathComponent("command-history-v1.json"))
        do { if let value = try templateStore.load() { guard value.version == 1 else { throw TransferError.message("指令範本版本不支援") }; templates = value.templates } }
        catch { readable = false; self.error = error.localizedDescription }
        do { if let value = try historyStore.load() { guard value.version == 1 else { throw TransferError.message("指令紀錄版本不支援") }; records = value.records; for i in records.indices where ["執行中", "驗證中"].contains(records[i].state) { records[i].state = "遠端狀態未確認（重啟後不重試）" } } }
        catch { historyReadable = false; self.error = error.localizedDescription }
    }
    func saveTemplates() {
        guard readable else { return }
        do { try templateStore.save(CommandTemplateDocument(templates: templates)) } catch { self.error = error.localizedDescription }
    }
    func capability(_ c: CommandContext) -> CommandCapabilities {
        guard c.valid else { return CommandCapabilities(reason: "連線已改變，請重新檢查命令能力") }
        guard let session = c.session, let value = capabilities[c.tab.id], value.0 === session else { return CommandCapabilities(reason: probing.contains(c.tab.id) ? "正在檢查 SSH 命令能力…" : "請先檢查 SSH 命令能力") }
        return value.1
    }
    func probe(_ c: CommandContext) async {
        guard c.remote, c.valid, let session = c.session, let connection = c.tab.connection, !probing.contains(c.tab.id) else { return }
        probing.insert(c.tab.id); defer { probing.remove(c.tab.id) }
        do {
            let result = try await RemoteCommandRunner().run(connection: try authenticate?(connection) ?? connection, script: CommandCapabilities.probe, timeout: 15)
            guard c.valid else { return }; capabilities[c.tab.id] = (session, CommandCapabilities.parse(result))
        } catch { capabilities[c.tab.id] = (session, CommandCapabilities(reason: "命令能力檢查失敗：" + error.localizedDescription)) }
        objectWillChange.send()
    }
    func matches(_ template: CommandTemplate, context c: CommandContext) -> Bool {
        switch template.scope {
        case .directory: return c.background
        case .file: return c.entries.count == 1 && c.entries[0].kind == .file
        case .folder: return c.entries.count == 1 && c.entries[0].directory
        case .multiple: return c.entries.count > 1
        }
    }
    func prepare(_ template: CommandTemplate, context c: CommandContext) {
        do { guard c.valid, capability(c).shell, matches(template, context: c) else { throw TransferError.message("命令不適用目前情境") }; preview = CommandPreview(context: c, title: template.name, scripts: try template.expand(paths: c.entries.map(\.path), directory: c.directory), timeout: template.timeout) }
        catch { self.error = error.localizedDescription; showJobs = true }
    }
    func prepareTool(_ tool: ArchiveTool, context c: CommandContext) {
        guard c.valid, capability(c).shell, ArchiveTools.required(tool).isSubset(of: capability(c).tools) else { error = "站台缺少必要工具"; showJobs = true; return }
        var target: String?
        if tool != .touch {
            let basename = c.entries.count == 1 ? c.entries[0].name : "Archive"
            target = Dialogs.text(tool.rawValue, detail: "輸入新的完整目的路徑，不覆蓋或合併既有項目。", value: RemotePath.join(c.directory, basename + (tool == .zip ? ".zip" : tool == .tar ? ".tar.gz" : "-解壓")))
            if target == nil { return }
        }
        do { let plan = try ArchiveTools.make(tool, paths: c.entries.map(\.path), directory: c.directory, destination: target); preview = CommandPreview(context: c, title: tool.rawValue, scripts: [plan.script], timeout: 600, archive: plan) }
        catch { self.error = error.localizedDescription; showJobs = true }
    }
    func executePreview() {
        guard let request = preview, request.context.valid, (1...86400).contains(request.timeout), historyReadable else { error = "情境已改變或紀錄無法保存"; return }
        preview = nil; showJobs = true
        executionTabs[request.id] = request.context.tab.id
        Task {
            defer { executionTabs[request.id] = nil }
            for script in request.scripts {
                let runner = RemoteCommandRunner()
                let record = CommandExecutionRecord(title: request.title, site: request.context.tab.state.profile.name, directory: request.context.directory, script: script, state: "執行中", staging: request.archive?.staging)
                records.insert(record, at: 0); active[record.id] = runner
                do {
                    try saveHistory()
                    guard request.context.valid, let connection = request.context.tab.connection else { throw TransferError.message("來源連線已改變") }
                    if let target = request.archive?.destination, try await request.context.session!.exists(target) != nil { throw TransferError.message("目的地已存在；未執行命令") }
                    let result = try await runner.run(connection: try authenticate?(connection) ?? connection, script: script, timeout: request.timeout)
                    guard let i = records.firstIndex(where: { $0.id == record.id }) else { throw CancellationError() }
                    records[i].stdout = result.stdout + (result.truncated ? "\n（輸出過長，只保留尾段）" : ""); records[i].stderr = result.stderr; records[i].exitCode = result.exitCode
                    records[i].state = result.uncertain ? "遠端狀態未確認；不自動重試" : result.success ? "驗證中" : "失敗"
                    if result.success, let plan = request.archive, let staging = plan.staging, let destination = plan.destination {
                        guard request.context.valid else { throw TransferError.message("命令完成但連線已改變；暫存保留") }
                        let attr = try await request.context.session!.attributes(staging)
                        guard attr.kind == (plan.directory ? .directory : .file) else { throw TransferError.message("暫存結果種類不符") }
                        try await request.context.session!.rename(staging, to: destination)
                        guard try await request.context.session!.exists(destination) != nil else { throw TransferError.message("目的地讀回失敗") }
                        guard let finalIndex = records.firstIndex(where: { $0.id == record.id }) else { throw CancellationError() }
                        records[finalIndex].staging = nil; records[finalIndex].stdout += "\n目的地已讀回：" + destination
                    }
                    if result.success, let finalIndex = records.firstIndex(where: { $0.id == record.id }) { records[finalIndex].state = "完成" }
                    active[record.id] = nil; try saveHistory(); await request.context.tab.refreshRemote()
                    if !result.success { break }
                } catch {
                    if let i = records.firstIndex(where: { $0.id == record.id }) { records[i].state = "失敗；請檢查結果，不自動重試"; records[i].stderr += "\n" + error.localizedDescription }
                    active[record.id] = nil; try? saveHistory(); await request.context.tab.refreshRemote(); break
                }
            }
        }
    }
    func stop(_ id: UUID) { active[id]?.stop() }
    private func saveHistory() throws { guard historyReadable else { throw TransferError.message("命令紀錄無法讀取，禁止覆寫") }; try historyStore.save(CommandHistoryDocument(records: records)) }
}

extension CommandManager {
    func appendMenu(to menu: NSMenu, context c: CommandContext) {
        guard c.remote else { return }
        let item = NSMenuItem(title: c.background ? "目錄自訂指令" : "檔案自訂指令", action: nil, keyEquivalent: "")
        let child = NSMenu(); child.autoenablesItems = false; item.submenu = child; menu.addItem(.separator()); menu.addItem(item)
        let cap = capability(c)
        func refreshAfterProbe() {
            Task {
                await self.probe(c)
                let refreshed = NSMenu(); self.appendMenu(to: refreshed, context: c)
                if let replacement = refreshed.items.last?.submenu {
                    let rows = replacement.items; replacement.removeAllItems(); child.removeAllItems()
                    for row in rows { child.addItem(row) }; child.update()
                }
            }
        }
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) { let row = ClosureMenuItem(title: title, handler: action); row.isEnabled = enabled; child.addItem(row) }
        if !cap.shell { add(cap.reason, enabled: false) {} }
        add("重新檢查命令能力", enabled: c.valid && !probing.contains(c.tab.id)) { refreshAfterProbe() }
        if !c.background {
            for tool in ArchiveTool.allCases {
                let applicable = !c.entries.isEmpty && (tool != .extract || (c.entries.count == 1 && c.entries[0].kind == .file && (c.entries[0].name.lowercased().hasSuffix(".zip") || c.entries[0].name.lowercased().hasSuffix(".tar.gz"))))
                let missing = ArchiveTools.required(tool).subtracting(cap.tools)
                add(tool.rawValue + (cap.shell && !missing.isEmpty ? "（缺少 " + missing.sorted().joined(separator: ", ") + "）" : ""), enabled: cap.shell && missing.isEmpty && applicable) { self.prepareTool(tool, context: c) }
            }
        }
        for template in templates where matches(template, context: c) { add(template.name, enabled: cap.shell && c.valid) { self.prepare(template, context: c) } }
        child.addItem(.separator())
        if c.background { add("輸入指令…", enabled: cap.shell && c.valid) {
            if let text = Dialogs.text("輸入指令", detail: "以目前遠端目錄執行；下一步會顯示完整預覽。") { var template = CommandTemplate(); template.name = "臨時指令"; template.command = text; template.scope = .directory; self.prepare(template, context: c) }
        } }
        add("管理自訂指令…") { self.showManager = true }
        if c.valid, capabilities[c.tab.id]?.0 !== c.session, !probing.contains(c.tab.id) { refreshAfterProbe() }
    }
}
