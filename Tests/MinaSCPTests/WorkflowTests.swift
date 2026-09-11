import XCTest
@testable import MinaSCP

final class WorkflowTests: XCTestCase {
    func testSyncConflictsExclusionsAndNoImplicitDeletion() throws {
        let a = FileSnapshot(kind: .file, size: 1, modified: 1, hash: "a")
        let b = FileSnapshot(kind: .file, size: 1, modified: 1, hash: "b")
        let c = FileSnapshot(kind: .file, size: 1, modified: 1, hash: "c")
        let plan = SyncPlanner.plan(local: ["both": b], remote: ["both": c, "remote-only": a], baseline: SyncBaseline(local: ["both": a], remote: ["both": a]), direction: .both, deleteExtra: true)
        XCTAssertEqual(plan.first { $0.path == "both" }?.kind, .conflict)
        XCTAssertEqual(plan.first { $0.path == "remote-only" }?.kind, .download)
        XCTAssertFalse(plan.contains { $0.kind == .deleteLocal || $0.kind == .deleteRemote })
        XCTAssertTrue(Snapshotter.excluded("deep/node_modules", patterns: ["node_modules"]))
        XCTAssertTrue(Snapshotter.excluded(".env", patterns: [".env"]))
    }
    @MainActor func testWorkspaceRestoresDisconnectedAndQueuePaused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = SavedSite(name: "test", host: "127.0.0.1", user: "tester")
        var tab = WorkspaceTab(profile: site); tab.local.path = root.path; tab.remote.path = "/data/a"
        try AtomicStore(url: root.appendingPathComponent("workspace-v1.json")).save(WorkspaceDocument(tabs: [tab], selected: tab.id))
        var record = TransferTask(connection: site.connection, direction: .upload, source: "/not-read", destination: "/not-written"); record.state = .running
        try AtomicStore(url: root.appendingPathComponent("transfers.json")).save([record])
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        XCTAssertEqual(model.current?.state.remote.path, "/data/a"); XCTAssertFalse(model.connected)
        XCTAssertEqual(model.queue.records.first?.state, .paused); XCTAssertEqual(model.queue.activeCount, 0)
    }
    func testMigrationBackupAndImportReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = SavedSite(name: "old", host: "127.0.0.1", user: "tester")
        let original = try JSONEncoder().encode([site]), url = root.appendingPathComponent("sites.json")
        try original.write(to: url)
        XCTAssertEqual(try SiteStore(url: url).load().count, 1)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("backup") }
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        let data = try Data(contentsOf: url); let preview = try SiteImporter.preview(url)
        XCTAssertFalse(try XCTUnwrap(preview.first).selected); XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testMoveRefusesSkippedOrChangedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("one".utf8).write(to: a)
        var record = try await TransferEngine(record: TransferTask(connection: Connection(fixture: true), direction: .upload, source: a.path, destination: b.path), conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        try await MoveSafety.validate(record)
        try Data("two".utf8).write(to: a)
        do { try await MoveSafety.validate(record); XCTFail("changed source must block") } catch {}
        record.skippedCount = 1
        do { try await MoveSafety.validate(record); XCTFail("skip must block") } catch {}
        XCTAssertEqual(try String(contentsOf: a), "two")
    }
}

extension WorkflowTests {
    func testCommitRacePreservesNewDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("source".utf8).write(to: a)
        let engine = TransferEngine(record: TransferTask(connection: Connection(fixture: true), direction: .upload, source: a.path, destination: b.path), conflict: { _ in throw CancellationError() }, update: { record in
            if !record.checkpoints.isEmpty, !FileManager.default.fileExists(atPath: b.path) { try? Data("concurrent".utf8).write(to: b) }
        })
        do { _ = try await engine.run(); XCTFail("No-overwrite race must fail") } catch {}
        XCTAssertEqual(try String(contentsOf: b), "concurrent")
    }
    func testDockerReadOnlyDestination() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER_TEST"] == "1" else { throw XCTSkip("Docker") }
        let c = Connection(host: "127.0.0.1", user: "tester", port: "22222", identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
        let session = try await SFTPSession.open(c), remote = "/home/tester/readonly-" + UUID().uuidString
        try await session.mkdir(remote); try await session.setAttributes(remote, FileAttributes(permissions: 0o555))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        do { _ = try await TransferEngine(record: TransferTask(connection: c, direction: .upload, source: source.path, destination: remote + "/file"), conflict: { _ in throw CancellationError() }, update: { _ in }).run(); XCTFail("Readonly must fail") } catch {}
        let absent = try await session.exists(remote + "/file"); XCTAssertNil(absent)
        try await session.setAttributes(remote, FileAttributes(permissions: 0o755)); try await session.remove(remote, directory: true); await session.close()
    }
    func testWrongHostKeyBlocksConnection() throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER_TEST"] == "1" else { throw XCTSkip("Docker") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The client's public key is deliberately not the server host key.
        let key = try String(contentsOfFile: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519.pub").split(separator: " ").prefix(2).joined(separator: " ")
        let known = root.appendingPathComponent("known_hosts")
        try Data(("[127.0.0.1]:22222 " + key + "\n").utf8).write(to: known)
        let c = Connection(host: "127.0.0.1", user: "tester", port: "22222", identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
        var args = try c.sshArguments(); args.removeAll { $0.hasPrefix("-oUserKnownHostsFile=") }; args.insert("-oUserKnownHostsFile=" + known.path, at: 0); args.insert("-oGlobalKnownHostsFile=/dev/null", at: 0)
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = args; process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
        try process.run(); let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0); XCTAssertTrue(result.contains("HOST IDENTIFICATION HAS CHANGED"))
    }
}
