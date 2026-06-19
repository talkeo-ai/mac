import AppKit
import XCTest
@testable import Talkeo

private struct FakeAXElement: AXElementReading {
    var role: String?
    var selectedTextSupported: Bool
    var selectedText: String?
    var selectedRangeText: String?
}

final class AXSelectionDecisionTests: XCTestCase {
    /// VS Code / Monaco fix: a real text area with an empty selection is
    /// authoritative → stop (do not fall through to the clipboard).
    func testTextAreaEmptyIsAuthoritativeEmpty() {
        let el = FakeAXElement(role: "AXTextArea", selectedTextSupported: true, selectedText: "", selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .empty)
    }

    func testTextAreaWithTextReturnsText() {
        let el = FakeAXElement(role: "AXTextArea", selectedTextSupported: true, selectedText: "hello", selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .text("hello"))
    }

    /// Range-based text wins when the direct attribute is empty.
    func testRangeTextReturnsText() {
        let el = FakeAXElement(role: "AXTextField", selectedTextSupported: true, selectedText: "", selectedRangeText: "ranged")
        XCTAssertEqual(AXSelectionDecision.decide(el), .text("ranged"))
    }

    func testTextFieldEmptyIsAuthoritativeEmpty() {
        let el = FakeAXElement(role: "AXTextField", selectedTextSupported: true, selectedText: "", selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .empty)
    }

    /// THE Chrome guard: an empty web area must NOT be trusted as empty — fall
    /// through to the clipboard so a real selection is never suppressed.
    func testWebAreaEmptyIsUnsupported() {
        let el = FakeAXElement(role: "AXWebArea", selectedTextSupported: true, selectedText: "", selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .unsupported)
    }

    func testWebAreaWithTextReturnsText() {
        let el = FakeAXElement(role: "AXWebArea", selectedTextSupported: true, selectedText: "selected", selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .text("selected"))
    }

    func testUnknownRoleEmptyIsUnsupported() {
        let el = FakeAXElement(role: "AXGroup", selectedTextSupported: true, selectedText: "", selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .unsupported)
    }

    /// Attribute not supported on a text role → can't tell → fall through.
    func testUnsupportedAttributeOnTextRoleIsUnsupported() {
        let el = FakeAXElement(role: "AXTextArea", selectedTextSupported: false, selectedText: nil, selectedRangeText: nil)
        XCTAssertEqual(AXSelectionDecision.decide(el), .unsupported)
    }
}
