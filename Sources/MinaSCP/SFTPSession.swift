import Foundation
import CryptoKit

struct SFTPResponse: Sendable { let type: UInt8; let payload: Data }
actor SFTPSession {
    let connection: Connection
    private var channel: SSHChannel?
    private let captureInfo: Bool
    private var readerTask: Task<Void, Never>?
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var timers: [UInt32: Task<Void, Never>] = [:]
    private var nextID: UInt32 = 1
    private var framer = PacketFramer()
    private(set) var extensions: [String: String] = [:]
    private(set) var ready = false
    init(connection: Connection, captureInfo: Bool = false) { self.connection = connection; self.captureInfo = captureInfo }
    static func open(_ connection: Connection, captureInfo: Bool = false) async throws -> SFTPSession {
        let session = SFTPSession(connection: connection, captureInfo: captureInfo)
        do { try await session.start(); return session } catch { await session.close(); throw error }
    }
    private func start() async throws {
        let channel = try SSHChannel(connection: connection, captureInfo: captureInfo); self.channel = channel
        readerTask = Task { [weak self, stream = channel.stream] in
            do { for try await bytes in stream { guard let self else { break }; try await self.receive(bytes) } }
            catch { await self?.fail(error) }
        }
        var p = PacketWriter(); p.byte(1); p.uint32(3)
        let response = try await waitFor(id: 0, frame: PacketWriter.frame(p.data), timeout: max(30, connection.timeout + 120))
        guard response.type == 2 else { throw SFTPFailure.protocolError("未收到 SFTP 版本") }
        var r = PacketReader(data: response.payload)
        guard try r.uint32() == 3 else { throw SFTPFailure.protocolError("伺服器未協商 SFTP v3") }
        while r.remaining > 0 { let name = try r.string(); extensions[name] = try r.string() }
        ready = true
    }
    func connectionInfo() -> ConnectionInfo {
        ConnectionInfo(host: connection.host, port: connection.port, user: connection.user, sftpVersion: 3, ssh: channel?.negotiation ?? SSHNegotiation(), extensions: extensions, capturedAt: Date())
    }
    private func receive(_ bytes: Data) throws {
        for packet in try framer.append(bytes) {
            var r = PacketReader(data: packet)
            let type = try r.byte(), id: UInt32
            if type == 2 { id = 0 } else { id = try r.uint32() }
            if let continuation = pending.removeValue(forKey: id) {
                timers.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: SFTPResponse(type: type, payload: try r.take(r.remaining)))
            }
        }
    }
    private func fail(_ error: Error) {
        ready = false
        let requests = pending; pending.removeAll()
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        requests.values.forEach { $0.resume(throwing: error) }
        channel?.stop(); channel = nil
    }
    func close() { fail(CancellationError()); readerTask?.cancel(); readerTask = nil }
    private func cancelRequest(_ id: UInt32, error: Error = CancellationError()) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func waitFor(id: UInt32, frame: Data, timeout: Int) async throws -> SFTPResponse {
        try Task.checkCancellation()
        guard let channel else { throw SFTPFailure(code: 6, message: "連線未開啟") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)); await self?.cancelRequest(id, error: SFTPFailure(code: 7, message: "請求逾時")) } catch { }
                }
                Task { [weak self] in
                    do { try await channel.write(frame) } catch { await self?.cancelRequest(id, error: error) }
                }
            }
        } onCancel: { Task { await self.cancelRequest(id) } }
    }
    private func exchange(_ type: UInt8, _ body: Data) async throws -> SFTPResponse {
        guard ready else { throw SFTPFailure(code: 6, message: "連線已中斷，請重新連線") }
        let id = nextID; nextID &+= 1; if nextID == 0 { nextID = 1 }
        guard pending[id] == nil else { throw SFTPFailure.protocolError("請求編號衝突") }
        var p = PacketWriter(); p.byte(type); p.uint32(id); p.data.append(body)
        let response = try await waitFor(id: id, frame: PacketWriter.frame(p.data), timeout: max(5, connection.timeout))
        if response.type == 101 {
            var r = PacketReader(data: response.payload); let code = try r.uint32(), message = try r.string()
            if code != 0 { throw SFTPFailure(code: code, message: message) }
        }
        return response
    }
    private func pathPacket(_ path: String) throws -> Data {
        guard !path.isEmpty, !path.contains("\0") else { throw SFTPFailure.protocolError("路徑為空或含 NUL") }
        var p = PacketWriter(); p.string(path); return p.data
    }
    private func expect(_ response: SFTPResponse, type: UInt8) throws -> PacketReader {
        guard response.type == type else { throw SFTPFailure.protocolError("預期回應 \(type)，收到 \(response.type)") }
        return PacketReader(data: response.payload)
    }
    func canonical(_ path: String) async throws -> String {
        let response = try await exchange(16, pathPacket(path))
        var r = try expect(response, type: 104); guard try r.uint32() > 0 else { throw SFTPFailure.protocolError("無法解析路徑") }; return try r.string()
    }
    func attributes(_ path: String, followLink: Bool = false) async throws -> FileAttributes {
        let response = try await exchange(followLink ? 17 : 7, pathPacket(path))
        var r = try expect(response, type: 105); return try r.attributes()
    }
    func exists(_ path: String) async throws -> FileAttributes? {
        do { return try await attributes(path) } catch let error as SFTPFailure where error.code == 2 { return nil }
    }
    func list(_ path: String) async throws -> [Entry] {
        let response = try await exchange(11, pathPacket(path))
        var r = try expect(response, type: 102); let handle = try r.bytes()
        var p = PacketWriter(); p.bytes(handle)
        var entries: [Entry] = []
        do {
            while true {
                try Task.checkCancellation()
                let result: SFTPResponse
                do { result = try await exchange(12, p.data) } catch let error as SFTPFailure where error.code == 1 { break }
                var names = try expect(result, type: 104); let count = try names.uint32()
                guard count <= 100_000 else { throw SFTPFailure.protocolError("目錄回應筆數異常") }
                if count == 0 { break }
                for _ in 0..<count {
                    let name = try names.string(); _ = try names.bytes(); let attributes = try names.attributes()
                    guard name != ".", name != ".." else { continue }
                    guard !name.contains("/") else { throw SFTPFailure.protocolError("檔名含分隔符號") }
                    entries.append(Entry(name: name, path: RemotePath.join(path, name), attributes: attributes))
                }
            }
            try await closeHandle(handle); return entries.sorted(by: Entry.nameOrder)
        } catch { try? await closeHandle(handle); throw error }
    }
    func openFile(_ path: String, flags: UInt32, permissions: UInt32 = 0o600) async throws -> Data {
        var p = PacketWriter(); p.string(path); p.uint32(flags); p.data.append(FileAttributes(permissions: permissions).encoded)
        var r = try expect(try await exchange(3, p.data), type: 102); return try r.bytes()
    }
    func closeHandle(_ handle: Data) async throws { var p = PacketWriter(); p.bytes(handle); _ = try expect(try await exchange(4, p.data), type: 101) }
    func read(_ handle: Data, offset: UInt64, count: UInt32 = 32768) async throws -> Data {
        var p = PacketWriter(); p.bytes(handle); p.uint64(offset); p.uint32(min(count, 32768))
        do { var r = try expect(try await exchange(5, p.data), type: 103); return try r.bytes() }
        catch let error as SFTPFailure where error.code == 1 { return Data() }
    }
    func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        guard data.count <= 32768 else { throw SFTPFailure.protocolError("寫入區塊過大") }
        var p = PacketWriter(); p.bytes(handle); p.uint64(offset); p.bytes(data)
        _ = try expect(try await exchange(6, p.data), type: 101)
    }
    func mkdir(_ path: String) async throws { var p = PacketWriter(); p.string(path); p.data.append(FileAttributes(permissions: 0o755).encoded); _ = try expect(try await exchange(14, p.data), type: 101) }
    func remove(_ path: String, directory: Bool = false) async throws { _ = try expect(try await exchange(directory ? 15 : 13, pathPacket(path)), type: 101) }
    func rename(_ source: String, to destination: String, overwrite: Bool = false) async throws {
        var p = PacketWriter()
        if overwrite {
            guard extensions["posix-rename@openssh.com"] != nil else { throw SFTPFailure(code: 8, message: "伺服器不支援原子覆蓋；已保留暫存檔") }
            p.string("posix-rename@openssh.com")
        }
        p.string(source); p.string(destination)
        _ = try expect(try await exchange(overwrite ? 200 : 18, p.data), type: 101)
    }
    func setAttributes(_ path: String, _ attributes: FileAttributes) async throws {
        var p = PacketWriter(); p.string(path); p.data.append(attributes.encoded)
        _ = try expect(try await exchange(9, p.data), type: 101)
    }
    func setAttributesNoFollow(_ path: String, _ attributes: FileAttributes) async throws {
        guard try await self.attributes(path).kind != .symlink else { throw TransferError.message("不修改符號連結") }
        if extensions["lsetstat@openssh.com"] != nil {
            var p = PacketWriter(); p.string("lsetstat@openssh.com"); p.string(path); p.data.append(attributes.encoded)
            _ = try expect(try await exchange(200, p.data), type: 101)
        } else { try await setAttributes(path, attributes) }
    }
    func readlink(_ path: String) async throws -> String {
        var r = try expect(try await exchange(19, pathPacket(path)), type: 104)
        guard try r.uint32() > 0 else { throw SFTPFailure.protocolError("連結沒有目標") }; return try r.string()
    }
    func symlink(_ target: String, at path: String) async throws {
        // OpenSSH uses target, linkpath order (opposite the original v3 draft).
        var p = PacketWriter(); p.string(target); p.string(path)
        _ = try expect(try await exchange(20, p.data), type: 101)
    }
    func hash(_ path: String, length: UInt64? = nil) async throws -> String {
        let handle = try await openFile(path, flags: 1)
        do {
            var digest = SHA256(), offset: UInt64 = 0
            while length == nil || offset < length! {
                try Task.checkCancellation()
                let count = UInt32(min(UInt64(32768), length.map { $0 - offset } ?? 32768))
                let bytes = try await read(handle, offset: offset, count: count)
                if bytes.isEmpty { break }; digest.update(data: bytes); offset += UInt64(bytes.count)
            }
            if let length, offset != length { throw SFTPFailure(code: 4, message: "校驗時來源長度改變") }
            try await closeHandle(handle)
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { try? await closeHandle(handle); throw error }
    }
    func removeTree(_ path: String) async throws {
        guard RemotePath.isSafeMutation(path) else { throw SFTPFailure(code: 3, message: "禁止刪除根目錄或不明路徑") }
        let attr = try await attributes(path)
        if attr.kind == .directory { for item in try await list(path) { try await removeTree(item.path) }; try await remove(path, directory: true) }
        else { try await remove(path) }
    }
}
