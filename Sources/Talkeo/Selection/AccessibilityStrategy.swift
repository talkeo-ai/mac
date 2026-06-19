import AppKit
import ApplicationServices

/// Minimal seam over an AX element so the selection decision is unit-testable
/// without a live app. The live implementation wraps an `AXUIElement`.
protocol AXElementReading {
    /// `kAXRoleAttribute` (e.g. "AXTextArea", "AXWebArea").
    var role: String? { get }
    /// Whether `kAXSelectedTextAttribute` returned `.success` at all.
    var selectedTextSupported: Bool { get }
    /// The value of `kAXSelectedTextAttribute` (may be ""), nil if not readable.
    var selectedText: String? { get }
    /// Text for the selected range when its length > 0, else nil.
    var selectedRangeText: String? { get }
}

/// Pure decision logic, separated from AppKit/AX so it is trivially testable.
enum AXSelectionDecision {
    /// Roles whose *empty* selection we trust as authoritative. A web area or an
    /// unknown role reporting empty is NOT trusted — it falls through to the
    /// clipboard so we never suppress a real (e.g. Chrome) selection.
    static let trustedTextRoles: Set<String> = [
        kAXTextFieldRole as String, // "AXTextField"
        kAXTextAreaRole as String,  // "AXTextArea" — Monaco after AXManualAccessibility
        kAXComboBoxRole as String,  // "AXComboBox"
    ]

    static func decide(_ element: AXElementReading) -> SelectionResult {
        // 1. Real selected text wins immediately, for any role.
        if let text = element.selectedText, !text.isEmpty { return .text(text) }
        if let text = element.selectedRangeText, !text.isEmpty { return .text(text) }

        // 2. No text. Authoritative empty only for a real, known text control whose
        //    selected-text attribute was actually supported.
        if let role = element.role,
           trustedTextRoles.contains(role),
           element.selectedTextSupported {
            return .empty
        }

        // 3. AXWebArea / unknown role / unsupported attribute → can't tell.
        return .unsupported
    }
}

/// Reads the selection via the Accessibility API — non-destructive, no clipboard
/// involvement, and the path macOS privacy changes increasingly favor.
///
/// Resolves the frontmost app's focused element (with a messaging timeout), runs
/// the role-gated decision, and on a miss lazily flips `AXManualAccessibility` on
/// Electron apps so their a11y tree builds and subsequent selections answer via AX.
/// AX calls are synchronous IPC and can block, so the read runs on a serial queue.
final class AccessibilityStrategy: SelectionStrategy {
    private let queue = DispatchQueue(label: "dev.joaquin.talkeo.selection.ax")
    private let messagingTimeout: Float = 0.25

    /// Apps we've already asked to enable manual accessibility, keyed by pid.
    private var manualAccessibilityEnabled = Set<pid_t>()

    func readSelection(completion: @escaping (SelectionResult) -> Void) {
        queue.async { [weak self] in
            completion(self?.read() ?? .unsupported)
        }
    }

    private func read() -> SelectionResult {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unsupported }
        let pid = app.processIdentifier

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var focused: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusErr == .success, let focused else {
            enableManualAccessibilityIfNeeded(appElement, pid: pid)
            return .unsupported
        }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        let decision = AXSelectionDecision.decide(LiveAXElement(element: element))
        if decision == .unsupported {
            enableManualAccessibilityIfNeeded(appElement, pid: pid)
        }
        return decision
    }

    /// Electron apps keep their a11y tree off until an AT requests it. Setting
    /// `AXManualAccessibility` builds it. The tree populates asynchronously, so the
    /// current selection still falls through — the next one will use AX.
    private func enableManualAccessibilityIfNeeded(_ appElement: AXUIElement, pid: pid_t) {
        guard !manualAccessibilityEnabled.contains(pid) else { return }
        manualAccessibilityEnabled.insert(pid)
        // Best-effort: ignore kAXErrorAttributeUnsupported and friends.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// Live `AXElementReading` backed by a real `AXUIElement`.
private struct LiveAXElement: AXElementReading {
    let element: AXUIElement

    var role: String? {
        copyAttribute(kAXRoleAttribute) as? String
    }

    private var selectedTextResult: (supported: Bool, value: String?) {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success else { return (false, nil) }
        return (true, value as? String)
    }

    var selectedTextSupported: Bool { selectedTextResult.supported }
    var selectedText: String? { selectedTextResult.value }

    var selectedRangeText: String? {
        var rangeValue: AnyObject?
        let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard rangeErr == .success, let rangeValue else { return nil }
        // swiftlint:disable:next force_cast
        let axRange = rangeValue as! AXValue

        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range), range.length > 0 else { return nil }

        var stringValue: AnyObject?
        let strErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &stringValue
        )
        guard strErr == .success, let text = stringValue as? String, !text.isEmpty else { return nil }
        return text
    }

    private func copyAttribute(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }
}
