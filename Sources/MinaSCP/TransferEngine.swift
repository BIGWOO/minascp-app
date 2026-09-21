import Foundation
import CryptoKit

/// One engine owns one transfer connection. Pausing cancels its task and closes that channel.
actor TransferEngine {
    private var record: TransferTask
    private var session: SFTPSession?
    private let conflict: ConflictHandler
    private let update: TransferUpdate
    private var stopped = false
    private var lastUpdate = Date.distantPast
    private var started = Date()
    private var runBytes: UInt64 = 0
    init(record: TransferTask, conflict: @escaping ConflictHandler, update: @escaping TransferUpdate) { self.record = record; self.conflict = conflict; self.update = update }
    func stop() async { stopped = true; await session?.close() }
    private func check() throws { try Task.checkCancellation(); if stopped { throw CancellationError() } }
    private func report(force: Bool = false) {
        if force || Date().timeIntervalSince(lastUpdate) >= 0.1 { lastUpdate = Date(); update(record) }
    }
    private func progress(_ bytes: UInt64) async throws {
        record.transferred += bytes; record.currentFileBytes = (record.currentFileBytes ?? 0) + bytes; runBytes += bytes; report()
        if record.options.speedLimit > 0 {
            let required = Double(runBytes) / Double(record.options.speedLimit)
            let wait = required - Date().timeIntervalSince(started)
            if wait > 0 { try await Task.sleep(for: .seconds(min(wait, 2))) }
        }
        try check()
    }
    func run() async throws -> TransferTask {
        try check(); record.state = .running; started = Date(); runBytes = 0; record.transferred = 0; record.skippedCount = 0
        if record.direction != .local { session = try await SFTPSession.open(record.connection) }
        do {
            if record.sameSideOperation != nil || record.noOverwriteCopy == true {
                if record.sameSideOperation != nil { try await validateSameSide(allowSameTarget: record.sameSideOperation == .copy && record.rootPrepared != true) }
                if record.rootPrepared != true {
                    let attr = try await sourceAttributes(record.source)
                    let item = TransferItem(relativePath: "", source: record.source, kind: attr.kind, attributes: attr)
                    guard let (target, _) = try await resolve(item, destination: record.destination) else {
                        record.skippedCount = 1; record.state = .complete; record.message = "略過；來源保留"; await session?.close(); report(force: true); return record
                    }
                    record.destination = target; if record.sameSideOperation != nil { try await validateSameSide() }; record.rootPrepared = true; report(force: true)
                }
                if record.sameSideOperation == .move {
                    try check()
                    if record.direction == .remoteCopy { try await session!.rename(record.source, to: record.destination) }
                    else { try LocalFiles.atomicRename(record.source, to: record.destination, overwrite: false) }
                    guard try await targetAttributes(record.destination) != nil else { throw TransferError.message("移動後目的地讀回失敗") }
                    record.state = .complete; record.message = "移動完成"; await session?.close(); report(force: true); return record
                }
            }
            if record.items.isEmpty {
                record.items = try await enumerate(record.source, relative: "")
                record.total = record.items.filter { $0.kind == .file }.reduce(0) { $0 + ($1.attributes.size ?? 0) }
                report(force: true)
            }
            for item in record.items {
                try check(); record.message = item.source; report()
                let destination = item.relativePath.isEmpty ? record.destination : RemotePath.join(record.destination, item.relativePath)
                if item.kind == .directory {
                    if let existing = try await targetAttributes(destination) {
                        if record.noOverwriteCopy == true && item.relativePath.isEmpty && record.crossRootCreated != true { throw TransferError.message("目的資料夾在準備後出現，拒絕合併") }
                        guard existing.kind == .directory else { throw TransferError.message("目的地存在同名非資料夾：\(destination)") } }
                    else { try await makeTargetDirectory(destination) }
                    if record.noOverwriteCopy == true && item.relativePath.isEmpty { record.crossRootCreated = true; report(force: true) }
                } else if item.kind == .symlink { try await transferLink(item, destination: destination) }
                else { try await transferFile(item, destination: destination) }
            }
            if record.options.preserveTime || record.options.preservePermissions {
                for item in record.items.reversed() where item.kind == .directory { try await applyMetadata(item.attributes, to: item.relativePath.isEmpty ? record.destination : RemotePath.join(record.destination, item.relativePath)) }
            }
            await session?.close(); record.state = .complete; record.message = (record.skippedCount ?? 0) == 0 ? "內容校驗完成" : "完成；略過 \(record.skippedCount ?? 0) 項"; report(force: true); return record
        } catch { await session?.close(); throw error }
    }
    private func validateSameSide(allowSameTarget: Bool = false) async throws {
        let source: String, parent: String
        if record.direction == .remoteCopy {
            let attr = try await session!.attributes(record.source)
            if attr.kind == .symlink { source = RemotePath.join(try await session!.canonical(RemotePath.parent(record.source)), (record.source as NSString).lastPathComponent) }
            else { source = try await session!.canonical(record.source) }
            parent = try await session!.canonical(RemotePath.parent(record.destination))
        } else {
            let attr = try LocalFiles.attributes(record.source)
            if attr.kind == .symlink { source = RemotePath.join(URL(fileURLWithPath: RemotePath.parent(record.source)).resolvingSymlinksInPath().standardizedFileURL.path, (record.source as NSString).lastPathComponent) }
            else { source = URL(fileURLWithPath: record.source).resolvingSymlinksInPath().standardizedFileURL.path }
            parent = URL(fileURLWithPath: RemotePath.parent(record.destination)).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let target = RemotePath.join(parent, (record.destination as NSString).lastPathComponent)
        guard (allowSameTarget || target != source), !target.hasPrefix(source + "/"), RemotePath.isSafeMutation(record.source), RemotePath.isSafeMutation(target) else { throw TransferError.message("目的地不可是來源本身或子目錄") }
    }
    private func remoteBytes(_ source: String, staging: String, offset start: UInt64, size: UInt64) async throws {
        let input = try await session!.openFile(source, flags: 1)
        let exists = try await session!.exists(staging) != nil
        let output = try await session!.openFile(staging, flags: exists ? 2 : (2 | 8 | 32))
        do {
            var offset = start
            while offset < size {
                try check(); let data = try await session!.read(input, offset: offset, count: UInt32(min(32768, size - offset)))
                guard !data.isEmpty else { throw TransferError.message("來源檔案提早結束") }
                try await session!.write(output, offset: offset, data: data); offset += UInt64(data.count); try await progress(UInt64(data.count))
            }
            try await session!.closeHandle(input); try await session!.closeHandle(output)
        } catch { try? await session!.closeHandle(input); try? await session!.closeHandle(output); throw error }
    }
    private func enumerate(_ path: String, relative: String) async throws -> [TransferItem] {
        try check()
        let attr = try await sourceAttributes(path)
        var result = [TransferItem(relativePath: relative, source: path, kind: attr.kind, attributes: attr)]
        if attr.kind == .directory {
            let children = [.download, .remoteCopy].contains(record.direction) ? try await session!.list(path) : try LocalFiles.list(path)
            for child in children { result += try await enumerate(child.path, relative: relative.isEmpty ? child.name : RemotePath.join(relative, child.name)) }
        }
        return result
    }
    private func sourceAttributes(_ path: String) async throws -> FileAttributes { [.download, .remoteCopy].contains(record.direction) ? try await session!.attributes(path) : try LocalFiles.attributes(path) }
    private func targetAttributes(_ path: String) async throws -> FileAttributes? { [.upload, .remoteCopy].contains(record.direction) ? try await session!.exists(path) : try LocalFiles.exists(path) }
    private func makeTargetDirectory(_ path: String) async throws {
        if [.upload, .remoteCopy].contains(record.direction) { try await session!.mkdir(path) } else { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
    }
    private func sourceHash(_ path: String, length: UInt64? = nil) async throws -> String {
        if [.download, .remoteCopy].contains(record.direction) { return try await session!.hash(path, length: length) }
        return try LocalFiles.hash(path, length: length)
    }
    private func targetHash(_ path: String, length: UInt64? = nil) async throws -> String {
        if [.upload, .remoteCopy].contains(record.direction) { return try await session!.hash(path, length: length) }
        return try LocalFiles.hash(path, length: length)
    }
    private func resolve(_ item: TransferItem, destination: String) async throws -> (String, Bool)? {
        guard let existing = try await targetAttributes(destination) else { return (destination, false) }
        var policy = record.options.policy
        if policy == .ask {
            record.state = .decision; report(force: true)
            let result = try await conflict(TransferConflict(taskID: record.id, source: item.source, destination: destination, sourceAttributes: item.attributes, destinationAttributes: existing, safeOnly: record.sameSideOperation != nil || record.noOverwriteCopy == true))
            policy = result.policy
            record.state = .running; report(force: true)
        }
        try check()
        if (record.sameSideOperation != nil || record.noOverwriteCopy == true) && ![CollisionPolicy.skip,.rename].contains(policy) { throw TransferError.message("同端操作僅允許略過或另取名稱") }
        switch policy {
        case .skip: return nil
        case .rename:
            var number = 1, alternative: String
            repeat { alternative = destination + " (\(number))"; number += 1 } while try await targetAttributes(alternative) != nil
            return (alternative, false)
        case .newer:
            guard let sourceTime = item.attributes.modificationTime, let targetTime = existing.modificationTime else { throw TransferError.message("時間資訊不足，不能判定較新檔案") }
            if sourceTime <= targetTime { return nil }
            fallthrough
        case .overwrite:
            guard existing.kind != .directory else { throw TransferError.message("不會以檔案覆蓋資料夾：\(destination)") }
            return (destination, true)
        case .ask: throw CancellationError()
        }
    }
    private func transferFile(_ item: TransferItem, destination: String) async throws {
        let attrs = try await sourceAttributes(item.source)
        record.currentFileBytes = 0; record.currentFileSize = attrs.size
        guard attrs.kind == .file else { throw TransferError.message("來源種類已改變：\(item.source)") }
        let fingerprint = SourceFingerprint(size: attrs.size ?? 0, modificationTime: attrs.modificationTime, sha256: try await sourceHash(item.source))
        if let expected = record.expectedSourceHash, expected != fingerprint.sha256 { throw TransferError.message("預覽後來源已修改，請重新掃描") }
        if let prior = record.checkpoints[item.relativePath] {
            guard prior.source == fingerprint else { throw TransferError.message("來源已改變，不能續傳；請建立新傳輸。\(item.source)") }
            if prior.completed, let attr = try await targetAttributes(prior.destination), attr.kind == .file, attr.size == fingerprint.size, try await targetHash(prior.destination) == fingerprint.sha256 {
                record.transferred += fingerprint.size; report(); return
            }
        }
        guard let (target, overwrite) = try await resolve(item, destination: record.checkpoints[item.relativePath]?.destination ?? destination) else { record.skippedCount = (record.skippedCount ?? 0) + 1; record.transferred += fingerprint.size; report(); return }
        let originalTarget = record.direction == .upload && overwrite ? try await targetAttributes(target) : nil
        let staging = record.checkpoints[item.relativePath]?.staging ?? RemotePath.join(RemotePath.parent(target), ".minascp-\(record.id.uuidString)-\(SHA256.hash(data: Data(item.relativePath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())")
        record.checkpoints[item.relativePath] = FileCheckpoint(source: fingerprint, staging: staging, destination: target)
        report(force: true)
        var offset: UInt64 = 0
        if let partial = try await targetAttributes(staging) {
            guard partial.kind == .file, (partial.size ?? UInt64.max) <= fingerprint.size else { throw TransferError.message("部分檔案種類或長度不符，已保留：\(staging)") }
            offset = partial.size ?? 0
            guard try await targetHash(staging, length: offset) == sourceHash(item.source, length: offset) else { throw TransferError.message("部分檔案校驗不符，已保留：\(staging)") }
        }
        record.currentFileBytes = offset
        record.transferred += offset
        switch record.direction {
        case .upload: try await uploadBytes(item.source, staging: staging, offset: offset, size: fingerprint.size)
        case .download: try await downloadBytes(item.source, staging: staging, offset: offset, size: fingerprint.size)
        case .remoteCopy: try await remoteBytes(item.source, staging: staging, offset: offset, size: fingerprint.size)
        case .local: try await localBytes(item.source, staging: staging, offset: offset, size: fingerprint.size)
        }
        try check()
        guard try await sourceHash(item.source) == fingerprint.sha256, try await targetHash(staging) == fingerprint.sha256 else { throw TransferError.message("傳輸內容校驗失敗或來源已變更；暫存檔已保留") }
        if let expected = record.expectedDestinationHash {
            guard let targetAttributes = try await targetAttributes(target), targetAttributes.kind == .file, try await targetHash(target) == expected else { throw EditConflict() }
        }
        try await applyMetadata(attrs, to: staging)
        if record.direction == .upload && overwrite {
            guard let original = originalTarget, original.kind == .file,
                  let uid = original.uid, let gid = original.gid, let permissions = original.permissions else {
                throw TransferError.message("無法取得遠端原檔擁有者與權限；原檔與暫存檔已保留")
            }
            do {
                guard let current = try await targetAttributes(target), current.kind == original.kind, current.uid == original.uid, current.gid == original.gid,
                      current.permissions == original.permissions, current.size == original.size,
                      current.modificationTime == original.modificationTime else {
                    throw TransferError.message("上傳期間遠端屬性已變更，請重新確認覆蓋")
                }
                let staged = try await session!.attributes(staging)
                if staged.uid != uid || staged.gid != gid {
                    try await session!.setAttributes(staging, FileAttributes(uid: uid, gid: gid))
                }
                // chown may clear setuid/setgid: restore the full mode afterwards.
                try await session!.setAttributes(staging, FileAttributes(permissions: permissions & 0o7777))
                let verified = try await session!.attributes(staging)
                guard verified.uid == uid, verified.gid == gid,
                      verified.permissions.map({ $0 & 0o7777 }) == permissions & 0o7777 else {
                    throw TransferError.message("遠端屬性讀回不符")
                }
            } catch {
                throw TransferError.message("無法保留遠端原檔擁有者與權限，未覆蓋原檔：\(error.localizedDescription)")
            }
        }
        if [.upload, .remoteCopy].contains(record.direction) { try await session!.rename(staging, to: target, overwrite: overwrite) }
        else { try LocalFiles.atomicRename(staging, to: target, overwrite: overwrite) }
        record.checkpoints[item.relativePath]?.completed = true; report(force: true)
    }
    private func uploadBytes(_ source: String, staging: String, offset start: UInt64, size: UInt64) async throws {
        let local = try FileHandle(forReadingFrom: URL(fileURLWithPath: source)); defer { try? local.close() }
        try local.seek(toOffset: start)
        let exists = try await session!.exists(staging) != nil
        let handle = try await session!.openFile(staging, flags: exists ? 2 : (2 | 8 | 32))
        do {
            var offset = start
            while offset < size {
                try check(); let data = try local.read(upToCount: Int(min(32768, size - offset))) ?? Data()
                guard !data.isEmpty else { throw TransferError.message("來源檔案提早結束") }
                try await session!.write(handle, offset: offset, data: data); offset += UInt64(data.count); try await progress(UInt64(data.count))
            }
            try await session!.closeHandle(handle)
        } catch { try? await session!.closeHandle(handle); throw error }
    }
    private func downloadBytes(_ source: String, staging: String, offset start: UInt64, size: UInt64) async throws {
        if try LocalFiles.exists(staging) == nil { guard FileManager.default.createFile(atPath: staging, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TransferError.message("無法建立暫存檔") } }
        let local = try FileHandle(forWritingTo: URL(fileURLWithPath: staging)); defer { try? local.close() }
        try local.seek(toOffset: start)
        let handle = try await session!.openFile(source, flags: 1)
        do {
            var offset = start
            while offset < size {
                try check(); let data = try await session!.read(handle, offset: offset, count: UInt32(min(32768, size - offset)))
                guard !data.isEmpty else { throw TransferError.message("遠端檔案提早結束") }
                try local.write(contentsOf: data); offset += UInt64(data.count); try await progress(UInt64(data.count))
            }
            try local.synchronize(); try await session!.closeHandle(handle)
        } catch { try? await session!.closeHandle(handle); throw error }
    }
    private func localBytes(_ source: String, staging: String, offset start: UInt64, size: UInt64) async throws {
        if try LocalFiles.exists(staging) == nil { guard FileManager.default.createFile(atPath: staging, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TransferError.message("無法建立暫存檔") } }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source)), output = try FileHandle(forWritingTo: URL(fileURLWithPath: staging))
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: start); try output.seek(toOffset: start)
        var offset = start
        while offset < size {
            try check(); let data = try input.read(upToCount: Int(min(32768, size - offset))) ?? Data()
            guard !data.isEmpty else { throw TransferError.message("來源檔案提早結束") }; try output.write(contentsOf: data); offset += UInt64(data.count); try await progress(UInt64(data.count))
        }
        try output.synchronize()
    }
    private func transferLink(_ item: TransferItem, destination: String) async throws {
        if record.noOverwriteCopy == true, let prior = record.linkTargets?[item.relativePath], let attr = try await targetAttributes(destination), attr.kind == .symlink {
            let actual = try await session!.readlink(destination)
            if actual == prior { return }
        }
        guard let (target, overwrite) = try await resolve(item, destination: destination) else { record.skippedCount = (record.skippedCount ?? 0) + 1; return }
        let link = [.download, .remoteCopy].contains(record.direction) ? try await session!.readlink(item.source) : try FileManager.default.destinationOfSymbolicLink(atPath: item.source)
        record.linkTargets = (record.linkTargets ?? [:]).merging([item.relativePath: link]) { _, new in new }
        let staging = RemotePath.join(RemotePath.parent(target), ".minascp-link-" + UUID().uuidString)
        if [.upload, .remoteCopy].contains(record.direction) { try await session!.symlink(link, at: staging); try await session!.rename(staging, to: target, overwrite: overwrite) }
        else { try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: link); try LocalFiles.atomicRename(staging, to: target, overwrite: overwrite) }
    }
    private func applyMetadata(_ attributes: FileAttributes, to path: String) async throws {
        if [.upload, .remoteCopy].contains(record.direction) {
            var attr = FileAttributes()
            if record.options.preserveTime { attr.accessTime = attributes.accessTime; attr.modificationTime = attributes.modificationTime }
            if record.options.preservePermissions { attr.permissions = attributes.permissions.map { $0 & 0o777 } }
            if attr != FileAttributes() { try await session!.setAttributes(path, attr) }
        } else {
            var attr: [FileAttributeKey: Any] = [:]
            if record.options.preserveTime, let time = attributes.modificationTime { attr[.modificationDate] = Date(timeIntervalSince1970: Double(time)) }
            if record.options.preservePermissions, let mode = attributes.permissions { attr[.posixPermissions] = mode & 0o777 }
            if !attr.isEmpty { try FileManager.default.setAttributes(attr, ofItemAtPath: path) }
        }
    }
}
