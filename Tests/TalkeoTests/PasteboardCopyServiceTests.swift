import AppKit
import XCTest
@testable import Talkeo

/// In-memory pasteboard. Each external write (`simulateExternalWrite`) and each
/// `restore` bumps `changeCount`, mirroring NSPasteboard semantics.
private final class FakePasteboard: PasteboardProtocol {
    private(set) var changeCount = 0
    private var stored: String?
    private(set) var restoreCount = 0

    init(initial: String?) {
        self.stored = initial
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? { stored }

    func snapshotItems() -> [[NSPasteboard.PasteboardType: Data]] {
        guard let stored, let data = stored.data(using: .utf8) else { return [] }
        return [[.string: data]]
    }

    func restore(items: [[NSPasteboard.PasteboardType: Data]]) {
        restoreCount += 1
        changeCount += 1
        if let data = items.first?[.string] {
            stored = String(data: data, encoding: .utf8)
        } else {
            stored = nil
        }
    }

    /// Simulates a copy landing on the pasteboard (ours or the user's).
    func simulateWrite(_ value: String) {
        changeCount += 1
        stored = value
    }
}

final class PasteboardCopyServiceTests: XCTestCase {
    /// Builds a service driven by a synchronous, clock-advancing scheduler so the
    /// recursion runs inline and timeouts are reachable.
    private func makeService(
        pasteboard: FakePasteboard,
        triggerCopy: @escaping () -> Void
    ) -> PasteboardCopyService {
        var clock: TimeInterval = 0
        return PasteboardCopyService(
            pasteboard: pasteboard,
            triggerCopy: triggerCopy,
            now: { clock },
            schedule: { delay, work in
                clock += delay
                work()
            },
            pollInterval: 0.015,
            timeout: 0.4
        )
    }

    /// 1. Normal copy, no interference → returns selection, clipboard restored.
    func testNormalCopyRestoresOriginalClipboard() {
        let pb = FakePasteboard(initial: "user-clipboard")
        let service = makeService(pasteboard: pb) {
            pb.simulateWrite("the selection")
        }

        let exp = expectation(description: "completion")
        service.transientCopy { text in
            XCTAssertEqual(text, "the selection")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(pb.restoreCount, 1)
        XCTAssertEqual(pb.string(forType: .string), "user-clipboard")
    }

    /// 2. Regression for the bug: user copies AFTER our synthetic copy → restore
    ///    must NOT run, and the user's fresh copy must survive.
    func testUserCopyAfterOurCopyIsPreserved() {
        let pb = FakePasteboard(initial: "old-clipboard")
        let service = makeService(pasteboard: pb) {
            pb.simulateWrite("the selection") // our synthetic copy
            pb.simulateWrite("USER FRESH COPY") // user's real Cmd+C, right after
        }

        let exp = expectation(description: "completion")
        service.transientCopy { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(pb.restoreCount, 0, "restore must be skipped when another write landed after ours")
        XCTAssertEqual(pb.string(forType: .string), "USER FRESH COPY")
    }

    /// 3. No selection / app never copies → nil, clipboard untouched.
    func testNoCopyLeavesClipboardUntouched() {
        let pb = FakePasteboard(initial: "user-clipboard")
        let service = makeService(pasteboard: pb) { /* nothing copies */ }

        let exp = expectation(description: "completion")
        service.transientCopy { text in
            XCTAssertNil(text)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(pb.restoreCount, 0)
        XCTAssertEqual(pb.string(forType: .string), "user-clipboard")
    }

    /// 4. Two writes interleave before we observe the count → skip restore.
    func testTwoWriteInterleaveSkipsRestore() {
        let pb = FakePasteboard(initial: "old-clipboard")
        let service = makeService(pasteboard: pb) {
            pb.simulateWrite("user-interleaved") // user's copy lands first
            pb.simulateWrite("the selection") // then ours
        }

        let exp = expectation(description: "completion")
        service.transientCopy { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(pb.restoreCount, 0, "two writes since snapshot → restore skipped")
        XCTAssertEqual(pb.string(forType: .string), "the selection")
    }
}
