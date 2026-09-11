import SwiftUI

struct CrossSiteJob: Identifiable, Codable {
    var id = UUID()
    let sourceSite: SavedSite
    let destinationSite: SavedSite
    let paths: [String]
    let destination: String
    var manifest: [String: FileSnapshot]
    var bytes: UInt64
    var state = "已暫停"
    var message = ""
    var downloads: [String: UUID] = [:]
    var uploads: [String: UUID] = [:]
    var staging: String = ""
    var created = Date()
}
struct CrossSiteDocument: Codable { var version = 1; var jobs: [CrossSiteJob] = [] }
enum CrossManifest {
    static func remote(_ paths: [String], session: SFTPSession) async throws -> [String: FileSnapshot] {
        var result: [String: FileSnapshot] = [:]
        func scan(_ path: String, key: String) async throws {
            try Task.checkCancellation()
            let attr = try await session.attributes(path), hash: String
            switch attr.kind { case .file: hash = try await session.hash(path); case .symlink: hash = try await session.readlink(path); case .directory: hash = "directory" }
            result[key] = FileSnapshot(kind: attr.kind, size: attr.size ?? 0, modified: attr.modificationTime, hash: hash)
            if attr.kind == .directory { for child in try await session.list(path) { try await scan(child.path, key: RemotePath.join(key, child.name)) } }
        }
        for path in paths { try await scan(path, key: (path as NSString).lastPathComponent) }
        return result
    }
    static func contentMatches(_ a: [String: FileSnapshot], _ b: [String: FileSnapshot]) -> Bool {
        a.keys.sorted() == b.keys.sorted() && a.allSatisfy { key, value in
            guard let other = b[key] else { return false }; return value.kind == other.kind && value.hash == other.hash && (value.kind != .file || value.size == other.size)
        }
    }
    static func requiredSpace(_ bytes: UInt64) throws -> UInt64 {
        let (value, overflow) = bytes.addingReportingOverflow(max(bytes / 10, 64 * 1024 * 1024))
        guard !overflow else { throw TransferError.message("容量估算超出可處理範圍") }; return value
    }
}
@MainActor final class CrossSiteManager: ObservableObject {
    @Published var jobs: [CrossSiteJob] = []
    @Published var showJobs = false
    @Published var error: String?
    @Published var preparing = false
    private let store: AtomicStore<CrossSiteDocument>
    let stagingRoot: URL
    private var readable = true
    private var active: [UUID: Task<Void, Never>] = [:]
    private var stopStates: [UUID: String] = [:]
    private let queue: TransferQueue
    var authenticate: ((Connection) throws -> Connection)?
    var sites: (() -> [SavedSite])?
    var availableBytes: () throws -> UInt64
    var activeCount: Int { active.count }
    init(root: URL, queue: TransferQueue) {
        self.queue = queue; stagingRoot = root.appendingPathComponent("cross-site-staging", isDirectory: true)
        store = AtomicStore(url: root.appendingPathComponent("cross-site-v1.json"))
        availableBytes = { let info = try FileManager.default.attributesOfFileSystem(forPath: root.path); return (info[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0 }
        do { if let doc = try store.load() { guard doc.version == 1 else { throw TransferError.message("跨站台紀錄版本不支援") }; jobs = doc.jobs; for i in jobs.indices where ["掃描中", "下載中", "上傳中", "驗證中"].contains(jobs[i].state) { jobs[i].state = "已暫停"; jobs[i].message = "重啟後請手動恢復；會重驗來源與暫存" } } }
        catch { readable = false; self.error = error.localizedDescription }
    }
    func prepare(source: SavedSite, destination: SavedSite, paths: [String], directory: String) async throws -> CrossSiteJob {
        guard readable, source.id != destination.id, source.connection.valid, destination.connection.valid, directory.hasPrefix("/"), !paths.isEmpty, paths.allSatisfy(RemotePath.isSafeMutation) else { throw TransferError.message("跨站台來源或目的地無效") }
        guard Set(paths.map { ($0 as NSString).lastPathComponent }).count == paths.count else { throw TransferError.message("來源有重複名稱") }
        preparing = true; defer { preparing = false }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = try await SFTPSession.open(try authenticate?(source.connection) ?? source.connection)
        let manifest: [String: FileSnapshot]
        do { manifest = try await CrossManifest.remote(paths, session: session); await session.close() } catch { await session.close(); throw error }
        var bytes: UInt64 = 0
        for item in manifest.values where item.kind == .file { let (sum, overflow) = bytes.addingReportingOverflow(item.size); guard !overflow else { throw TransferError.message("來源容量過大") }; bytes = sum }
        guard try availableBytes() >= CrossManifest.requiredSpace(bytes) else { throw TransferError.message("本機暫存空間不足，需要內容大小加 10%，至少另留 64 MiB") }
        var job = CrossSiteJob(sourceSite: source, destinationSite: destination, paths: paths, destination: directory, manifest: manifest, bytes: bytes)
        job.staging = stagingRoot.appendingPathComponent(job.id.uuidString).path
        return job
    }
    func start(_ job: CrossSiteJob) {
        guard readable, !jobs.contains(where: { $0.id == job.id }) else { return }
        jobs.insert(job, at: 0)
        do { try save(); resume(job.id) } catch { self.error = error.localizedDescription }
        showJobs = true
    }
    func stop(_ id: UUID, pause: Bool) { stopStates[id] = pause ? "已暫停" : "已取消"; active[id]?.cancel() }
    func resume(_ id: UUID) {
        guard active[id] == nil, let i = index(id), !["完成", "已清理", "完成（有略過）"].contains(jobs[i].state), readable else { return }
        stopStates[id] = nil
        active[id] = Task {
            do { try await run(id) }
            catch { if let i = index(id) { jobs[i].state = stopStates[id] ?? "失敗"; jobs[i].message = error.localizedDescription + "；暫存與已完成項目保留" }; try? save() }
            active[id] = nil; stopStates[id] = nil
        }
    }
    private func endpoint(_ saved: SavedSite) throws -> Connection {
        guard let current = sites?().first(where: { $0.id == saved.id }), FileClipboard.signature(current.connection) == FileClipboard.signature(saved.connection) else { throw TransferError.message("站台已移除或端點改變，禁止恢復") }
        return try authenticate?(current.connection) ?? current.connection
    }
    private func run(_ id: UUID) async throws {
        guard let initial = index(id) else { return }
        let job = jobs[initial]
        let sourceConnection = try endpoint(job.sourceSite), destinationConnection = try endpoint(job.destinationSite)
        let source = try await SFTPSession.open(sourceConnection)
        do {
            try status(id, "掃描中", "重新驗證來源清單與雜湊")
            guard try await CrossManifest.remote(job.paths, session: source) == job.manifest else { throw TransferError.message("來源已變更，請重新建立跨站台工作") }
            await source.close()
        } catch { await source.close(); throw error }
        try Task.checkCancellation()
        let payload = URL(fileURLWithPath: job.staging).appendingPathComponent("payload")
        guard URL(fileURLWithPath: job.staging).standardizedFileURL.path == stagingRoot.appendingPathComponent(id.uuidString).path else { throw TransferError.message("暫存目錄不符") }
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existingBytes = try Snapshotter.local(payload.path, patterns: []).values.filter { $0.kind == .file }.reduce(UInt64(0)) { $0 + $1.size }
        let remaining = job.bytes > existingBytes ? job.bytes - existingBytes : 0
        guard try availableBytes() >= CrossManifest.requiredSpace(remaining) else { throw TransferError.message("本機剩餘空間不足") }
        for path in job.paths {
            try Task.checkCancellation(); let name = (path as NSString).lastPathComponent
            try status(id, "下載中", name)
            var record = TransferTask(batchID: id, connection: sourceConnection, direction: .download, source: path, destination: payload.appendingPathComponent(name).path)
            record.crossSiteJobID = id
            record.options = job.sourceSite.transferOptions; record.options.policy = .ask
            try await child(id, name: name, download: true, record: record)
        }
        guard CrossManifest.contentMatches(job.manifest, try Snapshotter.local(payload.path, patterns: [])) else { throw TransferError.message("暫存內容與來源基準不一致") }
        let fresh = try await SFTPSession.open(sourceConnection)
        do { guard try await CrossManifest.remote(job.paths, session: fresh) == job.manifest else { throw TransferError.message("下載期間來源變更，未開始上傳") }; await fresh.close() } catch { await fresh.close(); throw error }
        let destination = try await SFTPSession.open(destinationConnection)
        do {
            guard try await destination.attributes(job.destination).kind == .directory else { throw TransferError.message("目的地必須是既有資料夾") }
            var skipped = false
            for path in job.paths {
                try Task.checkCancellation(); let name = (path as NSString).lastPathComponent
                try status(id, "上傳中", name)
                var record = TransferTask(batchID: id, connection: destinationConnection, direction: .upload, source: payload.appendingPathComponent(name).path, destination: RemotePath.join(job.destination, name))
                record.crossSiteJobID = id
                record.options = job.destinationSite.transferOptions; record.options.policy = .ask
                record.noOverwriteCopy = true
                let result = try await child(id, name: name, download: false, record: record)
                if (result.skippedCount ?? 0) > 0 { skipped = true; continue }
                try status(id, "驗證中", "獨立讀回 " + name)
                let actual = try await CrossManifest.remote([result.destination], session: destination)
                let targetName = (result.destination as NSString).lastPathComponent
                var expected: [String: FileSnapshot] = [:]
                for (key, value) in job.manifest where key == name || key.hasPrefix(name + "/") { expected[targetName + String(key.dropFirst(name.count))] = value }
                guard CrossManifest.contentMatches(expected, actual) else { throw TransferError.message("目的站台讀回不一致：" + result.destination) }
            }
            await destination.close(); try Task.checkCancellation()
            if skipped { try status(id, "完成（有略過）", "來源保留；暫存保留，可手動清理") }
            else {
                try FileManager.default.removeItem(atPath: job.staging)
                queue.releaseCrossSite(id)
                try status(id, "完成", "目的內容已獨立校驗，已清理本機暫存；來源保留")
            }
        } catch { await destination.close(); throw error }
    }
    @discardableResult private func child(_ id: UUID, name: String, download: Bool, record: TransferTask) async throws -> TransferTask {
        guard let i = index(id) else { throw CancellationError() }
        let existing = download ? jobs[i].downloads[name] : jobs[i].uploads[name]
        if let existing { try await queue.performExisting(existing) }
        else {
            if download { jobs[i].downloads[name] = record.id } else { jobs[i].uploads[name] = record.id }
            try save(); try await queue.perform(record)
        }
        guard let result = queue.records.first(where: { $0.id == (existing ?? record.id) }) else { throw TransferError.message("子工作紀錄遺失，請重新建立工作") }
        return result
    }
    func cleanup(_ id: UUID) {
        guard active[id] == nil, let i = index(id) else { return }
        let path = stagingRoot.appendingPathComponent(id.uuidString)
        guard jobs[i].staging == path.path else { error = "暫存目錄不符"; return }
        do { if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }; queue.releaseCrossSite(id); jobs[i].state = "已清理"; jobs[i].message = "本機暫存已清理；不再恢復此工作"; try save() }
        catch { self.error = error.localizedDescription }
    }
    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    private func status(_ id: UUID, _ state: String, _ message: String) throws { guard let i = index(id) else { throw CancellationError() }; jobs[i].state = state; jobs[i].message = message; try save() }
    private func save() throws { guard readable else { throw TransferError.message("跨站台紀錄無法讀取，禁止覆寫") }; try store.save(CrossSiteDocument(jobs: jobs)) }
}
