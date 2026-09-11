import XCTest
@testable import MinaSCP
final class SiteTests: XCTestCase {
    @MainActor func testSitesSurviveRestartAndCanUpdateAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SiteStore(url: root.appendingPathComponent("sites.json"))
        let first = BrowserModel(siteStore: store)
        first.connection = Connection(host: "127.0.0.1", user: "tester", port: "22222", identity: "/test/key")
        first.siteName = "本機測試"; first.remotePath = "/data"
        XCTAssertTrue(first.saveSite())
        let second = BrowserModel(siteStore: store)
        XCTAssertEqual(second.sites.count, 1, second.error ?? "no error")
        XCTAssertEqual(try store.load().count, 1)
        second.selectSite(try XCTUnwrap(second.sites.first))
        XCTAssertEqual(second.connection, first.connection)
        XCTAssertEqual(second.remotePath, "/data")
        XCTAssertFalse(second.connected)
        second.siteName = "修改名稱"; XCTAssertTrue(second.saveSite())
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertEqual(try store.load().first?.name, "修改名稱")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        second.deleteSite(second.sites[0]); XCTAssertTrue(try store.load().isEmpty)
    }
    func testCorruptStoreIsNotSilentlyDiscarded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try SiteStore(url: url).load())
    }
}
