import AppKit
import ApplicationServices
import CoreGraphics

/// Replaces the current selection in the frontmost app with new text — the
/// "Replace" action of Improve (talkeo-ai/mac#5).
///
/// Two strategies for editable targets, strongest first:
///   1. **Accessibility write** — set `kAXSelectedTextAttribute` on the frontmost
///      app's focused element. Replaces the element's current selection in place,
///      independent of key-window focus and timing, and never touches the
///      clipboard. Reliable for native text controls (`AXTextField` / `AXTextArea`
///      / `AXComboBox`): the Chrome/Brave omnibox, TextEdit, Mail, Notes.
///   2. **Clipboard + ⌘V** — fallback for web content / Electron / contentEditable.
///      Requires the target app to be key, so the caller orders Talkeo's panel out
///      first; we reactivate the target, paste, then restore the user's clipboard.
///
/// **Terminals are deliberately not edited in place.** A terminal selection is
/// copy-only and decoupled from the editable input, and Accessibility exposes the
/// whole scrollback (not a logical input line), so there's no sound way to address
/// the selection for editing — especially in TUIs (e.g. Claude Code) that render
/// their input inside the same buffer. For terminals we put the improved text on
/// the clipboard and let the user paste it deliberately (`copyToClipboard`).
final class SelectionReplacer {
    private let pasteboard: NSPasteboard
    /// AX calls are synchronous IPC and can block; run them off the main thread.
    private let queue = DispatchQueue(label: "dev.joaquin.talkeo.selection.replace")
    private let messagingTimeout: Float = 0.25
    /// Delay before the fallback ⌘V, so the reactivated target app is key first.
    private let pasteDelay: TimeInterval
    /// Delay before restoring the user's clipboard, after the paste is consumed.
    private let restoreDelay: TimeInterval

    init(
        pasteboard: NSPasteboard = .general,
        pasteDelay: TimeInterval = 0.10,
        restoreDelay: TimeInterval = 0.30
    ) {
        self.pasteboard = pasteboard
        self.pasteDelay = pasteDelay
        self.restoreDelay = restoreDelay
    }

    // MARK: Terminals (copy, not edit)

    /// Known terminal emulators. Their selections are copy-only and decoupled from
    /// the editable input, so Replace degrades to Copy for these (see class doc).
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "dev.warp.warp-stable",
        "co.zeit.hyper",
        "org.tabby",
    ]

    /// Whether `app` is a known terminal emulator (case-insensitive bundle id).
    static func isTerminal(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier?.lowercased() else { return false }
        return terminalBundleIDs.contains(id)
    }

    /// Put `text` on the clipboard for the user to paste themselves (no restore) —
    /// the safe Replace path for targets we can't edit in place (terminals).
    func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Editable targets (AX write, then clipboard)

    /// Replace the frontmost selection with `text`. `target` is the app that owned
    /// the selection (captured before Talkeo's panel closed), reactivated only for
    /// the clipboard fallback. No-op for empty text.
    func replace(with text: String, reactivating target: NSRunningApplication?) {
        guard !text.isEmpty else { return }
        SelectionReplacer.dbg("replace() target=\(target?.bundleIdentifier ?? "nil") textLen=\(text.count)")
        queue.async { [weak self] in
            guard let self else { return }
            if self.accessibilityReplace(with: text) {
                SelectionReplacer.dbg("AX write SUCCEEDED")
                return
            }
            SelectionReplacer.dbg("AX write failed → clipboard paste fallback")
            DispatchQueue.main.async {
                self.clipboardReplace(with: text, reactivating: target)
            }
        }
    }

    static func dbg(_ msg: String) {
        guard ProcessInfo.processInfo.environment["TALKEO_REPLACE_DEBUG"] != nil else { return }
        NSLog("[TalkeoReplace] %@", msg)
    }

    /// Try to replace the focused native text element's selection via AX. Returns
    /// true only when it actually wrote into a settable, currently-selected native
    /// control — otherwise the caller uses the clipboard fallback.
    private func accessibilityReplace(with text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        SelectionReplacer.dbg("AX: frontmost=\(app.bundleIdentifier ?? "nil") pid=\(app.processIdentifier)")

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused
        else { SelectionReplacer.dbg("AX: no focused element"); return false }
        // `focused` is an untyped CFTypeRef; a plain cast to AXUIElement can't fail
        // at compile time but would silently reinterpret a wrong CF type, so verify
        // the runtime type id first and bail to the clipboard fallback if it differs.
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            SelectionReplacer.dbg("AX: focused element is not an AXUIElement")
            return false
        }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        let role = copyString(element, kAXRoleAttribute)
        let settable = isSettable(element, kAXSelectedTextAttribute)
        let hasSel = hasSelection(element)
        SelectionReplacer.dbg("AX: role=\(role ?? "nil") settable=\(settable) hasSelection=\(hasSel)")

        // Only native text controls — web areas / groups (contentEditable) fall
        // through to the clipboard, where Chromium's AX write is unreliable.
        guard let role, AXSelectionDecision.trustedTextRoles.contains(role) else { return false }

        // The attribute must be writable, and there must be a live selection, so we
        // replace what's selected rather than inserting at a collapsed caret.
        guard settable, hasSel else { return false }

        // Chromium (and other web/Electron content) returns `.success` for the
        // write but silently no-ops it. Don't trust the status — verify the
        // element's value actually changed; if it didn't, report failure so the
        // caller falls back to clipboard + ⌘V, which web fields honor.
        let before = copyString(element, kAXValueAttribute)
        let wrote = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
        let after = copyString(element, kAXValueAttribute)
        let changed = wrote && before != nil && after != before
        SelectionReplacer.dbg("AX verify: wrote=\(wrote) valueChanged=\(changed)")
        return changed
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// True when the element currently has a non-empty selection (text or range).
    private func hasSelection(_ element: AXUIElement) -> Bool {
        if let text = copyString(element, kAXSelectedTextAttribute), !text.isEmpty { return true }

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue
        else { return false }
        // Verify the CF type id before casting — see `accessibilityReplace`.
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return false }
        // swiftlint:disable:next force_cast
        let axRange = rangeValue as! AXValue
        var range = CFRange()
        return AXValueGetValue(axRange, .cfRange, &range) && range.length > 0
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func clipboardReplace(with text: String, reactivating target: NSRunningApplication?) {
        // Snapshot so we can put the user's clipboard back afterwards.
        let snapshot = pasteboard.snapshotItems()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Make sure the target app is key before the keystroke lands (Talkeo's
        // non-activating panel left it frontmost; activate promotes its window).
        target?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            guard let self else { return }
            SelectionReplacer.sendPasteKeystroke()
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restoreDelay) {
                self.pasteboard.restore(items: snapshot)
            }
        }
    }

    /// Posts ⌘V at the HID level (mirrors `ClipboardStrategy.sendCopyKeystroke`,
    /// key `c` → `v`).
    private static func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)  // left cmd
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)    // v
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        let loc: CGEventTapLocation = .cghidEventTap
        cmdDown?.post(tap: loc)
        vDown?.post(tap: loc)
        vUp?.post(tap: loc)
        cmdUp?.post(tap: loc)
    }
}
