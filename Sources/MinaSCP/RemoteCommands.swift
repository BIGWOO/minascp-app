import Foundation
import Darwin

enum Shell {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func inDirectory(_ directory: String, command: String) -> String { "cd " + quote(directory) + " &&\n" + command }
}
extension Connection {
    func commandArguments(_ script: String) throws -> [String] {
        var args = try sshArguments()
        guard let subsystem = args.firstIndex(of: "-s"), args.last == "sftp" else { throw TransferError.message("SSH 命令參數無效") }
        args.remove(at: subsystem); args[args.count - 1] = "sh -c " + Shell.quote(script); return args
    }
}
struct RemoteCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let uncertain: Bool
    let truncated: Bool
    var success: Bool { exitCode == 0 && !uncertain }
}
/// Owns only its local ssh child. Stopping ssh does not prove the remote process stopped.
final class RemoteCommandRunner: @unchecked Sendable {
    private let process = Process(), output = Pipe(), diagnostic = Pipe()
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var stopped = false, truncated = false
    private let limit = 2 * 1024 * 1024
    func stop() {
        lock.lock(); stopped = true; let running = process.isRunning; let pid = running ? process.processIdentifier : 0; lock.unlock()
        if running {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) } }
        }
    }
    func run(connection: Connection, script: String, timeout: Int = 600) async throws -> RemoteCommandResult {
        guard !script.contains("\0"), timeout > 0 else { throw TransferError.message("無效命令或逾時設定") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = try connection.commandArguments(script)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C.UTF-8"
        if let endpoint = connection.askPassEndpoint {
            environment["SSH_ASKPASS"] = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MinaSCPAskPass").path
            environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["MINASCP_AUTH_SOCKET"] = endpoint
        }
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = diagnostic
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let readers = DispatchGroup()
                func drain(_ pipe: Pipe, stdout: Bool) {
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async { [self] in
                        defer { readers.leave() }
                        while true {
                            let data = pipe.fileHandleForReading.availableData; if data.isEmpty { break }
                            lock.lock()
                            if stdout { out.append(data); if out.count > limit { out = out.suffix(limit); truncated = true } }
                            else { err.append(data); if err.count > limit { err = err.suffix(limit); truncated = true } }
                            lock.unlock()
                        }
                    }
                }
                process.terminationHandler = { [self] process in
                    DispatchQueue.global().async {
                        readers.wait()
                        self.lock.lock()
                        let result = RemoteCommandResult(stdout: String(decoding: self.out, as: UTF8.self), stderr: String(decoding: self.err, as: UTF8.self), exitCode: process.terminationStatus, uncertain: self.stopped || process.terminationStatus == 255, truncated: self.truncated)
                        self.lock.unlock(); continuation.resume(returning: result)
                    }
                }
                do {
                    lock.lock()
                    if stopped { lock.unlock(); throw CancellationError() }
                    // Enter both readers before termination can notify, including very fast commands.
                    readers.enter()
                    do { try process.run() } catch { readers.leave(); lock.unlock(); throw error }
                    lock.unlock()
                    drain(output, stdout: true); drain(diagnostic, stdout: false); readers.leave()
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) { [self] in if process.isRunning { stop() } }
                } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: { self.stop() }
    }
}
struct CommandCapabilities: Sendable {
    var shell = false
    var tools = Set<String>()
    var reason = "尚未檢查"
    static let probe = "printf 'MINASCP_SHELL_V1\\n'; for t in touch zip unzip tar python3; do command -v \"$t\" >/dev/null 2>&1 && printf 'TOOL:%s\\n' \"$t\"; done; exit 0"
    static func parse(_ result: RemoteCommandResult) -> Self {
        guard result.success, result.stdout.split(separator: "\n").contains("MINASCP_SHELL_V1") else { return Self(reason: "站台不允許 SSH 命令，或連線／能力檢查失敗；SFTP 傳輸仍可使用") }
        return Self(shell: true, tools: Set(result.stdout.split(separator: "\n").filter { $0.hasPrefix("TOOL:") }.map { String($0.dropFirst(5)) }), reason: "SSH 命令可用")
    }
}
enum CommandScope: String, Codable, CaseIterable { case file = "單一檔案", folder = "單一資料夾", multiple = "多選", directory = "目前目錄" }
enum CommandExecution: String, Codable, CaseIterable { case batch = "整批一次", each = "逐項" }
struct CommandTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新指令"
    var command = "printf '%s\\n' {paths}"
    var scope: CommandScope = .multiple
    var execution: CommandExecution = .batch
    var timeout = 600
    func expand(paths: [String], directory: String) throws -> [String] {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.contains("\0"), (1...86400).contains(timeout) else { throw TransferError.message("名稱、命令或逾時無效") }
        let regex = try NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        let ns = command as NSString
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: ns.length))
        let allowed = Set(["path", "name", "directory", "paths"])
        guard matches.allSatisfy({ allowed.contains(ns.substring(with: $0.range(at: 1))) }) else { throw TransferError.message("命令包含未知變數") }
        // Placeholders are complete shell words. Quoted/interpolated placement can undo escaping.
        var quote: Character?, escaped = false, depth = 0
        let starts = Set(matches.map { $0.range.location })
        var offset = 0
        for char in command {
            if starts.contains(offset), quote != nil || escaped || depth > 0 { throw TransferError.message("變數須放在未加引號的獨立參數位置") }
            if escaped { escaped = false }
            else if char == "\\" && quote != "'" { escaped = true }
            else if char == "'" || char == "\"" { if quote == char { quote = nil } else if quote == nil { quote = char } }
            else if quote == nil && (char == "`" || char == "(") { depth += 1 }
            else if quote == nil && char == ")" { depth = max(0, depth - 1) }
            offset += String(char).utf16.count
        }
        for m in matches {
            let before = m.range.location == 0 ? " " : ns.substring(with: NSRange(location: m.range.location - 1, length: 1))
            let end = NSMaxRange(m.range), after = end == ns.length ? " " : ns.substring(with: NSRange(location: end, length: 1))
            guard before.rangeOfCharacter(from: .whitespacesAndNewlines) != nil, after.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { throw TransferError.message("變數前後需有空白；不要自行包引號") }
        }
        let groups = execution == .each && !paths.isEmpty ? paths.map { [$0] } : [paths]
        return try groups.map { selected in
            var result = command
            for m in matches.reversed() {
                let key = ns.substring(with: m.range(at: 1)), value: String
                switch key {
                case "directory": value = Shell.quote(directory)
                case "paths": guard !selected.isEmpty else { throw TransferError.message("此指令需要選取檔案") }; value = selected.map(Shell.quote).joined(separator: " ")
                default:
                    guard selected.count == 1 else { throw TransferError.message("{path}／{name} 需要單選或逐項執行") }
                    value = Shell.quote(key == "name" ? (selected[0] as NSString).lastPathComponent : selected[0])
                }
                guard let range = Range(m.range, in: result) else { throw TransferError.message("變數位置無效") }; result.replaceSubrange(range, with: value)
            }
            return Shell.inDirectory(directory, command: result)
        }
    }
}
