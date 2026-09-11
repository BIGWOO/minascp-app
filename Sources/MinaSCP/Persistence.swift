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
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.object(forInfoDictionaryKey: "MinaUpdateTestBuild") as? Bool == true ? "com.mina.scp.update-test" : "com.mina.scp")
}
enum AuthenticationMethod: String, Codable, CaseIterable { case key = "SSH 金鑰", agent = "SSH Agent", password = "密碼", interactive = "互動驗證" }
enum AppearanceMode: String, Codable, CaseIterable {
    case light, dark, system
    var title: String {
        switch self {
        case .light: return "明亮玻璃"
        case .dark: return "深色玻璃"
        case .system: return "跟隨 macOS"
        }
    }
}
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
    var queueExpanded = false
    var restoreWorkspace = true
    var exclusions = ".git,node_modules,.DS_Store,.minascp-*"
    var confirmTransfers = false
    var reconnectAttempts = 2
    var localColumns: [Double] = [240,85,150,65]
    var remoteColumns: [Double] = [240,85,150,65]
    var appearanceMode: AppearanceMode = .light
    var glassTransparency = 50.0

    init() {}

    // Keep v1 readable by older builds. Only the new appearance keys are optional;
    // malformed existing settings must still trigger the store's no-overwrite guard.
    enum CodingKeys: String, CodingKey {
        case version, showHidden, commanderKeys, concurrentTransfers, speedLimit
        case preserveTime, preservePermissions, editorPath, defaultCollision, notifyCompletion
        case queueExpanded, restoreWorkspace, exclusions, confirmTransfers, reconnectAttempts
        case localColumns, remoteColumns, appearanceMode, glassTransparency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        showHidden = try c.decode(Bool.self, forKey: .showHidden)
        commanderKeys = try c.decode(Bool.self, forKey: .commanderKeys)
        concurrentTransfers = try c.decode(Int.self, forKey: .concurrentTransfers)
        speedLimit = try c.decode(Int.self, forKey: .speedLimit)
        preserveTime = try c.decode(Bool.self, forKey: .preserveTime)
        preservePermissions = try c.decode(Bool.self, forKey: .preservePermissions)
        editorPath = try c.decode(String.self, forKey: .editorPath)
        defaultCollision = try c.decode(CollisionPolicy.self, forKey: .defaultCollision)
        notifyCompletion = try c.decode(Bool.self, forKey: .notifyCompletion)
        queueExpanded = try c.decode(Bool.self, forKey: .queueExpanded)
        restoreWorkspace = try c.decode(Bool.self, forKey: .restoreWorkspace)
        exclusions = try c.decode(String.self, forKey: .exclusions)
        confirmTransfers = try c.decode(Bool.self, forKey: .confirmTransfers)
        reconnectAttempts = try c.decode(Int.self, forKey: .reconnectAttempts)
        localColumns = try c.decode([Double].self, forKey: .localColumns)
        remoteColumns = try c.decode([Double].self, forKey: .remoteColumns)
        let mode = try c.decodeIfPresent(String.self, forKey: .appearanceMode)
        appearanceMode = mode.flatMap(AppearanceMode.init(rawValue:)) ?? .light
        glassTransparency = Self.normalizedTransparency(try c.decodeIfPresent(Double.self, forKey: .glassTransparency) ?? 50)
    }

    static func normalizedTransparency(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 50
    }
}
