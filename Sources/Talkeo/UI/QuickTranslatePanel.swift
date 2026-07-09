import AppKit
import Combine
import NaturalLanguage
import SwiftUI

/// Compact translate + learn popover that opens from the floating bar's
/// Translate action. It sizes itself to content, can't be moved, and sits at the
/// right margin so it stays out of the way.
///
/// Two parts: the translation (detected language and its translation) and the
/// learning core — **select any word or phrase to see a structured vocabulary
/// card below** (meaning, examples, a typed insight). It dismisses on a click
/// anywhere outside it.
///
/// Presenting makes this panel key WITHOUT activating the app (Spotlight
/// style): opening an option means the user wants to use it, so typing and
/// clicking work immediately — but activating would raise every other Talkeo
/// window too (e.g. the main app window, when open). The app behind keeps
/// being the frontmost app, which Improve's Replace depends on. Cursor
/// correctness inside a key-but-inactive window comes from the same
/// per-window server tag the floating bar uses (`BackgroundCursor.tagWindow`,
/// whose documented purpose is exactly this: panels presenting editable
/// controls from an inactive app).
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view that takes the first click even when its window isn't key, so a
/// single click registers (no "click once to focus, again to act"). Required
/// because `QuickPanel` can become key: without this the activating click is
/// swallowed before it reaches the SwiftUI content.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class QuickTranslatePanel {
    private let panel: NSPanel
    private let model: QuickTranslateModel
    private let replacer = SelectionReplacer()
    private var dismissMonitor: Any?
    private var topAnchor: CGFloat = 0
    private var leftAnchor: CGFloat = 0
    /// Deferred window shrink — see `resize(to:)`.
    private var pendingShrink: DispatchWorkItem?

    /// "Full history" tapped in the Translate/History view. Mirrors
    /// `FloatingBarPanel.onOpenApp` — this panel doesn't know the main app
    /// window exists; whoever owns both (`AppDelegate`) wires this to it once
    /// that window can open to a specific section.
    var onOpenFullHistory: (() -> Void)?

    /// Fires with `true` when the popover comes on screen and `false` once it
    /// leaves, whatever the path (dismiss click, close button, Replace). The
    /// owner uses it to hold the floating bar revealed while we're open.
    var onVisibilityChange: ((Bool) -> Void)?

    /// The app that was frontmost when the popover opened. We don't activate,
    /// so frontmost normally stays put — but capturing it at open time makes
    /// Improve's Replace target independent of whatever focus dance happens
    /// while the popover is up.
    private var previousApp: NSRunningApplication?

    private static let width: CGFloat = 400
    private static let nominalHeight: CGFloat = 170
    private static let maxHeight: CGFloat = 600
    /// Width the floating bar reserves at the right edge (its width + margin),
    /// so the popover tucks just to the left of it. Mirrors `FloatingBarPanel`.
    private static let barReservedWidth: CGFloat = 52 + 8
    private static let gap: CGFloat = 10

    init() {
        let panel = QuickPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.nominalHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu // above the floating bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false

        // Dev affordance: run with TALKEO_STUB_NETWORK set to drive the panel from
        // canned data (build/visually test the UI before the endpoints exist).
        let model = ProcessInfo.processInfo.environment["TALKEO_STUB_NETWORK"] != nil
            ? QuickTranslateModel(client: QuickPreviewClient())
            : QuickTranslateModel()
        self.model = model

        var onResizeRef: ((CGSize) -> Void)?
        var onCloseRef: (() -> Void)?
        var onReplaceRef: ((String) -> Void)?
        var onOpenFullHistoryRef: (() -> Void)?
        let view = QuickTranslateView(
            model: model,
            onResize: { onResizeRef?($0) },
            onClose: { onCloseRef?() },
            onReplace: { onReplaceRef?($0) },
            onOpenFullHistory: { onOpenFullHistoryRef?() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.nominalHeight))
        panel.contentView = hosting

        self.panel = panel
        onResizeRef = { [weak self] size in self?.resize(to: size) }
        onCloseRef = { [weak self] in self?.hide() }
        onReplaceRef = { [weak self] text in self?.performReplace(text) }
        onOpenFullHistoryRef = { [weak self] in self?.onOpenFullHistory?() }
    }

    func show(text: String) {
        // Toggle: re-tapping Translate for the text already on screen means
        // "close it", not "present it again". A different selection still
        // switches the content instead of dismissing.
        if panel.isVisible, model.mode == .translate,
           model.sourceText == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            hide()
            return
        }
        model.translate(text)
        // A single word goes straight to its explain card (the translation still
        // streams in the background, so removing the card falls back to it).
        if QuickTranslateModel.isSingleWord(text) {
            model.explainWholeSource()
        }
        present()
    }

    /// Improve tapped with text selected — rewrite it natively and show the diff.
    /// `targetIsTerminal` flips Replace into a safe Copy (terminals can't be
    /// edited in place).
    func improve(text: String, targetIsTerminal: Bool = false) {
        model.improve(text, targetIsTerminal: targetIsTerminal)
        present()
    }

    /// Listen tapped with text selected — open the Listen card (auto-plays).
    func listen(text: String) {
        model.listen(text)
        present()
    }

    /// Translate tapped with nothing selected — show the local history list.
    /// A bare tap while the popover is already open (whatever it shows) reads
    /// as "close it", so it toggles off instead of switching to history.
    func showHistory() {
        if panel.isVisible {
            hide()
            return
        }
        model.showHistory()
        present()
    }

    /// Apply the improved text in place. The popover holds focus while open,
    /// so the write-back target is the app captured at present time. Order the
    /// panel out instantly so it resigns key with no fade delay, then let the
    /// replacer do its thing (AX write first, clipboard + ⌘V fallback).
    private func performReplace(_ text: String) {
        guard !text.isEmpty else { return }
        let target = previousApp ?? NSWorkspace.shared.frontmostApplication
        // Terminals: the selection is copy-only and decoupled from the editable
        // input, and AX exposes the whole scrollback (not a logical input line), so
        // there's no sound way to edit the selection in place — especially in TUIs
        // like Claude Code. Degrade to a safe Copy; the user pastes it deliberately.
        if SelectionReplacer.isTerminal(target) {
            replacer.copyToClipboard(text)
            closeImmediately()
            target?.activate() // hand focus back for the deliberate paste
            return
        }
        closeImmediately()
        replacer.replace(with: text, reactivating: target)
    }

    /// Order out now (no fade): the fade-out animation would keep the panel key
    /// for ~140ms, so a fallback ⌘V could land here instead of the target app.
    private func closeImmediately() {
        removeDismissMonitor()
        pendingShrink?.cancel()
        pendingShrink = nil
        Speaker.stop() // never let playback outlive the popover
        TTSAudioPlayer.shared.stop()
        panel.orderOut(nil)
        panel.alphaValue = 1
        onVisibilityChange?(false)
    }

    private func present() {
        // Capture who has focus before we take it — only on the transition, so
        // re-presenting while already active can't overwrite it with ourselves.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        computeAnchor()
        // Keep the current height when already visible — snapping down to the
        // nominal height would clip content that's still animating (the next
        // preference-driven `resize` settles it). Fresh presentations start at
        // the nominal height as before.
        pendingShrink?.cancel()
        pendingShrink = nil
        let height = panel.isVisible ? panel.frame.height : Self.nominalHeight
        panel.setFrame(frame(forHeight: height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        // Key only — never NSApp.activate(): activation raises the app's other
        // windows too (the main window, when open), yanking the user out of
        // their context just for a popover.
        panel.makeKey()
        // Cursor authority while key-but-inactive (I-beam over text, etc.);
        // async because tag application is asynchronous in the window server.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = BackgroundCursor.tagWindow(self.panel)
        }
        installDismissMonitor()
        onVisibilityChange?(true)
    }

    func hide() {
        removeDismissMonitor()
        pendingShrink?.cancel()
        pendingShrink = nil
        Speaker.stop() // never let playback outlive the popover
        TTSAudioPlayer.shared.stop()
        guard panel.isVisible, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
        // Release the bar as soon as the fade starts — visually the popover is
        // already going away, so the bar may retract with it.
        onVisibilityChange?(false)
        restoreFocus()
    }

    /// Hand focus back to the app the popover took it from — but only if we
    /// still hold it. Deferred a beat: when the dismissal was a click on
    /// another app, that click's own activation may still be in flight, and
    /// re-activating the previous app here would steal focus from where the
    /// user just put it.
    private func restoreFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, NSApp.isActive else { return }
            self.previousApp?.activate()
        }
    }

    /// Pin the top-left so the popover grows downward from a fixed point, tucked
    /// against the right margin beside the bar and roughly vertically centered.
    private func computeAnchor() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let barLeft = visible.maxX - Self.barReservedWidth
        leftAnchor = max(visible.minX + 8, barLeft - Self.gap - Self.width)
        topAnchor = visible.midY + Self.nominalHeight / 2
    }

    /// Resize to content height, growing downward from `topAnchor`, clamped to
    /// the screen so a long translation never spills off the bottom.
    ///
    /// The window must never be SMALLER than the content while the content is
    /// mid-animation: the content's `withAnimation` transitions (0.22s) lag the
    /// preference-reported target size, and a window already at the smaller
    /// final size hard-clips the still-animating content — rows sliced off at
    /// a square edge, no rounded corner (the rounding is SwiftUI's clipShape
    /// on the content, not a native window shape). So: grow immediately, but
    /// defer shrinks until the content animation has landed. The panel is
    /// transparent and the chrome is drawn at content size, so the oversized
    /// window in the interim is invisible.
    ///
    /// (Animating the window frame itself was tried and reverted — the corner
    /// clip and vibrancy redraw lag the native resize and flash square.)
    private func resize(to size: CGSize) {
        let height = min(max(size.height, 56), Self.maxHeight)
        pendingShrink?.cancel()
        pendingShrink = nil
        if height >= panel.frame.height - 0.5 {
            panel.setFrame(frame(forHeight: height), display: true, animate: false)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingShrink = nil
                self.panel.setFrame(self.frame(forHeight: height), display: true, animate: false)
            }
            pendingShrink = work
            // Slightly past the longest content animation (0.22s translate/open,
            // 0.3s reveal), so the clip only ever trims transparent overhang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
        }
    }

    private func frame(forHeight height: CGFloat) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: leftAnchor, y: topAnchor - height)
        if origin.y < visible.minY + 8 { origin.y = visible.minY + 8 }
        if origin.y + height > visible.maxY - 8 { origin.y = visible.maxY - 8 - height }
        return NSRect(origin: origin, size: NSSize(width: Self.width, height: height))
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        // Global monitor only sees events delivered to other apps, so clicks on
        // the popover's own controls don't dismiss it — only clicks elsewhere do.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeDismissMonitor() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }
    }
}

