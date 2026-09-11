import Foundation
import Darwin

// This helper writes secrets only to OpenSSH's private askpass stdout pipe.
func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); if n <= 0 { return false }; offset += n }
        return true
    }
}
func readAll(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data(count: count), offset = 0
    let ok = data.withUnsafeMutableBytes { raw -> Bool in
        while offset < count { let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset); if n <= 0 { return false }; offset += n }; return true
    }
    return ok ? data : nil
}
guard let path = ProcessInfo.processInfo.environment["MINASCP_AUTH_SOCKET"], path.utf8.count < 104 else { exit(1) }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8CString.withUnsafeBytes { memcpy(bytes.baseAddress!, $0.baseAddress!, $0.count) } }
let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard connected == 0 else { exit(1) }
var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
let payload = try JSONSerialization.data(withJSONObject: ["prompt": CommandLine.arguments.dropFirst().joined(separator: " "), "hint": ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? ""])
var length = UInt32(payload.count).bigEndian
let prefix = withUnsafeBytes(of: &length) { Data($0) }
guard sendAll(fd, prefix + payload), let header = readAll(fd, 4) else { close(fd); exit(1) }
let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
guard size <= 16384, let response = readAll(fd, Int(size)), let json = try? JSONSerialization.jsonObject(with: response) as? [String: String], let secret = json["answer"] else { close(fd); exit(1) }
close(fd)
FileHandle.standardOutput.write(Data((secret + "\n").utf8))
