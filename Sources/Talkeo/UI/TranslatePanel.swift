import AppKit
import AVFoundation
import SwiftUI

/// Google-Translate-style translation panel that opens from the tooltip's
/// Translate action. Unlike the tooltip chip (a non-activating panel that never
/// takes focus), this panel is **activating/key** because it has an editable
/// text input — the user can correct the source and re-translate.
///
/// Phase 1 (this file) is a **mockup**: the translation is a canned sample
/// revealed one-shot, Copy is real, Listen is a stub, and there is no network.
/// Phase 2 replaces `TranslateMock` with the real `StreamingClient` consuming
/// `POST /api/v1/transform/translate` (SSE).
///
/// Beyond plain translation it adds the feature that sets Talkeo apart from
/// Google Translate: **select any span in the result to paint it**, and an
/// explanation of that span in context appears below. Selection is real text
/// selection (drag, double-click, etc.), so the user can paint whole phrases,
/// not just single words. Those painted spans are exactly the vocabulary the
/// user doesn't understand — the ones worth saving later (spaced repetition,
/// Phase 2+).

/// Borderless panels can't become key by default, which would block text input.
/// Overriding `canBecomeKey` lets the activating translate panel accept the
/// keyboard while staying chromeless.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TranslatePanel {
    private let panel: KeyablePanel
    private let model = TranslateModel()
    private var escMonitor: Any?

    private static let size = NSSize(width: 580, height: 460)

    init() {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = true

        let view = TranslateView(model: model, onClose: { [weak panel] in panel?.orderOut(nil) })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting

        self.panel = panel
    }

    func show(text: String) {
        model.startTranslation(source: text)
        positionCentered()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Don't auto-focus the first control (the swap button) — no stray focus
        // ring on open. A text view still takes focus when the user clicks it.
        panel.makeFirstResponder(nil)
        installEscMonitor()
    }

    func hide() {
        removeEscMonitor()
        panel.orderOut(nil)
    }

    private func positionCentered() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.midY - Self.size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }
}

// MARK: - Model

/// Which pane a painted span lives in (marking works in source *and* target).
enum TextPane: Equatable {
    case source
    case target
}

/// A span the user painted, with the text it covers and the pane it belongs to.
struct PaintedSpan: Identifiable, Equatable {
    let pane: TextPane
    let range: NSRange
    let text: String
    var id: String { "\(pane)-\(range.location)-\(range.length)" }
}

