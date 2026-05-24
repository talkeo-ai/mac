import AppKit
import ApplicationServices

/// Reads the currently selected text on the system.
/// Strategy:
///   1. Ask the focused UI element for its `AXSelectedText`. Most native apps
///      and web views with proper accessibility support answer here.
///   2. If empty/unsupported (common in Electron apps), fall back to a
///      transient Cmd+C, read the pasteboard, then restore prior contents.
final class SelectionReader {
    func readSelectedText(completion: @escaping (String?) -> Void) {
        if let text = readViaAccessibility(), !text.isEmpty {
            completion(text)
            return
        }
        readViaClipboardFallback(completion: completion)
    }

    // MARK: - Accessibility path

    private func readViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusErr == .success, let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let text = value as? String else { return nil }
        return text
    }

    // MARK: - Clipboard fallback path

    private func readViaClipboardFallback(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let priorChangeCount = pasteboard.changeCount

        sendCopyKeystroke()

        // Give the frontmost app a beat to populate the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            defer { snapshot.restore(into: pasteboard) }

            guard pasteboard.changeCount != priorChangeCount else {
                completion(nil)
                return
            }
            let text = pasteboard.string(forType: .string)
            completion(text?.isEmpty == false ? text : nil)
        }
    }

    private func sendCopyKeystroke() {
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

/// Captures and restores the pasteboard for every type at the time of capture.
/// Best-effort: not all promise providers will survive a restore.
private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            captured.append(dict)
        }
        self.items = captured
    }

    func restore(into pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pbItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if !pbItems.isEmpty {
            pasteboard.writeObjects(pbItems)
        }
    }
}
