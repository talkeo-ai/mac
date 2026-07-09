import AppKit
import SwiftUI

/// Talkeo's main application window — the normal-app surface, as opposed to
/// the ambient selection UI (floating bar, popovers).
///
/// Talkeo runs as a regular app (Dock icon, Cmd-Tab). Closing this window
/// doesn't quit or hide the app: the ambient feature keeps running and the
/// Dock icon stays, Discord-style — clicking it brings the window back.
final class MainWindowController: NSObject {
    private var window: NSWindow?
    /// Selection state shared with the SwiftUI tree, so callers can deep-link
    /// into a section (e.g. the popover's "Full history" → Translate).
    private let model = MainWindowModel()

    override init() {
        super.init()
        installMainMenuIfNeeded()
    }

    /// Deep-link for the popover's "Full history": land on Translate with the
    /// history drawer open.
    func openTranslateHistory() {
        model.translate.historyOpen = true
        show(section: .translate)
    }

    /// Order the main window front and focus the app. Pass a section to land
    /// on it; nil keeps whatever the user last had open.
    func show(section: MainSection? = nil) {
        if let section { model.selection = section }
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Don't let AppKit hand initial key focus to a control (it draws a
        // focus ring); async because SwiftUI assigns focus after key.
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Talkeo"
        // The SPA draws its own chrome (icon rail + floating content card);
        // the titlebar is just the traffic lights floating over it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        window.backgroundColor = Palette.nsDynamic(0xF7F7F8, 0x161616)
        window.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
        // Open filling the screen (minus menu bar / Dock), like a full-size SPA.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrame(screen.visibleFrame, display: true)
        } else {
            window.center()
        }
        return window
    }

    /// The executable builds its menu bar in code (no nib). Without one the
    /// window has no Cmd+W/Cmd+Q and text fields lose the standard Edit
    /// shortcuts.
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Talkeo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Talkeo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Talkeo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

// MARK: - Navigation

/// Sections of the main window's left-hand rail: AI conversation (chat,
/// voice teacher), the floating bar's tools, the user-facing record
/// (transcript, estimated English level), and settings pinned at the bottom.
enum MainSection: String, CaseIterable, Identifiable {
    case chat, teacher, translate, improve, listen, capture, transcript, englishLevel, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .teacher: return "Teacher"
        case .translate: return "Translate"
        case .improve: return "Improve"
        case .listen: return "Listen"
        case .capture: return "Capture"
        case .transcript: return "Transcript"
        case .englishLevel: return "English level"
        case .settings: return "Settings"
        }
    }

    /// Short label for the narrow icon rail (the page keeps the full title).
    var railTitle: String {
        switch self {
        case .englishLevel: return "Level"
        default: return title
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .teacher: return "graduationcap.fill"
        case .translate: return "character.bubble.fill"
        case .improve: return "text.badge.checkmark"
        case .listen: return "speaker.wave.2.fill"
        case .capture: return "text.viewfinder"
        case .transcript: return "waveform"
        case .englishLevel: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }

    static let ai: [MainSection] = [.chat, .teacher]
    static let tools: [MainSection] = [.translate, .improve, .listen, .capture]
    static let progress: [MainSection] = [.transcript, .englishLevel]
}

// MARK: - Root view (SPA: icon rail + floating content card)

