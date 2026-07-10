import AppKit
import SwiftUI

/// Shared building blocks of the main window's tool pages (Translate,
/// Improve, Listen, …). Each page keeps its own layout and states — these are
/// the identical pieces: the native pane editor, the quiet icon buttons, and
/// the history-drawer chrome. Same split as `ExplainCardParts` for the cards.

/// Minimal NSTextView wrapper for a page's text panes. SwiftUI's TextEditor
/// misbehaves for real editing here (selection/paste — same class of problem
/// feat/ui-options hit in the popover inputs), so the panes use the real
/// thing: native selection, context menu, undo, and overlay scrollers that
/// only appear when the content actually overflows.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Fired only on user edits (typing/paste) — programmatic `text` updates
    /// don't trigger it, so loading history entries doesn't re-translate.
    var onUserEdit: (() -> Void)?
    /// Select-to-explain: fired when a mouse selection settles, snapped to
    /// whole words. Read-only panes then collapse the OS selection so the
    /// marker is the pick indicator; editable ones keep it (type-over-selection
    /// must still work).
    var onWordSelect: ((String, NSRange) -> Void)?
    /// Picked-term markers drawn behind the text (rounded, popover-style).
    var markers: [(range: NSRange, active: Bool)] = []
    /// Override marker fill (Improve's red diff tint); nil keeps the standard
    /// pick-marker look.
    var markerColor: NSColor?
    /// Word currently being spoken (Listen): drawn in accent on top of any
    /// markers, karaoke-style. `nil` everywhere else.
    var spokenRange: NSRange? = nil
    /// Return commits (e.g. Listen's "play this"); Shift+Return still inserts
    /// a real line break. `nil` (Translate's/Improve's default) leaves Return
    /// as a plain newline.
    var onCommit: (() -> Void)? = nil
    /// Fire `onWordSelect` on a plain click, not just a drag-selection —
    /// Listen's "tap any word to jump there" (see
    /// `MarkerTextView.picksOnPlainClick`).
    var picksOnPlainClick: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkerTextView()
        // The app's source pane is a live editor AND picks words — unlike the
        // popover, where editing means caret-only.
        textView.allowsPickWhileEditable = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = Palette.nsForeground
        textView.insertionPointColor = Palette.nsForeground
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        // Snap-to-word picking (collapse rule included) lives in
        // MarkerTextView. Reads the fresh struct through the coordinator —
        // the closure outlives this render.
        let coordinator = context.coordinator
        textView.onWordPick = { term, range in
            coordinator.parent.onWordSelect?(term, range)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: Palette.nsForeground,
            .paragraphStyle: paragraph,
        ]
        textView.font = .systemFont(ofSize: 16)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkerTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.picksOnPlainClick = picksOnPlainClick
        if textView.string != text {
            textView.string = text
        }
        // Drop any marker that outran the text (belt over the model's
        // clear-on-edit) so drawing never indexes past the storage.
        let length = (textView.string as NSString).length
        textView.markers = markers.filter { NSMaxRange($0.range) <= length }
        textView.markerColor = markerColor
        textView.spokenMarker = spokenRange.flatMap { NSMaxRange($0) <= length ? $0 : nil }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onUserEdit?()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let onCommit = parent.onCommit,
                  commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            onCommit()
            return true
        }
    }
}

/// Small quiet icon button used inside the panes (clear, copy, history).
struct PaneIconButton: View {
    let system: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isHover ? Palette.foreground : Palette.muted)
                .frame(width: size, height: size)
                .background(Circle().fill(isHover ? Palette.surface : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .help(help)
    }
}

struct CopyButton: View {
    let text: String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        PaneIconButton(system: copied ? "checkmark" : "doc.on.doc", help: help) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

/// Small quiet speaker that reads English aloud (offline voice).
struct SpeakerButton: View {
    let english: String

    var body: some View {
        PaneIconButton(system: "speaker.wave.2", help: "Listen", size: 28) {
            Speaker.speak(english, lang: "EN")
        }
    }
}

/// Labeled toggle for the history drawer — icon + text so it doesn't read as
/// decoration.
struct HistoryToggle: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isOpen || isHover ? Palette.foreground : Palette.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Palette.elevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .help(isOpen ? "Hide history" : "Show history")
    }
}

/// The history row's delete affordance: a bare trash glyph on a small rounded
/// tile (matching the row's corner language — a circle read as a hole in the
/// hovered card), muted until the pointer reaches it.
struct RowDeleteButton: View {
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHover ? Palette.foreground : Palette.muted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHover ? Palette.surface : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .help("Delete")
    }
}