// MARK: - Model

final class QuickTranslateModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var targetText: String = ""
    /// The language detected in the selection (EN or ES), shown as the top box's
    /// label, and the language we translate it into (the other one).
    @Published var detectedLang: String = "EN"
    @Published var translateLang: String = "ES"
    @Published var phase: Phase = .idle
    /// One-shot blur reveal of the translation: flips true on the first delta.
    @Published var revealed: Bool = false

    /// Terms the user highlighted to learn, the focused one, and their loaded
    /// cards (keyed by term text). Multiple terms page with ‹ ›, like v1.
    /// The state machine is the shared `ExplainSession`; the model re-exposes
    /// it under the original names so the ~28 view call sites stay put, and
    /// re-emits its changes (nested ObservableObjects don't bubble up).
    let session: ExplainSession
    private var sessionChanges: AnyCancellable?

    var terms: [ExplainTerm] { session.terms }
    var activeTermIndex: Int? { session.activeTermIndex }
    var cards: [String: ExplainCard] { session.cards }
    var loadingTerms: Set<String> { session.loadingTerms }
    var cardErrors: [String: String] { session.cardErrors }

    /// Translate view vs. the local history list (shown when Translate is tapped
    /// with nothing selected) vs. the improve view (native rewrite + diff) vs. the
    /// listen view (TTS playback + select-to-hear).
    enum Mode { case translate, history, improve, listen }
    @Published var mode: Mode = .translate
    @Published var historyEntries: [HistoryEntry] = []

    /// Playback speed for the Listen card. These feed `AVAudioPlayer.rate` (the
    /// cloud-voice player), where 1.0 is normal speed — so the values are the
    /// literal multipliers the labels advertise (0.75×/1×/1.25×).
    enum SpeechRate: String, CaseIterable {
        case slow, normal, fast
        var value: Float {
            switch self {
            case .slow: return 0.75
            case .normal: return 1.0
            case .fast: return 1.25
            }
        }
        var label: String {
            switch self {
            case .slow: return "0.75×"
            case .normal: return "1×"
            case .fast: return "1.25×"
            }
        }
    }
    @Published var speechRate: SpeechRate = .normal

    /// Improve (talkeo-ai/mac#5): the structured rewrite, its own lifecycle phase
    /// (kept separate from translate's `phase`), and the changes the user has
    /// dismissed so their row and source highlight clear.
    @Published var improveResult: ImproveResult?
    @Published var improvePhase: Phase = .idle
    @Published var dismissedChangeIDs: Set<UUID> = []
    /// Which correction is shown — one at a time, paged with ‹ › like the
    /// translation's explain card. Index into `activeChanges`.
    @Published var activeChangeIndex: Int = 0
    /// True when the text came from a terminal (select-to-copy, not editable), so
    /// Replace degrades to a safe Copy instead of editing in place.
    @Published var targetIsTerminal: Bool = false

    /// When true the detected (source) box is an editable input: typing changes
    /// the text and selecting does not mark terms; confirming re-translates.
    @Published var sourceEditing: Bool = false

    /// While an explain card is open, the pane that stays expanded — the other
    /// collapses to its header (tap it to switch, e.g. to select words there
    /// too). Follows the pane the active term was picked from; nil = no card,
    /// both panes shown normally.
    @Published var focusedPane: Pane? = nil

    /// Expand `pane` (collapsing the other) while a card is open.
    func switchFocus(to pane: Pane) {
        withAnimation(.easeInOut(duration: 0.22)) { focusedPane = pane }
    }

    /// The views name `QuickTranslateModel.Pane`; the shared enum keeps that
    /// spelling working.
    typealias Pane = ExplainPane

    var activeTerm: ExplainTerm? { session.activeTerm }

    /// Marker ranges (and which is focused) for a pane, so its text view can
    /// highlight the selected words.
    func highlights(for pane: Pane) -> [(range: NSRange, active: Bool)] {
        session.highlights(for: pane)
    }

    /// The language shown in a pane: the detected one on top, the translation
    /// below.
    func language(for pane: Pane) -> String {
        pane == .source ? detectedLang : translateLang
    }

    /// True when the selection is a single token (no internal whitespace), so we
    /// can jump straight to explaining it instead of translating.
    static func isSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// Select the whole source text as the active term and explain it directly.
    /// Used when the user picked a single word — skips the manual highlight step.
    func explainWholeSource() {
        let ns = sourceText as NSString
        guard ns.length > 0 else { return }
        explain(term: sourceText, pane: .source, range: NSRange(location: 0, length: ns.length))
    }

    /// Detect whether `text` is English or Spanish (the only two we support),
    /// picking whichever the recognizer rates higher; defaults to English.
    static func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let en = hypotheses[.english] ?? 0
        let es = hypotheses[.spanish] ?? 0
        return es > en ? "ES" : "EN"
    }

    enum Phase: Equatable {
        case idle, streaming, done
        case failed(String)
    }

    private let client: TransformClient
    private let history: HistoryStore
    private var task: Task<Void, Never>?

    init(client: TransformClient = TalkeoTransformClient(), history: HistoryStore = LocalHistoryStore.shared) {
        self.client = client
        self.history = history
        // Card arrival animates exactly as it used to when the load lived here.
        self.session = ExplainSession(client: client, cardAnimation: .easeOut(duration: 0.2))
        sessionChanges = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func translate(_ text: String) {
        task?.cancel()
        clearSelection()
        // Animated: `sourceCard` is one persistent view bound to `sourceText`
        // (see `QuickTranslateView`) that just becomes read-only here, so this
        // transition updates it in place instead of swapping the view tree.
        withAnimation(.easeInOut(duration: 0.22)) {
            mode = .translate
            sourceEditing = false
            sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            targetText = ""
            revealed = false

            // Detect EN/ES and translate to the other (only those two are supported).
            detectedLang = QuickTranslateModel.detectLanguage(sourceText)
            translateLang = detectedLang == "EN" ? "ES" : "EN"
        }

        guard !sourceText.isEmpty else { phase = .idle; return }
        phase = .streaming

        let stream = client.translate(text: sourceText, sourceLang: detectedLang, targetLang: translateLang)
        task = Task { @MainActor [weak self] in
            do {
                for try await delta in stream {
                    guard let self else { return }
                    self.reveal()
                    self.targetText += delta
                }
                self?.phase = .done
                self?.reveal()
                self?.recordHistory()
            } catch {
                guard let self else { return }
                self.phase = .failed(QuickTranslateModel.message(error))
                self.reveal()
            }
        }
    }

    func retry() { translate(sourceText) }

    // MARK: Listen (TTS playback + select-to-hear)

    /// Open the Listen card for `text`: show it, detect its language, and load the
    /// real Talkeo voice (auto-plays once ready). Selecting a word later jumps the
    /// playhead to it in the same clip.
    func listen(_ text: String) {
        task?.cancel()
        clearSelection()
        mode = .listen
        sourceEditing = false
        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedLang = QuickTranslateModel.detectLanguage(sourceText)
        guard !sourceText.isEmpty else { return }
        playFull()
    }

    /// Load + play the whole text through the real TTS voice.
    func playFull() {
        TTSAudioPlayer.shared.load(sourceText, lang: detectedLang, rate: speechRate.value)
    }

    /// The user selected a word/phrase: mark it, focus it, and jump the playhead
    /// to it in the buffered clip (instant — no extra synthesis). No explanations
    /// — the session just marks (`loadCard: false`).
    func pickListen(term: String, range: NSRange) {
        let item = ExplainTerm(text: term, sentence: sourceText, sourceLang: detectedLang, targetLang: detectedLang, pane: .source, range: range)
        session.pick(item, loadCard: false)
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        seekToWord(range)
    }

    /// Page between selected words and jump the playhead to each.
    func stepListen(by delta: Int) {
        session.step(by: delta, loadCard: false)
        if let term = activeTerm { seekToWord(term.range) }
    }

    /// Drop the focused selected word, focusing a neighbour.
    func removeActiveListen() {
        session.removeActive()
    }

    /// Jump the buffered clip to where `range` starts in the text. Loads the clip
    /// first (from that point) if it isn't ready yet.
    private func seekToWord(_ range: NSRange) {
        let length = (sourceText as NSString).length
        let fraction = length > 0 ? Double(range.location) / Double(length) : 0
        let player = TTSAudioPlayer.shared
        if player.hasAudio(sourceText) {
            player.seek(toFraction: fraction)
        } else {
            player.load(sourceText, lang: detectedLang, rate: speechRate.value, fromFraction: fraction)
        }
    }

    // MARK: Improve (native/natural rewrite)

    /// Rewrite `text` into more native English and load the structured changes.
    /// One short JSON call (not a stream), mirroring `translate(_:)`'s structure.
    func improve(_ text: String, targetIsTerminal: Bool = false) {
        task?.cancel()
        clearSelection()
        mode = .improve
        sourceEditing = false
        self.targetIsTerminal = targetIsTerminal
        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        improveResult = nil
        dismissedChangeIDs = []
        activeChangeIndex = 0

        // Improve always rewrites English; detection picks the explanation
        // language (the user's own — the other of the EN/ES pair).
        detectedLang = QuickTranslateModel.detectLanguage(sourceText)
        translateLang = detectedLang == "EN" ? "ES" : "EN"

        guard !sourceText.isEmpty else { improvePhase = .idle; return }
        improvePhase = .streaming

        let explainLang = translateLang
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.improve(text: self.sourceText, targetLang: explainLang)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.improveResult = result
                    self.improvePhase = .done
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.improvePhase = .failed(QuickTranslateModel.message(error))
            }
        }
    }

    func retryImprove() { improve(sourceText) }

    /// Changes the user hasn't dismissed — the set the pager moves through.
    var activeChanges: [ImproveResult.Change] {
        (improveResult?.changes ?? []).filter { !dismissedChangeIDs.contains($0.id) }
    }

    /// The single correction currently shown (paged), clamped to the live set.
    var activeChange: ImproveResult.Change? {
        let changes = activeChanges
        guard !changes.isEmpty else { return nil }
        return changes[min(max(activeChangeIndex, 0), changes.count - 1)]
    }

    /// True once the result arrived with no corrections at all (the trust-critical
    /// "already natural" case) — distinct from the user dismissing every one.
    var improveAlreadyNatural: Bool {
        guard let result = improveResult else { return false }
        return result.changes.isEmpty
    }

    /// Page between corrections (wraps, like the explain card's ‹ › pager).
    func stepChange(by delta: Int) {
        let count = activeChanges.count
        guard count > 0 else { return }
        activeChangeIndex = (activeChangeIndex + delta + count) % count
    }

    /// Reject a correction: it leaves the pager and its source highlight clears
    /// (the `improved` text is unchanged — Replace still applies the full rewrite).
    func dismissChange(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.18)) {
            _ = dismissedChangeIDs.insert(id)
            let count = activeChanges.count
            if activeChangeIndex >= count { activeChangeIndex = max(0, count - 1) }
        }
    }

    /// Ranges of every active correction's `original` within `sourceText`, so the
    /// original pane marks all the changed words from the start; the currently-
    /// paged one is emphasized and the rest are dimmed. Walks corrections in order
    /// to disambiguate a fragment that repeats, and tolerates whitespace
    /// differences — the backend normalizes spaces/newlines, so an exact substring
    /// match would miss fragments that span line breaks.
    func improveHighlights() -> [(range: NSRange, active: Bool)] {
        let activeID = activeChange?.id
        let ns = sourceText as NSString
        var result: [(range: NSRange, active: Bool)] = []
        var cursor = 0
        for change in activeChanges {
            let found = QuickTranslateModel.flexibleRange(of: change.original, in: ns, from: cursor)
            guard found.location != NSNotFound else { continue }
            result.append((found, change.id == activeID))
            cursor = NSMaxRange(found)
        }
        return result
    }

    /// Find `fragment` in `ns` at/after `start`, tolerant of whitespace: tries an
    /// exact forward match, then a regex that lets any run of whitespace in the
    /// fragment match any whitespace (incl. newlines) in the text. Both searches are
    /// confined to the forward `scope`, so a fragment that repeats in the source is
    /// disambiguated by the caller's walk order and never mis-tints an earlier copy.
    static func flexibleRange(of fragment: String, in ns: NSString, from start: Int) -> NSRange {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NSRange(location: NSNotFound, length: 0) }

        let scope = NSRange(location: start, length: max(0, ns.length - start))
        let exact = ns.range(of: fragment, options: [], range: scope)
        if exact.location != NSNotFound { return exact }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        let pattern = tokens.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        if let m = regex.firstMatch(in: ns as String, range: scope) { return m.range }
        return NSRange(location: NSNotFound, length: 0)
    }

    // MARK: History

    /// Save the finished translation locally so it can be revisited.
    private func recordHistory() {
        let src = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tgt = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !tgt.isEmpty else { return }
        history.add(HistoryEntry(
            id: UUID().uuidString,
            source: src,
            target: tgt,
            detectedLang: detectedLang,
            translateLang: translateLang,
            timestamp: Date()
        ))
    }

    /// Switch the popover into the history list (Translate tapped with no text).
    /// The source card now binds straight to `sourceText`, so it has to be
    /// cleared here — otherwise a prior translation would linger in what's
    /// supposed to be the empty compose box.
    func showHistory() {
        task?.cancel()
        clearSelection()
        sourceEditing = false
        sourceText = ""
        targetText = ""
        revealed = false
        phase = .idle
        historyEntries = history.all()
        mode = .history
    }

    /// Re-open a past translation from history without calling the API.
    func open(_ entry: HistoryEntry) {
        task?.cancel()
        clearSelection()
        withAnimation(.easeInOut(duration: 0.22)) {
            sourceEditing = false
            sourceText = entry.source
            targetText = entry.target
            detectedLang = entry.detectedLang
            translateLang = entry.translateLang
            phase = .done
            revealed = true
            mode = .translate
        }
    }

    func deleteHistory(_ entry: HistoryEntry) {
        history.remove(id: entry.id)
        historyEntries = history.all()
    }

    func clearHistory() {
        history.clear()
        historyEntries = []
    }

    // MARK: Editing the source

    /// Make the detected box editable (drops any picked terms, since editing
    /// invalidates their offsets).
    func beginEdit() {
        task?.cancel()
        clearSelection()
        mode = .translate
        sourceEditing = true
    }

    /// Confirm the edit and re-translate the (possibly changed) text.
    func commitEdit() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceEditing = false
        guard !text.isEmpty else { return }
        translate(text)
    }

    private func reveal() {
        guard !revealed else { return }
        withAnimation(.easeOut(duration: 0.3)) { revealed = true }
    }

    static func message(_ error: Error) -> String {
        (error as? TalkeoError)?.userMessage ?? "Something went wrong."
    }

    static func languageName(_ code: String) -> String {
        switch code.uppercased() {
        case "ES": return "Spanish"
        case "EN": return "English"
        case "PT": return "Portuguese"
        case "FR": return "French"
        default: return code.uppercased()
        }
    }

    // MARK: Highlight-to-explain

    /// The user highlighted `term` in `pane`. Add it (or focus it if already
    /// added) and load its vocab card. The explain direction depends on the pane:
    /// an English word (original) is explained in Spanish; a Spanish word
    /// (translation) is explained in English.
    func explain(term: String, pane: Pane, range: NSRange) {
        // Early out on empty picks, before any focus change.
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // The card always teaches English. An English term is explained in
        // Spanish; a Spanish term is explained in English (how to say it in
        // English), per the same shape. Direction follows the term's language.
        let termLang = language(for: pane)
        let item = ExplainTerm(
            text: term,
            sentence: pane == .source ? sourceText : targetText,
            sourceLang: termLang,
            targetLang: termLang == "EN" ? "ES" : "EN",
            pane: pane,
            range: range
        )
        // Animated: opening the card collapses the other pane to its header
        // and slides the card section in below. The load kickoff stays outside
        // the animation, as it always did.
        withAnimation(.easeInOut(duration: 0.22)) {
            session.pick(item, loadCard: false)
            focusedPane = pane
        }
        if let focused = activeTerm { session.loadCardIfNeeded(for: focused) }
    }

    /// Move focus between the selected terms (follows the term's pane).
    func stepTerm(by delta: Int) {
        guard !terms.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            session.step(by: delta, loadCard: false)
            focusedPane = activeTerm?.pane
        }
        if let focused = activeTerm { session.loadCardIfNeeded(for: focused) }
    }

    /// Remove the focused term (and its card), focusing a neighbour.
    func removeActiveTerm() {
        guard activeTerm != nil else { return }
        // Animated: closing the last card gives the panes their space back.
        withAnimation(.easeInOut(duration: 0.22)) {
            session.removeActive()
            focusedPane = activeTerm?.pane
        }
    }

    func retryActiveCard() {
        session.retryActiveCard()
    }

    func clearSelection() {
        session.clear()
        focusedPane = nil
    }
}

