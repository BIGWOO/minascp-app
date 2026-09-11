import Foundation

/// Blocking pipe I/O stays off actor and UI executors. stdout is protocol-only.
final class SSHChannel: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe(), diagnostic = Pipe()
    private let writer = DispatchQueue(label: "MinaSCP.ssh.write")
    private let lock = NSLock()
    private var errorTail = Data()
    private var diagnostics: SSHDiagnosticParser
    var negotiation: SSHNegotiation { lock.lock(); defer { lock.unlock() }; return diagnostics.snapshot }
    private var stopped = false
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(connection: Connection, captureInfo: Bool = false) throws {
        diagnostics = SSHDiagnosticParser(proxyExpected: !connection.jumpHost.isEmpty)
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }; continuation = captured
        #if DEBUG
        if connection.fixture { process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server") }
        else { process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = try connection.sshArguments(captureInfo: captureInfo) }
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = try connection.sshArguments(captureInfo: captureInfo)
        #endif
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        if let endpoint = connection.askPassEndpoint {
            environment["SSH_ASKPASS"] = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MinaSCPAskPass").path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["MINASCP_AUTH_SOCKET"] = endpoint
        }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
        try process.run()
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let data = diagnostic.fileHandleForReading.availableData
                lock.lock()
                let messages = data.isEmpty ? diagnostics.finish() : diagnostics.feed(data)
                for message in messages { errorTail.append(Data((message + "\n").utf8)) }
                if errorTail.count > 8192 { errorTail = Data(errorTail.suffix(8192)) }
                lock.unlock()
                if data.isEmpty { break }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                continuation.yield(data)
            }
            process.waitUntilExit()
            lock.lock(); let tail = String(decoding: errorTail, as: UTF8.self); let wasStopped = stopped; lock.unlock()
            if wasStopped { continuation.finish(throwing: CancellationError()) }
            else { continuation.finish(throwing: SFTPFailure(code: 7, message: tail.isEmpty ? "SSH 連線已關閉" : tail)) }
        }
    }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            writer.async { [self] in
                lock.lock(); let cancelled = stopped; lock.unlock()
                guard !cancelled else { done.resume(throwing: CancellationError()); return }
                do { try input.fileHandleForWriting.write(contentsOf: data); done.resume() }
                catch { done.resume(throwing: error) }
            }
        }
    }
    func stop() {
        lock.lock(); let already = stopped; stopped = true; lock.unlock()
        guard !already else { return }
        if process.isRunning { process.terminate() }
        continuation.finish(throwing: CancellationError())
    }
}
