import SwiftUI
import AppKit

final class MinaAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.propertyEditor?.busy == true { Dialogs.info("屬性操作仍在進行", detail: "請等逐項讀回完成後再結束。"); return .terminateCancel }
        if model.commands.activeCount > 0 || model.crossSite.activeCount > 0 { Dialogs.info("進階工作仍在進行", detail: "請先從工作清單停止命令或暫停跨站台複製，再結束程式。"); return .terminateCancel }
        model.flushAppearancePreferences(); model.saveWorkspace(); model.savePreferences()
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
        Window("MinaSCP", id: "main") { ContentView(model: model).minaWindowAppearance(model: model).frame(minWidth: 1000, minHeight: 680).onAppear { delegate.model = model; model.activateAppAppearance() } }
            .defaultSize(width: 1320, height: 850)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("站台管理…") { model.showConnection = true }.keyboardShortcut("n", modifiers: .command)
                    Button("重新整理") { model.refreshLocal(); model.refreshRemote() }.keyboardShortcut("r", modifiers: .command)
                    Button("編輯目前路徑") { model.requestPaneFocus(.path) }.keyboardShortcut("l", modifiers: .command)
                    Button("篩選目前面板") { model.requestPaneFocus(.filter) }.keyboardShortcut("f", modifiers: .command)
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
func siteColor(_ name: String) -> Color { switch name { case "red": return .red; case "orange": return .orange; case "green": return .green; case "purple": return .purple; default: return .blue } }
struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View { HStack { Image(systemName: "exclamationmark.triangle"); Text(text).lineLimit(3).textSelection(.enabled); Spacer(); Button("詳情") { Dialogs.info("操作訊息", detail: text) }; Button(action: dismiss) { Image(systemName: "xmark") } }.font(.caption).foregroundStyle(.red).padding(10).background(.red.opacity(0.05)) }
}