// MARK: - View

struct QuickTranslateView: View {
    @ObservedObject var model: QuickTranslateModel
    let onResize: (CGSize) -> Void
    let onClose: () -> Void
    /// Apply the improved text in place (Improve's Replace action).
    var onReplace: (String) -> Void = { _ in }
    /// "Full history" tapped — open the main app's History/Transcript screen.
    var onOpenFullHistory: () -> Void = {}
    @State private var sourceHeight: CGFloat = QuickTranslateView.textBoxMinHeight
    @State private var targetHeight: CGFloat = QuickTranslateView.textBoxMinHeight
    /// Measured natural height of the improve correction card, so it scrolls
    /// internally past a cap instead of growing the popover off-screen.
    @State private var cardHeight: CGFloat = 120

    /// Red tint marking the changed fragments in the original (Improve). Clearly
    /// visible for the currently-paged correction; `drawMarkers` dims the rest.
    private static let diffColor = NSColor.systemRed.withAlphaComponent(0.32)
    /// Cap for the correction card; taller (sentence-level) corrections scroll.
    private static let cardMaxHeight: CGFloat = 168
    /// Width text lays out at inside a `cardChrome()` box: content width (368)
    /// minus the card's own horizontal padding (12 × 2).
    static let cardTextWidth: CGFloat = width - 32 - 24
    /// Shared floor/ceiling for every text box that uses `cardChrome()` — the
    /// source card and the translate result's target card. Same bounds
    /// everywhere so a box's size doesn't jump just because a particular
    /// state (loading vs. content, compose vs. translated) happened to use a
    /// different cap.
    static let textBoxMinHeight: CGFloat = 52
    /// ~7 lines; past this the box scrolls internally. Kept modest on purpose:
    /// with source + translation both capped, the whole popover stays well
    /// under half the screen even for long pasted text.
    static let textBoxMaxHeight: CGFloat = 160
    /// How many recent entries show inline under the source card in History.
    /// Older ones live in the main app's History screen, reached via
    /// `fullHistoryLink`.
    private static let recentHistoryCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.mode == .improve {
                improveView
            } else if model.mode == .listen {
                listenView
            } else {
                // History ⇄ translate result: one persistent source card (see
                // `sourceCard`) — only its editability/content and whatever's
                // below it change with mode, so it's never replaced mid-transition.
                // Picking a word keeps both panes visible (they tighten a bit)
                // and adds the explain card underneath.
                sourceCardSection
            }
        }
        .padding(16)
        .frame(width: QuickTranslateView.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                QuickVisualEffectView()
                Palette.surface.opacity(0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 14, y: 4)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: QuickSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(QuickSizeKey.self) { onResize($0) }
        // Pin to the window's top: the window can briefly be taller than the
        // content (shrinks are deferred until content animations land — see
        // `QuickTranslatePanel.resize(to:)`), and default centering would make
        // the whole popover drift down and snap back on every shrink. Outside
        // the GeometryReader so the reported size stays the content's own.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static let width: CGFloat = 400

    // MARK: The translation pane (the source pane is `sourceCard`)

    @ViewBuilder
    private func paneView(_ pane: QuickTranslateModel.Pane, height: Binding<CGFloat>) -> some View {
        let isSource = pane == .source
        let text = isSource ? model.sourceText : model.targetText
        let isEnglish = model.language(for: pane) == "EN"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                cardLabel(QuickTranslateModel.languageName(model.language(for: pane)))
                Spacer()
                if !text.isEmpty {
                    // Listen only for English — never read the Spanish side aloud.
                    if isEnglish {
                        QuickIconButton(system: "speaker.wave.2") {
                            Speaker.speak(text, lang: "EN")
                        }
                    }
                    QuickIconButton(system: "doc.on.doc") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    }
                }
            }
            // Reserve the icon-row height even while there are no icons yet
            // (streaming), and fade them in when the text lands — otherwise
            // their appearance pushes the card down.
            .frame(height: 26)
            .animation(.easeOut(duration: 0.2), value: text.isEmpty)
            paneText(pane, height: height)
                .cardChrome()
        }
    }

    @ViewBuilder
    private func paneText(_ pane: QuickTranslateModel.Pane, height: Binding<CGFloat>) -> some View {
        let isSource = pane == .source
        let editing = isSource && model.sourceEditing
        if !isSource, case let .failed(message) = model.phase {
            translationError(message)
        } else {
            ZStack(alignment: .topLeading) {
                SelectableText(
                    text: isSource ? model.sourceText : model.targetText,
                    height: height,
                    width: QuickTranslateView.cardTextWidth,
                    maxHeight: QuickTranslateView.textBoxMaxHeight,
                    minHeight: QuickTranslateView.textBoxMinHeight,
                    highlights: model.highlights(for: pane),
                    isEditable: editing,
                    onTextChange: { if isSource { model.sourceText = $0 } },
                    onCommit: { if isSource { model.commitEdit() } }
                ) { term, range in
                    model.explain(term: term, pane: pane, range: range)
                }
                .frame(height: height.wrappedValue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isSource || model.revealed ? 1 : 0)
                .blur(radius: isSource || model.revealed ? 0 : 5)

                if editing, model.sourceText.isEmpty {
                    Text("Type or paste text to translate, then press Return.")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.tertiary)
                        .allowsHitTesting(false)
                } else if !isSource, !model.revealed {
                    // Skeleton while the first delta is in flight. Keyed to
                    // `revealed` (not text-emptiness) so its removal runs inside
                    // `reveal()`'s withAnimation — it cross-fades with the text
                    // instead of popping out. Sized to sit within the reserved
                    // `textBoxMinHeight`, so short results land with no shift.
                    VStack(alignment: .leading, spacing: 8) {
                        shimmerBar(width: 220, height: 12)
                        shimmerBar(width: 150, height: 12)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    /// Sits between the two panes: the plain divider plus a swap control for
    /// when auto-detection guesses the wrong language (easy on short or
    /// ambiguous text) — tapping it corrects the direction and re-translates.
    private func translationError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.muted)
            Button(action: { model.retry() }) {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.elevated))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.tertiary)
    }

    // MARK: History ⇄ translate result (shown with nothing selected)

    /// The header above the source card, plus what's below it. Only the
    /// header content and the below-the-card section change with mode — the
    /// card itself (`sourceCard`) is a single view used unconditionally, so
    /// switching between History and a translate result reads as that one box
    /// updating in place (Linear's persistent-viewport pattern: swap the
    /// content, not the container).
    ///
    /// While an explain card is open only ONE pane keeps its text box, and
    /// shadcn-style tabs in the header pick which one — so words can be
    /// selected on either side without both boxes crowding the card out.
    @ViewBuilder
    private var sourceCardSection: some View {
        let explaining = model.activeTerm != nil
        let sourceCollapsed = explaining && model.focusedPane == .target

        HStack(alignment: .center) {
            if model.mode == .history {
                Text("Translate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            } else if explaining {
                paneTabs
            } else {
                cardLabel(QuickTranslateModel.languageName(model.detectedLang))
            }
            Spacer()
            if model.mode == .translate, !sourceCollapsed {
                QuickIconButton(icon: model.sourceEditing ? .system("checkmark", weight: .bold) : .pencil) {
                    if model.sourceEditing { model.commitEdit() } else { model.beginEdit() }
                }
                if !model.sourceText.isEmpty, !model.sourceEditing {
                    // Listen only for English — never read the Spanish side aloud.
                    if model.detectedLang == "EN" {
                        QuickIconButton(system: "speaker.wave.2") {
                            Speaker.speak(model.sourceText, lang: "EN")
                        }
                    }
                    QuickIconButton(system: "doc.on.doc") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(model.sourceText, forType: .string)
                    }
                }
            } else if model.mode == .translate, !model.targetText.isEmpty {
                // Target tab active: the same slots act on the translation
                // (no pencil — the translation isn't editable).
                if model.language(for: .target) == "EN" {
                    QuickIconButton(system: "speaker.wave.2") {
                        Speaker.speak(model.targetText, lang: "EN")
                    }
                }
                QuickIconButton(system: "doc.on.doc") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(model.targetText, forType: .string)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.elevated))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .frame(height: 26)

        // The one text box: normally the source; while explaining, whichever
        // pane the tabs picked.
        if !sourceCollapsed {
            sourceCard
        } else {
            paneText(.target, height: $targetHeight)
                .cardChrome()
        }

        if model.mode == .history {
            if !model.historyEntries.isEmpty {
                Divider().overlay(Palette.border).opacity(0.5)
                cardLabel("Recent")

                let recent = Array(model.historyEntries.prefix(QuickTranslateView.recentHistoryCount))
                VStack(spacing: 0) {
                    ForEach(recent) { entry in
                        HistoryRow(
                            entry: entry,
                            onOpen: { model.open(entry) },
                            onDelete: { model.deleteHistory(entry) }
                        )
                    }
                }
                fullHistoryLink
            }
        } else if !model.sourceEditing {
            Divider().overlay(Palette.border).opacity(0.6)
            if explaining {
                explainSection
            } else {
                paneView(.target, height: $targetHeight)
                if model.phase == .streaming || model.phase == .done {
                    // Make the select-to-explain feature discoverable — nothing
                    // else hints that the text is interactive. Present from the
                    // skeleton on (not just .done), so the row's height is part of
                    // the loading layout and the popover doesn't jump when the
                    // translation lands.
                    selectHint
                }
            }
        }
    }

    /// shadcn-style tabs shown while an explain card is open: inactive labels
    /// on a muted track, the active one lifted on a surface pill. Switching
    /// swaps which pane's text box is visible.
    private var paneTabs: some View {
        HStack(spacing: 2) {
            paneTab(.source)
            paneTab(.target)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.elevated)
        )
    }

    private func paneTab(_ pane: QuickTranslateModel.Pane) -> some View {
        let active = model.focusedPane == pane
        return Button(action: { model.switchFocus(to: pane) }) {
            Text(QuickTranslateModel.languageName(model.language(for: pane)).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(active ? Palette.foreground : Palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? Palette.surface : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(active ? Palette.border : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    /// One quiet line under the result teaching the core learning gesture.
    private var selectHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 10, weight: .medium))
            Text("Select any word or phrase to see its meaning")
                .font(.system(size: 11))
        }
        .foregroundStyle(Palette.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The explain card at its full height — no internal scroll; the popover
    /// grows to fit instead (only one pane's box is up while explaining, so
    /// there's headroom under the panel's 600pt cap for any realistic card).
    private var explainSection: some View {
        cardSection
    }

    /// The one persistent text box for whatever's being translated: empty and
    /// editable before there's anything (History's compose input), then
    /// showing the detected text once translated (tap the pencil to edit
    /// again). Always bound straight to `model.sourceText` — this is the same
    /// view in both states, not two different views standing in for each
    /// other.
    @ViewBuilder
    private var sourceCard: some View {
        let editing = model.mode == .history || model.sourceEditing
        ZStack(alignment: .topLeading) {
            SelectableText(
                text: model.sourceText,
                height: $sourceHeight,
                width: QuickTranslateView.cardTextWidth,
                maxHeight: QuickTranslateView.textBoxMaxHeight,
                minHeight: QuickTranslateView.textBoxMinHeight,
                highlights: model.highlights(for: .source),
                isEditable: editing,
                onTextChange: { model.sourceText = $0 },
                onCommit: {
                    if model.mode == .history {
                        let trimmed = model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.translate(trimmed)
                    } else {
                        model.commitEdit()
                    }
                }
            ) { term, range in
                model.explain(term: term, pane: .source, range: range)
            }
            .frame(height: sourceHeight)
            .frame(maxWidth: .infinity, alignment: .leading)

            if editing, model.sourceText.isEmpty {
                Text("Type or paste text to translate…")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .cardChrome()
    }

    /// Jumps to the full history in the main app — the popover only ever shows
    /// the last few. `onOpenFullHistory` is a no-op until `AppDelegate` wires it
    /// to the main window (that window, and the ability to open it to a
    /// specific section, don't exist on this branch yet).
    private var fullHistoryLink: some View {
        HStack {
            Spacer()
            Button(action: onOpenFullHistory) {
                HStack(spacing: 4) {
                    Text("Full history")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .padding(.top, 4)
    }

    // MARK: Listen (TTS playback + select-to-hear, no explanations)

    @ViewBuilder
    private var listenView: some View {
        // Header.
        HStack {
            cardLabel("Listen")
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
        }

        // The text — tap a word to jump the playhead there; the word being
        // spoken is highlighted as it plays (its own observing subview, so it
        // refreshes per word, not on the 60 fps progress ticks).
        ListenTextPane(model: model, height: $sourceHeight)

        // Transport: play / pause / stop, a seekable timeline, and speed.
        ListenTransport(model: model)

        // The currently-selected word: page with ‹ › (each jumps the playhead).
        if let term = model.activeTerm {
            Divider().overlay(Palette.border).opacity(0.6)
            HStack(alignment: .center, spacing: 10) {
                Text(term.text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: { model.stepListen(by: 0) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump here")
                .handCursor()
                if model.terms.count > 1 { listenPager }
                removeButton { model.removeActiveListen() }
            }
        }
    }

    /// ‹ 1/2 › pager over the selected fragments (plays each as you page).
    private var listenPager: some View {
        HStack(spacing: 8) {
            Button(action: { model.stepListen(by: -1) }) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            Text("\((model.activeTermIndex ?? 0) + 1) / \(model.terms.count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Button(action: { model.stepListen(by: 1) }) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.muted)
        .handCursor()
    }

    // MARK: Improve (native rewrite + compact, scannable changes)

    @ViewBuilder
    private var improveView: some View {
        // Original, with the changed fragments tinted red (the diff).
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                cardLabel("Original")
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
            improvePaneText(
                model.sourceText,
                height: $sourceHeight,
                highlights: model.improveHighlights(),
                highlightColor: QuickTranslateView.diffColor
            )
        }

        if model.improvePhase == .streaming {
            Divider().overlay(Palette.border).opacity(0.6)
            improveLoading
        } else if case let .failed(message) = model.improvePhase {
            Divider().overlay(Palette.border).opacity(0.6)
            improveError(message)
        } else if let result = model.improveResult {
            Divider().overlay(Palette.border).opacity(0.6)

            // Improved, with Listen (always English) + copy.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    cardLabel("Improved")
                    Spacer()
                    QuickIconButton(system: "speaker.wave.2") { Speaker.speak(result.improved, lang: "EN") }
                    QuickIconButton(system: "doc.on.doc") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(result.improved, forType: .string)
                    }
                }
                improvePaneText(result.improved, height: $targetHeight, highlights: [], highlightColor: nil)
            }

            if model.improveAlreadyNatural {
                alreadyNatural
            } else {
                let changes = model.activeChanges
                if let active = model.activeChange {
                    Divider().overlay(Palette.border).opacity(0.6)
                    ScrollView(.vertical, showsIndicators: true) {
                        changeCard(active, index: min(model.activeChangeIndex, changes.count - 1), total: changes.count)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(key: ImproveCardHeightKey.self, value: geo.size.height)
                                }
                            )
                    }
                    .frame(height: min(max(cardHeight, 1), QuickTranslateView.cardMaxHeight))
                    .onPreferenceChange(ImproveCardHeightKey.self) { cardHeight = $0 }
                } else {
                    Divider().overlay(Palette.border).opacity(0.6)
                    allDismissedNote
                }
            }

            replaceBar(result.improved)
        }
    }

    @ViewBuilder
    private func improvePaneText(
        _ text: String,
        height: Binding<CGFloat>,
        highlights: [(range: NSRange, active: Bool)],
        highlightColor: NSColor?
    ) -> some View {
        SelectableText(
            text: text,
            height: height,
            width: QuickTranslateView.width - 32,
            // Keep the panes compact — Improve is a quick glance, not a reader.
            // Long text scrolls inside the box so the correction card stays visible.
            maxHeight: 116,
            highlights: highlights,
            highlightColor: highlightColor,
            isEditable: false,
            onTextChange: { _ in },
            onCommit: {}
        ) { _, _ in }
            .frame(height: height.wrappedValue)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One correction at a time: `original → fixed`, a ‹ › pager when there are
    /// several, a brief why, examples only when the backend sent them, and a
    /// dismiss that pages on to the next.
    private func changeCard(_ change: ImproveResult.Change, index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                (Text(change.original)
                    .font(.system(size: 14.5))
                    .strikethrough(color: Palette.tertiary)
                    .foregroundColor(Palette.muted)
                 + Text("  →  ")
                    .font(.system(size: 14.5))
                    .foregroundColor(Palette.tertiary)
                 + Text(change.fixed)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(Palette.foreground))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if total > 1 { changePager(index: index, total: total) }
                QuickIconButton(system: "xmark") { model.dismissChange(change.id) }
            }
            if !change.why.isEmpty {
                Text(change.why)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let examples = change.examples, !examples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(examples.indices, id: \.self) { i in
                        let ex = examples[i]
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                markdownBold(ex.source)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Palette.foreground)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                markdownBold(ex.target)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.muted)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            speakerButton(QuickTranslateView.plain(ex.source))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.elevated.opacity(0.45))
        )
    }

    /// ‹ 1/2 › pager for stepping through corrections, mirroring the explain card.
    private func changePager(index: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            Button(action: { model.stepChange(by: -1) }) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            Text("\(index + 1) / \(total)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Button(action: { model.stepChange(by: 1) }) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.muted)
        .padding(.top, 1)
        .handCursor()
    }

    private var alreadyNatural: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.green.opacity(0.8))
            Text("Already natural — no changes needed.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
    }

    /// Shown when the user has dismissed every correction (distinct from the
    /// backend returning none).
    private var allDismissedNote: some View {
        Text("All suggestions dismissed.")
            .font(.system(size: 13))
            .foregroundStyle(Palette.tertiary)
    }

    private func replaceBar(_ improved: String) -> some View {
        let terminal = model.targetIsTerminal
        return VStack(alignment: .leading, spacing: 7) {
            if terminal {
                // Terminals can't be edited in place (copy-only selection); be
                // honest — Replace copies and the user pastes where they mean to.
                Text("Terminal: can't replace in place. This copies the improved text — paste it (⌘V) where you want it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: { onReplace(improved) }) {
                    HStack(spacing: 6) {
                        Image(systemName: terminal ? "doc.on.clipboard" : "arrow.down.doc")
                            .font(.system(size: 12, weight: .semibold))
                        Text(terminal ? "Copy" : "Replace").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help(terminal ? "Copy the improved text to paste it yourself" : "Replace the selection with the improved text")
                .handCursor()
            }
        }
        .padding(.top, 2)
    }

    private var improveLoading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Improving…")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.tertiary)
            shimmerBar(width: 220, height: 12)
            shimmerBar(width: 180, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func improveError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.retryImprove() }) {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.elevated))
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small speaker that reads English aloud (shared by the improve changes).
    private func speakerButton(_ english: String) -> some View {
        Button {
            Speaker.speak(english, lang: "EN")
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Listen")
        .handCursor()
    }

    /// Render markdown so the backend's `**term**` shows in bold.
    private func markdownBold(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string) {
            return Text(attributed)
        }
        return Text(string)
    }

    /// Strip markdown bold markers so spoken text is clean.
    private static func plain(_ string: String) -> String {
        string.replacingOccurrences(of: "**", with: "")
    }

    // MARK: Vocab card (highlight-to-explain, with ‹ › pager)

    @ViewBuilder
    private var cardSection: some View {
        if let term = model.activeTerm {
            if let card = model.cards[term.text] {
                ExplainCardView(
                    card: card,
                    // The English side to read aloud: the term itself if it's
                    // English, otherwise its English equivalent (first meaning).
                    speakEnglish: term.sourceLang == "EN" ? card.term : (card.meanings.first ?? card.term),
                    index: model.activeTermIndex ?? 0,
                    total: model.terms.count,
                    onPrev: { model.stepTerm(by: -1) },
                    onNext: { model.stepTerm(by: 1) },
                    onRemove: { model.removeActiveTerm() }
                )
                .transition(.opacity)
            } else if let error = model.cardErrors[term.text] {
                cardLoadingHeader(term.text)
                cardError(error)
            } else {
                cardLoadingHeader(term.text)
                cardShimmer
            }
        }
    }

    /// Minimal headword row shown while the card loads or errors, so the term is
    /// visible immediately and the layout doesn't jump when the card arrives.
    private func cardLoadingHeader(_ term: String) -> some View {
        HStack {
            Text(term)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Spacer(minLength: 0)
            removeButton { model.removeActiveTerm() }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.elevated))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .handCursor()
    }

    private func cardError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.retryActiveCard() }) {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.elevated))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shaped like the card it's standing in for — a meanings line plus two
    /// example pairs (the typical payload) — so the swap to real content is a
    /// small settle, not a big grow. The headword above it is already real.
    private var cardShimmer: some View {
        VStack(alignment: .leading, spacing: 16) {
            shimmerBar(width: 230, height: 14)
            VStack(alignment: .leading, spacing: 5) {
                shimmerBar(width: 280, height: 12)
                shimmerBar(width: 220, height: 11)
            }
            VStack(alignment: .leading, spacing: 5) {
                shimmerBar(width: 260, height: 12)
                shimmerBar(width: 200, height: 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shimmerBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Palette.elevated)
            .frame(width: width, height: height)
    }
}

// MARK: - Explain card view

private struct ExplainCardView: View {
    let card: ExplainCard
    /// The English text to read aloud for the headword (term or its equivalent).
    let speakEnglish: String
    let index: Int
    let total: Int
    let onPrev: () -> Void
    let onNext: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headword
            if !card.examples.isEmpty { examples }
            if let insight = card.insight { insightView(insight) }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Headword row: term → meanings (flowing) + pager (only when several) + close.
    private var headword: some View {
        HStack(alignment: .top, spacing: 10) {
            (Text(card.term)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Palette.foreground)
             + Text("  →  ")
                .font(.system(size: 15))
                .foregroundColor(Palette.tertiary)
             + Text(card.meanings.joined(separator: " / "))
                .font(.system(size: 15))
                .foregroundColor(Palette.muted))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            speakerButton(speakEnglish)
            if total > 1 { pager }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.elevated))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .handCursor()
        }
    }

    private var pager: some View {
        HStack(spacing: 8) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            Text("\(index + 1) / \(total)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Button(action: onNext) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.muted)
        .padding(.top, 3)
        .handCursor()
    }

    // Examples: EN (term bold) over ES, stacked, with a Listen for the English.
    private var examples: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(card.examples.indices, id: \.self) { i in
                let ex = card.examples[i]
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        markdownBold(ex.source)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Palette.foreground)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        markdownBold(ex.target)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    speakerButton(Self.plain(ex.source))
                }
            }
        }
    }

    /// Small speaker that reads English aloud.
    private func speakerButton(_ english: String) -> some View {
        Button {
            Speaker.speak(english, lang: "EN")
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Listen")
        .handCursor()
    }

    /// Strip markdown bold markers so the spoken text is clean.
    private static func plain(_ string: String) -> String {
        string.replacingOccurrences(of: "**", with: "")
    }

    private func insightView(_ insight: ExplainCard.Insight) -> some View {
        let warning = insight.kind == .falseFriend
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                .font(.system(size: 12))
                .foregroundStyle(warning ? Color.orange.opacity(0.9) : Palette.tertiary)
                .padding(.top, 1)
            Text(insight.text)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.elevated.opacity(0.6))
        )
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            cardPill(system: "bubble.left.and.text.bubble.right", title: "Ask Leo") {
                // TODO: pre-fill Ask Leo with this term (agent <-> panel wiring)
            }
        }
        .padding(.top, 2)
    }

    /// Render markdown so the backend's `**term**` shows in bold (no italics).
    private func markdownBold(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func cardPill(system: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

// MARK: - Selectable text (highlight a word/phrase to explain)

/// Read-only NSTextView that reports the word/phrase the user selects (snapped
/// to whole words), and reports its laid-out height back so the popover can size
/// to it.
private struct SelectableText: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat
    /// The width the text lays out in — used to measure height deterministically.
    var width: CGFloat
    /// Cap the box height; past it the text scrolls internally instead of growing
    /// the popover off-screen.
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    /// Floor the box height (e.g. a compose input that shouldn't look like a
    /// cramped single line while empty).
    var minHeight: CGFloat = 0
    /// Persistent markers for the words already picked, and which one is focused.
    var highlights: [(range: NSRange, active: Bool)] = []
    /// Override the marker fill (e.g. a red diff tint for Improve). Defaults to
    /// the monochrome pick marker when nil.
    var highlightColor: NSColor? = nil
    /// Word currently being spoken (Listen): drawn in accent on top of any picks,
    /// karaoke-style.
    var spokenRange: NSRange? = nil
    /// When true the view is an editable input (no marking); Enter commits.
    var isEditable: Bool = false
    var onTextChange: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onSelect: (String, NSRange) -> Void

    /// Height of `text` at `width`, computed up front so the popover never sizes
    /// from a half-laid-out text view (which clipped, variably).
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let measured = (text.isEmpty ? " " : text) as NSString
        let rect = measured.boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: para]
        )
        return ceil(rect.height) + 6
    }

    /// Real layout height of `textView`'s current content at `width` — reads
    /// the same layout manager/text container the view renders with, instead
    /// of a separate `NSString.boundingRect` estimate that can diverge from it
    /// (notably: reserving a phantom extra line when a wrapped line exactly
    /// fills the container width). Falls back to `height(of:width:)` on the
    /// rare case the layout manager isn't available yet.
    static func measuredHeight(_ textView: NSTextView, width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return height(of: textView.string, width: width)
        }
        // Container width is already set by the caller (`updateNSView`), the
        // single source of truth — just measure against it.
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return ceil(used.height) + textView.textContainerInset.height * 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onTextChange: onTextChange, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkerTextView()
        // Non-activating panel: selections must register on the first click.
        textView.acceptsFirstMouseEnabled = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = Palette.nsForeground
        textView.insertionPointColor = Palette.nsForeground
        textView.textContainerInset = NSSize(width: 0, height: 1)
        // Standard "text view inside a scroll view" setup so long text scrolls.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        // We set the container's width ourselves every `updateNSView` pass
        // (below), from the same `width` SwiftUI lays this view out at.
        // Leaving `widthTracksTextView` on too means AppKit's own auto-sync
        // (driven by the NSTextView's *actual* frame, which can briefly lag
        // behind during a panel resize) fights our explicit value — a one-frame
        // mismatch there re-wraps the text at the wrong width, changes the
        // measured height, and shows up as a visible pop before it corrects.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        // Snap-to-word picking and the collapse-after-pick rule live in
        // MarkerTextView; the default (no picking while editable) is exactly
        // this popover's behavior. Reads the coordinator at call time so the
        // closure survives re-renders.
        let coordinator = context.coordinator
        textView.onWordPick = { term, range in
            coordinator.onSelect(term, range)
        }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay // doesn't take width, so wrapping is stable
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkerTextView else { return }
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onTextChange = onTextChange
        coordinator.onCommit = onCommit

        // Single source of truth for the container's width (see `makeNSView`).
        textView.textContainer?.containerSize = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)

        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            applyAttributes(textView)
            scroll.documentView?.scroll(.zero) // show the top of new text
        }
        // Take focus + caret at end when editing turns on.
        if isEditable, !coordinator.wasEditable {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
        coordinator.wasEditable = isEditable

        // Markers only in read mode (editing invalidates ranges).
        let length = (textView.string as NSString).length
        textView.markers = isEditable ? [] : highlights.filter { NSMaxRange($0.range) <= length }
        textView.markerColor = highlightColor
        textView.spokenMarker = (isEditable ? nil : spokenRange).flatMap { NSMaxRange($0) <= length ? $0 : nil }
        textView.needsDisplay = true

        // Deterministic content height (text + width), floored and capped — past
        // the cap the scroll view takes over instead of the popover growing
        // off-screen. Measured off the text view's own layout manager (not a
        // separate `boundingRect` estimate) — `NSString.boundingRect` reserves a
        // phantom extra line whenever a wrapped line exactly fills the width,
        // which read as the box growing/scrolling one line early.
        let full = SelectableText.measuredHeight(textView, width: width)
        let target = min(max(full, minHeight), maxHeight)
        scroll.hasVerticalScroller = full > maxHeight + 0.5
        if abs(target - height) > 0.5 {
            // Animated so the box grows/shrinks smoothly as content changes
            // (streamed deltas, typing past a wrap) instead of snapping a line
            // at a time. Must stay shorter than the popover window's deferred
            // shrink (0.32s in `QuickTranslatePanel.resize`) so the window
            // never clips a box that's still animating.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.18)) { height = target }
            }
        }
    }

    private func applyAttributes(_ textView: NSTextView) {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: Palette.nsForeground,
            .paragraphStyle: para,
        ]
        textView.textColor = Palette.nsForeground
        textView.typingAttributes = attrs
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        if full.length > 0 { textView.textStorage?.addAttributes(attrs, range: full) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String, NSRange) -> Void
        var onTextChange: (String) -> Void
        var onCommit: () -> Void
        var wasEditable = false

        init(onSelect: @escaping (String, NSRange) -> Void,
             onTextChange: @escaping (String) -> Void,
             onCommit: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onTextChange = onTextChange
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Enter confirms; Shift+Enter inserts a real line break instead —
            // returning false here lets the text view's own default handling
            // (a plain newline) run, same as any normal multi-line input.
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            onCommit()
            return true
        }
    }
}

