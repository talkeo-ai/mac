import XCTest
@testable import Talkeo

/// Verifies the Improve diff-highlight locates a change's `original` fragment in
/// the source even when the backend normalized whitespace (the bug where a
/// fragment spanning a line break got no red highlight).
final class ImproveHighlightTests: XCTestCase {
    private func range(_ fragment: String, in source: String, from start: Int = 0) -> NSRange {
        QuickTranslateModel.flexibleRange(of: fragment, in: source as NSString, from: start)
    }

    func testExactMatch() {
        let source = "I work out every morning."
        let r = range("work out", in: source)
        XCTAssertEqual((source as NSString).substring(with: r), "work out")
    }

    func testMatchesAcrossNewline() {
        // Source has a hard line break + indent; the fragment uses single spaces.
        let source = "check the intension\n  and give me the final phrase."
        let fragment = "intension and give me the final"
        let r = range(fragment, in: source)
        XCTAssertNotEqual(r.location, NSNotFound)
        // The matched span starts at "intension" and ends at "final".
        let matched = (source as NSString).substring(with: r)
        XCTAssertTrue(matched.hasPrefix("intension"))
        XCTAssertTrue(matched.hasSuffix("final"))
    }

    func testMatchesCollapsedDoubleSpaces() {
        let source = "the  committee    reached an accord"
        let r = range("committee reached", in: source)
        XCTAssertNotEqual(r.location, NSNotFound)
    }

    func testForwardCursorDisambiguatesRepeats() {
        let source = "set it and forget it"
        let first = range("it", in: source, from: 0)
        let second = range("it", in: source, from: NSMaxRange(first))
        XCTAssertEqual(first.location, 4)
        XCTAssertEqual(second.location, 18)
    }

    func testRegexMetacharactersAreEscaped() {
        let source = "is this correct? (yes) [maybe]"
        let r = range("correct? (yes)", in: source)
        XCTAssertNotEqual(r.location, NSNotFound)
        XCTAssertEqual((source as NSString).substring(with: r), "correct? (yes)")
    }

    func testNoMatchReturnsNotFound() {
        let r = range("absent fragment", in: "totally different text")
        XCTAssertEqual(r.location, NSNotFound)
    }
}
