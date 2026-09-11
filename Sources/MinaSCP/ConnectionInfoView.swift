import SwiftUI
import AppKit

@MainActor final class ConnectionInspector: ObservableObject {
    let tab: TabBrowser
    let generation: Int
    let session: SFTPSession
    let info: ConnectionInfo
    let context: CommandContext
    let commands: CommandManager
    @Published private(set) var command: CommandCapabilities
    @Published private(set) var checking = false
    init(tab: TabBrowser, session: SFTPSession, info: ConnectionInfo, commands: CommandManager) {
        self.tab = tab; self.session = session; self.info = info; self.commands = commands
        generation = tab.connectionGeneration; context = CommandContext.forSide(tab, side: .remote); command = commands.capability(context)
    }
    var current: Bool { tab.connected && tab.session === session && tab.connectionGeneration == generation }
    var status: String { current ? "已連線 · 本次連線資訊" : "已中斷／上次連線資訊" }
    func checkCommands() async {
        guard current, !checking else { return }
        checking = true; defer { checking = false }
        await commands.probe(context)
        guard current else { return }; command = commands.capability(context)
    }
    var copiedText: String {
        let rows = info.protocolRows.map { $0.0 + "：" + $0.1 }.joined(separator: "\n")
        let capabilities = info.capabilities(command: command).map { $0.name + "：" + $0.support + " — " + $0.basis }.joined(separator: "\n")
        return "伺服器／通訊協定資訊\n" + status + "\n擷取時間：" + info.capturedAt.formatted() + "\n\n通訊協定\n" + rows + (info.ssh.unavailableReason.map { "\n" + $0 } ?? "") + "\n\n能力（不代表目前帳號具有所有操作權限）\n" + capabilities + "\n\n伺服器宣告的 SFTP 擴充\n" + info.extensionText
    }
}
struct ConnectionInfoView: View {
    @ObservedObject var inspector: ConnectionInspector
    @ObservedObject var tab: TabBrowser
    let close: () -> Void
    @State private var page = 0
    @State private var copied = false
    init(inspector: ConnectionInspector, close: @escaping () -> Void) { self.inspector = inspector; tab = inspector.tab; self.close = close }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("伺服器／通訊協定資訊").font(.title2)
            HStack { Circle().fill(inspector.current ? .green : .gray).frame(width: 7, height: 7); Text(inspector.status); Spacer(); Text(inspector.info.capturedAt.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }.font(.caption)
            TabView(selection: $page) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            ForEach(Array(inspector.info.protocolRows.enumerated()), id: \.offset) { _, row in
                                GridRow { Text(row.0).foregroundStyle(.secondary).frame(width: 170, alignment: .leading); Text(row.1).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                        }
                        if let reason = inspector.info.ssh.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }.padding(20)
                }.tabItem { Text("通訊協定") }.tag(0)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("支援能力不代表目前帳號對所有路徑有操作權限。").font(.caption).foregroundStyle(.secondary); Spacer(); Button(inspector.checking ? "檢查中…" : "檢查命令能力") { Task { await inspector.checkCommands() } }.disabled(!inspector.current || inspector.checking) }
                    Table(inspector.info.capabilities(command: inspector.command)) {
                        TableColumn("項目", value: \.name).width(min: 140, ideal: 150, max: 180)
                        TableColumn("支援情況", value: \.support).width(min: 160, ideal: 180, max: 220)
                        TableColumn("依據") { row in Text(row.basis).font(.caption).help(row.basis) }
                    }.frame(minHeight: 235)
                    Text("伺服器宣告的 SFTP 擴充").font(.headline)
                    ScrollView([.horizontal,.vertical]) { Text(inspector.info.extensionText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 95)
                }.padding(14).tabItem { Text("能力") }.tag(1)
            }
            HStack { Button(copied ? "已複製資訊" : "複製資訊") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(inspector.copiedText, forType: .string); copied = true }; Spacer(); Button("關閉", action: close).keyboardShortcut(.cancelAction) }
        }.padding(22).frame(minWidth: 820, idealWidth: 880, minHeight: 580, idealHeight: 620)
    }
}
extension BrowserModel {
    func presentConnectionInfo(_ tab: TabBrowser) {
        guard tab.connected, let session = tab.session else { return }
        let generation = tab.connectionGeneration
        Task {
            let info = await session.connectionInfo()
            guard tab.connected, tab.session === session, tab.connectionGeneration == generation, tabs.contains(where: { $0.id == tab.id }) else { return }
            let inspector = ConnectionInspector(tab: tab, session: session, info: info, commands: commands)
            connectionInspector = inspector
            guard NSApp != nil else { return }
            connectionInfoWindow?.close()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "\(tab.state.title) — 伺服器資訊"; window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ConnectionInfoView(inspector: inspector) { [weak window] in window?.close() }.minaWindowAppearance(model: self))
            connectionInfoWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
        }
    }
}
