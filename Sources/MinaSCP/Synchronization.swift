import Foundation
import SwiftUI
import Darwin

struct FileSnapshot: Codable, Equatable, Sendable {
    let kind: FileKind
    let size: UInt64
    let modified: UInt32?
    let hash: String
}
struct SyncBaseline: Codable { var local: [String: FileSnapshot]; var remote: [String: FileSnapshot] }
enum SyncDirection: String, CaseIterable { case upload = "本機 → 遠端", download = "遠端 → 本機", both = "雙向" }
enum SyncActionKind: String { case upload = "上傳", download = "下載", deleteLocal = "本機移至垃圾桶", deleteRemote = "遠端永久刪除", conflict = "衝突" }
struct SyncAction: Identifiable {
    var id = UUID()
    var path: String
    var kind: SyncActionKind
    var selected = true
    var detail = ""
    var local: FileSnapshot?
    var remote: FileSnapshot?
}
enum Snapshotter {
    static func excluded(_ path: String, patterns: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        return patterns.contains { pattern in pattern.withCString { p in name.withCString { fnmatch(p, $0, 0) == 0 } || path.withCString { fnmatch(p, $0, 0) == 0 } } }
    }
    static func local(_ root: String, patterns: [String]) throws -> [String: FileSnapshot] {
        var results: [String: FileSnapshot] = [:]
        func scan(_ path: String, relative: String) throws {
            try Task.checkCancellation()
            for entry in try LocalFiles.list(path) {
                let key = relative.isEmpty ? entry.name : RemotePath.join(relative, entry.name)
                if excluded(key, patterns: patterns) { continue }
                let hash: String
                switch entry.kind { case .directory: hash = "directory"; case .symlink: hash = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path); case .file: hash = try LocalFiles.hash(entry.path) }
                results[key] = FileSnapshot(kind: entry.kind, size: UInt64(max(0, entry.size)), modified: entry.attributes.modificationTime, hash: hash)
                if entry.directory { try scan(entry.path, relative: key) }
            }
        }
        try scan(root, relative: ""); return results
    }
    static func remote(_ root: String, session: SFTPSession, patterns: [String]) async throws -> [String: FileSnapshot] {
        var results: [String: FileSnapshot] = [:]
        func scan(_ path: String, relative: String) async throws {
            try Task.checkCancellation()
            for entry in try await session.list(path) {
                let key = relative.isEmpty ? entry.name : RemotePath.join(relative, entry.name)
                if excluded(key, patterns: patterns) { continue }
                let hash: String
                switch entry.kind { case .directory: hash = "directory"; case .symlink: hash = try await session.readlink(entry.path); case .file: hash = try await session.hash(entry.path) }
                results[key] = FileSnapshot(kind: entry.kind, size: UInt64(max(0, entry.size)), modified: entry.attributes.modificationTime, hash: hash)
                if entry.directory { try await scan(entry.path, relative: key) }
            }
        }
        try await scan(root, relative: ""); return results
    }
}
enum SyncPlanner {
    static func plan(local: [String: FileSnapshot], remote: [String: FileSnapshot], baseline: SyncBaseline?, direction: SyncDirection, deleteExtra: Bool) -> [SyncAction] {
        var actions: [SyncAction] = []
        for path in Set(local.keys).union(remote.keys).sorted() {
            let l = local[path], r = remote[path]
            if let l, let r, l.kind == r.kind && l.hash == r.hash { continue }
            let kind: SyncActionKind
            if let l, let r, l.kind != r.kind { kind = .conflict }
            else {
                switch direction {
                case .upload: if l != nil { kind = .upload } else if deleteExtra { kind = .deleteRemote } else { continue }
                case .download: if r != nil { kind = .download } else if deleteExtra { kind = .deleteLocal } else { continue }
                case .both:
                    if l == nil { kind = .download }
                    else if r == nil { kind = .upload }
                    else if let old = baseline {
                        let localChanged = l?.hash != old.local[path]?.hash, remoteChanged = r?.hash != old.remote[path]?.hash
                        kind = localChanged && !remoteChanged ? .upload : remoteChanged && !localChanged ? .download : .conflict
                    } else { kind = .conflict }
                }
            }
            actions.append(SyncAction(path: path, kind: kind, selected: kind != .conflict && kind != .deleteRemote && kind != .deleteLocal, detail: kind == .conflict ? "兩端內容或種類不同，請明確選擇方向" : "", local: l, remote: r))
        }
        return actions
    }
}
@MainActor final class SyncManager: ObservableObject {
    @Published var direction: SyncDirection = .upload
    @Published var deleteExtra = false
    @Published var exclusions = ".git,node_modules,.DS_Store,.minascp-*"
    @Published var actions: [SyncAction] = []
    @Published var busy = false
    @Published var message = "先掃描並預覽差異，再執行所選項目"
    @Published var watching = false
    private var operation: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var context: (Connection, String, String)?
    private(set) var originTabID: UUID?
    private var localSnapshot: [String: FileSnapshot] = [:]
    private var remoteSnapshot: [String: FileSnapshot] = [:]
    private var patternList: [String] { exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } + [".minascp-*"] }
    private var baselineStore: AtomicStore<SyncBaseline>?
    var enqueue: ((TransferTask) async throws -> Void)?
    var authenticate: ((Connection) throws -> Connection)?
    func configure(_ tab: TabBrowser, exclusions: String) {
        guard !busy, !watching, let c = tab.connection else { return }
        originTabID = tab.id
        context = (c, tab.state.local.path, tab.state.remote.path); self.exclusions = exclusions; actions = []; message = "\(c.host) · \(tab.state.local.path) ↔ \(tab.state.remote.path)"
        let identity = "\(c.host):\(c.port):\(c.user):\(tab.state.local.path):\(tab.state.remote.path)"
        let filename = Data(identity.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        // Avoid filesystem filename limits while keeping baselines scoped to both roots and the host.
        let digest = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        _ = filename
        baselineStore = AtomicStore(url: AppStoragePaths.root.appendingPathComponent("sync/\(digest).json"))
    }
    func scan() {
        guard !busy, let context else { return }
        busy = true; message = "正在讀取兩端內容與 SHA-256…"; actions = []
        let patterns = patternList, direction = direction, deletion = deleteExtra
        operation = Task {
            var session: SFTPSession?
            do {
                let c = try authenticate?(context.0) ?? context.0; session = try await SFTPSession.open(c)
                let channel = session!
                async let local = Task.detached { try Snapshotter.local(context.1, patterns: patterns) }.value
                async let remote = Snapshotter.remote(context.2, session: channel, patterns: patterns)
                (localSnapshot, remoteSnapshot) = try await (local, remote)
                let baseline = try baselineStore?.load()
                actions = SyncPlanner.plan(local: localSnapshot, remote: remoteSnapshot, baseline: baseline, direction: direction, deleteExtra: deletion)
                message = "\(actions.count) 個差異；不會執行未勾選項目"
            } catch { message = "掃描未完成：" + error.localizedDescription; actions = [] }
            await session?.close(); busy = false
        }
    }
    func cancel() { operation?.cancel(); watcher?.cancel(); watching = false; message = "正在停止…" }
    func execute() {
        guard !busy, let context, let enqueue else { return }
        let selected = actions.filter { $0.selected && $0.kind != .conflict }.sorted { a,b in
            let ad = a.kind == .deleteLocal || a.kind == .deleteRemote, bd = b.kind == .deleteLocal || b.kind == .deleteRemote
            if ad != bd { return !ad }; return ad ? a.path.count > b.path.count : a.path.count < b.path.count
        }
        let deletes = selected.filter { $0.kind == .deleteLocal || $0.kind == .deleteRemote }
        if !deletes.isEmpty, !Dialogs.confirm("確認同步刪除？", detail: "\(context.0.host)\n" + deletes.map { $0.kind.rawValue + "：" + $0.path }.joined(separator: "\n"), destructive: true) { return }
        busy = true
        let patterns = patternList
        operation = Task {
            var session: SFTPSession?
            do {
                let c = try authenticate?(context.0) ?? context.0; session = try await SFTPSession.open(c)
                let channel = session!
                // Validate the entire preview immediately before scheduling any mutations.
                async let currentLocal = Task.detached { try Snapshotter.local(context.1, patterns: patterns) }.value
                async let currentRemote = Snapshotter.remote(context.2, session: channel, patterns: patternList)
                let (l, r) = try await (currentLocal, currentRemote)
                guard l == localSnapshot && r == remoteSnapshot else { throw TransferError.message("預覽後檔案已改變，請重新掃描") }
                for action in selected {
                    try Task.checkCancellation(); message = action.kind.rawValue + "：" + action.path
                    let local = RemotePath.join(context.1, action.path), remote = RemotePath.join(context.2, action.path)
                    try await validateSnapshot(local, expected: action.local, session: nil)
                    try await validateSnapshot(remote, expected: action.remote, session: session)
                    switch action.kind {
                    case .upload,.download:
                        let sourceKind = action.kind == .upload ? action.local?.kind : action.remote?.kind
                        if sourceKind == .directory {
                            if action.kind == .upload { if try await session!.exists(remote) == nil { try await session!.mkdir(remote) } }
                            else if try LocalFiles.exists(local) == nil { try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: false) }
                            continue
                        }
                        var task = TransferTask(connection: c, direction: action.kind == .upload ? .upload : .download, source: action.kind == .upload ? local : remote, destination: action.kind == .upload ? remote : local)
                        task.options.policy = (action.kind == .upload ? action.remote : action.local) == nil ? .ask : .overwrite
                        task.expectedSourceHash = sourceKind == .file ? (action.kind == .upload ? action.local?.hash : action.remote?.hash) : nil
                        task.expectedDestinationHash = action.kind == .upload ? (action.remote?.kind == .file ? action.remote?.hash : nil) : (action.local?.kind == .file ? action.local?.hash : nil)
                        try await enqueue(task)
                    case .deleteRemote: try await session!.remove(remote, directory: action.remote?.kind == .directory)
                    case .deleteLocal:
                        if action.local?.kind == .directory, !(try FileManager.default.contentsOfDirectory(atPath: local)).isEmpty { throw TransferError.message("資料夾仍有排除或新增項目，已保留：\(local)") }
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: local), resultingItemURL: nil)
                    case .conflict: break
                    }
                }
                async let finalLocal = Task.detached { try Snapshotter.local(context.1, patterns: patterns) }.value
                async let finalRemote = Snapshotter.remote(context.2, session: channel, patterns: patternList)
                let baseline = try await SyncBaseline(local: finalLocal, remote: finalRemote)
                try baselineStore?.save(baseline); localSnapshot = baseline.local; remoteSnapshot = baseline.remote
                actions = []; message = "所選同步操作完成，內容基準已保存"
            } catch { message = error is CancellationError ? "同步已停止；已完成項目與部分檔案均保留" : "同步未完成：" + error.localizedDescription }
            await session?.close(); busy = false
        }
    }
    private func validateSnapshot(_ path: String, expected: FileSnapshot?, session: SFTPSession?) async throws {
        let attr = session != nil ? try await session!.exists(path) : try LocalFiles.exists(path)
        guard let expected else { guard attr == nil else { throw TransferError.message("預覽後新增項目：" + path) }; return }
        guard let attr, attr.kind == expected.kind else { throw TransferError.message("預覽後種類已改變：" + path) }
        if attr.kind == .directory { return }
        let hash: String
        if attr.kind == .file { hash = session != nil ? try await session!.hash(path) : try LocalFiles.hash(path) }
        else { hash = session != nil ? try await session!.readlink(path) : try FileManager.default.destinationOfSymbolicLink(atPath: path) }
        guard hash == expected.hash else { throw TransferError.message("預覽後內容已改變：" + path) }
    }
    func startWatching() {
        guard !watching, !busy, context != nil, !localSnapshot.isEmpty || !remoteSnapshot.isEmpty else { message = "請先完成一次差異掃描再啟動監看"; return }
        watching = true; deleteExtra = false
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, self.watching, let context = self.context, !self.busy else { continue }
                do {
                    let patterns = self.patternList
                    let current = try await Task.detached { try Snapshotter.local(context.1, patterns: patterns) }.value
                    let changed = current.filter { self.localSnapshot[$0.key]?.hash != $0.value.hash }
                    if changed.isEmpty { continue }
                    let c = try self.authenticate?(context.0) ?? context.0, session = try await SFTPSession.open(c)
                    let remote: [String: FileSnapshot]
                    do { remote = try await Snapshotter.remote(context.2, session: session, patterns: self.patternList); await session.close() } catch { await session.close(); throw error }
                    for (path, _) in changed where remote[path]?.hash != self.remoteSnapshot[path]?.hash { throw TransferError.message("監看衝突：\(path) 的遠端也已改變，已停止自動上傳") }
                    self.localSnapshot = current; self.remoteSnapshot = remote
                    self.actions = SyncPlanner.plan(local: changed, remote: remote, baseline: nil, direction: .upload, deleteExtra: false)
                    self.execute()
                } catch { self.message = error.localizedDescription; self.watching = false; return }
            }
        }
    }
}
