import XCTest
import AppKit
@testable import MinaSCP

final class ContextMenuTests: XCTestCase {
    @MainActor func testBackgroundDoesNotActOnSelectionAndDisconnectedPathsRemainAvailable() throws {
        let tab = TabBrowser(WorkspaceTab(profile: SavedSite(name: "test", host: "localhost", user: "tester")))
        let entry = Entry(name: "a", path: "/a", attributes: FileAttributes(permissions: 0o100644))
        tab.remoteEntries = [entry]; tab.state.remote.selection = [entry.id]; tab.state.activeSide = .remote
        let selected = CommandContext(tab: tab), background = CommandContext(tab: tab, background: true)
        XCTAssertTrue(selected.allows(.copyPaths)); XCTAssertFalse(selected.allows(.delete))
        XCTAssertFalse(background.allows(.delete)); XCTAssertTrue(background.allows(.currentPath))
        XCTAssertEqual(tab.state.remote.selection, [entry.id])
        let menu = FileMenus.make(background, commanderKeys: true, action: { _ in }, navigate: { _ in })
        XCTAssertFalse(menu.items.contains { $0.title == "刪除" }); XCTAssertTrue(menu.items.contains { $0.title == "前往" })
    }
    @MainActor func testMultiSelectionAndCapturedTarget() throws {
        let tab = TabBrowser(WorkspaceTab(profile: SavedSite(name: "test", host: "localhost", user: "tester")))
        let entries = ["中文 空白.txt", "a'b.txt"].map { Entry(name: $0, path: "/tmp/" + $0, attributes: FileAttributes(permissions: 0o100644)) }
        tab.localEntries = entries; tab.state.local.selection = Set(entries.map(\.id))
        let captured = CommandContext(tab: tab)
        XCTAssertTrue(captured.allows(.copyTo)); XCTAssertTrue(captured.allows(.properties)); XCTAssertFalse(captured.allows(.edit)); XCTAssertFalse(captured.allows(.rename))
        tab.state.local.selection = []; tab.state.activeSide = .remote
        XCTAssertEqual(captured.entries.count, 2); XCTAssertFalse(captured.remote)
    }
    func testPermissionPatchPreservesUneditedBitsAndOwnership() {
        let original = FileAttributes(uid: 10, gid: 20, permissions: 0o100640)
        let patch = PropertyChange(permissionMask: 1, permissionBits: 1, uid: 11)
        let result = patch.attributes(for: original)
        XCTAssertEqual(result.permissions, 0o641); XCTAssertEqual(result.uid, 11); XCTAssertEqual(result.gid, 20)
        XCTAssertTrue(patch.verified(FileAttributes(uid: 11, gid: 20, permissions: 0o100641), expected: result))
        XCTAssertFalse(patch.verified(original, expected: result))
    }
    func testSameSideConflictRenameAndMoveAndSelfProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("中文 ' file"), target = root.appendingPathComponent("target")
        try Data("source".utf8).write(to: source); try Data("keep".utf8).write(to: target)
        var record = TransferTask(connection: Connection(), direction: .local, source: source.path, destination: target.path); record.sameSideOperation = .copy
        let result = try await TransferEngine(record: record, conflict: { conflict in XCTAssertTrue(conflict.safeOnly); return ConflictResolution(policy: .rename) }, update: { _ in }).run()
        XCTAssertEqual(try String(contentsOf: target), "keep"); XCTAssertEqual(try String(contentsOfFile: result.destination), "source")
        record.destination = root.appendingPathComponent("moved").path; record.sameSideOperation = .move
        _ = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)); XCTAssertEqual(try String(contentsOfFile: record.destination), "source")
        var bad = TransferTask(connection: Connection(), direction: .local, source: root.path, destination: root.appendingPathComponent("inside").path); bad.sameSideOperation = .copy
        do { _ = try await TransferEngine(record: bad, conflict: { _ in throw CancellationError() }, update: { _ in }).run(); XCTFail("self child") } catch {}
    }
    @MainActor func testPropertiesRecursiveSkipLinkAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("child"), link = root.appendingPathComponent("link")
        try Data("hello".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        let tab = TabBrowser(WorkspaceTab(profile: SavedSite(name: "test", host: "localhost", user: "tester")))
        let entry = Entry(name: root.lastPathComponent, path: root.path, attributes: try LocalFiles.attributes(root.path)); tab.localEntries = [entry]; tab.state.local.selection = [entry.id]
        let editor = FilePropertyEditor(CommandContext(tab: tab)); await editor.load(); editor.recursive = true; editor.change = PropertyChange(permissionMask: 1, permissionBits: 1)
        await editor.apply()
        XCTAssertEqual(try LocalFiles.attributes(file.path).permissions! & 0o777, 0o641)
        XCTAssertTrue(editor.messages.contains { $0.contains("略過連結") }); XCTAssertEqual(editor.originals.count, 2)
        await editor.restore(); XCTAssertEqual(try LocalFiles.attributes(file.path).permissions! & 0o777, 0o640)
    }
    func testRemoteCopyUsesSFTPAndDoesNotOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("remote bytes".utf8).write(to: a)
        var record = TransferTask(connection: Connection(fixture: true), direction: .remoteCopy, source: a.path, destination: b.path); record.sameSideOperation = .copy
        let result = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(result.state, .complete); XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        record = TransferTask(connection: Connection(fixture: true), direction: .remoteCopy, source: a.path, destination: b.path); record.sameSideOperation = .copy
        do { _ = try await TransferEngine(record: record, conflict: { _ in ConflictResolution(policy: .overwrite) }, update: { _ in }).run(); XCTFail("overwrite forbidden") } catch {}
    }
}

