import SwiftUI
import AppKit

enum TabCommand: String, CaseIterable {
    case connect = "連線", reconnect = "重新連線", disconnect = "中斷連線", cancelConnection = "取消連線"
    case duplicate = "重複分頁", rename = "更名分頁…", restoreName = "恢復站台預設名稱", saveSite = "將目前工作階段另存成站台…", info = "伺服器／通訊協定資訊…"
    case close = "關閉分頁", closeOthers = "關閉其他分頁", closeRight = "關閉右側分頁"
}
struct TabDepartureAssessment {
    var blockers: [String] = []
    var background: [String] = []
}
extension BrowserModel {
    func selectTab(_ id: UUID) { guard tabs.contains(where: { $0.id == id }) else { return }; selectedTabID = id; saveWorkspace() }
    func canPerformTab(_ command: TabCommand, id: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return false }
        let remote = !tab.state.profile.host.isEmpty
        switch command {
        case .connect: return remote && !tab.connected && !tab.connecting
        case .reconnect: return remote && tab.connected && !tab.connecting
        case .disconnect: return tab.connected
        case .cancelConnection: return tab.connecting
        case .info: return tab.connected && tab.session != nil
        case .saveSite: return remote
        case .restoreName: return tab.state.alias != nil
        case .closeOthers: return tabs.count > 1
        case .closeRight: return tabs.last?.id != id
        default: return true
        }
    }
    func departureAssessment(_ targets: [TabBrowser]) -> TabDepartureAssessment {
        var result = TabDepartureAssessment()
        for tab in targets {
            if commands.usesTab(tab.id) { result.blockers.append("\(tab.state.title)：命令執行／封存驗證尚未完成，請到「指令工作」處理。") }
            if let editor = propertyEditor, editor.busy, editor.context.tab.id == tab.id { result.blockers.append("\(tab.state.title)：屬性操作尚未完成，請等候屬性視窗讀回結果。") }
        }
        let ids = Set(targets.map(\.id))
        let endpoints = Set(targets.filter { !$0.state.profile.host.isEmpty }.map { FileClipboard.signature($0.connection ?? $0.state.profile.connection) })
        func related(_ origin: UUID?, connection: Connection) -> Bool { origin.map { ids.contains($0) } ?? endpoints.contains(FileClipboard.signature(connection)) }
        let transfers = queue.records.filter { [.waiting,.running,.decision].contains($0.state) && $0.crossSiteJobID == nil && related($0.originTabID, connection: $0.connection) }
        if !transfers.isEmpty { result.background.append("背景傳輸：\(transfers.count) 項") }
        let copies = crossSite.jobs.filter { ["掃描中","下載中","上傳中","驗證中"].contains($0.state) && (endpoints.contains(FileClipboard.signature($0.sourceSite.connection)) || endpoints.contains(FileClipboard.signature($0.destinationSite.connection))) }
        if !copies.isEmpty { result.background.append("跨站台複製：\(copies.count) 項") }
        let editing = edits.records.filter { ["監看中","上傳中"].contains($0.state) && related($0.originTabID, connection: $0.connection) }
        if !editing.isEmpty { result.background.append("遠端編輯／監看：\(editing.count) 項") }
        if (sync.busy || sync.watching), let origin = sync.originTabID, ids.contains(origin) { result.background.append("同步／監看工作") }
        return result
    }
    private func approveDeparture(_ targets: [TabBrowser]) -> Bool {
        let assessment = departureAssessment(targets)
        if !assessment.blockers.isEmpty { reportTabBlock(assessment.blockers.joined(separator: "\n")); return false }
        guard assessment.background.isEmpty || confirmTabBackground("分頁：" + targets.map { $0.state.title }.joined(separator: "、") + "\n" + assessment.background.joined(separator: "\n")) else { return false }
        // Re-check after an AppKit modal dialog: its run loop can start another operation.
        let fresh = departureAssessment(targets)
        guard fresh.blockers.isEmpty else { reportTabBlock(fresh.blockers.joined(separator: "\n")); return false }
        return true
    }
    @discardableResult func performTab(_ command: TabCommand, id: UUID) -> Bool {
        guard canPerformTab(command, id: id), let tab = tabs.first(where: { $0.id == id }) else { return false }
        switch command {
        case .connect: Task { guard tabs.contains(where: { $0.id == tab.id }) else { return }; await tab.connect(authentication: authentication) }
        case .reconnect,.disconnect,.cancelConnection:
            guard approveDeparture([tab]), tabs.contains(where: { $0.id == id }) else { return false }
            tab.disconnect(); saveWorkspace()
            if command == .reconnect { Task { guard tabs.contains(where: { $0.id == tab.id }) else { return }; await tab.connect(authentication: authentication) } }
        case .duplicate: _ = duplicateTab(id)
        case .rename:
            if let value = Dialogs.text("更名分頁", detail: "只改此分頁；留空恢復站台預設名稱。", value: tab.state.alias ?? tab.state.profile.name) { renameTab(id, name: value) }
        case .restoreName: renameTab(id, name: "")
        case .saveSite: prepareSiteFromTab(id)
        case .info: presentConnectionInfo(tab)
        case .close,.closeOthers,.closeRight:
            let index = tabs.firstIndex(where: { $0.id == id })!
            let targets = command == .close ? [tab] : command == .closeOthers ? tabs.filter { $0.id != id } : Array(tabs.dropFirst(index + 1))
            guard approveDeparture(targets) else { return false }
            removeTabs(Set(targets.map(\.id)))
        }
        return true
    }
    private func removeTabs(_ ids: Set<UUID>) {
        let original = tabs, selected = current?.id
        let remaining = original.filter { !ids.contains($0.id) }
        var next = selected
        if let selected, ids.contains(selected), let position = original.firstIndex(where: { $0.id == selected }) {
            next = original.dropFirst(position + 1).first(where: { !ids.contains($0.id) })?.id ?? original.prefix(position).last(where: { !ids.contains($0.id) })?.id
        }
        for tab in original where ids.contains(tab.id) { tab.disconnect() }
        tabs = remaining.isEmpty ? [TabBrowser(WorkspaceTab(profile: SavedSite(name: "本機", host: "", user: NSUserName())))] : remaining
        selectedTabID = next.flatMap { id in tabs.contains(where: { $0.id == id }) ? id : nil } ?? tabs.first?.id
        observeTabs(); saveWorkspace()
    }
    @discardableResult func duplicateTab(_ id: UUID) -> TabBrowser? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let source = tabs[index]; var state = source.state
        state.id = UUID(); state.alias = source.state.title + " 副本"; state.local.selection.removeAll(); state.remote.selection.removeAll()
        let duplicate = TabBrowser(state); tabs.insert(duplicate, at: index + 1); selectedTabID = duplicate.id; observeTabs(); saveWorkspace()
        if source.connected { Task { guard tabs.contains(where: { $0.id == duplicate.id }) else { return }; await duplicate.connect(authentication: authentication) } }
        return duplicate
    }
    func renameTab(_ id: UUID, name: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.state.alias = value.isEmpty ? nil : String(value.prefix(120)); saveWorkspace()
    }
    func colorTab(_ id: UUID, color: String?) {
        guard color == nil || ["blue","red","orange","green","purple"].contains(color!), let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.state.colorOverride = color; saveWorkspace()
    }
    func prepareSiteFromTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.state.profile.host.isEmpty else { return }
        var site = tab.state.profile
        site.id = UUID(); site.name = tab.state.title + " 副本"; site.localPath = tab.state.local.path; site.remotePath = tab.state.remote.path; site.color = tab.state.color
        if let live = tab.connection { site.host = live.host; site.port = live.port; site.user = live.user; site.jumpHost = live.jumpHost; site.timeout = live.timeout; site.keepalive = live.keepalive; if site.authentication == .key { site.identity = live.identity } }
        draft = site; showConnection = true
    }
    @discardableResult func newLocalTab(after id: UUID? = nil) -> TabBrowser {
        let tab = TabBrowser(WorkspaceTab(profile: SavedSite(name: "本機", host: "", user: NSUserName())))
        let index = id.flatMap { target in tabs.firstIndex(where: { $0.id == target }).map { $0 + 1 } } ?? tabs.count
        tabs.insert(tab, at: index); selectedTabID = tab.id; observeTabs(); saveWorkspace(); return tab
    }
    func moveTab(_ id: UUID, relativeTo target: UUID, after: Bool) {
        guard id != target, let source = tabs.first(where: { $0.id == id }), tabs.contains(where: { $0.id == target }) else { return }
        var reordered = tabs.filter { $0.id != id }
        let index = reordered.firstIndex(where: { $0.id == target })!
        reordered.insert(source, at: index + (after ? 1 : 0)); tabs = reordered; saveWorkspace()
    }
}

