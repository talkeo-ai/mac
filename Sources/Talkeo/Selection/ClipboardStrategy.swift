import AppKit
import CoreGraphics

/// Last-resort selection read: a transient synthetic Cmd+C with race-safe
/// snapshot/restore (see `PasteboardCopyService`). Used only when the
/// Accessibility path can't read the selection (some web content, terminals,
/// not-yet-enabled Electron apps).
final class ClipboardStrategy: SelectionStrategy {
    private let service: PasteboardCopyService

    init(pasteboard: PasteboardProtocol = NSPasteboard.general) {
        self.service = PasteboardCopyService(
            pasteboard: pasteboard,
            triggerCopy: ClipboardStrategy.sendCopyKeystroke
        )
    }

    func readSelection(completion: @escaping (SelectionResult) -> Void) {
        // The clipboard can't distinguish "no selection" from "nothing copied", so
        // it never returns `.empty` — a miss is `.unsupported`.
        service.transientCopy { text in
            if let text, !text.isEmpty {
                completion(.text(text))
            } else {
                completion(.unsupported)
            }
        }
    }

    /// Posts ⌘C at the HID level.
    /// TODO: mute the system alert beep that can fire when the frontmost app has
    /// nothing to copy (no public NSSound API; needs a verified approach).
    private static func sendCopyKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)  // left cmd
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)    // c
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand

        let loc: CGEventTapLocation = .cghidEventTap
        cmdDown?.post(tap: loc)
        cDown?.post(tap: loc)
        cUp?.post(tap: loc)
        cmdUp?.post(tap: loc)
    }
}
