import Foundation
import CryptoKit
import Darwin

enum LocalFiles {
    static func attributes(_ path: String) throws -> FileAttributes {
        let a = try FileManager.default.attributesOfItem(atPath: path)
        let type = a[.type] as? FileAttributeType
        let bits: UInt32 = type == .typeDirectory ? 0o040000 : type == .typeSymbolicLink ? 0o120000 : 0o100000
        return FileAttributes(size: (a[.size] as? NSNumber)?.uint64Value, uid: (a[.ownerAccountID] as? NSNumber)?.uint32Value, gid: (a[.groupOwnerAccountID] as? NSNumber)?.uint32Value, permissions: bits | ((a[.posixPermissions] as? NSNumber)?.uint32Value ?? 0), accessTime: UInt32(clamping: Int64((a[.modificationDate] as? Date ?? .distantPast).timeIntervalSince1970)), modificationTime: UInt32(clamping: Int64((a[.modificationDate] as? Date ?? .distantPast).timeIntervalSince1970)))
    }
    static func exists(_ path: String) throws -> FileAttributes? {
        do { return try attributes(path) } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
    }
    static func list(_ path: String) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(atPath: path).map { name in let full = (path as NSString).appendingPathComponent(name); return Entry(name: name, path: full, attributes: try listingAttributes(full)) }.sorted(by: Entry.nameOrder)
    }
    // Directory listings need only POSIX metadata. Foundation also fetches extended
    // attributes, which can block on offline File Provider items in the home folder.
    static func listingAttributes(_ path: String) throws -> FileAttributes {
        var metadata = stat()
        guard path.withCString({ lstat($0, &metadata) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileAttributes(size: UInt64(max(0, metadata.st_size)), uid: metadata.st_uid, gid: metadata.st_gid,
                              permissions: UInt32(metadata.st_mode), accessTime: UInt32(clamping: metadata.st_atimespec.tv_sec),
                              modificationTime: UInt32(clamping: metadata.st_mtimespec.tv_sec))
    }
    static func hash(_ path: String, length: UInt64? = nil) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        var digest = SHA256(), offset: UInt64 = 0
        while length == nil || offset < length! {
            try Task.checkCancellation()
            let count = Int(min(UInt64(1024 * 1024), length.map { $0 - offset } ?? (1024 * 1024)))
            let bytes = try file.read(upToCount: count) ?? Data()
            if bytes.isEmpty { break }; digest.update(data: bytes); offset += UInt64(bytes.count)
        }
        if let length, offset != length { throw TransferError.message("校驗時本機來源長度改變") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func atomicRename(_ source: String, to target: String, overwrite: Bool) throws {
        let result = source.withCString { a in target.withCString { b in renamex_np(a, b, overwrite ? 0 : UInt32(RENAME_EXCL)) } }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func safeName(_ name: String) throws {
        guard RemotePath.validName(name) else { throw TransferError.message("名稱不可為空、.、..，或含 / 與 NUL") }
    }
}