struct TabActionsMenu: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: TabBrowser
    var body: some View {
        if !tab.state.profile.host.isEmpty {
            if tab.connecting { action(.cancelConnection) }
            else { action(tab.connected ? .reconnect : .connect); if tab.connected { action(.disconnect) } }
            Divider()
        }
        action(.duplicate); action(.rename); action(.restoreName)
        Menu("色彩") {
            Button("恢復站台預設色彩") { model.colorTab(tab.id, color: nil) }.disabled(tab.state.colorOverride == nil)
            ForEach([("blue","藍色"),("red","紅色"),("orange","橙色"),("green","綠色"),("purple","紫色")], id: \.0) { color, title in
                Button { model.colorTab(tab.id, color: color) } label: { Label(title + (tab.state.color == color ? " ✓" : ""), systemImage: "circle.fill").foregroundStyle(siteColor(color)) }
            }
        }
        Divider(); action(.saveSite); action(.info); Divider()
        Menu("新分頁") { Button("站台管理…") { model.newSite() }; Button("本機分頁") { model.newLocalTab(after: tab.id) } }
        Menu("站台") { SavedSitesMenu(model: model) }
        Menu("已開啟分頁") { OpenTabsMenu(model: model) }
        Divider(); action(.close); action(.closeOthers); action(.closeRight)
    }
    func action(_ command: TabCommand) -> some View { Button(command.rawValue) { model.performTab(command, id: tab.id) }.disabled(!model.canPerformTab(command, id: tab.id)) }
}
struct SavedSitesMenu: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        if model.sites.isEmpty { Text("尚無保存站台") }
        ForEach(Array(Set(model.sites.map(\.group))).sorted(), id: \.self) { group in
            Menu(group.isEmpty ? "未分組" : group) { ForEach(model.sites.filter { $0.group == group }) { site in Button(site.name) { model.openSite(site) } } }
        }
    }
}
struct OpenTabsMenu: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        ForEach(model.tabs) { tab in
            Button { model.selectTab(tab.id) } label: { Text((model.current?.id == tab.id ? "✓ " : "") + tab.state.title + " · " + tab.statusLabel) }
        }
    }
}
struct WorkspaceTabChip: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: TabBrowser
    @GestureState private var dragging = false
    var body: some View {
        decoratedLabel
            .contextMenu { TabActionsMenu(model: model, tab: tab) }
            .opacity(dragging ? 0.65 : 1)
            .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .updating($dragging) { _, active, _ in active = true }
                .onEnded { value in
                    let point = value.location
                    let frames = model.tabs.compactMap { item in model.tabFrames[item.id].map { (item.id, $0) } }
                    guard let (_, row) = frames.first, point.y >= row.minY - 16, point.y <= row.maxY + 16,
                          let destination = frames.min(by: { abs($0.1.midX - point.x) < abs($1.1.midX - point.x) }) else { return }
                    model.moveTab(tab.id, relativeTo: destination.0, after: point.x >= destination.1.midX)
                })
            .onDisappear { model.tabFrames.removeValue(forKey: tab.id) }
    }
    private var selected: Bool { model.current?.id == tab.id }
    private var statusColor: Color { tab.connected ? Color.green : tab.connecting ? Color.orange : Color.gray }
    private var tooltip: String {
        let profile = tab.state.profile
        return tab.state.title + (profile.host.isEmpty ? "" : " · \(profile.user)@\(profile.host):\(profile.port)")
    }
    private var label: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(tab.state.title).lineLimit(1)
            Button { model.performTab(.close, id: tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).accessibilityLabel("關閉分頁：" + tab.state.title)
        }
    }
    private var decoratedLabel: some View {
        label.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottom) { Rectangle().fill(siteColor(tab.state.color)).frame(height: selected ? 3 : 1) }
            .background(GeometryReader { proxy in Color.clear.onAppear { model.tabFrames[tab.id] = proxy.frame(in: .global) }.onChange(of: proxy.frame(in: .global)) { _, value in model.tabFrames[tab.id] = value } })
            .contentShape(Rectangle()).onTapGesture { model.selectTab(tab.id) }.help(tooltip)
    }
}
