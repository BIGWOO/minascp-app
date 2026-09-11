import XCTest
import AppKit
@testable import MinaSCP

final class UpdateTests: XCTestCase {
    func testEveryActivityBlocksRestart() {
        XCTAssertFalse(UpdateActivity().isBusy)
        for activity in [UpdateActivity(transfers: true), UpdateActivity(commands: true),
                         UpdateActivity(crossSite: true), UpdateActivity(properties: true)] {
            XCTAssertTrue(activity.isBusy)
            XCTAssertFalse(activity.reason.isEmpty)
        }
    }

    @MainActor func testBusyAndCancelledConfirmationKeepUpdatePending() {
        let gate = UpdateRestartGate()
        var installs = 0
        gate.postpone { installs += 1 }
        XCTAssertFalse(gate.resume(activity: UpdateActivity(transfers: true), confirmed: true))
        XCTAssertFalse(gate.resume(activity: UpdateActivity(), confirmed: false))
        XCTAssertTrue(gate.pending)
        XCTAssertFalse(gate.approved)
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(gate.resume(activity: UpdateActivity(), confirmed: true))
        XCTAssertEqual(installs, 1)
        XCTAssertTrue(gate.approved)
        XCTAssertFalse(gate.resume(activity: UpdateActivity(), confirmed: true))
        XCTAssertEqual(installs, 1)
    }

    @MainActor func testErrorDiscardsContinuationAndAllowsAnotherCycle() {
        let gate = UpdateRestartGate()
        var installs = 0
        gate.postpone { installs += 1 }
        gate.reset()
        XCTAssertFalse(gate.pending)
        XCTAssertFalse(gate.approved)
        XCTAssertFalse(gate.resume(activity: UpdateActivity(), confirmed: true))
        gate.postpone { installs += 1 }
        XCTAssertTrue(gate.resume(activity: UpdateActivity(), confirmed: true))
        XCTAssertEqual(installs, 1)
        gate.reset()
        XCTAssertFalse(gate.approved)
    }
}

extension UpdateTests {
    @MainActor func testConflictDecisionNeverPausesWorkForUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        try Data("new".utf8).write(to: root.appendingPathComponent("source"))
        try Data("existing".utf8).write(to: root.appendingPathComponent("target"))
        let record = TransferTask(connection: Connection(fixture: true), direction: .upload, source: root.appendingPathComponent("source").path, destination: root.appendingPathComponent("target").path)
        model.queue.enqueue(record)
        let deadline = Date().addingTimeInterval(5)
        while model.queue.conflicts.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let conflict = try XCTUnwrap(model.queue.conflicts.first)
        let updates = UpdateController(); updates.model = model
        var messages = 0, installs = 0
        updates.report = { _, _ in messages += 1 }
        updates.confirmRestart = { true }
        XCTAssertTrue(updates.activity.transfers)
        // A task can start after the initial install choice but before Sparkle's
        // termination request. It must require fresh consent, not pause the task.
        updates.restartGate.approvedForImmediateInstall()
        updates.deferApprovedTerminationIfBusy()
        XCTAssertTrue(updates.pendingRestart)
        XCTAssertFalse(updates.restartGate.approved)
        updates.resetAfterUpdateCycle()
        XCTAssertTrue(updates.postponeIfBusy { installs += 1 })
        let delegate = MinaAppDelegate(); delegate.model = model; delegate.updates = updates
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        updates.resumeInstallation()
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(model.queue.records.first?.state, .decision)
        model.queue.resolve(conflict.id, policy: .skip, applyToBatch: false)
        while model.queue.activeCount > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target")), "existing")
        updates.confirmRestart = { false }
        updates.resumeInstallation()
        XCTAssertTrue(updates.pendingRestart)
        XCTAssertEqual(installs, 0)
        updates.confirmRestart = { true }
        updates.resumeInstallation()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(updates.pendingRestart)
        XCTAssertEqual(messages, 3)
        updates.resetAfterUpdateCycle()
        XCTAssertFalse(updates.restartGate.approved)
    }

    @MainActor func testRealDockerTransferAndCommandFinishBeforeUpdateCanResume() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER"] == "1" else { throw XCTSkip("Opt-in loopback Docker") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        let connection = Connection(host: "127.0.0.1", user: "tester", port: "22224", identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
        let session = try await SFTPSession.open(connection)
        let tab = try XCTUnwrap(model.current)
        tab.connection = connection; tab.session = session; tab.connected = true
        tab.state.remote.path = "/data"
        let context = CommandContext(tab: tab, background: true, side: .remote)
        model.commands.preview = CommandPreview(context: context, title: "更新保護驗收", scripts: ["sleep 3; printf update-command-complete"], timeout: 15)
        model.commands.executePreview()
        let source = root.appendingPathComponent("payload")
        try Data(repeating: 0x61, count: 256 * 1024).write(to: source)
        let remote = "/data/update-" + UUID().uuidString
        var record = TransferTask(connection: connection, direction: .upload, source: source.path, destination: remote)
        record.options.speedLimit = 128 * 1024
        model.queue.enqueue(record)
        let updates = UpdateController(); updates.model = model
        var installs = 0
        updates.report = { _, _ in }
        updates.confirmRestart = { true }
        XCTAssertTrue(updates.activity.commands)
        XCTAssertTrue(updates.activity.transfers)
        XCTAssertTrue(updates.postponeIfBusy { installs += 1 })
        updates.resumeInstallation()
        XCTAssertEqual(installs, 0)
        let deadline = Date().addingTimeInterval(20)
        while updates.activity.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(updates.activity.isBusy)
        XCTAssertEqual(model.queue.records.first?.state, .complete)
        XCTAssertEqual(model.commands.records.first?.stdout, "update-command-complete")
        XCTAssertEqual(model.commands.records.first?.state, "完成")
        XCTAssertEqual(installs, 0, "Idle alone must never resume installation")
        let remoteHash = try await session.hash(remote)
        XCTAssertEqual(remoteHash, try LocalFiles.hash(source.path))
        updates.resumeInstallation()
        XCTAssertEqual(installs, 1)
        try await session.remove(remote)
        await session.close()
    }
}
