import AppKit
import NaturalLanguage
import SwiftUI

/// Compact translate + learn popover that opens from the floating bar's
/// Translate action. It sizes itself to content, can't be moved, and sits at the
/// right margin so it stays out of the way.
///
/// Two parts: translation (Original / target-language tabs) and the learning
/// core — **select any word or phrase in the shown text to see a structured
/// vocabulary card below** (meaning, category, examples, a typed insight). This
/// is the comfortable, compact take on the v1 `TranslatePanel` highlight-to-
/// explain. It dismisses on a click anywhere outside it.
///
/// The panel stays non-activating (it never steals focus when it appears) but
/// can become key, so clicking into it to select text works.
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
    private let model = QuickTranslateModel()
    private var dismissMonitor: Any?
    private var topAnchor: CGFloat = 0
    private var leftAnchor: CGFloat = 0

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

        var onResizeRef: ((CGSize) -> Void)?
        var onCloseRef: (() -> Void)?
        let view = QuickTranslateView(
            model: model,
            onResize: { onResizeRef?($0) },
            onClose: { onCloseRef?() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.nominalHeight))
        panel.contentView = hosting

        self.panel = panel
        onResizeRef = { [weak self] size in self?.resize(to: size) }
        onCloseRef = { [weak self] in self?.hide() }
    }

    func show(text: String) {
        model.translate(text)
        // A single word goes straight to its explain card (the translation still
        // streams in the background, so removing the card falls back to it).
        if QuickTranslateModel.isSingleWord(text) {
            model.explainWholeSource()
        }
        present()
    }

    /// Translate tapped with nothing selected — show the local history list.
    func showHistory() {
        model.showHistory()
        present()
    }

    private func present() {
        computeAnchor()
        let origin = NSPoint(x: leftAnchor, y: topAnchor - Self.nominalHeight)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: Self.nominalHeight)), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        installDismissMonitor()
    }

    func hide() {
        removeDismissMonitor()
        guard panel.isVisible, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
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
    private func resize(to size: CGSize) {
        let height = min(max(size.height, 56), Self.maxHeight)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: leftAnchor, y: topAnchor - height)
        if origin.y < visible.minY + 8 { origin.y = visible.minY + 8 }
        if origin.y + height > visible.maxY - 8 { origin.y = visible.maxY - 8 - height }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true, animate: false)
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
    @Published var terms: [LearnTerm] = []
    @Published var activeTermIndex: Int? = nil
    @Published var cards: [String: ExplainCard] = [:]
    @Published var loadingTerms: Set<String> = []
    @Published var cardErrors: [String: String] = [:]

    /// Translate view vs. the local history list (shown when Translate is tapped
    /// with nothing selected).
    enum Mode { case translate, history }
    @Published var mode: Mode = .translate
    @Published var historyEntries: [HistoryEntry] = []

    /// When true the detected (source) box is an editable input: typing changes
    /// the text and selecting does not mark terms; confirming re-translates.
    @Published var sourceEditing: Bool = false

    /// A highlighted term plus the context the explain endpoint needs (the
    /// sentence and explain direction) and where it sits, so the text can draw a
    /// persistent marker over it.
    struct LearnTerm {
        let text: String
        let sentence: String
        let sourceLang: String
        let targetLang: String
        let pane: Pane
        let range: NSRange
    }

    enum Pane: Equatable { case source, target }

    var activeTerm: LearnTerm? {
        guard let i = activeTermIndex, terms.indices.contains(i) else { return nil }
        return terms[i]
    }

    /// Marker ranges (and which is focused) for a pane, so its text view can
    /// highlight the selected words.
    func highlights(for pane: Pane) -> [(range: NSRange, active: Bool)] {
        terms.enumerated().compactMap { idx, term in
            term.pane == pane ? (term.range, idx == activeTermIndex) : nil
        }
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
    private var explainTasks: [String: Task<Void, Never>] = [:]

    init(client: TransformClient = TalkeoTransformClient(), history: HistoryStore = LocalHistoryStore.shared) {
        self.client = client
        self.history = history
    }

    func translate(_ text: String) {
        task?.cancel()
        clearSelection()
        mode = .translate
        sourceEditing = false
        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        targetText = ""
        revealed = false

        // Detect EN/ES and translate to the other (only those two are supported).
        detectedLang = QuickTranslateModel.detectLanguage(sourceText)
        translateLang = detectedLang == "EN" ? "ES" : "EN"

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
    func showHistory() {
        task?.cancel()
        clearSelection()
        historyEntries = history.all()
        mode = .history
    }

    /// Re-open a past translation from history without calling the API.
    func open(_ entry: HistoryEntry) {
        task?.cancel()
        clearSelection()
        sourceText = entry.source
        targetText = entry.target
        detectedLang = entry.detectedLang
        translateLang = entry.translateLang
        phase = .done
        revealed = true
        mode = .translate
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

    /// Open an empty editable input to translate something from scratch.
    func startBlank() {
        task?.cancel()
        clearSelection()
        mode = .translate
        sourceText = ""
        targetText = ""
        revealed = false
        phase = .idle
        sourceEditing = true
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
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // The card always teaches English. An English term is explained in
        // Spanish; a Spanish term is explained in English (how to say it in
        // English), per the same shape. Direction follows the term's language.
        let termLang = language(for: pane)
        let src = termLang
        let tgt = termLang == "EN" ? "ES" : "EN"
        let sentence = pane == .source ? sourceText : targetText
        let item = LearnTerm(text: clean, sentence: sentence, sourceLang: src, targetLang: tgt, pane: pane, range: range)
        // Re-selecting the exact same span just focuses it.
        if let i = terms.firstIndex(where: { $0.pane == pane && NSEqualRanges($0.range, range) }) {
            activeTermIndex = i
        } else {
            // No stacking: a new span replaces any markers it overlaps in this pane.
            terms.removeAll { $0.pane == pane && NSIntersectionRange($0.range, range).length > 0 }
            terms.append(item)
            activeTermIndex = terms.count - 1
        }
        loadCardIfNeeded(item)
    }

    /// Move focus between the selected terms.
    func stepTerm(by delta: Int) {
        guard !terms.isEmpty else { return }
        let current = activeTermIndex ?? 0
        let next = (current + delta + terms.count) % terms.count
        activeTermIndex = next
        loadCardIfNeeded(terms[next])
    }

    /// Remove the focused term (and its card), focusing a neighbour.
    func removeActiveTerm() {
        guard let i = activeTermIndex, terms.indices.contains(i) else { return }
        let key = terms[i].text
        explainTasks[key]?.cancel(); explainTasks[key] = nil
        cards[key] = nil
        loadingTerms.remove(key)
        cardErrors[key] = nil
        terms.remove(at: i)
        activeTermIndex = terms.isEmpty ? nil : min(i, terms.count - 1)
    }

    func retryActiveCard() {
        guard let item = activeTerm else { return }
        cards[item.text] = nil
        cardErrors[item.text] = nil
        loadCardIfNeeded(item)
    }

    private func loadCardIfNeeded(_ item: LearnTerm) {
        let key = item.text
        guard cards[key] == nil, !loadingTerms.contains(key) else { return }
        cardErrors[key] = nil
        loadingTerms.insert(key)
        explainTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let card = try await self.client.explainCard(
                    term: item.text,
                    sentence: item.sentence,
                    sourceLang: item.sourceLang,
                    targetLang: item.targetLang
                )
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.cards[key] = card
                    self.loadingTerms.remove(key)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.loadingTerms.remove(key)
                self.cardErrors[key] = QuickTranslateModel.message(error)
            }
        }
    }

    func clearSelection() {
        explainTasks.values.forEach { $0.cancel() }
        explainTasks = [:]
        terms = []
        activeTermIndex = nil
        cards = [:]
        loadingTerms = []
        cardErrors = [:]
    }
}

