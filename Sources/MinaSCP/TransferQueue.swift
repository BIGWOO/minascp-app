import Foundation
import SwiftUI

@MainActor final class TransferQueue: ObservableObject {
    @Published private(set) var records: [TransferTask] = []
    @Published var conflicts: [TransferConflict] = []
    @Published var persistenceError: String?
    var concurrency = 2
    var onChange: (() -> Void)?
    var authenticate: ((Connection) async throws -> Connection)?
    private let store: AtomicStore<[TransferTask]>
    private var readable = true
    private var active: [UUID: Task<Void, Never>] = [:]
    private var engines: [UUID: TransferEngine] = [:]
    private var stopIntents: [UUID: TransferState] = [:]
    private var completions: [UUID: (Error?) -> Void] = [:]
    private var decisions: [UUID: CheckedContinuation<ConflictResolution, Error>] = [:]
    private var batchPolicies: [UUID: CollisionPolicy] = [:]
    private var lastSaved = Date.distantPast
    private var started: [UUID: (Date, UInt64)] = [:]
    var activeCount: Int { active.count }
    init(url: URL = AppStoragePaths.root.appendingPathComponent("transfers.json")) {
        store = AtomicStore(url: url)
        do {
            records = try store.load() ?? []
            for i in records.indices where [.running, .waiting, .decision].contains(records[i].state) {
                records[i].state = .paused; records[i].message = "重啟後等待手動恢復；會重新驗證來源與部分檔案"
            }
        } catch { readable = false; persistenceError = "佇列讀取失敗，已保留原檔：\(error.localizedDescription)" }
    }
    @discardableResult func enqueue(_ record: TransferTask, completion: ((Error?) -> Void)? = nil) -> UUID {
        guard readable else { completion?(TransferError.message("佇列檔讀取失敗，禁止覆寫")); return record.id }
        records.insert(record, at: 0); completions[record.id] = completion; save(force: true); pump(); return record.id
    }
    func perform(_ record: TransferTask) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(record) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        } onCancel: { Task { @MainActor in self.stop(record.id, pause: false) } }
    }
    func performExisting(_ id: UUID) async throws {
        guard let record = records.first(where: { $0.id == id }) else { throw TransferError.message("子工作紀錄遺失") }
        if record.state == .complete { return }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard completions[id] == nil else { continuation.resume(throwing: TransferError.message("子工作仍有擁有者")); return }
                completions[id] = { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                if active[id] == nil { retry(id) }
            }
        } onCancel: { Task { @MainActor in self.stop(id, pause: true) } }
    }
    func speed(_ record: TransferTask) -> Double {
        guard record.state == .running, let (date, initial) = started[record.id] else { return 0 }
        return Double(record.transferred > initial ? record.transferred - initial : 0) / max(0.1, Date().timeIntervalSince(date))
    }
    func retry(_ id: UUID) {
        guard active[id] == nil, let i = index(id), records[i].state != .complete else { return }
        records[i].state = .waiting; records[i].message = ""; stopIntents[id] = nil; save(force: true); pump()
    }
    func stop(_ id: UUID, pause: Bool) {
        let state: TransferState = pause ? .paused : .cancelled
        guard let i = index(id), records[i].state != .complete else { return }
        stopIntents[id] = state
        if let conflict = conflicts.first(where: { $0.taskID == id }) { reject(conflict.id) }
        if let task = active[id] {
            task.cancel(); if let engine = engines[id] { Task { await engine.stop() } }
        } else { records[i].state = state; records[i].message = "已保留部分檔案，可手動重試"; completions.removeValue(forKey: id)?(CancellationError()); save(force: true) }
    }
    func sourceRemoved(_ id: UUID) { if let i = index(id) { records[i].sourceRemovalPending = false; save(force: true) } }
    func releaseCrossSite(_ id: UUID) { for i in records.indices where records[i].crossSiteJobID == id { records[i].crossSiteJobID = nil }; save(force: true) }
    func clearCompleted() { records.removeAll { $0.state == .complete && $0.crossSiteJobID == nil }; save(force: true) }
    func resolve(_ id: UUID, policy: CollisionPolicy, applyToBatch: Bool) {
        guard let conflict = conflicts.first(where: { $0.id == id }) else { return }
        if applyToBatch, let record = records.first(where: { $0.id == conflict.taskID }) { batchPolicies[record.batchID] = policy }
        conflicts.removeAll { $0.id == id }
        decisions.removeValue(forKey: id)?.resume(returning: ConflictResolution(policy: policy, applyToBatch: applyToBatch))
    }
    func reject(_ id: UUID) { conflicts.removeAll { $0.id == id }; decisions.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func request(_ conflict: TransferConflict) async throws -> ConflictResolution {
        if let record = records.first(where: { $0.id == conflict.taskID }), let policy = batchPolicies[record.batchID] { return ConflictResolution(policy: policy, applyToBatch: true) }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in decisions[conflict.id] = continuation; conflicts.append(conflict) }
        } onCancel: { Task { @MainActor in self.reject(conflict.id) } }
    }
    private func index(_ id: UUID) -> Int? { records.firstIndex { $0.id == id } }
    private func update(_ record: TransferTask) {
        guard let i = index(record.id), active[record.id] != nil else { return }
        records[i] = record; save()
    }
    private func save(force: Bool = false) {
        guard readable, force || Date().timeIntervalSince(lastSaved) > 1 else { return }
        do { try store.save(records); lastSaved = Date() } catch { persistenceError = "無法保存佇列：\(error.localizedDescription)" }
    }
    func pump() {
        guard readable else { return }
        while active.count < max(1, min(concurrency, 8)), let record = records.reversed().first(where: { $0.state == .waiting && active[$0.id] == nil }) {
            let id = record.id
            if let i = index(id) { records[i].state = .running }
            started[id] = (Date(), record.transferred)
            active[id] = Task {
                var taskRecord = record
                do {
                    if let authenticate, taskRecord.direction != .local { taskRecord.connection = try await authenticate(taskRecord.connection) }
                    try Task.checkCancellation()
                    let engine = TransferEngine(record: taskRecord, conflict: { [weak self] conflict in
                        guard let self else { throw CancellationError() }; return try await self.request(conflict)
                    }, update: { [weak self] updated in Task { @MainActor in self?.update(updated) } })
                    engines[id] = engine
                    let result = try await engine.run()
                    if let i = index(id) { records[i] = result }
                    completions.removeValue(forKey: id)?(nil)
                } catch {
                    if let i = index(id) { records[i].state = stopIntents[id] ?? (error is CancellationError ? .cancelled : .failed); records[i].message = error is CancellationError ? "已停止實際 I/O；部分檔案已保留" : error.localizedDescription }
                    completions.removeValue(forKey: id)?(error)
                }
                active[id] = nil; engines[id] = nil; started[id] = nil; stopIntents[id] = nil
                save(force: true); onChange?(); pump()
            }
        }
    }
}