extension ContextMenuTests {
    @MainActor func testDockerRemoteBatchPropertiesAndReadback() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER"] == "1" else { throw XCTSkip("Opt-in loopback Docker test") }
        let connection = Connection(host: "127.0.0.1", user: "tester", port: "22222", identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
        let session = try await SFTPSession.open(connection)
        let root = "/data/context-tests-" + UUID().uuidString
        try await session.mkdir(root)
        do {
            let a = root + "/中文 'a.txt", b = root + "/b.txt", link = root + "/link"
            let h = try await session.openFile(a, flags: 2 | 8 | 32); try await session.write(h, offset: 0, data: Data("Docker remote copy".utf8)); try await session.closeHandle(h)
            try await session.setAttributes(a, FileAttributes(permissions: 0o640)); try await session.symlink(a, at: link)
            var record = TransferTask(connection: connection, direction: .remoteCopy, source: a, destination: b); record.sameSideOperation = .copy
            _ = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
            let expectedHash = try await session.hash(a), copiedHash = try await session.hash(b); XCTAssertEqual(expectedHash, copiedHash)
            let tab = TabBrowser(WorkspaceTab(profile: SavedSite(name: "Docker test", host: "127.0.0.1", user: "tester")))
            tab.state.activeSide = .remote; tab.state.remote.path = root; tab.connection = connection; tab.session = session; tab.connected = true
            tab.remoteEntries = try await session.list(root); tab.state.remote.selection = Set(tab.remoteEntries.map(\.id))
            let editor = FilePropertyEditor(CommandContext(tab: tab)); await editor.load(); editor.change = PropertyChange(permissionMask: 1, permissionBits: 1); await editor.apply()
            let changed = try await session.attributes(a); XCTAssertEqual(changed.permissions! & 0o777, 0o641)
            XCTAssertTrue(editor.messages.contains { $0.contains("略過連結") })
            await editor.restore(); let restored = try await session.attributes(a); XCTAssertEqual(restored.permissions! & 0o777, 0o640)
            record = TransferTask(connection: connection, direction: .remoteCopy, source: b, destination: root + "/moved.txt"); record.sameSideOperation = .move
            _ = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
            let absent = try await session.exists(b); XCTAssertNil(absent)
            let movedHash = try await session.hash(record.destination); XCTAssertEqual(movedHash, expectedHash)
            try await session.removeTree(root); await session.close()
        } catch { try? await session.removeTree(root); await session.close(); throw error }
    }
    @MainActor func testClipboardLocalURLsAndNoCredentials() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/中文 'a.txt")])
        XCTAssertEqual(FileClipboard.read(board)?.paths, ["/tmp/中文 'a.txt"])
        let payload = FileClipboard(siteID: UUID(), paths: ["/data/a"])
        let data = try JSONEncoder().encode(payload); board.clearContents(); board.setData(data, forType: FileClipboard.type)
        XCTAssertEqual(FileClipboard.read(board)?.siteID, payload.siteID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); XCTAssertEqual(Set(object.keys), ["siteID", "paths"])
    }
}

extension ContextMenuTests {
    func testPasteInSameDirectoryCreatesAlternativeWithoutChangingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a")
        try Data("keep".utf8).write(to: source)
        var record = TransferTask(connection: Connection(), direction: .local, source: source.path, destination: source.path); record.sameSideOperation = .copy
        let result = try await TransferEngine(record: record, conflict: { _ in ConflictResolution(policy: .rename) }, update: { _ in }).run()
        XCTAssertNotEqual(result.destination, source.path); XCTAssertEqual(try String(contentsOf: source), "keep"); XCTAssertEqual(try String(contentsOfFile: result.destination), "keep")
    }
    func testCancelledCopyRetainsSourceAndCanResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data(repeating: 7, count: 262144).write(to: a)
        var record = TransferTask(connection: Connection(), direction: .local, source: a.path, destination: b.path); record.sameSideOperation = .copy; record.options.speedLimit = 32768
        let progress = expectation(description: "bytes staged"); progress.assertForOverFulfill = false
        let engine = TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { value in if value.transferred > 0 { progress.fulfill() } })
        let task = Task { try await engine.run() }
        await fulfillment(of: [progress], timeout: 5); task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") } catch {}
        XCTAssertEqual(try Data(contentsOf: a).count, 262144); XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        record.options.speedLimit = 0
        let completed = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(completed.state, .complete); XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }
    func testDanglingLinkCopyDoesNotFollowTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: "missing")
        var record = TransferTask(connection: Connection(fixture: true), direction: .remoteCopy, source: a.path, destination: b.path); record.sameSideOperation = .copy
        _ = try await TransferEngine(record: record, conflict: { _ in throw CancellationError() }, update: { _ in }).run()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: b.path), "missing")
    }
}

extension ContextMenuTests {
    func testClipboardRejectsOtherSiteAndChangedEndpoint() {
        let id = UUID(), connection = Connection(host: "127.0.0.1", user: "tester", port: "22222")
        let value = FileClipboard(siteID: id, paths: ["/data/a"], endpoint: FileClipboard.signature(connection))
        XCTAssertTrue(value.compatible(site: id, connection: connection, connected: true))
        XCTAssertFalse(value.compatible(site: UUID(), connection: connection, connected: true))
        var changed = connection; changed.host = "other-host"
        XCTAssertFalse(value.compatible(site: id, connection: changed, connected: true))
        XCTAssertFalse(value.compatible(site: id, connection: connection, connected: false))
    }
}
