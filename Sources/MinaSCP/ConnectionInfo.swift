import Foundation

struct SSHNegotiation: Sendable, Equatable {
    var version: String?
    var implementation: String?
    var clientCipher: String?
    var serverCipher: String?
    var clientCompression: String?
    var serverCompression: String?
    var hostKeyType: String?
    var hostKeySHA256: String?
    var unavailableReason: String?
}

/// Only whitelisted negotiation fields survive. A partial line never exceeds 8 KiB.
/// Proxy children can share stderr: ambiguous streams must not identify a jump host as the target.
struct SSHDiagnosticParser {
    private var pending = Data()
    private var droppingLine = false
    private var fields = SSHNegotiation()
    private var ambiguous = false
    private var sealed = false
    init(proxyExpected: Bool = false) { if proxyExpected { invalidate() } }
    var snapshot: SSHNegotiation { fields }
    private mutating func invalidate() {
        ambiguous = true
        fields = SSHNegotiation(unavailableReason: "使用跳板／ProxyCommand 或混合協商訊息，無法可靠辨識目的伺服器；SSH 欄位標示未知。")
    }
    /// Non-debug lines remain available to the existing connection error reporting, not the info view.
    mutating func feed(_ data: Data) -> [String] {
        var diagnostics: [String] = []
        for byte in data {
            if byte == 10 {
                if !droppingLine {
                    let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .newlines)
                    parse(line)
                    if !line.hasPrefix("debug1:") && !line.hasPrefix("debug2:") && !line.hasPrefix("debug3:") && !line.hasPrefix("OpenSSH_") && !line.isEmpty { diagnostics.append(line) }
                }
                pending.removeAll(keepingCapacity: true); droppingLine = false
            } else if !droppingLine {
                if pending.count < 8192 { pending.append(byte) } else { pending.removeAll(keepingCapacity: true); droppingLine = true }
            }
        }
        return diagnostics
    }
    mutating func finish() -> [String] { feed(Data([10])) }
    private mutating func parse(_ line: String) {
        if line.contains("Executing proxy command:") || line.contains("Setting implicit ProxyCommand from ProxyJump:") { invalidate(); return }
        guard !ambiguous, !sealed else { return }
        if line == "debug1: SSH2_MSG_NEWKEYS received" { sealed = true; return }
        func captures(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
        }
        if let values = captures(#"^debug1: Remote protocol version ([0-9]{1,2}\.[0-9]{1,2}), remote software version ([\x20-\x7e]{1,160})$"#) {
            if let prior = fields.implementation, prior != values[1] { invalidate(); return }
            fields.version = values[0]; fields.implementation = values[1]
        } else if let values = captures(#"^debug1: kex: (client->server|server->client) cipher: ([A-Za-z0-9@._+-]+) MAC: [A-Za-z0-9@._<>+-]+ compression: ([A-Za-z0-9@._+-]+)$"#) {
            if values[0] == "client->server" { fields.clientCipher = values[1]; fields.clientCompression = values[2] }
            else { fields.serverCipher = values[1]; fields.serverCompression = values[2] }
        } else if let values = captures(#"^debug1: Server host key: ([A-Za-z0-9@._+-]+) (SHA256:[A-Za-z0-9+/]{43}=?)$"#) {
            if let prior = fields.hostKeySHA256, prior != values[1] { invalidate(); return }
            fields.hostKeyType = values[0]; fields.hostKeySHA256 = values[1]
        }
    }
}
struct ConnectionInfo: Sendable {
    let host: String
    let port: String
    let user: String
    let sftpVersion: Int
    let ssh: SSHNegotiation
    let extensions: [String: String]
    let capturedAt: Date
    var endpoint: String { user + "@" + host + ":" + port }
    var protocolRows: [(String, String)] {
        [ ("端點", endpoint), ("檔案傳輸協定", "SFTP-\(sftpVersion)"), ("SSH 版本", ssh.version.map { "SSH-" + $0 } ?? "未知"),
          ("伺服器實作", ssh.implementation ?? "未知"), ("加密：本機 → 伺服器", ssh.clientCipher ?? "未知"), ("加密：伺服器 → 本機", ssh.serverCipher ?? "未知"),
          ("壓縮：本機 → 伺服器", compression(ssh.clientCompression)), ("壓縮：伺服器 → 本機", compression(ssh.serverCompression)),
          ("主機金鑰類型", ssh.hostKeyType ?? "未知"), ("主機金鑰 SHA-256", ssh.hostKeySHA256 ?? "未知") ]
    }
    private func compression(_ value: String?) -> String { value.map { $0 == "none" ? "否（none）" : "是（\($0)）" } ?? "未知" }
    var extensionText: String {
        if extensions.isEmpty { return "伺服器未宣告 SFTP 擴充" }
        return extensions.keys.sorted().map { Self.display($0) + " = " + Self.display(extensions[$0]!) }.joined(separator: "\n")
    }
    // Server-supplied extension strings are displayed as data, with controls escaped and a UI length bound.
    static func display(_ value: String) -> String {
        let cleaned = value.unicodeScalars.prefix(1024).map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? String(format: "\\u{%04X}", scalar.value) : String(scalar)
        }.joined()
        return cleaned + (value.unicodeScalars.count > 1024 ? "…（過長已截斷）" : "")
    }
    func capabilities(command: CommandCapabilities) -> [ConnectionCapability] {
        func declared(_ names: [String]) -> String { let matches = names.filter { extensions[$0] != nil }; return matches.isEmpty ? "未宣告" : matches.joined(separator: "、") }
        return [
            .init(name: "修改權限", support: "協定提供／App 已實作", basis: "SFTP v3 SETSTAT；實際權限依帳號與路徑而定"),
            .init(name: "修改擁有者／群組", support: "協定提供／App 已實作", basis: "SFTP v3 UID／GID；不代表具有變更任意擁有者的權限"),
            .init(name: "符號連結", support: "協定提供／App 已實作", basis: "SFTP v3 SYMLINK／READLINK；伺服器可拒絕個別操作"),
            .init(name: "硬連結", support: "App 未實作", basis: "伺服器擴充：" + declared(["hardlink@openssh.com"])),
            .init(name: "存取控制清單（ACL）", support: "App 未實作", basis: "目前只使用 SFTP v3 權限位元，不探測帳號 ACL 權限"),
            .init(name: "SSH 遠端命令", support: command.shell ? "探測可用／App 已實作" : "未確認可用", basis: command.reason),
            .init(name: "伺服器端複製", support: "App 未實作", basis: "伺服器擴充：" + declared(["copy-data", "copy-file"]) + "；現有複製由本機中轉"),
            .init(name: "檔案校驗碼", support: "App 已實作 SHA-256", basis: "讀取檔案後在本機計算；伺服器校驗擴充：" + declared(["check-file", "check-file-name", "check-file-handle"])),
            .init(name: "文字／ASCII 傳輸模式", support: "App 未實作", basis: "維持檔案原始位元組，不轉換換行"),
            .init(name: "遠端命令工具", support: command.shell ? "本次連線探測" : "未檢查／未知", basis: command.shell ? (command.tools.isEmpty ? "未找到預設工具" : command.tools.sorted().joined(separator: "、")) : "請檢查命令能力")
        ]
    }
}
struct ConnectionCapability: Identifiable {
    var id: String { name }
    let name: String
    let support: String
    let basis: String
}
