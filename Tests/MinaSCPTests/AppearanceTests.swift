import XCTest
@testable import MinaSCP

final class AppearanceTests: XCTestCase {
    private let legacy = Data("""
    {"version":1,"showHidden":true,"commanderKeys":false,"concurrentTransfers":4,
    "speedLimit":65536,"preserveTime":false,"preservePermissions":true,
    "editorPath":"/Applications/TextEdit.app","defaultCollision":"每次詢問",
    "notifyCompletion":true,"queueExpanded":true,"restoreWorkspace":false,
    "exclusions":".git,private","confirmTransfers":true,"reconnectAttempts":3,
    "localColumns":[300,90,170,70],"remoteColumns":[280,95,160,75]}
    """.utf8)

    private func legacyData() throws -> Data {
        // The fixture's original keys stay fixed while the existing collision value
        // is supplied from the domain enum, whose persisted spelling is unrelated.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json["defaultCollision"] = CollisionPolicy.ask.rawValue
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testLegacySettingsKeepUserChoicesAndGainAppearanceDefaults() throws {
        let value = try JSONDecoder().decode(Preferences.self, from: legacyData())
        XCTAssertEqual(value.appearanceMode, .light)
        XCTAssertEqual(value.glassTransparency, 50)
        XCTAssertTrue(value.showHidden)
        XCTAssertFalse(value.commanderKeys)
        XCTAssertEqual(value.concurrentTransfers, 4)
        XCTAssertEqual(value.speedLimit, 65536)
        XCTAssertEqual(value.editorPath, "/Applications/TextEdit.app")
        XCTAssertTrue(value.preservePermissions)
        XCTAssertFalse(value.restoreWorkspace)
        XCTAssertTrue(value.queueExpanded)
        XCTAssertEqual(value.exclusions, ".git,private")
        XCTAssertEqual(value.remoteColumns, [280, 95, 160, 75])
        XCTAssertFalse(Preferences().queueExpanded)
    }

    func testAppearanceRoundTripAndOutOfRangeValues() throws {
        for mode in AppearanceMode.allCases {
            var value = Preferences(); value.appearanceMode = mode; value.glassTransparency = 73
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(value)), value)
        }
        for (input, expected) in [(-30.0, 0.0), (150.0, 100.0)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData()) as? [String: Any])
            json["glassTransparency"] = input
            let data = try JSONSerialization.data(withJSONObject: json)
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data).glassTransparency, expected)
        }
        XCTAssertEqual(Preferences.normalizedTransparency(.nan), 50)
    }

    func testAccessibilityOverridesBackdropWithoutChangingSavedChoice() {
        let opaque = GlassAppearance.backgroundOpacity(transparency: 0, reduceTransparency: false, increaseContrast: false)
        let middle = GlassAppearance.backgroundOpacity(transparency: 50, reduceTransparency: false, increaseContrast: false)
        let transparent = GlassAppearance.backgroundOpacity(transparency: 100, reduceTransparency: false, increaseContrast: false)
        XCTAssertEqual(opaque, 1)
        XCTAssertGreaterThan(opaque, middle)
        XCTAssertGreaterThan(middle, transparent)
        XCTAssertGreaterThan(transparent, 0)
        XCTAssertEqual(GlassAppearance.backgroundOpacity(transparency: 100, reduceTransparency: true, increaseContrast: false), 1)
        XCTAssertGreaterThan(GlassAppearance.backgroundOpacity(transparency: 100, reduceTransparency: false, increaseContrast: true), middle)
    }

    @MainActor func testAppearanceSavePreservesWorkspaceAndDoesNotReconfigureQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        let tab = try XCTUnwrap(model.current), selected = model.selectedTabID
        tab.state.local.filter = "README"; tab.state.local.selection = ["/fixture/README.md"]
        model.preferences.concurrentTransfers = 7
        model.updateAppearance(mode: .dark, transparency: 81)
        model.flushAppearancePreferences()
        XCTAssertEqual(model.queue.concurrency, 2)
        XCTAssertTrue(model.current === tab)
        XCTAssertEqual(model.selectedTabID, selected)
        XCTAssertEqual(tab.state.local.filter, "README")
        XCTAssertEqual(tab.state.local.selection, ["/fixture/README.md"])
        let saved = try XCTUnwrap(AtomicStore<Preferences>(url: root.appendingPathComponent("preferences-v1.json")).load())
        XCTAssertEqual(saved.appearanceMode, .dark)
        XCTAssertEqual(saved.glassTransparency, 81)
        model.resetAppearance(); model.flushAppearancePreferences()
        XCTAssertEqual(model.preferences.appearanceMode, .light)
        XCTAssertEqual(model.preferences.glassTransparency, 50)
        XCTAssertEqual(model.preferences.concurrentTransfers, 7)
        let restarted = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        XCTAssertEqual(restarted.preferences.appearanceMode, .light)
        XCTAssertEqual(restarted.preferences.glassTransparency, 50)
    }

    @MainActor func testAppearanceDebounceSavesLatestValueWithoutClosingSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        model.updateAppearance(mode: .dark, transparency: 10)
        model.updateAppearance(transparency: 60)
        model.updateAppearance(mode: .system, transparency: 90)
        let store = AtomicStore<Preferences>(url: root.appendingPathComponent("preferences-v1.json"))
        for _ in 0..<30 {
            if try store.load()?.glassTransparency == 90 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.appearanceMode, .system)
        XCTAssertEqual(saved.glassTransparency, 90)
    }

    @MainActor func testCorruptPreferencesAreNotOverwrittenByAppearanceAutosave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("preferences-v1.json"), invalid = Data("{ broken settings".utf8)
        try invalid.write(to: path)
        let model = BrowserModel(siteStore: SiteStore(url: root.appendingPathComponent("sites.json")))
        model.updateAppearance(mode: .dark, transparency: 70); model.flushAppearancePreferences()
        XCTAssertEqual(try Data(contentsOf: path), invalid)
        XCTAssertTrue(model.error?.contains("禁止覆寫") == true)
    }

    func testMissingExistingPreferenceStillFailsInsteadOfSilentlyResetting() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData()) as? [String: Any])
        json.removeValue(forKey: "concurrentTransfers")
        XCTAssertThrowsError(try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testBreadcrumbsPreserveUnicodeAndAbsoluteParentPaths() {
        let crumbs = PathCrumb.components(of: "/var/www/網站 assets")
        XCTAssertEqual(crumbs.map(\.path), ["/", "/var", "/var/www", "/var/www/網站 assets"])
        XCTAssertEqual(crumbs.last?.title, "網站 assets")
        XCTAssertEqual(PathCrumb.components(of: "/"), [PathCrumb(path: "/", title: "/")])
    }
}
