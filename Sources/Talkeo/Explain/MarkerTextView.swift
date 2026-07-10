import AppKit

/// NSTextView shared by every select-to-explain surface (the popover's panes,
/// the app's translator). One class owns the three concerns its two former
/// copies (`WordSelectingTextView`, `ShortcutTextView`) each half-had:
///
/// - **Markers**: rounded highlights behind picked words (`markers`), an
///   optional override fill (`markerColor`, Improve's diff tint), and the
///   karaoke marker for the word being spoken (`spokenMarker`, Listen).
/// - **Pick on settle**: `mouseDown` runs AppKit's whole selection drag loop;
///   when it returns the selection is final and `onWordPick` fires with the
///   selection snapped to whole words. Read-only views then collapse the OS
///   selection so the marker is the pick indicator; editable ones keep it so
///   type-over-selection still works. `allowsPickWhileEditable` opts an
///   editable view into picking (the app's source pane); the default keeps
///   the popover's rule — editing means clicks just place the caret.
/// - **Editing shortcuts**: resolves ⌘A/C/V/X (and ⌘Z/⇧⌘Z where undo is on)
///   itself, so they work both under the popover (menu-bar panel, no Edit
///   menu routing) and the app window, regardless of the main menu.
///
/// Stale-range safety: markers arrive from SwiftUI's update pass, but the
/// storage can change between passes (typing edits it synchronously). Drawing
/// skips any range that outruns the current storage — without this, a picked
/// word near the end plus fast typing raised `NSRangeException` inside
/// `glyphRange(forCharacterRange:)`.
final class MarkerTextView: NSTextView {
    /// Word-snapped pick callback (select-to-explain / select-to-hear).
    var onWordPick: ((String, NSRange) -> Void)?
    /// Let an editable view pick words too (default: editing = caret only).
    var allowsPickWhileEditable = false
    /// Fire `onWordPick` on a plain click (caret placement, zero-length
    /// selection) too — not just on an actual drag-selection. Off by default:
    /// Translate/Improve's pick-to-explain is deliberately a real selection
    /// gesture. Listen's "tap any word to jump there" means a single click,
    /// so its read-only pane opts in.
    var picksOnPlainClick = false
    /// Register a selection on the first click even when the window isn't key.
    /// The popover's non-activating panel needs it; a regular window must not
    /// have it (a first click would pick words while the window is inactive).
    var acceptsFirstMouseEnabled = false

    /// Picked word ranges to draw (range, isFocused).
    var markers: [(range: NSRange, active: Bool)] = []
    /// Optional override fill for the markers (Improve's diff tint).
    var markerColor: NSColor?
    /// Word currently being spoken (Listen) — drawn in accent, karaoke-style.
    var spokenMarker: NSRange?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstMouseEnabled }

    /// `mouseDown` runs the whole selection drag loop; when it returns the
    /// selection is settled and can be reported.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        reportPick()
    }

    /// Snap the settled selection to whole words and report it. Read-only
    /// views collapse the OS selection afterwards (the marker is the pick
    /// indicator); editable ones keep it (type-over must still work).
    private func reportPick() {
        guard let onWordPick, !isEditable || allowsPickWhileEditable else { return }
        let raw = selectedRange()
        let ns = string as NSString
        let snapped: NSRange
        if raw.length > 0 {
            snapped = snapWords(raw, in: ns)
        } else if picksOnPlainClick {
            snapped = wordAt(raw.location, in: ns)
        } else {
            return
        }
        guard snapped.length > 0 else { return }
        onWordPick(ns.substring(with: snapped), snapped)
        if !isEditable {
            DispatchQueue.main.async { [weak self] in
                self?.setSelectedRange(NSRange(location: NSMaxRange(snapped), length: 0))
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, mods == .command || mods == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "a" where mods == .command: selectAll(nil)
        case "c" where mods == .command: copy(nil)
        case "v" where mods == .command: paste(nil)
        case "x" where mods == .command: cut(nil)
        // Gated on `allowsUndo`: views without undo (the popover's) keep
        // passing ⌘Z through instead of swallowing it as a no-op.
        case "z" where allowsUndo && mods == .command: undoManager?.undo()
        case "z" where allowsUndo && mods == [.command, .shift]: undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMarkers()
        drawSpokenMarker()
        super.draw(dirtyRect)
    }

    private func drawMarkers() {
        guard !markers.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        for marker in markers {
            // Skip ranges that outran the storage (edited since the last
            // SwiftUI pass) — indexing past it raises NSRangeException.
            guard NSMaxRange(marker.range) <= length else { continue }
            let glyphRange = lm.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: tc
            ) { rect, _ in
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                let fill: NSColor
                if let tint = self.markerColor {
                    // Diff tint: emphasize the paged fragment, keep the rest visible.
                    fill = marker.active ? tint : tint.withAlphaComponent(tint.alphaComponent * 0.5)
                } else {
                    fill = Palette.marker(active: marker.active)
                }
                fill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    /// The current spoken word, accent-tinted, drawn over the pick markers.
    private func drawSpokenMarker() {
        guard let spokenMarker, spokenMarker.length > 0,
              NSMaxRange(spokenMarker) <= (string as NSString).length,
              let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let glyphRange = lm.glyphRange(forCharacterRange: spokenMarker, actualCharacterRange: nil)
        lm.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: tc
        ) { rect, _ in
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        }
    }
}

/// Grow a raw selection to the whole words it touches; a selection covering no
/// word characters snaps to nothing.
func snapWords(_ range: NSRange, in ns: NSString) -> NSRange {
    let empty = NSRange(location: range.location, length: 0)
    guard range.length > 0, range.location >= 0, NSMaxRange(range) <= ns.length else { return empty }
    let wordSet = CharacterSet.alphanumerics
    func isWord(_ i: Int) -> Bool {
        guard i >= 0, i < ns.length, let s = UnicodeScalar(ns.character(at: i)) else { return false }
        return wordSet.contains(s) || s == "'" || s == "’"
    }
    var first = -1, last = -1
    for i in range.location..<NSMaxRange(range) where isWord(i) {
        if first == -1 { first = i }
        last = i
    }
    guard first != -1 else { return empty }
    var start = first, end = last + 1
    while start > 0, isWord(start - 1) { start -= 1 }
    while end < ns.length, isWord(end) { end += 1 }
    return NSRange(location: start, length: end - start)
}

/// The whole word touching a caret position (a plain click has no selection
/// length, just an insertion point sitting between two characters) — checks
/// the character right at `index` and, if that's not a word char, the one
/// just before it (a caret at the end of a word still counts as touching it).
func wordAt(_ index: Int, in ns: NSString) -> NSRange {
    let empty = NSRange(location: index, length: 0)
    guard index >= 0, index <= ns.length else { return empty }
    let wordSet = CharacterSet.alphanumerics
    func isWord(_ i: Int) -> Bool {
        guard i >= 0, i < ns.length, let s = UnicodeScalar(ns.character(at: i)) else { return false }
        return wordSet.contains(s) || s == "'" || s == "’"
    }
    var i = index
    if !isWord(i), isWord(i - 1) { i -= 1 }
    guard isWord(i) else { return empty }
    var start = i, end = i + 1
    while start > 0, isWord(start - 1) { start -= 1 }
    while end < ns.length, isWord(end) { end += 1 }
    return NSRange(location: start, length: end - start)
}
