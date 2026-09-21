import XCTest
@testable import MinaSCP

final class LocationPresetTests: XCTestCase {
    func testSiteAndSharedPresetsPersistInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicStore<[LocationPreset]>(url: root.appendingPathComponent("presets.json"))
        let site = UUID()
        let presets = [LocationPreset(name: "帳單", localPath: "/tmp/本機", remotePath: "/var/www/billing", siteID: site),
                       LocationPreset(name: "共用", localPath: "/tmp", remotePath: "/var/log", siteID: nil)]
        try store.save(presets)
        XCTAssertEqual(try store.load(), presets)
        try store.save(Array(presets.reversed()))
        XCTAssertEqual(try store.load(), Array(presets.reversed()))
    }
}