// MARK: - View

struct QuickTranslateView: View {
    @ObservedObject var model: QuickTranslateModel
    let onResize: (CGSize) -> Void
    let onClose: () -> Void
    @State private var sourceHeight: CGFloat = 22
    @State private var targetHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.mode == .history {
                historyView
            } else if let term = model.activeTerm {
                // One box: the pane the term was picked from (with its highlight),
                // then the card. The other box is hidden.
                paneView(term.pane, withClose: true, height: term.pane == .source ? $sourceHeight : $targetHeight)
                Divider().overlay(Palette.border).opacity(0.6)
                cardSection
            } else {
                // No selection yet: detected text on top, its translation below.
                // While editing the source, only the input shows.
                paneView(.source, withClose: true, height: $sourceHeight)
                if !model.sourceEditing {
                    Divider().overlay(Palette.border).opacity(0.6)
                    paneView(.target, withClose: false, height: $targetHeight)
                }
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
    }

    static let width: CGFloat = 400

    // MARK: A language pane (detected on top, translation below) — selectable

    @ViewBuilder
    private func paneView(_ pane: QuickTranslateModel.Pane, withClose: Bool, height: Binding<CGFloat>) -> some View {
        let isSource = pane == .source
        let text = isSource ? model.sourceText : model.targetText
        let isEnglish = model.language(for: pane) == "EN"
        let editing = isSource && model.sourceEditing
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                cardLabel(QuickTranslateModel.languageName(model.language(for: pane)))
                Spacer()
                // Edit the detected text (pencil), or confirm it (checkmark).
                if isSource {
                    QuickIconButton(system: editing ? "checkmark" : "pencil") {
                        if model.sourceEditing { model.commitEdit() } else { model.beginEdit() }
                    }
                }
                if !text.isEmpty, !editing {
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
                if withClose {
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
            }
            paneText(pane, height: height)
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
                    width: QuickTranslateView.width - 32,
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
                } else if !isSource, model.phase == .streaming, model.targetText.isEmpty {
                    Text("Translating…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.tertiary)
                }
            }
        }
    }

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

    // MARK: History (shown when Translate is tapped with nothing selected)

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                cardLabel("History")
                Spacer()
                if !model.historyEntries.isEmpty {
                    Button(action: { model.clearHistory() }) {
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
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

            // Start a fresh translation from a blank input.
            Button(action: { model.startBlank() }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                    Text("New translation").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.foreground)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.elevated.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .handCursor()

            if model.historyEntries.isEmpty {
                Text("No translations yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.historyEntries) { entry in
                            HistoryRow(
                                entry: entry,
                                onOpen: { model.open(entry) },
                                onDelete: { model.deleteHistory(entry) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
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

    private var cardShimmer: some View {
        VStack(alignment: .leading, spacing: 8) {
            shimmerBar(width: 120, height: 15)
            shimmerBar(width: 200, height: 12)
            shimmerBar(width: 240, height: 12)
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
    /// Persistent markers for the words already picked, and which one is focused.
    var highlights: [(range: NSRange, active: Bool)] = []
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onTextChange: onTextChange, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = WordSelectingTextView()
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = Palette.nsForeground
        textView.insertionPointColor = Palette.nsForeground
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        textView.onSettled = { [weak textView] in
            // No marking while editing — clicks just place the caret.
            guard let textView, !textView.isEditable else { return }
            let raw = textView.selectedRange()
            guard raw.length > 0 else { return }
            let ns = textView.string as NSString
            let snapped = snapWords(raw, in: ns)
            guard snapped.length > 0 else { return }
            coordinator.onSelect(ns.substring(with: snapped), snapped)
            // Collapse the OS selection so only our marker shows the pick.
            DispatchQueue.main.async { [weak textView] in
                textView?.setSelectedRange(NSRange(location: NSMaxRange(snapped), length: 0))
            }
        }
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onTextChange = onTextChange
        coordinator.onCommit = onCommit

        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            applyAttributes(textView)
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
        if let marked = textView as? WordSelectingTextView {
            marked.markers = isEditable ? [] : highlights.filter { NSMaxRange($0.range) <= length }
            marked.needsDisplay = true
        }
        // Report a deterministic height (text + width), not the live text view's
        // — that raced with layout and clipped.
        let target = SelectableText.height(of: text, width: width)
        if abs(target - height) > 0.5 {
            DispatchQueue.main.async { height = target }
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
            // Enter confirms the edit instead of inserting a newline.
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onCommit()
                return true
            }
            return false
        }
    }
}

/// NSTextView that runs its selection tracking inside `mouseDown`, then reports
/// the settled selection, and draws rounded markers behind the picked words.
private final class WordSelectingTextView: NSTextView {
    var onSettled: (() -> Void)?
    /// Picked word ranges to draw (range, isFocused).
    var markers: [(range: NSRange, active: Bool)] = []

    /// Register a selection on the first click even when the panel isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawMarkers()
        super.draw(dirtyRect)
    }

    private func drawMarkers() {
        guard !markers.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        for marker in markers {
            let glyphRange = lm.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: tc
            ) { rect, _ in
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                Palette.marker(active: marker.active).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onSettled?()
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
}

/// Grow a raw selection to the whole words it touches; a selection covering no
/// word characters snaps to nothing.
private func snapWords(_ range: NSRange, in ns: NSString) -> NSRange {
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

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // A real Button (not onTapGesture) so the first click registers even
            // when the panel isn't key — tap gestures ignore acceptsFirstMouse.
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    Text("\(entry.detectedLang) → \(entry.translateLang)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                        .frame(width: 54, alignment: .leading)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.source)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.foreground)
                            .lineLimit(1)
                        Text(entry.target)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()

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
            } else {
                Text(HistoryRow.relative(entry.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? Palette.elevated.opacity(0.5) : Color.clear)
        )
        .onHover { hover = $0 }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct QuickIconButton: View {
    let system: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
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
}

private struct QuickSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Local native vibrancy backing (the file-private one in TranslatePanel.swift
/// isn't visible here).
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
    func explain(term: String, sentence: String, sourceLang: String?, targetLang: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
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