/// Shared navigation state: the controller writes it for deep-links, the rail
/// writes it on clicks, the detail pane reads it. Owns the per-section models
/// that should survive switching sections (e.g. the translator keeps its text).
final class MainWindowModel: ObservableObject {
    @Published var selection: MainSection = .translate
    let translate = TranslatePageModel()
}

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel

    /// Window backdrop — the rail sits directly on it and the content card
    /// floats over it (Palette.surface is one step lighter, so the card
    /// reads as raised in both appearances).
    private static let backdrop = Palette.dynamic(0xF7F7F8, 0x161616)

    var body: some View {
        HStack(spacing: 0) {
            rail

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                )
                .padding([.top, .trailing, .bottom], 14)
        }
        .background(Self.backdrop)
        // Full-bleed SPA: the backdrop owns the titlebar strip too; the rail's
        // top padding keeps the brand clear of the traffic lights.
        .ignoresSafeArea()
    }

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(MainSection.ai) { item in
                RailItem(item: item, isSelected: model.selection == item) { model.selection = item }
            }

            railDivider

            ForEach(MainSection.tools) { item in
                RailItem(item: item, isSelected: model.selection == item) { model.selection = item }
            }

            railDivider

            ForEach(MainSection.progress) { item in
                RailItem(item: item, isSelected: model.selection == item) { model.selection = item }
            }

            Spacer(minLength: 0)

            RailItem(item: .settings, isSelected: model.selection == .settings) { model.selection = .settings }
                .padding(.bottom, 14)
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .frame(width: 92)
        .frame(maxHeight: .infinity)
    }

    private var railDivider: some View {
        Divider()
            .overlay(Palette.border)
            .frame(width: 30)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .chat:
            ToolPage(
                section: .chat,
                summary: "Ask anything, ChatGPT-style — a chat that knows you're learning English.",
                steps: [],
                comingSoon: true
            )
        case .teacher:
            ToolPage(
                section: .teacher,
                summary: "Talk out loud with an AI teacher — real voice conversation, adapted to your level.",
                steps: [],
                comingSoon: true
            )
        case .translate:
            TranslatePage(model: model.translate)
        case .improve:
            ToolPage(
                section: .improve,
                summary: "Rewrite your English and replace it right where you wrote it.",
                steps: [
                    "Select something you wrote.",
                    "Click the improve button in the floating bar.",
                    "Review the diff and replace in place (or copy)."
                ]
            )
        case .listen:
            ToolPage(
                section: .listen,
                summary: "Hear any text out loud with word-by-word highlight.",
                steps: [
                    "Select the text you want to hear.",
                    "Click the listen button in the floating bar.",
                    "Follow along as each word lights up."
                ]
            )
        case .capture:
            ToolPage(
                section: .capture,
                summary: "Grab text straight from the screen — even where you can't select.",
                steps: [],
                comingSoon: true
            )
        case .transcript:
            ToolPage(
                section: .transcript,
                summary: "Real-time transcription of what you hear — live subtitles for meetings, videos and calls.",
                steps: [],
                comingSoon: true
            )
        case .englishLevel:
            EnglishLevelPage()
        case .settings:
            ToolPage(
                section: .settings,
                summary: "Providers, voices and behavior — configure how Talkeo works.",
                steps: [],
                comingSoon: true
            )
        }
    }
}

/// One entry of the icon rail: big icon with its label underneath, monochrome.
/// Selected lifts to full foreground on a soft tile; the rest stay muted.
private struct RailItem: View {
    let item: MainSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(item.railTitle)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Palette.foreground : Palette.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected || isHover ? Palette.elevated : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .animation(.easeOut(duration: 0.12), value: isHover)
    }
}

// MARK: - Tool pages

/// Detail page for one of the floating-bar tools. Today these document the
/// tool; they'll grow direct input (paste text here, no selection needed).
private struct ToolPage: View {
    let section: MainSection
    let summary: String
    let steps: [String]
    var comingSoon: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(section: section, subtitle: summary)

                if comingSoon {
                    Text("Coming soon")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Palette.elevated))
                } else {
                    StepsList(steps: steps)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Numbered how-to steps shared by the tool pages.
private struct StepsList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .center, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.foreground)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.elevated))
                    Text(step)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.foreground)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.elevated)
                )
            }
        }
    }
}