final class TranslateModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var targetText: String = ""
    @Published var sourceLang: String = "EN"
    @Published var targetLang: String = "ES"
    @Published var sourceDetected: Bool = true
    /// Source is read-only by default (selecting marks). The edit button flips this
    /// on so the user can modify the text; while editing, selecting does not mark.
    @Published var sourceEditing: Bool = false
    /// Painted spans across both panes — the words/phrases the user doesn't get.
    @Published var painted: [PaintedSpan] = []
    /// The single span currently shown in the focus area below (one at a time).
    @Published var activeSpanID: String?
    /// Selected voice model for pronunciation (user sees the Talkeo brand, not the
    /// underlying provider). Mock today; Phase 2 maps to real BYO / Talkeo Cloud voices.
    @Published var voiceModel: String = TranslateModel.voiceModels[0]
    static let voiceModels = ["Talkeo", "System voice"]

    /// One-shot blur reveal of the translation: flips true on the first delta.
    @Published var revealed: Bool = false
    /// Bumped on every (re)translation so the view can react if needed.
    @Published var streamID: Int = 0

    /// Streaming status of the current translation, and of each painted span's
    /// explanation (keyed by span id) — drives loading / error UI.
    @Published var translationPhase: LoadPhase = .idle
    @Published var explanations: [String: String] = [:]
    @Published var explanationPhases: [String: LoadPhase] = [:]

    private let client: TransformClient
    private var translateTask: Task<Void, Never>?
    private var explainTasks: [String: Task<Void, Never>] = [:]
    /// Last source we actually translated, so tapping "Done" without edits is a no-op.
    private var lastTranslatedSource = ""

    init(client: TransformClient = TalkeoTransformClient()) {
        self.client = client
    }

    enum LoadPhase: Equatable {
        case idle
        case streaming
        case done
        case failed(String)
    }

    // MARK: Translation

    func startTranslation(source: String) {
        sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        runTranslation()
    }

    /// Re-translate the current (edited) source. No-op if it hasn't changed since
    /// the last translation — tapping "Done" without edits shouldn't refetch.
    func retranslate() {
        sourceEditing = false
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastTranslatedSource else { return }
        runTranslation()
    }

    /// Retry after a failure (re-runs the current source).
    func retryTranslation() {
        runTranslation()
    }

    private func runTranslation() {
        translateTask?.cancel()
        cancelExplanations()
        targetText = ""
        painted = []
        explanations = [:]
        explanationPhases = [:]
        activeSpanID = nil
        revealed = false
        sourceEditing = false
        streamID += 1

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranslatedSource = text
        guard !text.isEmpty else {
            translationPhase = .idle
            return
        }
        translationPhase = .streaming

        // Auto-detect (omit source_lang) until the user pins the direction via swap.
        let source = sourceDetected ? nil : sourceLang
        let stream = client.translate(text: text, sourceLang: source, targetLang: targetLang)
        translateTask = Task { @MainActor [weak self] in
            do {
                for try await delta in stream {
                    guard let self else { return }
                    self.reveal()
                    self.targetText += delta
                }
                self?.translationPhase = .done
                self?.reveal()
            } catch {
                guard let self else { return }
                self.translationPhase = .failed(Self.message(error))
                self.reveal()
            }
        }
    }

    private func reveal() {
        guard !revealed else { return }
        withAnimation(.easeOut(duration: 0.35)) { revealed = true }
    }

    func swap() {
        translateTask?.cancel()
        cancelExplanations()
        let text = sourceText
        sourceText = targetText
        targetText = text
        let lang = sourceLang
        sourceLang = targetLang
        targetLang = lang
        sourceDetected = false
        painted = []
        explanations = [:]
        explanationPhases = [:]
        activeSpanID = nil
        lastTranslatedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        translationPhase = targetText.isEmpty ? .idle : .done
        revealed = true
    }

    static func message(_ error: Error) -> String {
        (error as? TalkeoError)?.userMessage ?? "Something went wrong."
    }

    var activeSpan: PaintedSpan? {
        painted.first { $0.id == activeSpanID }
    }

    var activeIndex: Int? {
        painted.firstIndex { $0.id == activeSpanID }
    }

    func paint(pane: TextPane, range: NSRange, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Re-selecting exactly the same span just focuses it.
        if let existing = painted.first(where: { $0.pane == pane && $0.range == range }) {
            activeSpanID = existing.id
            return
        }
        // No stacking: a new span replaces any markers it overlaps in this pane.
        painted.removeAll { $0.pane == pane && NSIntersectionRange($0.range, range).length > 0 }
        let span = PaintedSpan(pane: pane, range: range, text: text)
        painted.append(span)
        activeSpanID = span.id // newest painted span takes focus
    }

    func unpaint(_ id: String) {
        guard let index = painted.firstIndex(where: { $0.id == id }) else { return }
        explainTasks[id]?.cancel()
        explainTasks[id] = nil
        explanations[id] = nil
        explanationPhases[id] = nil
        painted.remove(at: index)
        if activeSpanID == id {
            let next = min(index, painted.count - 1)
            activeSpanID = painted.indices.contains(next) ? painted[next].id : nil
        }
    }

    func step(by delta: Int) {
        guard !painted.isEmpty else { return }
        let current = activeIndex ?? 0
        let next = (current + delta + painted.count) % painted.count
        activeSpanID = painted[next].id
    }

    /// Clicking inside an existing marker focuses it (so its detail shows below).
    /// Removal is explicit (the Remove control), so a click never destroys a
    /// marker — important now that the source is editable and clicks place a caret.
    func focusSpan(in pane: TextPane, at location: Int) {
        if let hit = painted.first(where: { $0.pane == pane && NSLocationInRange(location, $0.range) }) {
            activeSpanID = hit.id
        }
    }

    /// Editing a pane's text invalidates that pane's marker offsets, so drop them.
    func clearMarkers(in pane: TextPane) {
        guard painted.contains(where: { $0.pane == pane }) else { return }
        painted.removeAll { $0.pane == pane }
        if activeSpan == nil { activeSpanID = painted.first?.id }
    }

    func spans(in pane: TextPane) -> [PaintedSpan] {
        painted.filter { $0.pane == pane }
    }

    // MARK: Explanation (highlight-to-explain)

    /// Stream the explanation for the active span unless we already have it (or
    /// it's in flight). Called whenever the active span changes, so paging back
    /// to a span reuses its cached explanation instead of refetching.
    func loadExplanationIfNeeded() {
        guard let span = activeSpan else { return }
        switch explanationPhases[span.id] {
        case .streaming, .done:
            return
        default:
            requestExplanation(for: span)
        }
    }

    /// Retry the active span's explanation after a failure.
    func retryActiveExplanation() {
        if let span = activeSpan { requestExplanation(for: span) }
    }

    private func requestExplanation(for span: PaintedSpan) {
        let id = span.id
        explainTasks[id]?.cancel()
        explanations[id] = ""
        explanationPhases[id] = .streaming

        // The term lives in its pane's language; explain it in the *other*
        // language (a source-EN word explained in ES, a target-ES word in EN) —
        // the cross-language gloss the learner wants.
        let sentence = span.pane == .source ? sourceText : targetText
        let termLang = span.pane == .source ? sourceLang : targetLang
        let explainLang = span.pane == .source ? targetLang : sourceLang
        let stream = client.explain(
            term: span.text,
            sentence: sentence,
            sourceLang: termLang,
            targetLang: explainLang
        )
        explainTasks[id] = Task { @MainActor [weak self] in
            do {
                for try await delta in stream {
                    self?.explanations[id, default: ""] += delta
                }
                if !Task.isCancelled { self?.explanationPhases[id] = .done }
            } catch {
                if !Task.isCancelled { self?.explanationPhases[id] = .failed(TranslateModel.message(error)) }
            }
        }
    }

    private func cancelExplanations() {
        explainTasks.values.forEach { $0.cancel() }
        explainTasks = [:]
    }
}

