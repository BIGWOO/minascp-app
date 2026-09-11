import XCTest
@testable import MinaSCP

final class StressTests: XCTestCase {
    func testDockerGiBAndThousandFiles() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_STRESS_TEST"] == "1" else { throw XCTSkip("Explicit 1 GiB and 1000-file Docker test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = Connection(host: "127.0.0.1", user: "tester", port: "22222", identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
        let remote = "/data/stress-" + UUID().uuidString, source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let big = source.appendingPathComponent("1GiB.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        let block = Data((0..<(1024*1024)).map { UInt8($0 % 251) })
        for _ in 0..<1024 { try handle.write(contentsOf: block) }; try handle.close()
        for n in 0..<1000 { try Data("small-file-\(n) 中文".utf8).write(to: source.appendingPathComponent("\(n).txt")) }
        let result = try await TransferEngine(record: TransferTask(connection: c, direction: .upload, source: source.path, destination: remote), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(result.checkpoints.count, 1001)
        let target = root.appendingPathComponent("download")
        _ = try await TransferEngine(record: TransferTask(connection: c, direction: .download, source: remote, destination: target.path), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(try LocalFiles.hash(big.path), try LocalFiles.hash(target.appendingPathComponent("1GiB.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, 1001)
        for n in 0..<1000 { XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("\(n).txt")), try Data(contentsOf: target.appendingPathComponent("\(n).txt"))) }
        let session = try await SFTPSession.open(c); try await session.removeTree(remote); await session.close()
    }
    func testCancelStopsIOAndResumesVerifiedPartial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data(repeating: 73, count: 2 * 1024 * 1024).write(to: a)
        var record = TransferTask(connection: Connection(fixture: true), direction: .upload, source: a.path, destination: b.path); record.options.speedLimit = 65536
        let capture = RecordCapture()
        let engine = TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { updated in Task { await capture.set(updated) } })
        let work = Task { try await engine.run() }
        try await Task.sleep(for: .milliseconds(700)); work.cancel(); await engine.stop()
        do { _ = try await work.value; XCTFail("cancel must fail") } catch {}
        try await Task.sleep(for: .milliseconds(30))
        let captured = await capture.value
        var partial = try XCTUnwrap(captured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        let checkpoint = try XCTUnwrap(partial.checkpoints[""])
        let size = try LocalFiles.attributes(checkpoint.staging).size
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try LocalFiles.attributes(checkpoint.staging).size, size)
        partial.options.speedLimit = 0
        let resumed = try await TransferEngine(record: partial, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(resumed.state, .complete); XCTAssertEqual(try LocalFiles.hash(a.path), try LocalFiles.hash(b.path))
    }
}