extension View {
    /// Force the pointing-hand cursor while hovering, reasserting on every move
    /// so a neighbouring text view's I-beam can't linger over the control. These
    /// non-activating panels don't get AppKit's normal cursor-rect management.
    func handCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.pointingHand.set() }
        }
    }

    /// Consistent boxed-card chrome — rounded, filled, hairline border — shared
    /// by the compose input and the translate result's source/target text, so
    /// the popover reads as one continuous surface instead of switching visual
    /// language depending on whether there's a translation yet.
    func cardChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.elevated.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            )
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        // A real Button (not onTapGesture) so the first click registers even
        // when the panel isn't key — tap gestures ignore acceptsFirstMouse.
        // One quiet line, source → target — no language badge, no visible
        // timestamp (it's a tooltip); the delete affordance is the only thing
        // that appears on hover.
        Button(action: onOpen) {
            (Text(entry.source)
                .foregroundColor(Palette.muted)
             + Text("  →  ")
                .foregroundColor(Palette.tertiary)
             + Text(entry.target)
                .foregroundColor(Palette.tertiary))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover ? Palette.elevated.opacity(0.3) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(HistoryRow.relative(entry.timestamp))
        .overlay(alignment: .trailing) {
            if hover {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Palette.elevated))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove")
                .handCursor()
                .padding(.trailing, 2)
            }
        }
        .onHover { hover = $0 }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The Listen text, in its own subview so it can observe the spoken word (a few
/// updates per second) and highlight it karaoke-style without re-rendering the
/// whole popover on every progress tick. Tapping a word jumps the playhead there.
private struct ListenTextPane: View {
    @ObservedObject var model: QuickTranslateModel
    @ObservedObject private var spoken = TTSAudioPlayer.shared.spoken
    @Binding var height: CGFloat

    var body: some View {
        SelectableText(
            text: model.sourceText,
            height: $height,
            width: QuickTranslateView.width - 32,
            maxHeight: 240,
            highlights: model.highlights(for: .source),
            spokenRange: spoken.range,
            isEditable: false,
            onTextChange: { _ in },
            onCommit: {}
        ) { term, range in
            model.pickListen(term: term, range: range)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Playback transport for the Listen card: a seekable timeline (scrub anywhere)
/// plus play/pause/stop and speed, driven by the real Talkeo voice
/// (`TTSAudioPlayer`). Observes only the player, so the 60 fps progress ticks
/// re-render just this small view. Shows a loading state while the clip
/// synthesizes and a retry on failure.
private struct ListenTransport: View {
    @ObservedObject var model: QuickTranslateModel
    @ObservedObject private var player = TTSAudioPlayer.shared

    private var text: String { model.sourceText }
    private var mine: Bool { player.currentText == text }
    private var loading: Bool { mine && player.isLoading }
    private var failed: Bool { mine && player.failed }
    private var hasAudio: Bool { player.hasAudio(text) }
    private var playing: Bool { mine && player.isPlaying }
    private var progress: Double { mine ? player.progress : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            timeline
            HStack(spacing: 10) {
                primary
                stop
                Spacer()
                speed
            }
            if loading {
                caption("Loading the voice…")
            } else if failed {
                caption("Couldn't load the voice — tap ↻ to retry.")
            }
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = max(0, min(w, w * progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.elevated).frame(height: 5)
                Capsule().fill(Color.accentColor).frame(width: x, height: 5)
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Palette.border, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .offset(x: x - 6.5)
                    .opacity(hasAudio ? 1 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hasAudio else { return }
                        player.seek(toFraction: fraction(value.location.x, w))
                    }
                    .onEnded { value in
                        let frac = fraction(value.location.x, w)
                        if hasAudio { player.seek(toFraction: frac) }
                        else if !loading {
                            player.load(text, lang: model.detectedLang, rate: model.speechRate.value, fromFraction: frac)
                        }
                    }
            )
            .handCursor()
        }
        .frame(height: 16)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(width, 1))))
    }

    private var primary: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle().fill(Color.accentColor).frame(width: 34, height: 34)
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: failed ? "arrow.clockwise" : (playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .help(failed ? "Retry" : (playing ? "Pause" : "Play"))
        .handCursor()
    }

    private var stop: some View {
        Button(action: { player.stop() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasAudio ? Palette.muted : Palette.tertiary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.elevated))
        }
        .buttonStyle(.plain)
        .help("Stop")
        .disabled(!hasAudio)
        .handCursor()
    }

    private var speed: some View {
        HStack(spacing: 2) {
            ForEach(QuickTranslateModel.SpeechRate.allCases, id: \.self) { rate in
                let on = model.speechRate == rate
                Button {
                    model.speechRate = rate
                    player.setRate(rate.value)
                } label: {
                    Text(rate.label)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(on ? Palette.foreground : Palette.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Palette.elevated : Color.clear))
                }
                .buttonStyle(.plain)
                .handCursor()
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.elevated.opacity(0.4)))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.tertiary)
    }

    private func primaryAction() {
        if failed || !hasAudio {
            player.load(text, lang: model.detectedLang, rate: model.speechRate.value)
        } else {
            player.togglePlayPause()
        }
    }
}

