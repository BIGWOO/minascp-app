import XCTest
@testable import MinaSCP
actor RecordCapture {
    var value: TransferTask?
    func set(_ value: TransferTask) { self.value = value }
}
final class TransferEngineTests: XCTestCase {
    func testDirectoryRoundTripAndSymlinkWithoutFollowing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("remote"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("子目錄"), withIntermediateDirectories: true)
        let payload = Data((0..<100000).map { UInt8($0 % 251) })
        try payload.write(to: source.appendingPathComponent("子目錄/空白 [*]?\"\n.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "子目錄")
        let upload = TransferTask(connection: Connection(fixture: true), direction: .upload, source: source.path, destination: remote.path)
        let uploaded = try await TransferEngine(record: upload, conflict: { _ in XCTFail("No collision expected"); throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(uploaded.state, .complete)
        let download = TransferTask(connection: Connection(fixture: true), direction: .download, source: remote.path, destination: target.path)
        let downloaded = try await TransferEngine(record: download, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(downloaded.state, .complete)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("子目錄/空白 [*]?\"\n.txt")), payload)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path), "子目錄")
    }
    func testCollisionRequiresDecisionAndSkipPreservesFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("new".utf8).write(to: a); try Data("keep".utf8).write(to: b)
        let record = TransferTask(connection: Connection(fixture: true), direction: .upload, source: a.path, destination: b.path)
        _ = try await TransferEngine(record: record, conflict: { c in XCTAssertEqual(c.destination, b.path); return ConflictResolution(policy: .skip) }, update: { _ in }).run()
        XCTAssertEqual(try String(contentsOf: b), "keep")
    }
    func testResumeValidatesWholeSourceAndPartialPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), stage = root.appendingPathComponent("partial")
        let payload = Data((0..<200000).map { UInt8($0 % 127) })
        try payload.write(to: a); try Data(payload.prefix(32768)).write(to: stage)
        let attr = try LocalFiles.attributes(a.path)
        var record = TransferTask(connection: Connection(fixture: true), direction: .upload, source: a.path, destination: b.path)
        record.checkpoints[""] = FileCheckpoint(source: SourceFingerprint(size: UInt64(payload.count), modificationTime: attr.modificationTime, sha256: try LocalFiles.hash(a.path)), staging: stage.path, destination: b.path)
        let result = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(result.state, .complete); XCTAssertEqual(try Data(contentsOf: b), payload)
        let wrongStage = root.appendingPathComponent("badpartial")
        try Data(repeating: 0xff, count: 32768).write(to: wrongStage)
        record.destination = root.appendingPathComponent("different").path
        record.checkpoints[""] = FileCheckpoint(source: record.checkpoints[""]!.source, staging: wrongStage.path, destination: record.destination)
        do { _ = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run(); XCTFail("Corrupt partial must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.destination))
    }
    func testDockerRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER_TEST"] == "1" else { throw XCTSkip("Docker integration enabled explicitly") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = Connection(host: "127.0.0.1", user: "tester", port: "22222", identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
        let remote = "/data/engine-" + UUID().uuidString
        let a = root.appendingPathComponent("中文 [*]? 檔案"), b = root.appendingPathComponent("download")
        try Data(repeating: 0x6b, count: 1024 * 1024).write(to: a)
        _ = try await TransferEngine(record: TransferTask(connection: connection, direction: .upload, source: a.path, destination: remote), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        _ = try await TransferEngine(record: TransferTask(connection: connection, direction: .download, source: remote, destination: b.path), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(try LocalFiles.hash(a.path), try LocalFiles.hash(b.path))
        let session = try await SFTPSession.open(connection); try await session.remove(remote); await session.close()
    }
}
