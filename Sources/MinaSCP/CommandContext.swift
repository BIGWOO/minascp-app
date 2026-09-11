import AppKit
import CryptoKit

struct FileClipboard: Codable {
    static let type = NSPasteboard.PasteboardType("com.mina.scp.files.v1")
    let siteID: UUID?
    let paths: [String]
    var endpoint: String? = nil
    static func signature(_ connection: Connection) -> String {
        SHA256.hash(data: Data([connection.host, connection.port, connection.user, connection.jumpHost].joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func compatible(site: UUID, connection: Connection, connected: Bool) -> Bool {
        siteID == nil || (siteID == site && connected && endpoint == Self.signature(connection))
    }
    static func read(_ board: NSPasteboard = .general) -> FileClipboard? {
        if let data = board.data(forType: type), let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : Self(siteID: nil, paths: urls.map(\.path))
    }
}
@MainActor struct CommandContext {
    let tab: TabBrowser
    let side: PanelSide
    let directory: String
    let entries: [Entry]
    let background: Bool
    let session: SFTPSession?
    let siteID: UUID
    var remote: Bool { side == .remote }
    init(tab: TabBrowser, background: Bool = false, side requestedSide: PanelSide? = nil) {
        self.tab = tab; side = requestedSide ?? tab.state.activeSide; self.background = background
        let panel = side == .remote ? tab.state.remote : tab.state.local
        directory = panel.path; session = tab.session; siteID = tab.state.profile.id
        entries = background ? [] : (side == .remote ? tab.remoteEntries : tab.localEntries).filter { panel.selection.contains($0.id) }
    }
    var valid: Bool { tab.state.profile.id == siteID && (!remote || (tab.connected && session === tab.session)) }
    func allows(_ command: FileCommand) -> Bool {
        if [.copyNames,.copyPaths,.clipboardCopy].contains(command) { return !entries.isEmpty }
        if command == .currentPath { return true }
        guard valid else { return false }
        switch command {
        case .open: return entries.count == 1
        case .edit,.preview: return entries.count == 1 && entries[0].kind == .file
        case .rename: return entries.count == 1
        case .copy,.move: return !entries.isEmpty && tab.connected
        case .copyTo,.moveTo,.delete,.properties,.permissions,.ownership: return !entries.isEmpty
        case .paste:
            guard let value = FileClipboard.read(), !value.paths.isEmpty else { return false }
            return value.compatible(site: siteID, connection: tab.connection ?? tab.state.profile.connection, connected: tab.connected)
        case .back: let p = remote ? tab.state.remote : tab.state.local; return p.historyIndex > 0
        case .forward: let p = remote ? tab.state.remote : tab.state.local; return p.historyIndex + 1 < p.history.count
        default: return true
        }
    }
}
@MainActor enum FileMenus {
    static func make(_ c: CommandContext, commanderKeys: Bool, action: @escaping (FileCommand) -> Void, navigate: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ command: FileCommand, to parent: NSMenu, title: String? = nil) {
            let item = ClosureMenuItem(title: title ?? command.rawValue) { action(command) }
            item.isEnabled = c.allows(command); item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
            let keys: [FileCommand: String] = [.clipboardCopy:"c",.paste:"v",.properties:"i",.refresh:"r"]
            if let key = keys[command] { item.keyEquivalent = key; item.keyEquivalentModifierMask = .command }
            if command == .rename { item.keyEquivalent = "\r"; item.keyEquivalentModifierMask = [] }
            if commanderKeys {
                let f: [FileCommand: Int] = [.preview:3,.edit:4,.copy:5,.move:6,.mkdir:7,.delete:8]
                if let number = f[command] { item.keyEquivalent = String(UnicodeScalar(0xF704 + number - 1)!); item.keyEquivalentModifierMask = [] }
            }
            parent.addItem(item)
        }
        func submenu(_ title: String, commands: [FileCommand]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), child = NSMenu(); child.autoenablesItems = false
            item.submenu = child; menu.addItem(item); commands.forEach { add($0, to: child) }; return child
        }
        if c.background {
            let nav = submenu("前往", commands: [.goTo,.up,.root,.home,.back,.forward])
            let bookmarks = (c.remote ? c.tab.state.remote : c.tab.state.local).bookmarks
            if !bookmarks.isEmpty { nav.addItem(.separator()); for path in bookmarks { let item = ClosureMenuItem(title: path) { navigate(path) }; item.isEnabled = c.valid; nav.addItem(item) } }
            [.refresh,.bookmark,.filter,.currentPath].forEach { add($0, to: menu) }
            menu.addItem(.separator()); _ = submenu("新增", commands: [.newFile,.mkdir,.symlink]); add(.paste, to: menu)
        } else {
            if c.entries.count > 1 { let label = NSMenuItem(title: "已選取 \(c.entries.count) 個項目", action: nil, keyEquivalent: ""); label.isEnabled = false; menu.addItem(label) }
            add(.open, to: menu)
            if !c.entries.allSatisfy(\.directory) { add(.edit, to: menu); add(.preview, to: menu) }
            menu.addItem(.separator())
            add(.copy, to: menu, title: c.remote ? "下載到…" : "上傳到…")
            add(.copyTo, to: menu, title: "製作複本…"); add(.moveTo, to: menu)
            add(.move, to: menu, title: c.remote ? "移動到本機…" : "移動到遠端…")
            menu.addItem(.separator()); add(.rename, to: menu); add(.delete, to: menu)
            menu.addItem(.separator()); add(.clipboardCopy, to: menu)
            _ = submenu("檔案名稱", commands: [.copyNames,.copyPaths])
            menu.addItem(.separator()); add(.properties, to: menu, title: "屬性…")
        }
        return menu
    }
}
@MainActor final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void
    init(title: String, handler: @escaping () -> Void) { self.handler = handler; super.init(title: title, action: #selector(invoke), keyEquivalent: ""); target = self }
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func invoke() { handler() }
}