/// The one non-SF glyph in the row: SF's pencil is a wispy diagonal stick even
/// in bold, so the edit affordance uses Lucide's pencil (ISC license), traced
/// from its 24×24 SVG. Arcs are pre-solved from the SVG's endpoint form into
/// center/angle form; all sweep counterclockwise on screen (`clockwise: true`
/// in CG's y-up convention).
private struct LucidePencilShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s
        let oy = rect.midY - 12 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        var p = Path()
        // Body: rounded eraser end, both long edges, tiny rounded tip corner.
        p.move(to: pt(21.174, 6.812))
        p.addArc(center: pt(19.181, 4.819), radius: 2.819 * s,
                 startAngle: .degrees(45), endAngle: .degrees(-135), clockwise: true)
        p.addLine(to: pt(3.842, 16.174))
        p.addArc(center: pt(5.254, 17.590), radius: 2 * s,
                 startAngle: .degrees(-134.9), endAngle: .degrees(-163.0), clockwise: true)
        p.addLine(to: pt(2.021, 21.356))
        p.addArc(center: pt(2.500, 21.499), radius: 0.5 * s,
                 startAngle: .degrees(-163.4), endAngle: .degrees(73.3), clockwise: true)
        p.addLine(to: pt(6.997, 20.658))
        p.addArc(center: pt(6.415, 18.745), radius: 2 * s,
                 startAngle: .degrees(73.1), endAngle: .degrees(45.1), clockwise: true)
        p.closeSubpath()
        // Ferrule line separating tip from body.
        p.move(to: pt(15, 5))
        p.addLine(to: pt(19, 9))
        return p
    }
}

