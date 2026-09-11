import SwiftUI
import AppKit

struct CrossCopyView: View {
    @ObservedObject var model: BrowserModel
    let context: CommandContext
    @State private var siteID: UUID?
    @State private var destination = ""
    @State private var prepared: CrossSiteJob?
    @State private var busy = false
    @State private var error: String?
    var same: Bool { siteID == nil || siteID == context.siteID }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("製作複本…").font(.title2)
            Text("來源：\(context.tab.state.profile.name) · \(context.entries.count) 個項目")
            Picker("目的站台", selection: $siteID) {
                Text("目前站台：" + context.tab.state.profile.name).tag(Optional<UUID>.none)
                ForEach(model.sites.filter { $0.id != context.siteID }) { Text($0.name + " · " + $0.host).tag(Optional($0.id)) }
            }.onChange(of: siteID) { _, value in
                prepared = nil
                destination = value.flatMap { id in model.sites.first { $0.id == id }?.remotePath } ?? initialPath
            }
            TextField(same && context.entries.count == 1 ? "完整目的路徑" : "既有目的資料夾", text: $destination).onChange(of: destination) { _, _ in prepared = nil }
            if !same { Text("透過本機暫存，下載校驗完成後才上傳；保留來源。同名僅略過或自動改名。").font(.caption)
                if let prepared { Text("暫存內容：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: prepared.bytes), countStyle: .file))；需要可用空間：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: (try? CrossManifest.requiredSpace(prepared.bytes)) ?? 0), countStyle: .file))") }
            }
            if busy { ProgressView("掃描來源並估算暫存空間…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("取消") { model.copyContext = nil }.disabled(busy)
                Button(same ? "複製" : prepared == nil ? "掃描與估算" : "開始跨站台複製") { submit() }.disabled(busy || destination.isEmpty)
            }
        }.padding(24).frame(width: 650).onAppear { destination = initialPath }.interactiveDismissDisabled(busy)
    }
    var initialPath: String { context.entries.count == 1 ? RemotePath.join(context.directory, context.entries[0].name + " 副本") : context.directory }
    func submit() {
        guard context.valid else { error = "來源連線已改變"; return }
        if same { model.enqueuePaths(context.entries.map(\.path), sourceRemote: true, context: context, destination: destination, exact: context.entries.count == 1); model.copyContext = nil; return }
        if let prepared { model.copyContext = nil; model.crossSite.start(prepared); return }
        guard let target = model.sites.first(where: { $0.id == siteID }) else { error = "請選擇目的站台"; return }
        busy = true; error = nil
        Task { do { prepared = try await model.crossSite.prepare(source: context.tab.state.profile, destination: target, paths: context.entries.map(\.path), directory: destination) } catch { self.error = error.localizedDescription }; busy = false }
    }
}
struct CommandPreviewView: View {
    @ObservedObject var manager: CommandManager
    let request: CommandPreview
    @State private var timeout = 600
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title2)
            Text("站台：\(request.context.tab.state.profile.name) · \(request.context.tab.state.profile.host)")
            Text("工作目錄：" + request.context.directory).textSelection(.enabled)
            Text("選取：" + (request.context.entries.isEmpty ? "目前目錄" : request.context.entries.map(\.name).joined(separator: "、")))
            ScrollView { Text(request.scripts.joined(separator: "\n\n# 下一項\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 160, maxHeight: 320)
            HStack { Text("逾時（秒）"); TextField("600", value: $timeout, format: .number).frame(width: 100) }
            Text("指令可能產生不可逆效果。停止只中止本機 SSH，遠端狀態可能無法確認；不會自動重試。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { manager.preview = nil }; Button("執行") { manager.preview?.timeout = timeout; manager.executePreview() }.disabled(!(1...86400).contains(timeout)) }
        }.padding(24).frame(width: 720).onAppear { timeout = request.timeout }
    }
}
struct CommandTemplatesView: View {
    @ObservedObject var manager: CommandManager
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("自訂指令範本").font(.title2); Spacer(); Button("新增") { let value = CommandTemplate(); manager.templates.append(value); selected = value.id }; Button("儲存並關閉") { manager.saveTemplates(); manager.showManager = false } }
            HSplitView {
                List(manager.templates, selection: $selected) { Text($0.name).tag($0.id) }.frame(width: 180)
                if let index = manager.templates.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("名稱", text: $manager.templates[index].name)
                        Picker("適用情境", selection: $manager.templates[index].scope) { ForEach(CommandScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("執行方式", selection: $manager.templates[index].execution) { ForEach(CommandExecution.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        TextEditor(text: $manager.templates[index].command).font(.system(.body, design: .monospaced))
                        Text("變數：{path}、{name}、{directory}、{paths}。變數須為獨立參數，前後留空白，不自行包引號。").font(.caption)
                        HStack { Text("逾時（秒）"); TextField("600", value: $manager.templates[index].timeout, format: .number) }
                        Button("刪除範本") { manager.templates.remove(at: index); selected = nil; manager.saveTemplates() }
                    }.padding(12)
                } else { Text("新增或選擇範本").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            if let error = manager.error { Text(error).foregroundStyle(.red) }
        }.padding(20).frame(width: 800, height: 480)
    }
}
struct CommandJobsView: View {
    @ObservedObject var manager: CommandManager
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("指令工作").font(.title2); Spacer(); Button("關閉") { manager.showJobs = false } }
            if let error = manager.error { Text(error).foregroundStyle(.red) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 14) { ForEach(manager.records) { record in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(record.title + " · " + record.site).bold(); Spacer(); Text(record.state); if record.state == "執行中" { Button("停止") { manager.stop(record.id) } } }
                    Text("結束碼：" + (record.exitCode.map(String.init) ?? "—") + " · " + record.directory).font(.caption)
                    if let staging = record.staging { Text("保留暫存：" + staging).font(.caption).textSelection(.enabled) }
                    DisclosureGroup("指令與輸出") { Text(record.script + "\n\nstdout:\n" + record.stdout + "\n\nstderr:\n" + record.stderr).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }; Divider()
            } } }
        }.padding(22).frame(width: 850, height: 500)
    }
}
struct CrossJobsView: View {
    @ObservedObject var manager: CrossSiteManager
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("跨站台工作").font(.title2); Spacer(); Button("關閉") { manager.showJobs = false } }
            if let error = manager.error { Text(error).foregroundStyle(.red) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 14) { ForEach(manager.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.sourceSite.name + " → " + job.destinationSite.name).bold()
                    Text(job.state + " · " + job.message).textSelection(.enabled)
                    Text("目的：" + job.destination + "\n暫存：" + job.staging).font(.caption).textSelection(.enabled)
                    HStack {
                        if ["掃描中","下載中","上傳中","驗證中"].contains(job.state) { Button("暫停") { manager.stop(job.id, pause: true) }; Button("取消") { manager.stop(job.id, pause: false) } }
                        else { if ["已暫停","已取消","失敗"].contains(job.state) { Button("恢復") { manager.resume(job.id) } }; if !["完成","已清理"].contains(job.state) { Button("清理本機暫存…") { if Dialogs.confirm("清理此工作暫存？", detail: "只刪除此工作的本機暫存；已上傳與來源檔案保留，工作無法再恢復。", destructive: true) { manager.cleanup(job.id) } } } }
                    }
                }; Divider()
            } } }
        }.padding(22).frame(width: 800, height: 480)
    }
}