// MARK: - Pronunciation

/// Speaks text in the right language. Phase 1 uses the local `AVSpeechSynthesizer`
/// so pronunciation works offline in the mockup; Phase 2 swaps this for the
/// streamed cloud `/speak` voice without touching call sites.
enum Speaker {
    private static let synth = AVSpeechSynthesizer()

    static func speak(_ text: String, lang: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: bcp47(lang))
        synth.speak(utterance)
    }

    private static func bcp47(_ code: String) -> String {
        switch code.uppercased() {
        case "ES": return "es-ES"
        case "EN": return "en-US"
        default: return "en-US"
        }
    }
}

// MARK: - Palette (mirrors apps/web globals.css — neutral, minimal)

/// Talkeo's web palette ported to native. The brand is monochrome: near-black /
/// near-white foreground over neutral gray surfaces, no colored accent. Each
/// token resolves per light/dark appearance.
enum Palette {
    static let surface = dynamic(0xFFFFFF, 0x1C1C1C)   // popover
    static let elevated = dynamic(0xF5F5F5, 0x242424)  // muted / secondary surface
    static let foreground = dynamic(0x111111, 0xDEDEDE)
    static let muted = dynamic(0x555555, 0x8A8A8A)     // muted-foreground
    static let tertiary = dynamic(0xBBBBBB, 0x606060)
    static let border = dynamic(0xEBEBEB, 0x3A3A3A)

    static func dynamic(_ light: UInt, _ dark: UInt) -> Color {
        Color(nsColor: nsDynamic(light, dark))
    }

    static func nsDynamic(_ light: UInt, _ dark: UInt) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    static func rgb(_ hex: UInt) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Neutral marker; the focused span reads stronger (and is underlined).
    static func marker(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = rgb(isDark ? 0xDEDEDE : 0x111111)
            return base.withAlphaComponent(active ? 0.18 : 0.08)
        }
    }

    static let nsForeground = nsDynamic(0x111111, 0xDEDEDE)
}

/// Native vibrancy material — the frosted, layered look that makes the panel
/// read as a real macOS surface rather than a flat rectangle.
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - View

struct TranslateView: View {
    @ObservedObject var model: TranslateModel
    let onClose: () -> Void
    @State private var sourceHover = false
    @State private var targetHover = false
    @State private var sourceCollapse = 0
    @State private var targetCollapse = 0
    @State private var focusHover = false

