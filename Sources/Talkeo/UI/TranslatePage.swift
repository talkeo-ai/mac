import AppKit
import SwiftUI

/// The main window's Translate feature: the Google-Translate-style page (side-
/// by-side panes, translate-as-you-type, history drawer) plus its select-to-
/// explain (shared ExplainSession + vocab card). Lives beside the popover in
/// UI/ — the two surfaces of the same translate + learn core.

/// State for the in-app translator. Mirrors the popover's flow (detect EN/ES,
/// stream deltas, record history) but is its own model: text is typed rather
/// than captured, translation re-runs debounced as you type, and the language
/// pair can be pinned manually (the popover always auto-detects). Owned by
/// `MainWindowModel` so switching sections doesn't lose the text.
final class TranslatePageModel: ObservableObject {
    /// Explicit language pair override; `nil` = auto-detect per translation.
    @Published var pinnedSource: String?
    /// Detected source ("EN"/"ES") of the last translation, for the Auto chip.
    @Published private(set) var detected: String?
    @Published var sourceText = ""
    @Published private(set) var outputText = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var entries: [HistoryEntry] = []
    /// Whether the history drawer (right side) is open.
    @Published var historyOpen = false

    // MARK: Select-to-explain (the shared state machine)

    /// Picked terms and their vocab cards. The views observe the session
    /// directly (it's an ObservableObject of its own); the model only builds
    /// the terms (`pick`) and invalidates them when the text changes.
    let session: ExplainSession

    private let client: TransformClient
    private let history: HistoryStore
    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// Invalidates in-flight tasks when a newer translation supersedes them.
    private var generation = 0

    init(client: TransformClient = TalkeoTransformClient(), history: HistoryStore = LocalHistoryStore.shared) {
        self.client = client
        self.history = history
        self.session = ExplainSession(client: client)
    }

    /// Source of the *next* translation: pinned, else last detection, else ES
    /// (the placeholder direction — the user's language into English).
    var effectiveSource: String { pinnedSource ?? detected ?? "ES" }
    var targetLang: String { effectiveSource == "EN" ? "ES" : "EN" }

    var sourceChipLabel: String {
        if let pinnedSource { return QuickTranslateModel.languageName(pinnedSource) }
        if let detected { return "Auto · \(QuickTranslateModel.languageName(detected))" }
        return "Detect language"
    }

    var targetChipLabel: String { QuickTranslateModel.languageName(targetLang) }

    /// Debounced translate-as-you-type, Google Translate style.
    func sourceEdited() {
        debounceTask?.cancel()
        // Typing moves the text under any picked terms — drop them right away
        // (not at the debounce) so no marker ever floats over the wrong word.
        clearSelection()
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            reset(keepText: true)
            return
        }
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    func translateNow() {
        debounceTask?.cancel()
        streamTask?.cancel()
        generation += 1
        let gen = generation
        // A new translation replaces the output (and may re-detect the pair);
        // picked terms belong to the old text.
        clearSelection()

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let src = pinnedSource ?? QuickTranslateModel.detectLanguage(text)
        let tgt = src == "EN" ? "ES" : "EN"
        detected = pinnedSource == nil ? src : nil
        errorMessage = nil
        outputText = ""
        isStreaming = true

        let stream = client.translate(text: text, sourceLang: src, targetLang: tgt)
        streamTask = Task { @MainActor [weak self] in
            do {
                for try await delta in stream {
                    guard let self, self.generation == gen else { return }
                    self.outputText += delta
                }
                guard let self, self.generation == gen else { return }
                self.isStreaming = false
                self.record(source: text, sourceLang: src, targetLang: tgt)
            } catch {
                guard let self, self.generation == gen else { return }
                self.isStreaming = false
                self.errorMessage = QuickTranslateModel.message(error)
            }
        }
    }

    /// Swap the pair. Like Google Translate, the last translation becomes the
    /// new input so the swap is immediately useful.
    func swap() {
        let newSource = targetLang
        pinnedSource = newSource
        detected = nil
        if !outputText.isEmpty { sourceText = outputText }
        translateNow()
    }

    func pinSource(_ lang: String?) {
        pinnedSource = lang
        translateNow()
    }

    func pinTarget(_ lang: String) {
        pinSource(lang == "EN" ? "ES" : "EN")
    }

    /// Load a history entry back into the translator (no re-request).
    func select(_ entry: HistoryEntry) {
        debounceTask?.cancel()
        streamTask?.cancel()
        generation += 1
        clearSelection()
        pinnedSource = nil
        detected = entry.detectedLang
        sourceText = entry.source
        outputText = entry.target
        isStreaming = false
        errorMessage = nil
    }

    func refreshHistory() {
        entries = history.all()
    }

    func delete(_ entry: HistoryEntry) {
        history.remove(id: entry.id)
        refreshHistory()
    }

    /// The user picked `term` in `pane`: focus it (or add it) and load its card.
    /// Direction mirrors the popover — the term is explained into the other
    /// language of the pair.
    func pick(term: String, pane: ExplainPane, range: NSRange) {
        let termLang = pane == .source ? effectiveSource : targetLang
        session.pick(ExplainTerm(
            text: term,
            sentence: pane == .source ? sourceText : outputText,
            sourceLang: termLang,
            targetLang: termLang == "EN" ? "ES" : "EN",
            pane: pane,
            range: range
        ))
    }

