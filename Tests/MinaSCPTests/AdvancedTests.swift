import XCTest
@testable import MinaSCP

final class AdvancedTests: XCTestCase {
    func connection(_ port: String = "22224") throws -> Connection {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER"] == "1" else { throw XCTSkip("Opt-in Docker") }
        return Connection(host: "127.0.0.1", user: "tester", port: port, identity: FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519")
    }
    func testTemplateQuotingAndValidation() async throws {
        let c = try connection()
        let path = "/tmp/中文 空白 ' ;$(echo INJECTED) `echo BAD`\nnewline"
        var template = CommandTemplate(); template.scope = .file
        let scripts = try template.expand(paths: [path], directory: "/tmp")
        let result = try await RemoteCommandRunner().run(connection: c, script: scripts[0])
        XCTAssertTrue(result.success); XCTAssertEqual(result.stdout, path + "\n")
        for invalid in ["echo {unknown}", "echo '{path}'", "echo pre{path}", "echo $(echo {path} )", "echo \"{paths}\""] { template.command = invalid; XCTAssertThrowsError(try template.expand(paths: [path], directory: "/tmp")) }
        template.command = "echo {path}"; XCTAssertThrowsError(try template.expand(paths: ["/a","/b"], directory: "/tmp"))
        template.execution = .each; XCTAssertEqual(try template.expand(paths: ["/a","/b"], directory: "/tmp").count, 2)
    }
    func testRunnerCapabilitiesOutputAndUncertainStop() async throws {
        let c = try connection()
        let result = try await RemoteCommandRunner().run(connection: c, script: "printf output; printf diagnostic >&2; exit 7")
        XCTAssertEqual(result.stdout, "output"); XCTAssertEqual(result.stderr, "diagnostic"); XCTAssertEqual(result.exitCode, 7); XCTAssertFalse(result.uncertain)
        let probe = try await RemoteCommandRunner().run(connection: c, script: CommandCapabilities.probe)
        XCTAssertTrue(CommandCapabilities.parse(probe).tools.isSuperset(of: ["touch","zip","unzip","tar","python3"]))
        let sftp = try await RemoteCommandRunner().run(connection: connection("22222"), script: CommandCapabilities.probe, timeout: 5)
        XCTAssertFalse(CommandCapabilities.parse(sftp).shell)
        let timeout = try await RemoteCommandRunner().run(connection: c, script: "sleep 10", timeout: 1)
        XCTAssertTrue(timeout.uncertain); XCTAssertFalse(timeout.success)
        let runner = RemoteCommandRunner(); let task = Task { try await runner.run(connection: c, script: "sleep 10") }
        try await Task.sleep(for: .milliseconds(300)); task.cancel(); let stopped = try await task.value
        XCTAssertTrue(stopped.uncertain)
    }
    func testArchiveRoundtripsAndHostileMembers() async throws {
        let c = try connection(), root = "/data/archive-test-" + UUID().uuidString
        let session = try await SFTPSession.open(c)
        let setup = try await RemoteCommandRunner().run(connection: c, script: "mkdir " + Shell.quote(root) + " && mkdir " + Shell.quote(root + "/folder") + " && printf 'archive payload' > " + Shell.quote(root + "/folder/中文 ' ;$.txt"))
        XCTAssertTrue(setup.success)
        for tool in [ArchiveTool.zip, .tar] {
            let target = root + (tool == .zip ? "/result.zip" : "/result.tar.gz")
            let plan = try ArchiveTools.make(tool, paths: [root + "/folder"], directory: root, destination: target)
            let compressed = try await RemoteCommandRunner().run(connection: c, script: plan.script)
            XCTAssertTrue(compressed.success, compressed.stderr)
            try await session.rename(plan.staging!, to: target)
            let extract = try ArchiveTools.make(.extract, paths: [target], directory: root, destination: target + "-out")
            let result = try await RemoteCommandRunner().run(connection: c, script: extract.script)
            XCTAssertTrue(result.success, result.stderr)
            let sourceHash = try await session.hash(root + "/folder/中文 ' ;$.txt"), outputHash = try await session.hash(extract.staging! + "/folder/中文 ' ;$.txt")
            XCTAssertEqual(sourceHash, outputHash)
            // A pre-existing extraction staging directory must never be merged.
            let again = try await RemoteCommandRunner().run(connection: c, script: extract.script)
            XCTAssertFalse(again.success)
        }
        let malicious = #"""
import zipfile,tarfile,io,stat,os,sys
root=sys.argv[1]
for name,path in [('traversal','../ESCAPE'),('absolute','/tmp/ESCAPE'),('backslash','..\\ESCAPE')]:
    with zipfile.ZipFile(root+'/'+name+'.zip','w') as z: z.writestr(path,'bad')
with zipfile.ZipFile(root+'/duplicate.zip','w') as z: z.writestr('same','a'); z.writestr('same','b')
with zipfile.ZipFile(root+'/symlink.zip','w') as z:
    m=zipfile.ZipInfo('link'); m.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(m,'/tmp')
with tarfile.open(root+'/hardlink.tar.gz','w:gz') as t:
    m=tarfile.TarInfo('link'); m.type=tarfile.LNKTYPE; m.linkname='/tmp/out'; t.addfile(m)
with open(root+'/corrupt.zip','wb') as f: f.write(b'bad archive')
"""#
        let fixtures = try await RemoteCommandRunner().run(connection: c, script: "python3 -c " + Shell.quote(malicious) + " " + Shell.quote(root)); XCTAssertTrue(fixtures.success)
        for name in ["traversal.zip","absolute.zip","backslash.zip","duplicate.zip","symlink.zip","hardlink.tar.gz","corrupt.zip"] {
            let plan = try ArchiveTools.make(.extract, paths: [root + "/" + name], directory: root, destination: root + "/out-" + name)
            let result = try await RemoteCommandRunner().run(connection: c, script: plan.script)
            XCTAssertFalse(result.success, name)
            let exists = try await session.exists(plan.staging!); XCTAssertNil(exists, name)
        }
        await session.close()
    }
    @MainActor func testCrossSiteRoundtripCollisionCapacityAndSourceChange() async throws {
        let a = try connection("22222"), b = try connection()
        var source = SavedSite(name: "source", host: a.host, user: a.user); source.port = a.port; source.identity = a.identity
        var target = SavedSite(name: "target", host: b.host, user: b.user); target.port = b.port; target.identity = b.identity
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cross-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let remote = "/data/cross-test-" + UUID().uuidString
        let src = try await SFTPSession.open(a), dst = try await SFTPSession.open(b)
        try await src.mkdir(remote); try await src.mkdir(remote + "/folder"); try await dst.mkdir(remote)
        for path in [remote + "/中文 ' file", remote + "/folder/child"] { let h = try await src.openFile(path, flags: 2|8|32); try await src.write(h, offset: 0, data: Data(path.utf8)); try await src.closeHandle(h) }
        let paths = [remote + "/中文 ' file", remote + "/folder"]
        let queue = TransferQueue(url: root.appendingPathComponent("queue.json")), manager = CrossSiteManager(root: root, queue: TransferQueue(url: root.appendingPathComponent("unused.json")))
        manager.availableBytes = { 0 }
        do { _ = try await manager.prepare(source: source, destination: target, paths: paths, directory: remote); XCTFail("capacity gate") } catch {}
        let cross = CrossSiteManager(root: root, queue: queue); cross.sites = { [source,target] }
        let job = try await cross.prepare(source: source, destination: target, paths: paths, directory: remote); cross.start(job)
        try await wait(cross, job.id)
        XCTAssertEqual(cross.jobs.first?.state, "完成", cross.jobs.first?.message ?? "")
        let sourceManifest = try await CrossManifest.remote(paths, session: src), destinationManifest = try await CrossManifest.remote(paths, session: dst)
        XCTAssertTrue(CrossManifest.contentMatches(sourceManifest,destinationManifest)); XCTAssertFalse(FileManager.default.fileExists(atPath: job.staging))
        let collision = try await cross.prepare(source: source, destination: target, paths: paths, directory: remote); cross.start(collision)
        for _ in 0..<1000 { if cross.activeCount == 0 { break }; for conflict in queue.conflicts { XCTAssertTrue(conflict.safeOnly); queue.resolve(conflict.id, policy: .rename, applyToBatch: true) }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(cross.jobs.first?.state, "完成", cross.jobs.first?.message ?? "")
        let changed = try await cross.prepare(source: source, destination: target, paths: paths, directory: remote)
        let h = try await src.openFile(paths[0], flags: 2); try await src.write(h, offset: 0, data: Data("changed".utf8)); try await src.closeHandle(h)
        cross.start(changed); try await wait(cross, changed.id); XCTAssertEqual(cross.jobs.first?.state,"失敗"); XCTAssertTrue(cross.jobs.first?.message.contains("來源已變更") == true)
        let restored = CrossSiteManager(root: root, queue: queue); restored.sites = { [] }; restored.resume(changed.id); try await wait(restored,changed.id); XCTAssertTrue(restored.jobs.first?.message.contains("站台已移除") == true)
        await src.close(); await dst.close()
    }
    @MainActor func wait(_ manager: CrossSiteManager, _ id: UUID) async throws {
        for _ in 0..<1500 { if manager.activeCount == 0 { return }; try await Task.sleep(for: .milliseconds(20)) }; XCTFail("cross-site timed out")
    }
}

extension AdvancedTests {
    @MainActor func testCrossSitePauseCancelRestartAndStagingTamper() async throws {
        let a = try connection("22222"), b = try connection()
        var source = SavedSite(name: "source", host: a.host, user: a.user); source.port = a.port; source.identity = a.identity; source.transferOptions.speedLimit = 512 * 1024
        var target = SavedSite(name: "target", host: b.host, user: b.user); target.port = b.port; target.identity = b.identity; target.transferOptions.speedLimit = 512 * 1024
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cross-resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let remote = "/data/resume-" + UUID().uuidString
        let src = try await SFTPSession.open(a), dst = try await SFTPSession.open(b)
        try await src.mkdir(remote); try await dst.mkdir(remote)
        let path = remote + "/payload", h = try await src.openFile(path, flags: 2|8|32)
        for offset in stride(from: 0, to: 2*1024*1024, by: 32768) { try await src.write(h, offset: UInt64(offset), data: Data(repeating: 73, count: 32768)) }; try await src.closeHandle(h)
        let queueURL = root.appendingPathComponent("queue.json"), queue = TransferQueue(url: queueURL), manager = CrossSiteManager(root: root, queue: queue)
        manager.sites = { [source,target] }
        let job = try await manager.prepare(source: source, destination: target, paths: [path], directory: remote)
        manager.start(job)
        for _ in 0..<500 { if queue.records.contains(where: { $0.transferred > 0 }) { break }; try await Task.sleep(for: .milliseconds(10)) }
        manager.stop(job.id,pause:true); try await wait(manager,job.id)
        XCTAssertEqual(manager.jobs.first?.state,"已暫停"); XCTAssertTrue(FileManager.default.fileExists(atPath: job.staging))
        let queue2 = TransferQueue(url: queueURL), manager2 = CrossSiteManager(root: root, queue: queue2); manager2.sites = { [source,target] }
        XCTAssertEqual(manager2.activeCount,0); manager2.resume(job.id)
        for _ in 0..<1500 { if manager2.jobs.first?.state == "上傳中", queue2.records.contains(where: { $0.direction == .upload && $0.transferred > 0 }) { break }; try await Task.sleep(for: .milliseconds(10)) }
        manager2.stop(job.id,pause:false); try await wait(manager2,job.id)
        XCTAssertEqual(manager2.jobs.first?.state,"已取消")
        queue2.clearCompleted(); XCTAssertTrue(queue2.records.contains { $0.direction == .download })
        let queue3 = TransferQueue(url: queueURL), manager3 = CrossSiteManager(root: root, queue: queue3); manager3.sites = { [source,target] }; manager3.resume(job.id); try await wait(manager3,job.id)
        XCTAssertEqual(manager3.jobs.first?.state,"完成",manager3.jobs.first?.message ?? "")
        let ah = try await src.hash(path), bh = try await dst.hash(path); XCTAssertEqual(ah,bh)
        // Completed downloads remain pinned until the parent finishes; a changed staged payload blocks upload.
        let corrupt = try await manager3.prepare(source: source,destination:target,paths:[path],directory:remote)
        manager3.start(corrupt)
        for _ in 0..<1500 { if manager3.jobs.first?.state == "上傳中" { break }; try await Task.sleep(for:.milliseconds(10)) }
        manager3.stop(corrupt.id,pause:true); try await wait(manager3,corrupt.id)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath:corrupt.staging).appendingPathComponent("payload/payload"))
        manager3.resume(corrupt.id); try await wait(manager3,corrupt.id)
        XCTAssertEqual(manager3.jobs.first?.state,"失敗"); XCTAssertTrue(manager3.jobs.first?.message.contains("暫存內容") == true)
        manager3.cleanup(corrupt.id); XCTAssertFalse(FileManager.default.fileExists(atPath:corrupt.staging))
        await src.close(); await dst.close()
    }
}

extension AdvancedTests {
    @MainActor func testCrossSiteBothEndpointDisconnectsAndResume() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DISCONNECT_TEST"] == "1" else { throw XCTSkip("Explicit loopback container disconnect test") }
        func container(_ file: String, _ action: String) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["docker","compose","-f",file,action]; if action == "stop" { p.arguments! += ["-t","0"] }
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw TransferError.message("container operation failed") }
        }
        let a = try connection("22222"), b = try connection()
        var source = SavedSite(name:"source",host:a.host,user:a.user,port:a.port,identity:a.identity); source.transferOptions.speedLimit = 256*1024
        var target = SavedSite(name:"target",host:b.host,user:b.user,port:b.port,identity:b.identity); target.transferOptions.speedLimit = 256*1024
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disconnect-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let remote = "/data/disconnect-"+UUID().uuidString, path = remote+"/file"
        let src = try await SFTPSession.open(a), dst = try await SFTPSession.open(b)
        try await src.mkdir(remote); try await dst.mkdir(remote)
        let h = try await src.openFile(path,flags:2|8|32)
        for offset in stride(from:0,to:1024*1024,by:32768) { try await src.write(h,offset:UInt64(offset),data:Data(repeating:83,count:32768)) }; try await src.closeHandle(h); await src.close(); await dst.close()
        let queue = TransferQueue(url:root.appendingPathComponent("queue.json")), cross = CrossSiteManager(root:root,queue:queue); cross.sites = { [source,target] }
        let job = try await cross.prepare(source:source,destination:target,paths:[path],directory:remote); cross.start(job)
        for _ in 0..<1000 { if queue.records.contains(where:{$0.direction == .download && $0.transferred > 0}) { break }; try await Task.sleep(for:.milliseconds(10)) }
        try container("compose.sftp-test.yml","stop")
        do { try await wait(cross,job.id); XCTAssertEqual(cross.jobs.first?.state,"失敗") } catch { try container("compose.sftp-test.yml","start"); throw error }
        try container("compose.sftp-test.yml","start"); try await Task.sleep(for:.seconds(1)); cross.resume(job.id)
        for _ in 0..<1500 { if queue.records.contains(where:{$0.direction == .upload && $0.transferred > 0}) { break }; try await Task.sleep(for:.milliseconds(10)) }
        try container("compose.commands-test.yml","stop")
        do { try await wait(cross,job.id); XCTAssertEqual(cross.jobs.first?.state,"失敗") } catch { try container("compose.commands-test.yml","start"); throw error }
        try container("compose.commands-test.yml","start"); try await Task.sleep(for:.seconds(1)); cross.resume(job.id); try await wait(cross,job.id)
        XCTAssertEqual(cross.jobs.first?.state,"完成",cross.jobs.first?.message ?? "")
        let sourceRead = try await SFTPSession.open(a), targetRead = try await SFTPSession.open(b)
        let expected = try await sourceRead.hash(path), actual = try await targetRead.hash(path); XCTAssertEqual(expected,actual)
        await sourceRead.close(); await targetRead.close()
    }
}

extension AdvancedTests {
    @MainActor func testCommandManagerCommitCollisionScopeAndPersistence() async throws {
        let c = try connection(), remote = "/data/manager-"+UUID().uuidString
        let setup = try await RemoteCommandRunner().run(connection:c,script:"mkdir "+Shell.quote(remote)+" && printf content > "+Shell.quote(remote+"/a")); XCTAssertTrue(setup.success)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let tab = TabBrowser(WorkspaceTab(profile:SavedSite(name:"test",host:c.host,user:c.user,port:c.port,identity:c.identity,remotePath:remote)))
        await tab.connect(authentication:AuthenticationCenter()); XCTAssertTrue(tab.connected)
        tab.state.activeSide = .remote; tab.state.remote.selection = Set(tab.remoteEntries.map(\.id))
        let context = CommandContext(tab:tab), manager = CommandManager(root:root)
        await manager.probe(context); XCTAssertTrue(manager.capability(context).shell)
        var template = CommandTemplate(); template.scope = .file; XCTAssertTrue(manager.matches(template,context:context)); template.scope = .directory; XCTAssertFalse(manager.matches(template,context:context))
        template.name = "persisted"; manager.templates = [template]; manager.saveTemplates(); XCTAssertEqual(CommandManager(root:root).templates,[template])
        let plan = try ArchiveTools.make(.zip,paths:[remote+"/a"],directory:remote,destination:remote+"/a.zip")
        manager.preview = CommandPreview(context:context,title:"zip",scripts:[plan.script],timeout:30,archive:plan); manager.executePreview()
        for _ in 0..<500 { if manager.records.first?.state == "完成" || manager.records.first?.state.hasPrefix("失敗") == true { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(manager.records.first?.state,"完成"); XCTAssertNil(manager.records.first?.staging)
        let hash = try await tab.session!.hash(remote+"/a.zip")
        manager.preview = CommandPreview(context:context,title:"collision",scripts:[plan.script],timeout:30,archive:plan); manager.executePreview()
        for _ in 0..<500 { if manager.records.first?.title == "collision",manager.records.first?.state.hasPrefix("失敗") == true { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(manager.records.first?.stderr.contains("目的地已存在") == true)
        let after = try await tab.session!.hash(remote+"/a.zip"); XCTAssertEqual(hash,after)
        tab.disconnect(); XCTAssertFalse(manager.capability(context).shell)
        let restored = CommandManager(root:root); XCTAssertEqual(restored.records.count,2); XCTAssertEqual(restored.activeCount,0)
    }
}