private enum QuickIcon {
    case system(String, weight: Font.Weight)
    case pencil
}

private struct QuickIconButton: View {
    let icon: QuickIcon
    let action: () -> Void
    @State private var hover = false

    init(system: String, weight: Font.Weight = .medium, action: @escaping () -> Void) {
        self.icon = .system(system, weight: weight)
        self.action = action
    }

    init(icon: QuickIcon, action: @escaping () -> Void) {
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            glyph
                .foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hover ? Palette.elevated : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .handCursor()
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .system(let name, let weight):
            Image(systemName: name)
                .font(.system(size: 12, weight: weight))
        case .pencil:
            // Lucide's native proportions: stroke 2 on a 24 box.
            LucidePencilShape()
                .stroke(style: StrokeStyle(lineWidth: 13 * 2 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
        }
    }
}

private struct QuickSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Natural (uncapped) height of the improve correction card, reported up so the
/// surrounding scroll view can size to content up to its cap.
private struct ImproveCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > value { value = next }
    }
}

/// Native vibrancy backing for the popover's frosted surface.
private struct QuickVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Preview

private struct QuickPreviewClient: TransformClient {
    func translate(text: String, sourceLang: String?, targetLang: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            c.yield("El comité alcanzó un acuerdo tentativo tras una deliberación exhaustiva.")
            c.finish()
        }
    }

    func improve(text: String, targetLang: String) async throws -> ImproveResult {
        try? await Task.sleep(nanoseconds: 450_000_000)
        return ImproveResult(
            improved: "I'm about to work out, but the thing is, I didn't get to finish these improvements.",
            changes: [
                ImproveResult.Change(
                    original: "train",
                    fixed: "work out",
                    why: "“Train” sounds like sports practice; for the gym, natives say “work out.”",
                    type: "naturalness",
                    examples: [
                        ExplainCard.Example(source: "I **work out** every morning.", target: "Hago ejercicio cada mañana."),
                    ]
                ),
                ImproveResult.Change(
                    original: "this improvements",
                    fixed: "these improvements",
                    why: "“Improvements” is plural, so it takes “these.”",
                    type: "grammar",
                    examples: nil
                ),
            ]
        )
    }
}

