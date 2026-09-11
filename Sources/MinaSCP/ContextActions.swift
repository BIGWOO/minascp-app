import SwiftUI
import AppKit
import Darwin

extension BrowserModel {
    func handleContextCommand(_ command: FileCommand, context c: CommandContext) -> Bool {
        let tab = c.tab
        func textToClipboard(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        switch command {
        case .open: if let entry = c.entries.first { navigate(entry, remote: c.remote, tab: tab) }
        case .copyNames: textToClipboard(c.entries.map(\.name).joined(separator: "\n"))
        case .copyPaths: textToClipboard(c.entries.map(\.path).joined(separator: "\n"))
        case .currentPath: textToClipboard(c.directory)
        case .clipboardCopy:
            let board = NSPasteboard.general; board.clearContents()
            if !c.remote { board.writeObjects(c.entries.map { NSURL(fileURLWithPath: $0.path) }) }
            if let data = try? JSONEncoder().encode(FileClipboard(siteID: c.remote ? c.siteID : nil, paths: c.entries.map(\.path), endpoint: c.remote ? FileClipboard.signature(c.tab.connection ?? c.tab.state.profile.connection) : nil)) { board.setData(data, forType: FileClipboard.type) }
        case .paste:
            guard let value = FileClipboard.read() else { return true }
            enqueuePaths(value.paths, sourceRemote: value.siteID != nil, context: c, destination: c.directory)
        case .refresh: if c.remote { Task { await tab.refreshRemote() } } else { tab.refreshLocal() }
        case .goTo:
            if let path = Dialogs.text("前往路徑", value: c.directory), !path.isEmpty { Task { await tab.navigate(path, side: c.side) } }
        case .up,.root,.home:
            let path = command == .up ? RemotePath.parent(c.directory) : command == .root ? "/" : c.remote ? "." : FileManager.default.homeDirectoryForCurrentUser.path
            Task { await tab.navigate(path, side: c.side) }
        case .back,.forward: history(command == .back ? -1 : 1, remote: c.remote, tab: tab)
        case .bookmark:
            if c.remote { if !tab.state.remote.bookmarks.contains(c.directory) { tab.state.remote.bookmarks.append(c.directory) } }
            else if !tab.state.local.bookmarks.contains(c.directory) { tab.state.local.bookmarks.append(c.directory) }
            saveWorkspace()
        case .filter:
            if let value = Dialogs.text("篩選名稱（留空顯示全部）", value: c.remote ? tab.state.remote.filter : tab.state.local.filter) {
                if c.remote { tab.state.remote.filter = value } else { tab.state.local.filter = value }; saveWorkspace()
            }
        case .newFile:
            guard let name = Dialogs.text("新增檔案", detail: c.directory) else { return true }
            Task {
                do {
                    try LocalFiles.safeName(name); guard c.valid else { throw TransferError.message("連線已改變") }
                    let path = RemotePath.join(c.directory, name)
                    if c.remote { let handle = try await c.session!.openFile(path, flags: 2 | 8 | 32); try await c.session!.closeHandle(handle); await tab.refreshRemote() }
                    else { let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600); guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; Darwin.close(fd); tab.refreshLocal() }
                    let attr = c.remote ? try await c.session!.attributes(path) : try LocalFiles.attributes(path)
                    let entry = Entry(name: name, path: path, attributes: attr)
                    if c.remote { editRemote(entry, tab: tab) } else { openEditor(URL(fileURLWithPath: path)) }
                } catch { self.error = error.localizedDescription }
            }
        default: return false
        }
        return true
    }
    func promptTransfer(_ c: CommandContext) {
        let defaultPath = c.remote ? c.tab.state.local.path : c.tab.state.remote.path
        guard let target = Dialogs.text(c.remote ? "下載到…" : "上傳到…", detail: "\(c.entries.count) 個項目；輸入既有目的資料夾", value: defaultPath) else { return }
        let destinationContext = CommandContext.forSide(c.tab, side: c.remote ? .local : .remote)
        enqueuePaths(c.entries.map(\.path), sourceRemote: c.remote, context: destinationContext, destination: target)
    }
    func promptSameSide(_ command: FileCommand, context c: CommandContext) {
        if command == .copyTo && c.remote { copyContext = c; return }
        let single = c.entries.count == 1
        let initial = single ? RemotePath.join(c.directory, c.entries[0].name + (command == .copyTo ? " 副本" : "")) : c.directory
        guard let target = Dialogs.text(command == .copyTo ? "製作複本…" : "移動到…", detail: "\(c.entries.count) 個項目；" + (single ? "輸入完整目的路徑" : "輸入既有目的資料夾") + "。同名時詢問，不覆蓋。", value: initial) else { return }
        enqueuePaths(c.entries.map(\.path), sourceRemote: c.remote, context: c, destination: target, exact: single, move: command == .moveTo)
    }
    func enqueuePaths(_ paths: [String], sourceRemote: Bool, context c: CommandContext, destination: String, exact: Bool = false, move: Bool = false) {
        Task {
            do {
                guard c.valid, (!sourceRemote || (c.tab.connected && c.session === c.tab.session)), destination.hasPrefix("/"), !destination.contains("\0") else { throw TransferError.message("請輸入有效完整路徑，並確認連線仍有效") }
                let directory = exact ? RemotePath.parent(destination) : destination
                let attributes = c.remote ? try await c.session!.attributes(directory) : try LocalFiles.attributes(directory)
                guard attributes.kind == .directory else { throw TransferError.message("目的地必須是資料夾") }
                let batch = UUID()
                for path in paths {
                    let target = exact ? destination : RemotePath.join(destination, (path as NSString).lastPathComponent)
                    var record = TransferTask(batchID: batch, connection: c.tab.connection ?? Connection(), direction: sourceRemote ? (c.remote ? .remoteCopy : .download) : (c.remote ? .upload : .local), source: path, destination: target)
                    record.originTabID = c.tab.id
                    record.sameSideOperation = sourceRemote == c.remote ? (move ? .move : .copy) : nil
                    record.options.policy = .ask; record.options.preserveTime = preferences.preserveTime; record.options.preservePermissions = preferences.preservePermissions
                    queue.enqueue(record)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
extension CommandContext {
    static func forSide(_ tab: TabBrowser, side: PanelSide) -> CommandContext {
        CommandContext(tab: tab, background: true, side: side)
    }
}
