import Foundation

enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String { (directory == "/" ? "/" : directory.trimmingCharacters(in: CharacterSet(charactersIn: "/" )).isEmpty ? "/" : directory.hasSuffix("/") ? String(directory.dropLast()) + "/" : directory + "/") + name }
    static func parent(_ path: String) -> String { let p = (path as NSString).deletingLastPathComponent; return p.isEmpty ? "/" : p }
    static func isSafeMutation(_ path: String) -> Bool { path.hasPrefix("/") && path != "/" && !path.contains("\0") && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) }
    static func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") }
}
struct RemoteEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let attributes: FileAttributes
    var directory: Bool { attributes.kind == .directory }
    var kind: FileKind { attributes.kind }
    var size: Int64 { Int64(clamping: attributes.size ?? 0) }
    var modified: String { attributes.modificationTime.map { Date(timeIntervalSince1970: Double($0)).formatted(date: .numeric, time: .shortened) } ?? "—" }
    var permissionText: String { attributes.permissions.map { String(format: "%04o", $0 & 0o7777) } ?? "—" }
    init(name: String, path: String, attributes: FileAttributes) { self.name = name; self.path = path; self.attributes = attributes }
    init(name: String, path: String, directory: Bool, size: Int64, modified: String) {
        self.init(name: name, path: path, attributes: FileAttributes(size: UInt64(max(0, size)), permissions: directory ? 0o040755 : 0o100644))
    }
    static func nameOrder(_ a: RemoteEntry, _ b: RemoteEntry) -> Bool { a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
}
typealias Entry = RemoteEntry
struct Connection: Equatable, Codable, Sendable {
    var fixture = false
    var host = ""
    var user = NSUserName()
    var port = "22"
    var identity = ""
    var jumpHost = ""
    var timeout = 30
    var keepalive = 15
    var askPassEndpoint: String?
    var valid: Bool { !host.isEmpty && !host.hasPrefix("-") && !user.isEmpty && !user.hasPrefix("-") && Int(port).map { (1...65535).contains($0) } == true && !host.contains(where: { $0.isWhitespace || $0 == "\0" }) }
    enum CodingKeys: String, CodingKey { case host, user, port, identity, jumpHost, timeout, keepalive }
    init(fixture: Bool = false, host: String = "", user: String = NSUserName(), port: String = "22", identity: String = "", jumpHost: String = "", timeout: Int = 30, keepalive: Int = 15, askPassEndpoint: String? = nil) {
        self.fixture = fixture; self.host = host; self.user = user; self.port = port; self.identity = identity; self.jumpHost = jumpHost; self.timeout = timeout; self.keepalive = keepalive; self.askPassEndpoint = askPassEndpoint
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host); user = try c.decode(String.self, forKey: .user); port = try c.decode(String.self, forKey: .port); identity = try c.decodeIfPresent(String.self, forKey: .identity) ?? ""
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""; timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 30; keepalive = try c.decodeIfPresent(Int.self, forKey: .keepalive) ?? 15
    }
    func sshArguments(captureInfo: Bool = false) throws -> [String] {
        guard valid, !identity.contains("\0"), !jumpHost.contains("\0"), !jumpHost.hasPrefix("-") else { throw TransferError.message("無效的 SSH 連線設定") }
        var args = ["-T", "-s", "-p", port, "-l", user, "-oBatchMode=\(askPassEndpoint == nil ? "yes" : "no")", "-oStrictHostKeyChecking=\(askPassEndpoint == nil ? "yes" : "ask")", "-oConnectTimeout=\(max(5, timeout))", "-oServerAliveInterval=\(max(0, keepalive))", "-oServerAliveCountMax=2", "-oForwardAgent=no", "-oForwardX11=no", "-oClearAllForwardings=yes", "-oUserKnownHostsFile=~/.ssh/minascp_known_hosts ~/.ssh/known_hosts"]
        if captureInfo { args.insert("-v", at: 0) }
        if !identity.isEmpty { args += ["-i", identity, "-oIdentitiesOnly=yes"] }
        if !jumpHost.isEmpty { args += ["-J", jumpHost] }
        args += ["--", host, "sftp"]
        return args
    }
}
enum TransferError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}