// MARK: - Translate

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

    // MARK: Select-to-explain (mirrors the popover's highlight-to-explain)

    /// A word/phrase picked to learn: the term, its sentence context and explain
    /// direction, plus which pane it came from and where — so the pane draws a
    /// persistent marker over it and the card area below can teach it.
    struct PickedTerm {
        let text: String
        let sentence: String
        let sourceLang: String
        let targetLang: String
        let pane: Pane
        let range: NSRange
    }

    enum Pane { case source, output }

    @Published private(set) var terms: [PickedTerm] = []
    @Published private(set) var activeTermIndex: Int?
    /// Loaded cards, in-flight terms and failures, all keyed by term text —
    /// re-picking a term reuses its card instead of re-requesting.
    @Published private(set) var cards: [String: ExplainCard] = [:]
    @Published private(set) var loadingTerms: Set<String> = []
    @Published private(set) var cardErrors: [String: String] = [:]
    private var explainTasks: [String: Task<Void, Never>] = [:]

    private let client: TransformClient
    private let history: HistoryStore
    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// Invalidates in-flight tasks when a newer translation supersedes them.
    private var generation = 0

    init(client: TransformClient = TalkeoTransformClient(), history: HistoryStore = LocalHistoryStore.shared) {
        self.client = client
        self.history = history
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

    var activeTerm: PickedTerm? {
        guard let i = activeTermIndex, terms.indices.contains(i) else { return nil }
        return terms[i]
    }

    /// Marker ranges (and which is focused) for a pane, so its text view can
    /// highlight the picked words.
    func highlights(for pane: Pane) -> [(range: NSRange, active: Bool)] {
        terms.enumerated().compactMap { idx, term in
            term.pane == pane ? (term.range, idx == activeTermIndex) : nil
        }
    }

    /// The user picked `term` in `pane`: focus it (or add it) and load its card.
    /// Direction mirrors the popover — the term is explained into the other
    /// language of the pair.
    func pick(term: String, pane: Pane, range: NSRange) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let termLang = pane == .source ? effectiveSource : targetLang
        let item = PickedTerm(
            text: clean,
            sentence: pane == .source ? sourceText : outputText,
            sourceLang: termLang,
            targetLang: termLang == "EN" ? "ES" : "EN",
            pane: pane,
            range: range
        )
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

    /// Move focus between the picked terms (‹ › pager, wraps).
    func stepTerm(by delta: Int) {
        guard !terms.isEmpty else { return }
        let current = activeTermIndex ?? 0
        activeTermIndex = (current + delta + terms.count) % terms.count
        if let term = activeTerm { loadCardIfNeeded(term) }
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

    private func loadCardIfNeeded(_ item: PickedTerm) {
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
                self.cards[key] = card
                self.loadingTerms.remove(key)
            } catch {
                guard !Task.isCancelled else { return }
                self.loadingTerms.remove(key)
                self.cardErrors[key] = QuickTranslateModel.message(error)
            }
        }
    }

    /// Drop every picked term and its cards. Any change to the panes' text
    /// (typing, a new translation, loading history) invalidates the ranges.
    func clearSelection() {
        explainTasks.values.forEach { $0.cancel() }
        explainTasks = [:]
        terms = []
        activeTermIndex = nil
        cards = [:]
        loadingTerms = []
        cardErrors = [:]
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
private struct TranslatePage: View {
    @ObservedObject var model: TranslatePageModel

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
                markers: model.highlights(for: .source)
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
                    onWordSelect: { term, range in model.pick(term: term, pane: .output, range: range) },
                    markers: model.highlights(for: .output)
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
                CopyButton(text: model.outputText)
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
        if model.activeTerm != nil {
            ScrollView {
                ExplainCardPane(model: model)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Palette.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Palette.border, lineWidth: 1)
                    )
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
private struct ExplainCardPane: View {
    @ObservedObject var model: TranslatePageModel

    var body: some View {
        if let term = model.activeTerm {
            VStack(alignment: .leading, spacing: 18) {
                headword(term)
                if let card = model.cards[term.text] {
                    if !card.examples.isEmpty { examples(card) }
                    if let insight = card.insight { insightView(insight) }
                } else if let error = model.cardErrors[term.text] {
                    errorView(error)
                } else {
                    shimmer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Headword row: term → meanings (once loaded) + speaker + pager + close.
    private func headword(_ term: TranslatePageModel.PickedTerm) -> some View {
        let card = model.cards[term.text]
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
                // The English side to read aloud: the term itself if it's
                // English, otherwise its English equivalent (first meaning).
                SpeakerButton(english: term.sourceLang == "EN" ? card.term : (card.meanings.first ?? card.term))
            }
            if model.terms.count > 1 { pager }
            PaneIconButton(system: "xmark", help: "Close", size: 28) { model.removeActiveTerm() }
        }
    }

    private var pager: some View {
        HStack(spacing: 8) {
            Button(action: { model.stepTerm(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("\((model.activeTermIndex ?? 0) + 1) / \(model.terms.count)")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
            Button(action: { model.stepTerm(by: 1) }) {
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

    /// Examples: term's side (term bolded) over the user's side, each pair
    /// with a Listen for the English.
    private func examples(_ card: ExplainCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(card.examples.indices, id: \.self) { i in
                let ex = card.examples[i]
                // Center alignment: the speaker sits between the EN/ES lines,
                // belonging to the pair rather than hanging off the first one.
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        markdownBold(ex.source)
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.foreground)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        markdownBold(ex.target)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    SpeakerButton(english: Self.plain(ex.source))
                }
            }
        }
    }

    private func insightView(_ insight: ExplainCard.Insight) -> some View {
        let warning = insight.kind == .falseFriend
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                .font(.system(size: 12))
                .foregroundStyle(warning ? Color.orange.opacity(0.9) : Palette.tertiary)
                .padding(.top, 2)
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
            // The card container is elevated; one step back keeps the note
            // distinct in both appearances.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surface)
        )
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
            Button("Try again") { model.retryActiveCard() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().stroke(Palette.border, lineWidth: 1))
        }
    }

    /// Shaped like the card it stands in for — a meanings line plus two example
    /// pairs — so the swap to real content is a small settle, not a big grow.
    private var shimmer: some View {
        VStack(alignment: .leading, spacing: 16) {
            shimmerBar(width: 260, height: 14)
            VStack(alignment: .leading, spacing: 5) {
                shimmerBar(width: 320, height: 12)
                shimmerBar(width: 250, height: 11)
            }
            VStack(alignment: .leading, spacing: 5) {
                shimmerBar(width: 290, height: 12)
                shimmerBar(width: 220, height: 11)
            }
        }
    }

    private func shimmerBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Palette.surface)
            .frame(width: width, height: height)
    }

    /// Render markdown so the backend's `**term**` shows in bold.
    private func markdownBold(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string) {
            return Text(attributed)
        }
        return Text(string)
    }

    /// Strip markdown bold markers so the spoken text is clean.
    private static func plain(_ string: String) -> String {
        string.replacingOccurrences(of: "**", with: "")
    }
}

/// Small quiet speaker that reads English aloud (offline voice).
private struct SpeakerButton: View {
    let english: String

    var body: some View {
        PaneIconButton(system: "speaker.wave.2", help: "Listen", size: 28) {
            Speaker.speak(english, lang: "EN")
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

/// Small quiet icon button used inside the panes (clear, copy, history).
private struct PaneIconButton: View {
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

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        PaneIconButton(system: copied ? "checkmark" : "doc.on.doc", help: "Copy translation") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

/// Labeled toggle for the history drawer — icon + text so it doesn't read as
/// decoration.
private struct HistoryToggle: View {
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

/// The history row's delete affordance: a bare trash glyph on a small rounded
/// tile (matching the row's corner language — a circle read as a hole in the
/// hovered card), muted until the pointer reaches it.
private struct RowDeleteButton: View {
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

// MARK: - Native text editor

/// Minimal NSTextView wrapper for the translator panes. SwiftUI's TextEditor
/// misbehaves for real editing here (selection/paste — same class of problem
/// feat/ui-options hit in the popover inputs), so the panes use the real
/// thing: native selection, context menu, undo, and overlay scrollers that
/// only appear when the content actually overflows.
private struct PlainTextEditor: NSViewRepresentable {
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ShortcutTextView()
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

        // Word-snapped pick on mouse-up (select-to-explain). Reads the fresh
        // struct through the coordinator — the closure outlives this render.
        let coordinator = context.coordinator
        textView.onSettled = { [weak textView] in
            guard let textView, let onWordSelect = coordinator.parent.onWordSelect else { return }
            let raw = textView.selectedRange()
            guard raw.length > 0 else { return }
            let ns = textView.string as NSString
            let snapped = snapWords(raw, in: ns)
            guard snapped.length > 0 else { return }
            onWordSelect(ns.substring(with: snapped), snapped)
            // Collapse the OS selection in read-only panes so only the marker
            // shows the pick; editable panes keep it for type-over.
            if !textView.isEditable {
                DispatchQueue.main.async { [weak textView] in
                    textView?.setSelectedRange(NSRange(location: NSMaxRange(snapped), length: 0))
                }
            }
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
        guard let textView = scroll.documentView as? ShortcutTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
        }
        // Drop any marker that outran the text (belt over the model's
        // clear-on-edit) so drawing never indexes past the storage.
        let length = (textView.string as NSString).length
        textView.markers = markers.filter { NSMaxRange($0.range) <= length }
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
    }
}

/// NSTextView that resolves the standard editing shortcuts itself, so they
/// work no matter what the main menu offers (the fix feat/ui-options landed
/// for the popover inputs, applied here too). Also reports settled mouse
/// selections and draws the picked-term markers (select-to-explain).
private final class ShortcutTextView: NSTextView {
    /// Called after a mouse click/drag finishes, with the selection settled.
    var onSettled: (() -> Void)?
    /// Picked word ranges to draw (range, isFocused).
    var markers: [(range: NSRange, active: Bool)] = []

    /// `mouseDown` runs the whole selection drag loop; when it returns the
    /// selection is final — same pattern as the popover's text view.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onSettled?()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMarkers()
        super.draw(dirtyRect)
    }

    /// Rounded marker behind each picked word; the focused one reads stronger.
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, mods == .command || mods == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where mods == .command: selectAll(nil); return true
        case "c" where mods == .command: copy(nil); return true
        case "v" where mods == .command: paste(nil); return true
        case "x" where mods == .command: cut(nil); return true
        case "z" where mods == .command: undoManager?.undo(); return true
        case "z": undoManager?.redo(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - English level

/// The user's estimated English level. No signal is collected yet, so this is
/// the honest empty state over the CEFR scale; estimation from real usage
/// (translations, improvements) comes later.
private struct EnglishLevelPage: View {
    private static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    section: .englishLevel,
                    subtitle: "Talkeo estimates your level from how you actually use English."
                )

                HStack(spacing: 8) {
                    ForEach(Self.levels, id: \.self) { level in
                        Text(level)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Palette.elevated)
                            )
                    }
                }
                .frame(maxWidth: 560)

                Text("Not enough data yet. Keep translating, improving and listening — your estimated level will appear here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared page chrome

private struct PageHeader: View {
    let section: MainSection
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.elevated)
                Image(systemName: section.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
            .frame(width: 54, height: 54)

            Text(section.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Palette.foreground)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - Xcode Preview

#Preview("Main window") {
    MainWindowView(model: MainWindowModel())
        .frame(width: 1100, height: 700)
}
