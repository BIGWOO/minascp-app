import Foundation

enum MoveSafety {
    static func validate(_ record: TransferTask) async throws {
        guard record.state == .complete, (record.skippedCount ?? 0) == 0 else { throw TransferError.message("傳輸未完整完成或有略過項目，不能移除來源") }
        let session = try await SFTPSession.open(record.connection)
        do {
            var found = Set<String>()
            func walk(_ path: String, relative: String) async throws {
                let attr = record.direction == .download ? try await session.attributes(path) : try LocalFiles.attributes(path)
                guard let item = record.items.first(where: { $0.relativePath == relative }), item.kind == attr.kind else { throw TransferError.message("來源新增或種類已改變：" + path) }
                found.insert(relative)
                let target = relative.isEmpty ? record.destination : RemotePath.join(record.destination, relative)
                if attr.kind == .directory {
                    let entries = record.direction == .download ? try await session.list(path) : try LocalFiles.list(path)
                    for entry in entries { try await walk(entry.path, relative: relative.isEmpty ? entry.name : RemotePath.join(relative, entry.name)) }
                } else if attr.kind == .file {
                    guard let checkpoint = record.checkpoints[relative], checkpoint.completed else { throw TransferError.message("缺少完成校驗：" + path) }
                    let sourceHash = record.direction == .download ? try await session.hash(path) : try LocalFiles.hash(path)
                    let targetHash = record.direction == .upload ? try await session.hash(checkpoint.destination) : try LocalFiles.hash(checkpoint.destination)
                    guard sourceHash == checkpoint.source.sha256, targetHash == sourceHash else { throw TransferError.message("來源或目的地已修改：" + path) }
                } else {
                    let source = record.direction == .download ? try await session.readlink(path) : try FileManager.default.destinationOfSymbolicLink(atPath: path)
                    let destination = record.direction == .upload ? try await session.readlink(target) : try FileManager.default.destinationOfSymbolicLink(atPath: target)
                    guard source == record.linkTargets?[relative], destination == source else { throw TransferError.message("符號連結已改變：" + path) }
                }
            }
            try await walk(record.source, relative: "")
            guard found == Set(record.items.map(\.relativePath)) else { throw TransferError.message("來源清單已改變") }
            await session.close()
        } catch { await session.close(); throw error }
    }
}
