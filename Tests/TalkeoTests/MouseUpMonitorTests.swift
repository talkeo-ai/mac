import XCTest
@testable import Talkeo

final class MouseUpMonitorTests: XCTestCase {
    private func candidate(
        didDrag: Bool = false,
        dragDistanceSquared: Double = 0,
        clickState: Int64 = 1,
        shiftHeld: Bool = false
    ) -> Bool {
        MouseUpMonitor.isSelectionCandidate(
            didDrag: didDrag,
            dragDistanceSquared: dragDistanceSquared,
            clickState: clickState,
            shiftHeld: shiftHeld
        )
    }

    func testPlainClickIsNotCandidate() {
        XCTAssertFalse(candidate())
    }

    func testDragBeyondThresholdIsCandidate() {
        XCTAssertTrue(candidate(didDrag: true, dragDistanceSquared: 16))
    }

    func testTinyDragIsNotCandidate() {
        XCTAssertFalse(candidate(didDrag: true, dragDistanceSquared: 4))
    }

    func testMultiClickIsCandidate() {
        XCTAssertTrue(candidate(clickState: 2))
    }

    /// The mac#13 fix: shift+click with no drag and a single click is now detected.
    func testShiftClickIsCandidate() {
        XCTAssertTrue(candidate(shiftHeld: true))
    }
}
