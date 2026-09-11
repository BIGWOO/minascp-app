import XCTest
@testable import MinaSCP

final class EditingTests: XCTestCase {
    @MainActor func testAtomicSavesConflictAndRestartRetainsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.txt")
        try Data("initial".utf8).write(to: remote)
        let manager = RemoteEditManager(root: root.appendingPathComponent("editing"))
        let entry = Entry(name: "remote.txt", path: remote.path, attributes: try LocalFiles.attributes(remote.path))
        try await manager.begin(entry: entry, connection: Connection(fixture: true))
        let record = try XCTUnwrap(manager.records.first), local = URL(fileURLWithPath: record.localPath)
        for n in 0..<5 { try Data("save-\(n)".utf8).write(to: local, options: .atomic) }
        for _ in 0..<50 { if (try? String(contentsOf: remote)) == "save-4" { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(try String(contentsOf: remote), "save-4")
        try Data("external".utf8).write(to: remote)
        try Data("local-change".utf8).write(to: local, options: .atomic)
        await manager.upload(record.id, force: false)
        XCTAssertEqual(manager.records.first?.state, "衝突"); XCTAssertEqual(try String(contentsOf: remote), "external")
        let restarted = RemoteEditManager(root: root.appendingPathComponent("editing"))
        XCTAssertEqual(restarted.records.first?.state, "衝突"); XCTAssertEqual(try String(contentsOf: local), "local-change")
        await manager.upload(record.id, force: true)
        XCTAssertEqual(try String(contentsOf: remote), "local-change")
        manager.setWatching(record.id, active: false)
    }
    @MainActor func testReopeningPausedCopyResumesUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("README.txt")
        try Data("initial".utf8).write(to: remote)
        let manager = RemoteEditManager(root: root.appendingPathComponent("editing"))
        let entry = Entry(name: "README.txt", path: remote.path, attributes: try LocalFiles.attributes(remote.path))
        try await manager.begin(entry: entry, connection: Connection(fixture: true))
        let record = try XCTUnwrap(manager.records.first)
        manager.setWatching(record.id, active: false)
        try Data("saved while paused".utf8).write(to: URL(fileURLWithPath: record.localPath), options: .atomic)
        let restarted = RemoteEditManager(root: root.appendingPathComponent("editing"))
        XCTAssertEqual(restarted.records.first?.state, "已暫停")
        try await restarted.begin(entry: entry, connection: Connection(fixture: true))
        for _ in 0..<50 { if (try? String(contentsOf: remote)) == "saved while paused" { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(try String(contentsOf: remote), "saved while paused")
        XCTAssertEqual(restarted.records.count, 1)
        restarted.setWatching(record.id, active: false)
    }
    func testAskPassHelperSocketExchange() async throws {
        let broker = try AskPassServer { question, hint in question == "test-prompt" && hint.isEmpty ? "test-only-answer" : nil }
        let helper = FileManager.default.currentDirectoryPath + "/.build/debug/MinaSCPAskPass"
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: helper); process.arguments = ["test-prompt"]
        process.environment = ["MINASCP_AUTH_SOCKET": broker.endpoint]; process.standardOutput = output
        try process.run()
        let bytes = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0); XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "test-only-answer\n")
        let mode = try FileManager.default.attributesOfItem(atPath: broker.endpoint)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let encoded = try JSONEncoder().encode(Connection(host: "127.0.0.1", askPassEndpoint: broker.endpoint))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("auth"))
    }
}
