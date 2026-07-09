import XCTest
@testable import Talkeo

final class LocalSettingsStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkeo-settings-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testDefaultsToAutoHideOff() {
        let store = LocalSettingsStore(url: url)
        XCTAssertFalse(store.barAutoHide)
    }

    func testPersistsAcrossInstances() {
        LocalSettingsStore(url: url).barAutoHide = true
        XCTAssertTrue(LocalSettingsStore(url: url).barAutoHide)
    }

    func testTogglingBackPersists() {
        let store = LocalSettingsStore(url: url)
        store.barAutoHide = true
        store.barAutoHide = false
        XCTAssertFalse(LocalSettingsStore(url: url).barAutoHide)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertFalse(LocalSettingsStore(url: url).barAutoHide)
    }

    func testSchemaMismatchFallsBackToDefaults() throws {
        try Data(#"{"schemaVersion": 99, "barAutoHide": true}"#.utf8).write(to: url)
        XCTAssertFalse(LocalSettingsStore(url: url).barAutoHide)
    }
}