    /// Drop every picked term and its cards. Any change to the panes' text
    /// (typing, a new translation, loading history) invalidates the ranges.
    func clearSelection() {
        session.clear()
    }

    private func reset(keepText: Bool) {
        streamTask?.cancel()
        generation += 1
        clearSelection()
        if !keepText { sourceText = "" }
        outputText = ""
        detected = nil
        isStreaming = false
        errorMessage = nil
    }

    func clear() { reset(keepText: false) }

    private func record(source: String, sourceLang: String, targetLang: String) {
        guard !outputText.isEmpty else { return }
        history.add(HistoryEntry(
            id: UUID().uuidString,
            source: source,
            target: outputText,
            detectedLang: sourceLang,
            translateLang: targetLang,
            timestamp: Date()
        ))
        refreshHistory()
    }
}

/// The in-app translator: Google Translate distilled — language chips over
/// their panes with a swap on the gutter, side-by-side source/translation
/// panes, translate-as-you-type, and a collapsible history drawer on the
/// right. The space under the panes is reserved for selected meanings
/// (explain cards, mirroring the popover's select-to-learn).
struct TranslatePage: View {
    @ObservedObject var model: TranslatePageModel
    /// Observed directly: the session is its own ObservableObject and its
    /// changes don't bubble through the model.
    @ObservedObject var session: ExplainSession

    init(model: TranslatePageModel) {
        self.model = model
        self.session = model.session
    }

    var body: some View {
        HStack(spacing: 0) {
            translator
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Shown/hidden instantly — a slide here fights the HStack's width
            // relayout and looks off; snappy beats janky.
            if model.historyOpen {
                Divider().overlay(Palette.border)
                HistoryPanel(model: model)
                    .frame(width: 320)
            }
        }
        .onAppear { model.refreshHistory() }
        // Cmd+Return forces an immediate translation (skips the debounce).
        .background(
            Button("") { model.translateNow() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        )
    }

    private var translator: some View {
        VStack(spacing: 16) {
            ZStack {
                languageBar
                HStack {
                    Spacer()
                    HistoryToggle(isOpen: model.historyOpen) { model.historyOpen.toggle() }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                sourcePane
                outputPane
            }
            .frame(height: 240)

            // Selected meanings: pick a word in either pane and it's taught
            // here (the popover's select-to-learn, at home in the app).
            cardArea
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity)
    }

    /// Source chip · swap · target chip. The swap is pinned to the column's
    /// exact center — the gutter between the two panes — via equal flexible
    /// halves; centering the cluster as a whole would drift it with the chips'
    /// widths ("Detect language" is wider than "English").
    private var languageBar: some View {
        HStack(spacing: 10) {
            sourceMenu
                .frame(maxWidth: .infinity, alignment: .trailing)

            Button(action: { model.swap() }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.elevated))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Swap languages")

            targetMenu
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button("Detect language") { model.pinSource(nil) }
            Button("English") { model.pinSource("EN") }
            Button("Spanish") { model.pinSource("ES") }
        } label: {
            LangChip(text: model.sourceChipLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var targetMenu: some View {
        Menu {
            Button("English") { model.pinTarget("EN") }
            Button("Spanish") { model.pinTarget("ES") }
        } label: {
            LangChip(text: model.targetChipLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourcePane: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: $model.sourceText,
                onUserEdit: { model.sourceEdited() },
                onWordSelect: { term, range in model.pick(term: term, pane: .source, range: range) },
                markers: session.highlights(for: .source)
            )
                .padding(.top, 14)
                .padding(.leading, 14)
                .padding(.bottom, 14)
                // Keep typed text clear of the ✕ button in the corner.
                .padding(.trailing, 40)

            if model.sourceText.isEmpty {
                // Sits exactly where the editor's text starts (padding +
                // container inset 2 + line fragment padding 5).
                Text("Type or paste text…")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 16)
                    .padding(.leading, 21)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if !model.sourceText.isEmpty {
                PaneIconButton(system: "xmark", help: "Clear") { model.clear() }
                    .padding(10)
            }
        }
    }

    private var outputPane: some View {
        ZStack(alignment: .topLeading) {
            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                    Button("Try again") { model.translateNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(Palette.border, lineWidth: 1))
                }
                .padding(.top, 16)
                .padding(.horizontal, 21)
            } else if model.outputText.isEmpty {
                if model.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 18)
                        .padding(.leading, 21)
                } else {
                    // Mirrors the source placeholder's exact text position.
                    Text("Translation")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 16)
                        .padding(.leading, 21)
                }
            } else {
                // Read-only native text view: real selection/copy behavior.
                PlainTextEditor(
                    text: .constant(model.outputText),
                    isEditable: false,
                    onWordSelect: { term, range in model.pick(term: term, pane: .target, range: range) },
                    markers: session.highlights(for: .target)
                )
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .padding(.trailing, 14)
                    // Keep the last line clear of the copy button.
                    .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if !model.outputText.isEmpty && !model.isStreaming {
                CopyButton(text: model.outputText, help: "Copy translation")
                    .padding(10)
            }
        }
    }

