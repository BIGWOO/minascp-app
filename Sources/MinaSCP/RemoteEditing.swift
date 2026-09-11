import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemoteEditSession: Identifiable, Codable {
    var id = UUID()
    var connection: Connection
    var originTabID: UUID?
    var remotePath: String
    var localPath: String
    var baselineHash: String
    var uploadedLocalHash: String
    var state = "監看中"
    var message = ""
}
enum TextFiles {
    static func supported(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["txt","md","json","yaml","yml","toml","ini","conf","config","xml","html","css","js","jsx","ts","tsx","swift","py","php","sh","zsh","sql","csv","log","rs","go","c","h","cpp","vue","svelte","env","gitignore"].contains(ext) { return true }
        if ["Dockerfile","Makefile",".env",".gitignore",".editorconfig"].contains(name) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }
    static func read(_ url: URL) throws -> String {
        let attributes = try LocalFiles.attributes(url.path)
        guard attributes.size ?? 0 <= 16 * 1024 * 1024 else { throw TransferError.message("文字預覽與自動回存限制為 16 MiB；請用一般下載處理較大檔案") }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw TransferError.message("此檔案不是 UTF-8 文字，不會當作文字編輯") }
        return text
    }
}
@MainActor final class RemoteEditManager: ObservableObject {
    @Published var records: [RemoteEditSession] = []
    @Published var error: String?
    var authenticate: ((Connection) throws -> Connection)?
    var openEditor: ((URL) -> Void)?
    var onUpload: (() -> Void)?
    var onIssue: ((String) -> Void)?
    private let root: URL
    private let store: AtomicStore<[RemoteEditSession]>
    private var readable = true
    private var checking = Set<UUID>()
    private var missingTicks: [UUID: Int] = [:]
    private var pending: [UUID: (String, Date)] = [:]
    private var poller: Task<Void, Never>?
    init(root: URL = AppStoragePaths.root.appendingPathComponent("editing")) {
        self.root = root; store = AtomicStore(url: root.appendingPathComponent("sessions.json"))
        do { records = try store.load() ?? []; for i in records.indices { if records[i].state != "衝突" { records[i].state = "已暫停" }; records[i].message = "重啟後保留工作副本；按恢復監看才會繼續回存" } }
        catch { readable = false; self.error = "編輯紀錄讀取失敗，已保留原檔：" + error.localizedDescription }
        poller = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); guard let self else { return }; self.tick() }
        }
    }
    private func save() { guard readable else { return }; do { try store.save(records) } catch { self.error = error.localizedDescription } }
    func begin(entry: Entry, connection: Connection, originTabID: UUID? = nil) async throws {
        guard readable else { throw TransferError.message("編輯紀錄不可讀，禁止覆寫") }
        guard entry.kind == .file, TextFiles.supported(entry.name), entry.size <= 16 * 1024 * 1024 else { throw TransferError.message("請選擇不超過 16 MiB 的文字檔；其他檔案可一般下載或預覽") }
        if let existing = records.first(where: { $0.connection.host == connection.host && $0.connection.user == connection.user && $0.connection.port == connection.port && $0.remotePath == entry.path }) {
            if let i = records.firstIndex(where: { $0.id == existing.id }) {
                records[i].connection = connection
                records[i].originTabID = originTabID
                if records[i].state == "已暫停" { setWatching(existing.id, active: true) }
            }
            openEditor?(URL(fileURLWithPath: existing.localPath)); return
        }
        let id = UUID(), directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = directory.appendingPathComponent(entry.name)
        let c = try authenticate?(connection) ?? connection
        var task = TransferTask(connection: c, direction: .download, source: entry.path, destination: local.path)
        task.options.preservePermissions = true
        _ = try await TransferEngine(record: task, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        _ = try TextFiles.read(local)
        let hash = try LocalFiles.hash(local.path)
        records.append(RemoteEditSession(id: id, connection: connection, originTabID: originTabID, remotePath: entry.path, localPath: local.path, baselineHash: hash, uploadedLocalHash: hash)); save(); openEditor?(local)
    }
    func setWatching(_ id: UUID, active: Bool) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state != "上傳中" else { return }
        records[i].state = active ? "監看中" : "已暫停"; records[i].message = ""; save()
    }
    private func tick() {
        for record in records where record.state == "監看中" && !checking.contains(record.id) {
            checking.insert(record.id)
            Task {
                defer { checking.remove(record.id) }
                do {
                    let hash = try await Task.detached { try LocalFiles.hash(record.localPath) }.value
                    missingTicks[record.id] = nil
                    guard let current = records.first(where: { $0.id == record.id }), current.state == "監看中" else { return }
                    if hash == current.uploadedLocalHash { pending[record.id] = nil; return }
                    if let (prior, date) = pending[record.id], prior == hash, Date().timeIntervalSince(date) >= 0.6 {
                        pending[record.id] = nil; await upload(record.id, force: false)
                    } else { pending[record.id] = (hash, Date()) }
                } catch {
                    missingTicks[record.id] = (missingTicks[record.id] ?? 0) + 1
                    if (missingTicks[record.id] ?? 0) >= 3, let i = records.firstIndex(where: { $0.id == record.id }) { records[i].state = "失敗"; records[i].message = "工作副本無法讀取，已停止監看：" + error.localizedDescription; save() }
                }
            }
        }
    }
    func upload(_ id: UUID, force: Bool, saveAs: String? = nil) async {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != "上傳中" else { return }
        let original = records[index]
        records[index].state = "上傳中"; save()
        var session: SFTPSession?
        do {
            let c = try authenticate?(original.connection) ?? original.connection
            session = try await SFTPSession.open(c)
            let destination = saveAs ?? original.remotePath
            let current = try await session!.exists(destination)
            let currentHash = current == nil ? nil : try await session!.hash(destination)
            if saveAs == nil && !force && currentHash != original.baselineHash { throw EditConflict() }
            if saveAs != nil && current != nil { throw TransferError.message("另存目的地已存在，請使用新名稱") }
            let localURL = URL(fileURLWithPath: original.localPath)
            _ = try TextFiles.read(localURL)
            let snapshot = localURL.deletingLastPathComponent().appendingPathComponent(".upload-" + UUID().uuidString)
            try FileManager.default.copyItem(at: localURL, to: snapshot)
            if let permissions = current?.permissions { try FileManager.default.setAttributes([.posixPermissions: permissions & 0o777], ofItemAtPath: snapshot.path) }
            let newHash = try LocalFiles.hash(snapshot.path)
            var transfer = TransferTask(connection: c, direction: .upload, source: snapshot.path, destination: destination)
            transfer.options.preservePermissions = true
            transfer.options.policy = current == nil ? .ask : .overwrite
            transfer.expectedDestinationHash = currentHash
            _ = try await TransferEngine(record: transfer, conflict: { _ in throw EditConflict() }, update: { _ in }).run()
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].baselineHash = newHash; records[i].uploadedLocalHash = newHash; records[i].remotePath = destination; records[i].state = "監看中"; records[i].message = "儲存並校驗完成" }
            try? FileManager.default.removeItem(at: snapshot)
            onUpload?()
        } catch {
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].state = error is EditConflict ? "衝突" : "失敗"; records[i].message = error.localizedDescription; onIssue?(error.localizedDescription) }
        }
        await session?.close(); save()
    }
    func reload(_ id: UUID) async {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[i].state != "上傳中" else { return }
        records[i].state = "已暫停"
        let record = records[i]
        do {
            let local = URL(fileURLWithPath: record.localPath)
            if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.copyItem(at: local, to: local.appendingPathExtension("backup-" + UUID().uuidString)) }
            let c = try authenticate?(record.connection) ?? record.connection
            var task = TransferTask(connection: c, direction: .download, source: record.remotePath, destination: record.localPath); task.options.policy = .overwrite
            _ = try await TransferEngine(record: task, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
            let hash = try LocalFiles.hash(local.path)
            records[i].baselineHash = hash; records[i].uploadedLocalHash = hash; records[i].state = "已暫停"; records[i].message = "已重新下載；舊本機修改另存為 backup"; save(); openEditor?(local)
        } catch { self.error = error.localizedDescription }
    }
    func remoteText(_ record: RemoteEditSession) async throws -> String {
        let c = try authenticate?(record.connection) ?? record.connection
        let temporary = root.appendingPathComponent("compare-" + UUID().uuidString)
        _ = try await TransferEngine(record: TransferTask(connection: c, direction: .download, source: record.remotePath, destination: temporary.path), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        return try TextFiles.read(temporary)
    }
}
struct EditConflict: LocalizedError { var errorDescription: String? { "遠端內容已變更，已暫停回存；請比較、重新下載、另存或明確覆蓋。" } }
extension BrowserModel {
    func startRemoteEdit(_ entry: Entry, tab: TabBrowser) {
        guard let c = tab.connection else { return }
        Task { do { try await edits.begin(entry: entry, connection: c, originTabID: tab.id) } catch { self.error = error.localizedDescription } }
    }
    func startPreview(_ entry: Entry, tab: TabBrowser, remote: Bool) {
        guard entry.kind == .file else { error = "資料夾與連結請使用屬性檢視"; return }
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
        if type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true {
            Task {
                do {
                    guard entry.size <= 32 * 1024 * 1024 else { throw TransferError.message("圖片／PDF 預覽上限為 32 MiB") }
                    var url = URL(fileURLWithPath: entry.path)
                    if remote {
                        guard let c = tab.connection else { return }
                        let directory = AppStoragePaths.root.appendingPathComponent("previews/" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        url = directory.appendingPathComponent(entry.name)
                        _ = try await TransferEngine(record: TransferTask(connection: c, direction: .download, source: entry.path, destination: url.path), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
                    }
                    preview = PreviewDocument(title: entry.name, text: "", fileURL: url)
                } catch { self.error = error.localizedDescription }
            }
            return
        }
        if !TextFiles.supported(entry.name) {
            preview = PreviewDocument(title: entry.name, text: "非文字檔案\n大小：\(entry.size) bytes\n路徑：\(entry.path)\n請下載後以對應 App 開啟。")
            return
        }
        Task {
            do {
                if remote {
                    guard let c = tab.connection, entry.size <= 16 * 1024 * 1024 else { throw TransferError.message("文字預覽上限為 16 MiB") }
                    let root = AppStoragePaths.root.appendingPathComponent("previews")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let url = root.appendingPathComponent(UUID().uuidString)
                    _ = try await TransferEngine(record: TransferTask(connection: c, direction: .download, source: entry.path, destination: url.path), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
                    preview = PreviewDocument(title: entry.name, text: try TextFiles.read(url))
                } else { preview = PreviewDocument(title: entry.name, text: try TextFiles.read(URL(fileURLWithPath: entry.path))) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
