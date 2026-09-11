import Foundation
import AppKit

enum FileCommand: String, CaseIterable {
    case open = "開啟", copyNames = "複製名稱", copyPaths = "複製完整路徑", clipboardCopy = "複製", paste = "貼上", newFile = "新增檔案…", refresh = "重新整理", goTo = "前往路徑…", up = "上層目錄", root = "根目錄", home = "家目錄", back = "上一頁", forward = "下一頁", bookmark = "加入書籤", filter = "篩選…", currentPath = "複製目前目錄路徑"
    case preview = "預覽", edit = "編輯", copy = "複製／傳輸", move = "移動至另一端", mkdir = "新增資料夾", rename = "重新命名", delete = "刪除", properties = "屬性", permissions = "修改權限", ownership = "修改擁有者", symlink = "新增符號連結", copyTo = "複製到…", moveTo = "移動到…", search = "尋找檔案"
    var symbol: String {
        switch self { case .open: return "folder"; case .clipboardCopy,.copyNames,.copyPaths,.currentPath: return "doc.on.clipboard"; case .paste: return "clipboard"; case .newFile: return "doc.badge.plus"; case .refresh: return "arrow.clockwise"; case .goTo,.up,.root,.home,.back,.forward: return "arrow.turn.up.right"; case .bookmark: return "bookmark"; case .filter: return "line.3.horizontal.decrease"; case .preview: return "eye"; case .edit: return "square.and.pencil"; case .copy,.copyTo: return "doc.on.doc"; case .move,.moveTo: return "arrow.right.doc.on.clipboard"; case .mkdir: return "folder.badge.plus"; case .rename: return "pencil"; case .delete: return "trash"; case .properties: return "info.circle"; case .permissions,.ownership: return "lock"; case .symlink: return "link"; case .search: return "magnifyingglass" }
    }
}
@MainActor enum Dialogs {
    static func text(_ title: String, detail: String = "", value: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        let input = NSTextField(string: value); input.frame = NSRect(x: 0, y: 0, width: 440, height: 26); alert.accessoryView = input
        alert.addButton(withTitle: "確定"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }
    static func confirm(_ title: String, detail: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: destructive ? "確認執行" : "繼續")
        return alert.runModal() == .alertSecondButtonReturn
    }
    static func info(_ title: String, detail: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "好"); alert.runModal() }
}
enum RemoteFileOperations {
    static func copyTree(session: SFTPSession, source: String, destination: String) async throws {
        guard source != destination, !destination.hasPrefix(source + "/"), RemotePath.isSafeMutation(destination) else { throw TransferError.message("目的地不可是來源本身或其子目錄") }
        guard try await session.exists(destination) == nil else { throw TransferError.message("目的地已存在，請另選名稱") }
        let attributes = try await session.attributes(source)
        if attributes.kind == .directory {
            try await session.mkdir(destination)
            for child in try await session.list(source) { try await copyTree(session: session, source: child.path, destination: RemotePath.join(destination, child.name)) }
        } else if attributes.kind == .symlink { try await session.symlink(try await session.readlink(source), at: destination) }
        else {
            let staging = RemotePath.join(RemotePath.parent(destination), ".minascp-copy-" + UUID().uuidString)
            let input = try await session.openFile(source, flags: 1), output = try await session.openFile(staging, flags: 2 | 8 | 32)
            do {
                var offset: UInt64 = 0
                while true { try Task.checkCancellation(); let data = try await session.read(input, offset: offset); if data.isEmpty { break }; try await session.write(output, offset: offset, data: data); offset += UInt64(data.count) }
                try await session.closeHandle(input); try await session.closeHandle(output)
                guard try await session.hash(source) == session.hash(staging) else { throw TransferError.message("遠端複製校驗不符，暫存檔已保留") }
                try await session.rename(staging, to: destination)
            } catch { try? await session.closeHandle(input); try? await session.closeHandle(output); throw error }
        }
    }
}
