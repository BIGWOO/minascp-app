import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import MinaSCP
final class TransportTests: XCTestCase {
    func testInvalidConnection() {
        var c = Connection(); XCTAssertFalse(c.valid)
        c.host = "example.com"; XCTAssertTrue(c.valid)
        c.port = "0"; XCTAssertFalse(c.valid)
        c.port = "22"; c.host = "-oProxyCommand=x"; XCTAssertFalse(c.valid)
    }
    func testLocalUnicodeAndFolderListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("測試 file.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        let entries = try LocalFiles.list(root.path)
        XCTAssertEqual(entries.count, 2); XCTAssertTrue(entries[0].directory); XCTAssertEqual(entries[1].size, 5)
    }
    @MainActor func testFinderPromiseWritesRequestedDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("remote.txt"), target = root.appendingPathComponent("finder.txt")
        try Data("promise payload".utf8).write(to: source)
        var connection = Connection(); connection.fixture = true
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("config/sites.json")))
        let writer = PromiseWriter(entry: Entry(name: "remote.txt", path: source.path, directory: false, size: 15, modified: ""), connection: connection, model: model)
        let provider = RetainedPromise.make(type: UTType.data.identifier, writer: writer)
        XCTAssertTrue(provider.userInfo as? PromiseWriter === writer)
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(pasteboard.writeObjects([provider]))
        pasteboard.releaseGlobally()
        let done = expectation(description: "promise completed")
        writer.filePromiseProvider(provider, writePromiseTo: target) { error in
            XCTAssertNil(error); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: target))
    }

}