    var body: some View {
        VStack(spacing: 10) {
            header
            panes
            focusCard
        }
        .padding(12)
        .frame(width: 580, height: 480)
        .background(
            ZStack {
                VisualEffectView(material: .menu, blending: .behindWindow)
                Palette.surface.opacity(0.78)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
                .blendMode(.overlay)
        )
        .onChange(of: model.activeSpanID) { _ in
            model.loadExplanationIfNeeded()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LangPill(code: model.sourceLang, detected: model.sourceDetected)
            Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.swap() } }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.elevated))
            }
            .buttonStyle(.plain)
            LangPill(code: model.targetLang, detected: false)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Panes (side-by-side rounded cards, Google-Translate style)

    private var panes: some View {
        HStack(spacing: 10) {
            sourcePane
            targetPane
        }
        .frame(height: 196)
    }

    private var sourcePane: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    cardLabel("Source")
                    Spacer()
                    Button(action: {
                        // "Done" commits the edit and re-translates; "Edit" opens editing.
                        if model.sourceEditing { model.retranslate() } else { model.sourceEditing = true }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: model.sourceEditing ? "checkmark" : "pencil")
                                .font(.system(size: 10, weight: .semibold))
                            Text(model.sourceEditing ? "Done" : "Edit")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(model.sourceEditing ? Palette.foreground : Palette.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(model.sourceEditing ? Palette.elevated : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(model.sourceEditing ? "Done editing" : "Edit text")
                    .opacity(model.sourceEditing || sourceHover ? 1 : 0)
                }
                SelectableText(
                    text: model.sourceText,
                    isEditable: model.sourceEditing,
                    highlights: model.spans(in: .source),
                    activeID: model.activeSpanID,
                    collapseToken: sourceCollapse,
                    onTextChange: { newText in
                        model.sourceText = newText
                        model.clearMarkers(in: .source)
                    },
                    onSelect: { selection in
                        guard !model.sourceEditing, let selection else { return }
                        model.paint(pane: .source, range: selection.range, text: selection.text)
                        sourceCollapse += 1
                    },
                    onCaret: { location in model.focusSpan(in: .source, at: location) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                actionRow(text: model.sourceText, lang: model.sourceLang)
                    .opacity(sourceHover ? 1 : 0)
            }
        }
        .onHover { sourceHover = $0 }
    }

    private var targetPane: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Translation")
                ZStack(alignment: .topLeading) {
                    if case let .failed(message) = model.translationPhase {
                        paneError(message) { model.retryTranslation() }
                    } else {
                        SelectableText(
                            text: model.targetText,
                            isEditable: false,
                            highlights: model.spans(in: .target),
                            activeID: model.activeSpanID,
                            collapseToken: targetCollapse,
                            onSelect: { selection in
                                guard let selection else { return }
                                model.paint(pane: .target, range: selection.range, text: selection.text)
                                targetCollapse += 1
                            },
                            onCaret: { location in model.focusSpan(in: .target, at: location) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(model.revealed ? 1 : 0)
                        .blur(radius: model.revealed ? 0 : 6)
                        if model.translationPhase == .streaming, model.targetText.isEmpty {
                            Text("Translating…")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                actionRow(text: model.targetText, lang: model.targetLang)
                    .opacity(targetHover ? 1 : 0)
            }
        }
        .onHover { targetHover = $0 }
    }

    /// Rounded surface card shared by source/target/focus.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Palette.border.opacity(0.5), lineWidth: 0.5)
            )
    }

    // MARK: Focus area — one painted span at a time, with a pager

    private var focusCard: some View {
        focusArea
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onHover { focusHover = $0 }
    }

    @ViewBuilder
    private var focusArea: some View {
        if let span = model.activeSpan {
            spanDetail(span)
        } else {
            focusEmptyState
        }
    }

    private func spanDetail(_ span: PaintedSpan) -> some View {
        let word = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(word)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                if model.painted.count > 1 {
                    pager
                }
                Button(action: { model.unpaint(span.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Palette.elevated))
                }
                .buttonStyle(.plain)
                .help("Remove highlight")
                .opacity(focusHover ? 1 : 0)
            }
            explanationBody(span)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                askLeoBadge
                Spacer()
                listenButton(word: word, pane: span.pane)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The streamed contextual explanation for a painted span, with loading and
    /// error states matching the translation pane.
    @ViewBuilder
    private func explanationBody(_ span: PaintedSpan) -> some View {
        if case let .failed(message) = model.explanationPhases[span.id] {
            paneError(message) { model.retryActiveExplanation() }
        } else {
            let text = model.explanations[span.id] ?? ""
            if text.isEmpty, model.explanationPhases[span.id] == .streaming {
                Text("Explaining…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Inline error with a Retry affordance, shared by the translation pane and
    /// the explanation card.
    private func paneError(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.muted)
            Button(action: retry) {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.elevated))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Listen to the active word (primary action), plus a chevron to pick the
    /// voice model. Filled with the brand primary color, web-style.
    private func listenButton(word: String, pane: TextPane) -> some View {
        HStack(spacing: 7) {
            Button(action: { Speaker.speak(word, lang: lang(for: pane)) }) {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Listen")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Palette.surface)
            }
            .buttonStyle(.plain)

            Rectangle().fill(Palette.surface.opacity(0.25)).frame(width: 1, height: 12)

            Menu {
                Picker("Voice model", selection: $model.voiceModel) {
                    ForEach(TranslateModel.voiceModels, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.surface)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Palette.surface)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Palette.foreground))
    }

    /// Visible but inert — signals the upcoming "talk to Leo about this word".
    private var askLeoBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 11, weight: .semibold))
            Text("Ask Leo")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(Palette.muted)
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .opacity(0.6)
    }

    private func lang(for pane: TextPane) -> String {
        pane == .source ? model.sourceLang : model.targetLang
    }

    private var pager: some View {
        HStack(spacing: 8) {
            Button(action: { model.step(by: -1) }) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            Text("\((model.activeIndex ?? 0) + 1) / \(model.painted.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
            Button(action: { model.step(by: 1) }) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.muted)
    }

    private var focusEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "highlighter")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Palette.tertiary)
            Text("Highlight any word or phrase above\nto see it explained here.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Shared bits

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Palette.tertiary)
            .tracking(0.6)
    }

    private func actionRow(text: String, lang: String) -> some View {
        HStack(spacing: 4) {
            Spacer()
            IconButton(system: "speaker.wave.2") { Speaker.speak(text, lang: lang) }
            IconButton(system: "doc.on.doc") { copy(text) }
        }
    }

    private func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Components

