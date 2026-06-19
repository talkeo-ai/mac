import AppKit
import ApplicationServices

/// Reads the selection via the Accessibility API — non-destructive, no clipboard
/// involvement, and the path macOS privacy changes increasingly favor.
///
/// Strategy:
///   1. Resolve the frontmost app and its focused UI element (with a messaging
///      timeout so a wedged app can't hang us).
///   2. Read `kAXSelectedTextAttribute`; if unsupported, fall back to the
///      selected range + `kAXStringForRangeParameterizedAttribute`.
///   3. On a miss, lazily flip `AXManualAccessibility` on Electron apps so their
///      a11y tree builds — subsequent selections then answer via AX. Best-effort:
///      failures are ignored and the clipboard strategy remains the safety net.
///
/// AX calls are synchronous IPC and can block, so the read runs on a serial
/// background queue and the result hops back to the caller.
final class AccessibilityStrategy: SelectionStrategy {
    private let queue = DispatchQueue(label: "dev.joaquin.talkeo.selection.ax")
    private let messagingTimeout: Float = 0.25

    /// Apps we've already asked to enable manual accessibility, keyed by pid.
    private var manualAccessibilityEnabled = Set<pid_t>()

    func readSelection(completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            let text = self?.read()
            completion(text)
        }
    }

    private func read() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var focused: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusErr == .success, let focused else {
            enableManualAccessibilityIfNeeded(appElement, pid: pid)
            return nil
        }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        if let text = selectedText(of: element) ?? selectedTextViaRange(of: element) {
            return text
        }

        enableManualAccessibilityIfNeeded(appElement, pid: pid)
        return nil
    }

    private func selectedText(of element: AXUIElement) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Some elements expose a selected range but not the text directly.
    private func selectedTextViaRange(of element: AXUIElement) -> String? {
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
