import Foundation
import SwiftUI
import Security
import CryptoKit
import Darwin

struct AuthPrompt: Identifiable {
    let id = UUID()
    let connection: Connection
    let question: String
    let confirmation: Bool
    let canRemember: Bool
    let account: String
}
enum CredentialStore {
    static func account(_ c: Connection, question: String) -> String {
        // Separate private-key passphrases from login passwords. OTP prompts are never cached.
        let kind = question.lowercased().contains("passphrase") ? "key:\(c.identity)" : "password"
        return "\(c.user)@\(c.host):\(c.port):\(kind)"
    }
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mina.scp", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mina.scp", kSecAttrAccount as String: account]
        let fields: [String: Any] = [kSecValueData as String: Data(secret.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw TransferError.message("Keychain 儲存失敗（\(status)）") }
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mina.scp", kSecAttrAccount as String: account] as CFDictionary)
    }
}
final class AskPassServer: @unchecked Sendable {
    let endpoint: String
    private let fd: Int32
    private let directory: String
    private let handler: @Sendable (String, String) async -> String?
    init(handler: @escaping @Sendable (String, String) async -> String?) throws {
        self.handler = handler
        directory = "/tmp/mscp-\(getuid())-\(UUID().uuidString.prefix(12))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        endpoint = directory + "/auth"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = endpoint
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8CString.withUnsafeBytes { memcpy(bytes.baseAddress!, $0.baseAddress!, $0.count) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        chmod(endpoint, 0o600)
        let listener = fd
        DispatchQueue.global(qos: .utility).async { [handler] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); continue }
                DispatchQueue.global(qos: .utility).async {
                    var noSignal: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    var timeout = timeval(tv_sec: 130, tv_usec: 0); setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    guard let header = Self.read(client, count: 4) else { Darwin.close(client); return }
                    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard size <= 8192, let data = Self.read(client, count: Int(size)), let request = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { Darwin.close(client); return }
                    Task {
                        let answer = await handler(request["prompt"] ?? "SSH 驗證", request["hint"] ?? "")
                        let reply = (try? JSONSerialization.data(withJSONObject: answer.map { ["answer": $0] } ?? [:])) ?? Data("{}".utf8)
                        var p = PacketWriter(); p.bytes(reply)
                        _ = p.data.withUnsafeBytes { raw -> Bool in
                            var offset = 0
                            while offset < raw.count { let n = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset); if n <= 0 { return false }; offset += n }; return true
                        }
                        Darwin.close(client)
                    }
                }
            }
        }
    }
    private static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            while offset < count { let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset); if n <= 0 { return false }; offset += n }; return true
        }
        return ok ? data : nil
    }
    deinit { shutdown(fd, SHUT_RDWR); Darwin.close(fd); try? FileManager.default.removeItem(atPath: directory) }
}
@MainActor final class AuthenticationCenter: ObservableObject {
    @Published var prompts: [AuthPrompt] = []
    @Published var error: String?
    private var servers: [String: AskPassServer] = [:]
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var attemptedCache = Set<String>()
    func prepare(_ connection: Connection) throws -> Connection {
        if connection.fixture { return connection }
        guard FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MinaSCPAskPass").path) else { return connection }
        let key = "\(connection.user)@\(connection.host):\(connection.port):\(connection.identity):\(connection.jumpHost)"
        if servers[key] == nil { servers[key] = try AskPassServer { [weak self] question, hint in guard let self else { return nil }; return await self.ask(connection, question: question, hint: hint) } }
        var c = connection; c.askPassEndpoint = servers[key]?.endpoint; return c
    }
    private func ask(_ connection: Connection, question: String, hint: String) async -> String? {
        let lower = question.lowercased()
        let confirmation = hint == "confirm" || lower.contains("yes/no")
        let canRemember = !confirmation && (lower.contains("password") || lower.contains("passphrase")) && !lower.contains("verification") && !lower.contains("one-time") && !lower.contains("otp") && !lower.contains("code") && !lower.contains("token")
        let account = CredentialStore.account(connection, question: question)
        if canRemember, !attemptedCache.contains(account), let stored = CredentialStore.read(account) { attemptedCache.insert(account); return stored }
        let prompt = AuthPrompt(connection: connection, question: question, confirmation: confirmation, canRemember: canRemember, account: account)
        return await withCheckedContinuation { continuation in
            continuations[prompt.id] = continuation; prompts.append(prompt)
            Task { try? await Task.sleep(for: .seconds(120)); answer(prompt.id, secret: nil, remember: false) }
        }
    }
    func answer(_ id: UUID, secret: String?, remember: Bool) {
        guard let prompt = prompts.first(where: { $0.id == id }) else { return }
        if remember, prompt.canRemember, let secret {
            do { try CredentialStore.save(secret, account: prompt.account) } catch { self.error = error.localizedDescription }
        }
        prompts.removeAll { $0.id == id }; continuations.removeValue(forKey: id)?.resume(returning: secret)
    }
}
