import XCTest
@testable import Talkeo

final class AppExclusionListTests: XCTestCase {
    private let list = AppExclusionList(bundleIDs: ["com.apple.Music", "com.spotify.client"])

    func testExcludedBundleID() {
        XCTAssertTrue(list.isExcluded(bundleID: "com.apple.Music"))
    }

    func testExcludedIsCaseInsensitive() {
        XCTAssertTrue(list.isExcluded(bundleID: "COM.APPLE.MUSIC"))
    }

    func testNonListedIsNotExcluded() {
        XCTAssertFalse(list.isExcluded(bundleID: "com.microsoft.VSCode"))
    }

    func testNilBundleIDIsNotExcluded() {
        XCTAssertFalse(list.isExcluded(bundleID: nil))
    }

    func testDefaultsIncludeMediaApps() {
        let defaults = AppExclusionList()
        XCTAssertTrue(defaults.isExcluded(bundleID: "com.apple.TV"))
        XCTAssertTrue(defaults.isExcluded(bundleID: "com.apple.podcasts"))
    }
}
