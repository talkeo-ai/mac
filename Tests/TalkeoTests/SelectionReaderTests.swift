import XCTest
@testable import Talkeo

private final class SpyStrategy: SelectionStrategy {
    let result: SelectionResult
    private(set) var callCount = 0

    init(_ result: SelectionResult) { self.result = result }

    func readSelection(completion: @escaping (SelectionResult) -> Void) {
        callCount += 1
        completion(result)
    }
}

final class SelectionReaderTests: XCTestCase {
    /// Excluded app → nil, and NO strategy is invoked (no synthetic Cmd+C).
    func testExcludedAppShortCircuitsStrategies() {
        let spy = SpyStrategy(.text("should not run"))
        let reader = SelectionReader(
            strategies: [spy],
            exclusions: AppExclusionList(bundleIDs: ["com.apple.Music"]),
            frontmostBundleID: { "com.apple.Music" }
        )

        let exp = expectation(description: "completion")
        reader.readSelectedText { text in
            XCTAssertNil(text)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(spy.callCount, 0, "excluded app must not invoke any strategy")
    }

    /// First strategy `.empty` → nil, and the second strategy is NOT tried.
    func testAuthoritativeEmptyStopsPipeline() {
        let first = SpyStrategy(.empty)
        let second = SpyStrategy(.text("clipboard line"))
        let reader = SelectionReader(
            strategies: [first, second],
            frontmostBundleID: { "com.microsoft.VSCode" }
        )

        let exp = expectation(description: "completion")
        reader.readSelectedText { text in
            XCTAssertNil(text)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(first.callCount, 1)
        XCTAssertEqual(second.callCount, 0, "empty is authoritative — do not fall through")
    }

    /// `.unsupported` falls through to the next strategy.
    func testUnsupportedFallsThrough() {
        let first = SpyStrategy(.unsupported)
        let second = SpyStrategy(.text("from clipboard"))
        let reader = SelectionReader(
            strategies: [first, second],
            frontmostBundleID: { "com.google.Chrome" }
        )

        let exp = expectation(description: "completion")
        reader.readSelectedText { text in
            XCTAssertEqual(text, "from clipboard")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(first.callCount, 1)
        XCTAssertEqual(second.callCount, 1)
    }

    /// Empty text in `.text` is treated as no selection.
    func testEmptyTextDeliversNil() {
        let reader = SelectionReader(
            strategies: [SpyStrategy(.text(""))],
            frontmostBundleID: { "com.apple.TextEdit" }
        )

        let exp = expectation(description: "completion")
        reader.readSelectedText { text in
            XCTAssertNil(text)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
