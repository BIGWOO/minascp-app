import Foundation

struct SavedSite: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var user: String
    var port: String
    var identity: String
    var localPath: String
    var remotePath: String
    var group = ""
    var color = "blue"
    var authentication: AuthenticationMethod = .key
    var jumpHost = ""
    var timeout = 30
    var keepalive = 15
    var overrideTransferSettings = false
    var transferOptions = TransferOptions()
    var protocolName = "sftp"
    var connection: Connection { Connection(host: host, user: user, port: port, identity: authentication == .key ? identity : "", jumpHost: jumpHost, timeout: timeout, keepalive: keepalive) }
    var validationIssues: [String] {
        var result: [String] = []
        if protocolName.lowercased() != "sftp" { result.append("尚不支援 \(protocolName) 協定") }
        if !connection.valid { result.append("主機、使用者或連接埠無效") }
        if localPath.contains(":\\") { result.append("本機目錄是 Windows 路徑，請重新指定") }
        if !identity.isEmpty && authentication == .key {
            if identity.lowercased().hasSuffix(".ppk") { result.append("PPK 金鑰須先另行轉為 OpenSSH 格式") }
            else if !FileManager.default.fileExists(atPath: identity) { result.append("找不到私鑰檔案") }
        }
        return result
    }
    init(id: UUID = UUID(), name: String, host: String, user: String, port: String = "22", identity: String = "", localPath: String = FileManager.default.homeDirectoryForCurrentUser.path, remotePath: String = "/", group: String = "", color: String = "blue", authentication: AuthenticationMethod = .key, jumpHost: String = "", timeout: Int = 30, keepalive: Int = 15) {
        self.id = id; self.name = name; self.host = host; self.user = user; self.port = port; self.identity = identity; self.localPath = localPath; self.remotePath = remotePath; self.group = group; self.color = color; self.authentication = authentication; self.jumpHost = jumpHost; self.timeout = timeout; self.keepalive = keepalive
    }
    enum CodingKeys: String, CodingKey { case id, name, host, user, port, identity, localPath, remotePath, group, color, authentication, jumpHost, timeout, keepalive, overrideTransferSettings, transferOptions, protocolName }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name); host = try c.decode(String.self, forKey: .host); user = try c.decode(String.self, forKey: .user); port = try c.decode(String.self, forKey: .port)
        identity = try c.decodeIfPresent(String.self, forKey: .identity) ?? ""; localPath = try c.decodeIfPresent(String.self, forKey: .localPath) ?? FileManager.default.homeDirectoryForCurrentUser.path; remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath) ?? "/"
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""; color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"; authentication = try c.decodeIfPresent(AuthenticationMethod.self, forKey: .authentication) ?? .key
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""; timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 30; keepalive = try c.decodeIfPresent(Int.self, forKey: .keepalive) ?? 15
        overrideTransferSettings = try c.decodeIfPresent(Bool.self, forKey: .overrideTransferSettings) ?? false; transferOptions = try c.decodeIfPresent(TransferOptions.self, forKey: .transferOptions) ?? TransferOptions(); protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName) ?? "sftp"
    }
}
typealias SessionProfile = SavedSite
struct SiteEnvelope: Codable { var version = 2; var sites: [SavedSite] }
struct SiteStore {
    let url: URL
    init(url: URL = AppStoragePaths.root.appendingPathComponent("sites.json")) { self.url = url }
    func load() throws -> [SavedSite] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if let envelope = try? JSONDecoder().decode(SiteEnvelope.self, from: data) {
            guard envelope.version == 2 else { throw TransferError.message("不支援的站台格式版本 \(envelope.version)") }
            return envelope.sites
        }
        let sites = try JSONDecoder().decode([SavedSite].self, from: data)
        let backup = url.appendingPathExtension("v1-backup-" + UUID().uuidString)
        try data.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard try Data(contentsOf: backup) == data else { throw TransferError.message("站台備份校驗失敗") }
        try save(sites); return sites
    }
    func save(_ sites: [SavedSite]) throws { try AtomicStore<SiteEnvelope>(url: url).save(SiteEnvelope(sites: sites)) }
}
struct ImportCandidate: Identifiable {
    let id = UUID()
    var site: SavedSite
    var warnings: [String]
    var selected = false
}
enum SiteImporter {
    static func preview(_ url: URL) throws -> [ImportCandidate] {
        let data = try Data(contentsOf: url)
        if let envelope = try? JSONDecoder().decode(SiteEnvelope.self, from: data) {
            guard envelope.version == 2 else { throw TransferError.message("不支援的匯入版本") }
            return envelope.sites.map { ImportCandidate(site: $0, warnings: $0.validationIssues) }
        }
        if let sites = try? JSONDecoder().decode([SavedSite].self, from: data) { return sites.map { ImportCandidate(site: $0, warnings: $0.validationIssues) } }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw TransferError.message("請選擇站台 JSON 檔") }
        return values.map { value in
            var site = SavedSite(name: value["displayName"] as? String ?? "未命名站台", host: value["host"] as? String ?? "", user: value["username"] as? String ?? "", port: (value["port"] as? Int).map(String.init) ?? (value["port"] as? String ?? "22"), identity: value["privateKeyPath"] as? String ?? "", localPath: value["initialLocalPath"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path, remotePath: value["initialRemotePath"] as? String ?? "/", group: value["folderPath"] as? String ?? "")
            let method = value["authentication"] as? String ?? "privateKey"
            site.authentication = method == "password" ? .password : method == "agent" ? .agent : .key
            site.protocolName = value["protocol"] as? String ?? "sftp"
            var warnings = site.validationIssues
            if !["privateKey", "password", "agent"].contains(method) { warnings.append("驗證方式 \(method) 需要手動確認") }
            if value["trustedHostKey"] != nil { warnings.append("舊主機指紋不會自動信任，首次登入將重新核對") }
            return ImportCandidate(site: site, warnings: warnings)
        }
    }
}
