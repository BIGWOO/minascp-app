import XCTest
import CryptoKit
import AppKit
@testable import MinaSCP

final class TabTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @MainActor private func model(_ root: URL) -> BrowserModel { BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json"))) }
    func testLocalTabListingUsesPOSIXMetadataWithoutFollowingLinks() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
        try Data("local listing".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("missing").path)
        let entries = try LocalFiles.list(root.path)
        let item = try XCTUnwrap(entries.first { $0.name == "file" })
        XCTAssertEqual(item.attributes.size, 13); XCTAssertEqual(item.attributes.permissions! & 0o777, 0o640)
        XCTAssertEqual(entries.first { $0.name == "link" }?.attributes.permissions.map { $0 & 0o170000 }, 0o120000)
    }
    private var sample: String {
        """
        OpenSSH_9.9p2, LibreSSL 3.3.6
        debug1: identity file /private/secret-key type 3
        debug1: Remote protocol version 2.0, remote software version OpenSSH_10.0
        debug1: kex: server->client cipher: aes256-ctr MAC: hmac-sha2-256 compression: none
        debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: zlib@openssh.com
        debug1: Server host key: ssh-ed25519 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        debug1: send packet: password=DO_NOT_EXPORT

        """
    }
    func testNegotiationParserSplitStreamsAndSensitiveFields() {
        var parser = SSHDiagnosticParser(), returned: [String] = []
        for byte in sample.utf8 { returned += parser.feed(Data([byte])) }
        returned += parser.finish()
        let info = parser.snapshot
        XCTAssertTrue(returned.isEmpty); XCTAssertEqual(info.version, "2.0"); XCTAssertEqual(info.implementation, "OpenSSH_10.0")
        XCTAssertEqual(info.serverCipher, "aes256-ctr"); XCTAssertEqual(info.clientCipher, "chacha20-poly1305@openssh.com")
        XCTAssertEqual(info.serverCompression, "none"); XCTAssertEqual(info.clientCompression, "zlib@openssh.com")
        XCTAssertEqual(info.hostKeySHA256, "SHA256:" + String(repeating: "A", count: 43))
        XCTAssertFalse(String(describing: info).contains("DO_NOT_EXPORT")); XCTAssertFalse(String(describing: info).contains("secret-key"))
        _ = parser.feed(Data(("debug1: SSH2_MSG_NEWKEYS received\n" + "debug1: kex: server->client cipher: fake MAC: fake compression: fake\n").utf8))
        XCTAssertEqual(parser.snapshot.serverCipher, "aes256-ctr")
        let errors = parser.feed(Data("Permission denied (publickey).\n".utf8)); XCTAssertEqual(errors, ["Permission denied (publickey)."])
    }
    func testProxyAndAmbiguousNegotiationsRemainUnknown() {
        for prefix in ["debug1: Executing proxy command: exec ssh -W target:22 jump\n", "debug1: Setting implicit ProxyCommand from ProxyJump: ssh jump\n"] {
            var parser = SSHDiagnosticParser(); _ = parser.feed(Data((sample + prefix + sample).utf8))
            XCTAssertNil(parser.snapshot.hostKeySHA256); XCTAssertNil(parser.snapshot.implementation); XCTAssertNil(parser.snapshot.clientCipher); XCTAssertNotNil(parser.snapshot.unavailableReason)
        }
        var configured = SSHDiagnosticParser(proxyExpected: true); _ = configured.feed(Data(sample.utf8)); XCTAssertNil(configured.snapshot.hostKeyType)
        var mixed = SSHDiagnosticParser(); _ = mixed.feed(Data((sample + "debug1: Remote protocol version 2.0, remote software version OtherServer\n").utf8)); XCTAssertNil(mixed.snapshot.hostKeySHA256)
    }
    func testMalformedOrOversizedDiagnosticsDoNotInventFields() {
        var parser = SSHDiagnosticParser()
        _ = parser.feed(Data((String(repeating: "x", count: 100_000) + "debug1: Remote protocol version 2.0, remote software version fake\n").utf8))
        XCTAssertNil(parser.snapshot.implementation)
        _ = parser.feed(Data("debug1: Server host key: ssh-ed25519 SHA256:bad\nunknown cipher secret\n".utf8)); XCTAssertNil(parser.snapshot.hostKeySHA256)
        _ = parser.feed(Data(sample.utf8)); XCTAssertEqual(parser.snapshot.implementation, "OpenSSH_10.0")
    }
    @MainActor func testLegacyWorkspaceAliasColorDuplicationAndSave() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root), original = model.tabs[0]
        original.state.local.path = root.path; original.state.remote.path = "/data/current"
        original.state.local.filter = "txt"; original.state.local.bookmarks = [root.path]; original.state.local.history = ["/",root.path]; original.state.local.historyIndex = 1; original.state.local.selection = ["dummy"]
        let legacy = try JSONEncoder().encode(original.state)
        let decoded = try JSONDecoder().decode(WorkspaceTab.self, from: legacy)
        XCTAssertNil(decoded.alias); XCTAssertNil(decoded.colorOverride); XCTAssertEqual(decoded.title, decoded.profile.name)
        let siteName = original.state.profile.name, siteColor = original.state.profile.color
        model.renameTab(original.id,name:"工作 A"); model.colorTab(original.id,color:"red")
        let duplicate = try XCTUnwrap(model.duplicateTab(original.id))
        XCTAssertEqual(model.tabs.map(\.id), [original.id,duplicate.id]); XCTAssertFalse(duplicate.connected)
        XCTAssertEqual(duplicate.state.local.path,root.path); XCTAssertEqual(duplicate.state.remote.path,"/data/current")
        XCTAssertEqual(duplicate.state.local.history,original.state.local.history); XCTAssertEqual(duplicate.state.local.filter,"txt"); XCTAssertEqual(duplicate.state.local.bookmarks,[root.path]); XCTAssertTrue(duplicate.state.local.selection.isEmpty)
        model.renameTab(duplicate.id,name:"工作 B"); model.colorTab(duplicate.id,color:"green")
        XCTAssertEqual(original.state.title,"工作 A"); XCTAssertEqual(original.state.color,"red"); XCTAssertEqual(original.state.profile.name,siteName); XCTAssertEqual(original.state.profile.color,siteColor)
        model.renameTab(duplicate.id,name:" "); model.colorTab(duplicate.id,color:nil)
        XCTAssertEqual(duplicate.state.title,siteName); XCTAssertEqual(duplicate.state.color,siteColor)
        let restored = self.model(root)
        XCTAssertEqual(restored.tabs.map(\.id),model.tabs.map(\.id)); XCTAssertEqual(restored.tabs.first?.state.alias,"工作 A"); XCTAssertEqual(restored.tabs.first?.state.colorOverride,"red"); XCTAssertTrue(restored.tabs.allSatisfy { !$0.connected && !$0.connecting })
    }
    @MainActor func testTargetedCloseOrderAndBatchEdges() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root), a = model.tabs[0], b = model.newLocalTab(), c = model.newLocalTab(), d = model.newLocalTab()
        model.selectTab(b.id); model.moveTab(d.id,relativeTo:a.id,after:false)
        XCTAssertEqual(model.tabs.map(\.id),[d.id,a.id,b.id,c.id]); XCTAssertEqual(model.current?.id,b.id)
        XCTAssertTrue(model.performTab(.close,id:a.id)); XCTAssertEqual(model.current?.id,b.id)
        XCTAssertTrue(model.performTab(.close,id:b.id)); XCTAssertEqual(model.current?.id,c.id)
        XCTAssertFalse(model.canPerformTab(.closeRight,id:c.id)); XCTAssertFalse(model.performTab(.close,id:UUID()))
        model.newLocalTab(); model.selectTab(c.id)
        XCTAssertTrue(model.performTab(.closeRight,id:d.id)); XCTAssertEqual(model.tabs.map(\.id),[d.id]); XCTAssertEqual(model.current?.id,d.id)
        XCTAssertFalse(model.canPerformTab(.closeOthers,id:d.id)); XCTAssertTrue(model.performTab(.close,id:d.id))
        XCTAssertEqual(model.tabs.count,1); XCTAssertTrue(model.tabs[0].state.profile.host.isEmpty); XCTAssertNotEqual(model.tabs[0].id,d.id)
    }
    @MainActor func testPropertyWriteBlocksBatchCloseUntilReadback() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"); try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        for i in 0..<30 { try Data("property".utf8).write(to:data.appendingPathComponent("file\(i)")) }
        let model = model(root), tab = model.tabs[0], other = model.newLocalTab()
        let session = try await SFTPSession.open(Connection(fixture:true)); tab.session = session; tab.connection = Connection(fixture:true); tab.connected = true; tab.state.activeSide = .remote
        let entry = Entry(name:"data",path:data.path,attributes:try LocalFiles.attributes(data.path)); tab.remoteEntries = [entry]; tab.state.remote.selection = [entry.id]
        let editor = FilePropertyEditor(CommandContext(tab:tab)); model.propertyEditor = editor; await editor.load(); editor.recursive = true; editor.change = PropertyChange(permissionMask:1,permissionBits:1)
        var blocked = ""; model.reportTabBlock = { blocked = $0 }
        let applying = Task { await editor.apply() }
        for _ in 0..<100 { if editor.busy { break }; await Task.yield() }
        XCTAssertTrue(editor.busy); XCTAssertFalse(model.performTab(.closeOthers,id:other.id)); XCTAssertEqual(model.tabs.count,2); XCTAssertTrue(blocked.contains("屬性"))
        await applying.value; XCTAssertFalse(editor.busy); XCTAssertEqual(try LocalFiles.attributes(data.appendingPathComponent("file0").path).permissions! & 1,1)
        XCTAssertTrue(model.performTab(.closeOthers,id:other.id)); XCTAssertEqual(model.tabs.map(\.id),[other.id]); await session.close()
    }
    @MainActor func testIndependentTransferConfirmationDoesNotStopIO() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root), tab = model.tabs[0], source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating:71,count:128*1024).write(to:source)
        var record = TransferTask(connection:Connection(),direction:.local,source:source.path,destination:target.path); record.originTabID = tab.id; record.options.speedLimit = 128*1024
        model.queue.enqueue(record)
        var confirmations = 0
        model.confirmTabBackground = { message in confirmations += 1; XCTAssertTrue(message.contains("背景傳輸")); return false }
        XCTAssertFalse(model.performTab(.close,id:tab.id)); XCTAssertEqual(model.tabs[0].id,tab.id)
        model.confirmTabBackground = { _ in confirmations += 1; return true }
        XCTAssertTrue(model.performTab(.close,id:tab.id)); XCTAssertEqual(confirmations,2)
        for _ in 0..<500 { if model.queue.records.first?.state == .complete { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.queue.records.first?.state,.complete); XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:target))
    }
    @MainActor func testSiteDraftPreservesSourceAndCurrentPaths() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = SavedSite(name:"Saved",host:"example.invalid",user:"tester",localPath:"/tmp",remotePath:"/saved")
        try SiteStore(url:root.appendingPathComponent("sites.json")).save([original])
        let model = model(root), tab = model.tabs[0]; tab.state.profile = original; tab.state.local.path = root.path; tab.state.remote.path = "/current"; tab.state.alias = "Current"; tab.state.colorOverride = "purple"
        model.prepareSiteFromTab(tab.id)
        XCTAssertNotEqual(model.draft.id,original.id); XCTAssertEqual(model.draft.localPath,root.path); XCTAssertEqual(model.draft.remotePath,"/current"); XCTAssertEqual(model.draft.color,"purple")
        XCTAssertEqual(model.sites,[original]); XCTAssertEqual(try model.siteStore.load(),[original]); XCTAssertEqual(tab.state.profile,original)
    }
    @MainActor func testCopiedInfoUsesSnapshotAndExcludesSecrets() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root), tab = model.tabs[0], session = try await SFTPSession.open(Connection(fixture:true))
        tab.session = session; tab.connected = true
        let info = ConnectionInfo(host:"host",port:"22",user:"user",sftpVersion:3,ssh:SSHNegotiation(),extensions:["hardlink@openssh.com":"1","statvfs@openssh.com":"2","unsafe\nlabel":"x\u{0}"],capturedAt:Date())
        let inspector = ConnectionInspector(tab:tab,session:session,info:info,commands:model.commands)
        XCTAssertTrue(inspector.current); XCTAssertTrue(inspector.copiedText.contains("SSH 版本：未知")); XCTAssertFalse(inspector.copiedText.contains("可用空間"))
        XCTAssertTrue(inspector.copiedText.contains("statvfs@openssh.com = 2")); XCTAssertTrue(inspector.copiedText.contains("\\u{000A}")); XCTAssertTrue(inspector.copiedText.contains("不代表目前帳號"))
        tab.disconnect(); XCTAssertFalse(inspector.current); XCTAssertTrue(inspector.copiedText.contains("已中斷／上次連線資訊"))
        tab.state.profile.host = "different"; XCTAssertTrue(inspector.copiedText.contains("user@host:22")); XCTAssertFalse(inspector.copiedText.contains("different")); await session.close()
    }
    @MainActor func testDockerIndependentDuplicateMetadataAndCommandCloseGuard() async throws {
        guard ProcessInfo.processInfo.environment["MINASCP_DOCKER"] == "1" else { throw XCTSkip("Loopback Docker required") }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let key = FileManager.default.currentDirectoryPath + "/.local-sftp/keys/id_ed25519"
        let model = model(root), tab = model.tabs[0]
        tab.state = WorkspaceTab(profile:SavedSite(name:"commands",host:"127.0.0.1",user:"tester",port:"22224",identity:key,localPath:root.path,remotePath:"/data"))
        tab.state.id = tab.id
        await tab.connect(authentication:model.authentication); XCTAssertTrue(tab.connected)
        let info = await tab.session!.connectionInfo()
        XCTAssertEqual(info.sftpVersion,3); XCTAssertEqual(info.ssh.version,"2.0"); XCTAssertTrue(info.ssh.implementation?.hasPrefix("OpenSSH_") == true); XCTAssertNotNil(info.ssh.clientCipher); XCTAssertNotNil(info.ssh.serverCipher)
        let publicKey = try String(contentsOfFile:FileManager.default.currentDirectoryPath + "/.local-sftp/advanced/hostkeys/ssh_host_ed25519_key.pub").split(separator:" ")[1]
        let digest = Data(SHA256.hash(data:try XCTUnwrap(Data(base64Encoded:String(publicKey))))).base64EncodedString().replacingOccurrences(of:"=",with:"")
        XCTAssertEqual(info.ssh.hostKeySHA256,"SHA256:"+digest)
        let duplicate = try XCTUnwrap(model.duplicateTab(tab.id))
        for _ in 0..<300 { if duplicate.connected { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(duplicate.connected); XCTAssertFalse(duplicate.session === tab.session); XCTAssertEqual(duplicate.state.remote.path,tab.state.remote.path)
        let context = CommandContext.forSide(tab,side:.remote); model.commands.preview = CommandPreview(context:context,title:"close-guard",scripts:["sleep 0.3","printf done"],timeout:10)
        var message = ""; model.reportTabBlock = { message = $0 }; model.commands.executePreview()
        XCTAssertTrue(model.commands.usesTab(tab.id)); XCTAssertFalse(model.performTab(.closeOthers,id:duplicate.id)); XCTAssertFalse(model.performTab(.reconnect,id:tab.id)); XCTAssertTrue(message.contains("命令"))
        for _ in 0..<500 { if !model.commands.usesTab(tab.id) { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.commands.records.count,2); XCTAssertTrue(model.commands.records.allSatisfy { $0.state == "完成" })
        XCTAssertTrue(model.performTab(.disconnect,id:tab.id)); XCTAssertTrue(duplicate.connected)
        let originalInspector = ConnectionInspector(tab:duplicate,session:duplicate.session!,info:await duplicate.session!.connectionInfo(),commands:model.commands)
        XCTAssertTrue(model.performTab(.reconnect,id:duplicate.id))
        for _ in 0..<300 { if duplicate.connected { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(originalInspector.current); XCTAssertTrue(duplicate.connected)
        tab.disconnect(); duplicate.disconnect()
    }
}