#Preview("Quick translate") {
    let model = QuickTranslateModel(client: QuickPreviewClient())
    return QuickTranslateView(model: model, onResize: { _ in }, onClose: {})
        .padding(40)
        .onAppear {
            model.sourceText = "The committee reached a tentative agreement."
            model.targetText = "El comité alcanzó un acuerdo tentativo tras una deliberación exhaustiva."
            model.revealed = true
            model.phase = .done
        }
}

private struct QuickPreviewHistoryStore: HistoryStore {
    let entries: [HistoryEntry]
    func all() -> [HistoryEntry] { entries }
    func add(_ entry: HistoryEntry) {}
    func remove(id: String) {}
    func clear() {}
}

#Preview("History") {
    let stub = QuickPreviewHistoryStore(entries: [
        HistoryEntry(id: "1", source: "The committee reached a tentative agreement.", target: "El comité alcanzó un acuerdo tentativo.", detectedLang: "EN", translateLang: "ES", timestamp: Date(timeIntervalSinceNow: -120)),
        HistoryEntry(id: "2", source: "Necesito hablar con vos mañana.", target: "I need to talk to you tomorrow.", detectedLang: "ES", translateLang: "EN", timestamp: Date(timeIntervalSinceNow: -3600)),
        HistoryEntry(id: "3", source: "Let's meet at noon.", target: "Reunámonos al mediodía.", detectedLang: "EN", translateLang: "ES", timestamp: Date(timeIntervalSinceNow: -7200)),
        HistoryEntry(id: "4", source: "¿Podés enviarme el archivo?", target: "Can you send me the file?", detectedLang: "ES", translateLang: "EN", timestamp: Date(timeIntervalSinceNow: -90000)),
    ])
    let model = QuickTranslateModel(client: QuickPreviewClient(), history: stub)
    return QuickTranslateView(model: model, onResize: { _ in }, onClose: {})
        .padding(40)
        .onAppear { model.showHistory() }
}

#Preview("Improve") {
    let model = QuickTranslateModel(client: QuickPreviewClient())
    return QuickTranslateView(model: model, onResize: { _ in }, onClose: {}, onReplace: { _ in })
        .padding(40)
        .onAppear {
            model.improve("I'm about to train, but it happens that I didn't get to finish this improvements.")
        }
}