    /// The learning area under the panes: the focused picked term's card
    /// (shimmer while it loads, retry on failure) in a container matching the
    /// panes' chrome, or — once there's a translation — a quiet hint that
    /// words can be picked (the popover's copy).
    @ViewBuilder
    private var cardArea: some View {
        if session.activeTerm != nil {
            // Open, Google-dictionary-style content — no container card
            // (Joaquin's call); full column width keeps it aligned with the
            // panes' edges.
            ScrollView {
                ExplainCardPane(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
        } else if !model.outputText.isEmpty && model.errorMessage == nil {
            // Kept visible during streaming too, so it never pops in late
            // (same lesson the popover's skeleton hint learned).
            Text("Select any word or phrase to see its meaning")
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            Spacer(minLength: 0)
        } else {
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Explain card (select-to-learn)

/// The vocab card for the focused picked term, mirroring the popover's:
/// headword → meanings with a speaker, ‹ › pager across picked terms, examples
/// (term bolded) each with their own speaker, and the optional insight note.
/// Composition (headword/pager/buttons/states) is this surface's own; the
/// identical pieces come from `ExplainCardParts`.
private struct ExplainCardPane: View {
    @ObservedObject var session: ExplainSession

    var body: some View {
        if let term = session.activeTerm {
            VStack(alignment: .leading, spacing: 18) {
                headword(term)
                if let card = session.cards[term.text] {
                    if !card.examples.isEmpty {
                        // Speaker centered between the EN/ES lines, belonging
                        // to the pair rather than hanging off the first one.
                        ExplainExamplesList(
                            examples: card.examples,
                            sourceSize: 15,
                            targetSize: 14,
                            rowSpacing: 14,
                            speakerAlignment: .center
                        ) { english in
                            SpeakerButton(english: english)
                        }
                    }
                    if let insight = card.insight {
                        ExplainInsightNote(insight: insight, fill: Palette.elevated, iconTopPadding: 2)
                    }
                } else if let error = session.cardErrors[term.text] {
                    errorView(error)
                } else {
                    ExplainCardShimmer(widths: [260, 320, 250, 290, 220])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Headword row: term → meanings (once loaded) + speaker + pager + close.
    private func headword(_ term: ExplainTerm) -> some View {
        let card = session.cards[term.text]
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let card {
                    Text(card.term)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Palette.foreground)
                    + Text("  →  ")
                        .font(.system(size: 16))
                        .foregroundColor(Palette.tertiary)
                    + Text(card.meanings.joined(separator: " / "))
                        .font(.system(size: 16))
                        .foregroundColor(Palette.muted)
                } else {
                    Text(term.text)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Palette.foreground)
                }
            }
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if let card {
                SpeakerButton(english: ExplainCardText.spokenEnglish(term: term, card: card))
            }
            if session.terms.count > 1 { pager }
            PaneIconButton(system: "xmark", help: "Close", size: 28) { session.removeActive() }
        }
    }

    private var pager: some View {
        HStack(spacing: 8) {
            Button(action: { session.step(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("\((session.activeTermIndex ?? 0) + 1) / \(session.terms.count)")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
            Button(action: { session.step(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.muted)
        .padding(.top, 3)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
            Button("Try again") { session.retryActiveCard() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().stroke(Palette.border, lineWidth: 1))
        }
    }
}

private struct LangChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Palette.elevated))
        .contentShape(Capsule())
    }
}

/// Right-side history drawer. Rows are self-contained hover cards (no
/// separators): the rounded hover fill matches the row bounds exactly, the
/// modern list treatment (Raycast/Linear-style).
private struct HistoryPanel: View {
    @ObservedObject var model: TranslatePageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                Spacer()
                PaneIconButton(system: "xmark", help: "Close history") {
                    model.historyOpen = false
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            if model.entries.isEmpty {
                Text("Translations you make will show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.entries) { entry in
                            HistoryRow(
                                entry: entry,
                                select: { model.select(entry) },
                                delete: { model.delete(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

/// One history entry; clicking it loads the pair back into the translator.
/// Delete lives in a top-right overlay that fades in on hover — out of the
/// text flow, so it never stretches the header line or shifts the row.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let select: () -> Void
    let delete: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(QuickTranslateModel.languageName(entry.detectedLang)) → \(QuickTranslateModel.languageName(entry.translateLang))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                Text(entry.source)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                Text(entry.target)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // Keep the text clear of the delete corner (26pt trailing total).
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHover ? Palette.elevated : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHover {
                RowDeleteButton(action: delete)
                    .padding(.top, 4)
                    .padding(.trailing, 5)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHover)
        .onHover { isHover = $0 }
        .help(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
    }
}

// (PaneIconButton, CopyButton, SpeakerButton, HistoryToggle, RowDeleteButton
// and the native PlainTextEditor moved to PageParts.swift — shared with the
// Improve and Listen pages.)
