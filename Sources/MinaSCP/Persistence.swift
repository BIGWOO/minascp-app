import Foundation

struct AtomicStore<Value: Codable> {
    let url: URL
    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }
    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
enum AppStoragePaths {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.mina.scp")
}
enum AuthenticationMethod: String, Codable, CaseIterable { case key = "SSH 金鑰", agent = "SSH Agent", password = "密碼", interactive = "互動驗證" }
struct Preferences: Codable, Equatable {
    var version = 1
    var showHidden = false
    var commanderKeys = true
    var concurrentTransfers = 2
    var speedLimit = 0
    var preserveTime = true
    var preservePermissions = false
    var editorPath = "/Applications/Visual Studio Code.app"
    var defaultCollision: CollisionPolicy = .ask
    var notifyCompletion = false
    var queueExpanded = true
    var restoreWorkspace = true
    var exclusions = ".git,node_modules,.DS_Store,.minascp-*"
    var confirmTransfers = false
    var reconnectAttempts = 2
    var localColumns: [Double] = [240,85,150,65]
    var remoteColumns: [Double] = [240,85,150,65]
}
