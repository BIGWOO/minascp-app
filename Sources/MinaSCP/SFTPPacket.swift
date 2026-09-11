import Foundation

struct SFTPFailure: LocalizedError, Equatable {
    let code: UInt32
    let message: String
    var errorDescription: String? { "SFTP \(code)：\(message)" }
    static func protocolError(_ message: String) -> SFTPFailure { SFTPFailure(code: 5, message: message) }
}
struct PacketWriter {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) { data.append(contentsOf: [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    mutating func uint64(_ value: UInt64) { uint32(UInt32(value >> 32)); uint32(UInt32(truncatingIfNeeded: value)) }
    mutating func bytes(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    static func frame(_ body: Data) -> Data { var p = PacketWriter(); p.uint32(UInt32(body.count)); p.data.append(body); return p.data }
}
struct PacketReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SFTPFailure.protocolError("封包被截斷") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uint32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { let high = try uint32(), low = try uint32(); return UInt64(high) << 32 | UInt64(low) }
    mutating func bytes() throws -> Data { let count = try uint32(); guard count <= 16 * 1024 * 1024 else { throw SFTPFailure.protocolError("欄位超過大小限制") }; return try take(Int(count)) }
    mutating func string() throws -> String {
        guard let text = String(data: try bytes(), encoding: .utf8), !text.contains("\0") else { throw SFTPFailure.protocolError("伺服器傳回非 UTF-8 或含 NUL 的字串；已停止，避免操作錯誤檔名") }
        return text
    }
    mutating func attributes() throws -> FileAttributes {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPFailure.protocolError("未知的檔案屬性旗標") }
        var result = FileAttributes()
        if flags & 1 != 0 { result.size = try uint64() }
        if flags & 2 != 0 { result.uid = try uint32(); result.gid = try uint32() }
        if flags & 4 != 0 { result.permissions = try uint32() }
        if flags & 8 != 0 { result.accessTime = try uint32(); result.modificationTime = try uint32() }
        if flags & 0x80000000 != 0 {
            let count = try uint32(); guard count <= 1024 else { throw SFTPFailure.protocolError("延伸屬性數量異常") }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        return result
    }
}
struct PacketFramer {
    private var buffer = Data()
    let maximumSize = 16 * 1024 * 1024
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var packets: [Data] = []
        while buffer.count >= 4 {
            let size = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard size > 0, size <= maximumSize else { throw SFTPFailure.protocolError("無效封包長度 \(size)") }
            guard buffer.count >= size + 4 else { break }
            packets.append(buffer.subdata(in: 4..<(size + 4)))
            buffer = Data(buffer.dropFirst(size + 4))
        }
        return packets
    }
}
struct FileAttributes: Codable, Hashable, Sendable {
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modificationTime: UInt32?
    var kind: FileKind { switch (permissions ?? 0) & 0o170000 { case 0o040000: return .directory; case 0o120000: return .symlink; default: return .file } }
    var encoded: Data {
        var p = PacketWriter(), flags: UInt32 = 0
        if size != nil { flags |= 1 }; if uid != nil && gid != nil { flags |= 2 }; if permissions != nil { flags |= 4 }; if accessTime != nil && modificationTime != nil { flags |= 8 }
        p.uint32(flags)
        if let size { p.uint64(size) }; if flags & 2 != 0 { p.uint32(uid!); p.uint32(gid!) }; if let permissions { p.uint32(permissions) }; if flags & 8 != 0 { p.uint32(accessTime!); p.uint32(modificationTime!) }
        return p.data
    }
}
enum FileKind: String, Codable, Sendable { case file, directory, symlink }