private struct LangPill: View {
    let code: String
    let detected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(code)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            if detected {
                Text("auto")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Palette.elevated))
    }
}

private struct IconButton: View {
    let system: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Palette.elevated : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Selectable, paintable text (AppKit)

/// A non-empty selection settled in a pane: the word-snapped range, its text,
/// and the bounding rect (in the text view's coordinate space) used to anchor
/// the floating "Explain" pill.
struct PaneSelection: Equatable {
    let range: NSRange
    let text: String
    let rect: CGRect
}

/// An NSTextView that supports real text selection (drag, double-click, keyboard)
/// and, when `isEditable`, normal text editing. Selecting text does NOT mark it —
/// it reports the selection via `onSelect` so the parent can show an "Explain"
/// pill; marking only happens when the user taps that pill. This is what lets
/// editing and marking coexist (select to edit/copy, or tap Explain to mark).
/// Painted spans render as rounded markers drawn by PaintTextView.
private struct SelectableText: NSViewRepresentable {
    let text: String
    var isEditable: Bool = false
    let highlights: [PaintedSpan]
    let activeID: String?
    /// Incremented by the parent after marking, to clear the OS selection.
    var collapseToken: Int = 0
    var onTextChange: (String) -> Void = { _ in }
    let onSelect: (PaneSelection?) -> Void
    let onCaret: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PaintTextView()
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = Palette.nsForeground
        textView.insertionPointColor = Palette.nsForeground
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: Palette.nsForeground,
        ]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PaintTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            textView.textColor = Palette.nsForeground
        }
        context.coordinator.onTextChange = onTextChange

        // Take focus + place the caret at the end when edit mode turns on.
        if isEditable, !context.coordinator.wasEditable {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
        context.coordinator.wasEditable = isEditable

        textView.onSettled = { [weak textView] in
            guard let textView else { return }
            let raw = textView.selectedRange()
            let ns = textView.string as NSString
            if raw.length > 0 {
                let snapped = snapToWords(raw, in: ns)
                if snapped.length > 0 {
                    onSelect(PaneSelection(
                        range: snapped,
                        text: ns.substring(with: snapped),
                        rect: textView.boundingRect(for: snapped)
                    ))
                    return
                }
            }
            onSelect(nil)
            onCaret(raw.location)
        }

        // Collapse the OS selection once the parent has marked it.
        if context.coordinator.lastCollapse != collapseToken {
            context.coordinator.lastCollapse = collapseToken
            let end = NSMaxRange(textView.selectedRange())
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        let length = (textView.string as NSString).length
        textView.markers = highlights
            .filter { NSMaxRange($0.range) <= length }
            .map { ($0.range, $0.id == activeID) }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void = { _ in }
        var lastCollapse = 0
        var wasEditable = false

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}

/// Snaps a raw selection to the whole words it actually touches. A selection
/// that covers no letter at all (only spaces/punctuation) snaps to nothing, so
/// dragging over a gap never marks an adjacent word.
private func snapToWords(_ range: NSRange, in ns: NSString) -> NSRange {
    let empty = NSRange(location: range.location, length: 0)
    guard range.length > 0, range.location >= 0, NSMaxRange(range) <= ns.length else { return empty }
    let letters = CharacterSet.letters
    func isLetter(_ index: Int) -> Bool {
        guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
        return letters.contains(scalar)
    }
    // Anchor on the first/last letter that lies *inside* the selection.
    var firstLetter = -1
    var lastLetter = -1
    for index in range.location..<NSMaxRange(range) where isLetter(index) {
        if firstLetter == -1 { firstLetter = index }
        lastLetter = index
    }
    guard firstLetter != -1 else { return empty } // no letters selected → no marker
    var start = firstLetter
    var end = lastLetter + 1
    while start > 0, isLetter(start - 1) { start -= 1 } // grow left into the word
    while end < ns.length, isLetter(end) { end += 1 }   // grow right into the word
    return NSRange(location: start, length: end - start)
}

private final class PaintTextView: NSTextView {
    /// Called once a click/drag settles, so the parent can read the selection.
    var onSettled: (() -> Void)?
    /// Painted ranges to draw as rounded markers (range, isActive).
    var markers: [(range: NSRange, active: Bool)] = []

    /// Bounding rect of a character range in this view's coordinate space —
    /// used to anchor the floating "Explain" pill.
    func boundingRect(for range: NSRange) -> CGRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Draws rounded marker backgrounds behind the glyphs (Google-Translate-ish),
    /// then lets NSTextView render the text + selection on top.
    override func draw(_ dirtyRect: NSRect) {
        drawMarkers()
        super.draw(dirtyRect)
    }

    private func drawMarkers() {
        guard !markers.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for marker in markers {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 1)
                Palette.marker(active: marker.active).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    /// NSTextView runs its own mouse-tracking loop *inside* `mouseDown` (it does
    /// not deliver a separate `mouseUp` for selection drags), so `super.mouseDown`
    /// only returns once the drag/selection is finished — then we report it.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onSettled?()
    }
}

// MARK: - Previews

/// Canned `TransformClient` so the SwiftUI preview renders without a backend.
private struct PreviewTransformClient: TransformClient {
    func translate(text: String, sourceLang: String?, targetLang: String) -> AsyncThrowingStream<String, Error> {
        Self.canned("El comité alcanzó un acuerdo tentativo tras una deliberación exhaustiva.")
    }

    func explain(term: String, sentence: String, sourceLang: String?, targetLang: String) -> AsyncThrowingStream<String, Error> {
        Self.canned("Provisional, no definitivo; sujeto a confirmación — 'tentative'.")
    }

    private static func canned(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}

private struct TranslatePreview: View {
    @StateObject private var model = TranslateModel(client: PreviewTransformClient())
    var body: some View {
        TranslateView(model: model, onClose: {})
            .padding(40)
            .onAppear {
                model.sourceText = "The committee reached a tentative agreement after a thorough deliberation."
                model.targetText = "El comité alcanzó un acuerdo tentativo tras una deliberación exhaustiva."
                model.revealed = true
                model.translationPhase = .done
                let span = PaintedSpan(pane: .target, range: NSRange(location: 21, length: 18), text: "acuerdo tentativo")
                model.painted = [span]
                model.activeSpanID = span.id
                model.explanations[span.id] = "Acuerdo provisional, no definitivo; sujeto a confirmación."
                model.explanationPhases[span.id] = .done
            }
    }
}

#Preview("Translate panel") { TranslatePreview() }
