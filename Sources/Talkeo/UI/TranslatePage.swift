import AppKit
import SwiftUI

/// The main window's Translate feature: the Google-Translate-style page (side-
/// by-side panes, history drawer) plus its select-to-explain (shared
/// ExplainSession + vocab card). Lives beside the popover in UI/ — the two
/// surfaces of the same translate + learn core.

/// State for the in-app translator. Mirrors the popover's flow (detect EN/ES,
/// stream deltas, record history) but is its own model: text is typed rather
/// than captured, and translation runs only on the CTA / ⌘⏎ — never
/// auto-on-type. Owned by `MainWindowModel` so switching sections doesn't
/// lose the text.
final class TranslatePageModel: ObservableObject {
    /// Detected source ("EN"/"ES") of the last translation — feeds the
    /// header's passive direction label.
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
    /// Invalidates in-flight tasks when a newer translation supersedes them.
    private var generation = 0

    init(client: TransformClient = TalkeoTransformClient(), history: HistoryStore = LocalHistoryStore.shared) {
        self.client = client
        self.history = history
        self.session = ExplainSession(client: client)
    }

    /// Source of the *next* translation: last detection, else ES (the
    /// placeholder direction — the user's language into English).
    var effectiveSource: String { detected ?? "ES" }
    var targetLang: String { effectiveSource == "EN" ? "ES" : "EN" }

    /// Typing invalidates the last translation — its output and picked terms
    /// belonged to the text as it was. No auto-run: translation happens only
    /// on the CTA / ⌘⏎ (`translateNow`), the same deliberate trigger as
    /// Improve and Listen.
    func sourceEdited() {
        reset(keepText: true)
    }

    func translateNow() {
        streamTask?.cancel()
        generation += 1
        let gen = generation
        // A new translation replaces the output (and may re-detect the pair);
        // picked terms belong to the old text.
        clearSelection()

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let src = QuickTranslateModel.detectLanguage(text)
        let tgt = src == "EN" ? "ES" : "EN"
        detected = src
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

    /// Load a history entry back into the translator (no re-request).
    func select(_ entry: HistoryEntry) {
        streamTask?.cancel()
        generation += 1
        clearSelection()
        detected = entry.detectedLang
        sourceText = entry.source
        outputText = entry.target
        isStreaming = false
        errorMessage = nil
    }

    /// Programmatic text handoff (captured text routed from the capture
    /// preview): replace the source without auto-translating. The old output
    /// is dropped — it belonged to the old text — and nothing runs until the
    /// user triggers it. Unchanged text is a no-op, so re-capturing the same
    /// text keeps the last result.
    func replaceSource(_ text: String) {
        guard text != sourceText else { return }
        streamTask?.cancel()
        generation += 1
        clearSelection()
        detected = nil
        sourceText = text
        outputText = ""
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

/// The in-app translator: Google Translate distilled — side-by-side
/// source/translation panes, translate-as-you-type with automatic EN↔ES
/// detection (no chips, no swap), and a collapsible history drawer on the
/// right. The space under the panes is reserved for selected meanings
/// (explain cards, mirroring the popover's select-to-learn).
struct TranslatePage: View {
    @ObservedObject var model: TranslatePageModel
    /// Observed directly: the session is its own ObservableObject and its
    /// changes don't bubble through the model.
    @ObservedObject var session: ExplainSession
    /// The screen-capture entry point, injected by the window (the TCC-gated
    /// flow lives in the AppDelegate); nil hides the button.
    let onCapture: (() -> Void)?

    init(model: TranslatePageModel, onCapture: (() -> Void)? = nil) {
        self.model = model
        self.session = model.session
        self.onCapture = onCapture
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
    }

    private var translator: some View {
        VStack(spacing: 16) {
            PageTitleHeader(
                title: "Translate",
                subtitle: "Translate between English and Spanish — direction is detected automatically."
            ) {
                if let onCapture { CaptureButton(action: onCapture) }
                HistoryToggle(isOpen: model.historyOpen) {
                    model.historyOpen.toggle()
                    // The popover writes to the same store while this page
                    // is mounted — re-read on open so it's never stale.
                    if model.historyOpen { model.refreshHistory() }
                }
            } detail: {
                if let detected = model.detected,
                   !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(QuickTranslateModel.languageName(detected)) → \(QuickTranslateModel.languageName(model.targetLang))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                }
            }

            // No language chips or swap cluster: detection is automatic and
            // bidirectional EN↔ES, so the panes sit at the top and never
            // move. The header shows the detected direction passively on its
            // subtitle line.
            HStack(alignment: .top, spacing: 14) {
                sourcePane
                outputPane
            }
            .frame(height: 280)

            actionBar

            // Selected meanings: pick a word in either pane and it's taught
            // here (the popover's select-to-learn, at home in the app).
            cardArea
        }
        .padding(.horizontal, 48)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: PageGrid.maxWidth)
        .frame(maxWidth: .infinity)
        // ⌘⏎ runs the translation — the same commit trigger as the CTA.
        .background(
            Button("") { model.translateNow() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        )
    }

    /// The explicit run bar, mirroring Improve's CTA: the button (and its
    /// ⌘⏎ badge) is the only trigger — typing never auto-translates.
    private var actionBar: some View {
        let hasText = !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Disabled reads muted, not faded: tertiary label on the secondary
        // surface, matching how native controls gray out.
        let ctaText = hasText ? Palette.primaryForeground : Palette.tertiary
        return HStack {
            Spacer()
            Button(action: { model.translateNow() }) {
                HStack(spacing: 7) {
                    Text("Translate")
                        .font(.system(size: 15, weight: .semibold))
                    Text("⌘⏎")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ctaText.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ctaText.opacity(0.18)))
                }
                .foregroundStyle(ctaText)
                .padding(.horizontal, 17)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hasText ? Palette.primary : Palette.elevated))
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .handCursor()
        }
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
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 15)
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
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.muted)
                    Button("Try again") { model.translateNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
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
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 15)
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
            // (Joaquin's call). Capped to a reading measure and centered:
            // full grid width put the speakers a whole screen away from
            // the text.
            ScrollView {
                ExplainCardPane(session: session)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
        } else if !model.outputText.isEmpty && model.errorMessage == nil {
            // Kept visible during streaming too, so it never pops in late
            // (same lesson the popover's skeleton hint learned). A wireframe
            // illustration plays the pick gesture instead of just naming it.
            PickWordHint()
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            Spacer(minLength: 0)
        } else if model.outputText.isEmpty && !model.isStreaming && model.errorMessage == nil {
            // Idle, nothing translated yet: the EN⇄ES exchange plays in the
            // empty space instead.
            TranslateFlowHint()
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            Spacer(minLength: 0)
        } else {
            Spacer(minLength: 0)
        }
    }
}

// MARK: - EN→ES flight hint (isometric)

/// The idle-state illustration — Cartesia's isometric language on our
/// monochrome tokens: two extruded plates, the EN and ES territories,
/// anchored and immobile (the stable reference of the reference's stack);
/// a small extruded word tile lifts off one plate, glides across on
/// Cartesia's own easing, crossfades its text mid-flight (translations
/// change the words), and settles onto the other plate. Then it flies back —
/// the bidirectional auto-detection, shown. Verified frame-by-frame against
/// rendered stills.
private struct TranslateFlowHint: View {
    @State private var step = 0

    var body: some View {
        VStack(spacing: 18) {
            TranslateIsoIllustration(step: step)
            Text("Either direction — the language is detected automatically")
                .font(.system(size: 14))
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
        // Lift → glide → settle → hold, then the return trip; auto-cancelled
        // with the view. The reset to 0 is visually identical to step 6, so
        // the loop seam is invisible.
        .task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            while !Task.isCancelled {
                step = 1
                try? await Task.sleep(nanoseconds: 400_000_000)
                step = 2
                try? await Task.sleep(nanoseconds: 850_000_000)
                step = 3
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                step = 4
                try? await Task.sleep(nanoseconds: 400_000_000)
                step = 5
                try? await Task.sleep(nanoseconds: 850_000_000)
                step = 6
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                step = 0
            }
        }
    }
}

/// The stage. `step` drives the flight: 0 seated on EN · 1 lifted · 2 gliding
/// (over ES, still airborne) · 3 seated on ES · 4 lifted · 5 gliding back ·
/// 6 seated on EN (≡ 0).
private struct TranslateIsoIllustration: View {
    let step: Int

    static let stage = CGSize(width: 460, height: 232)
    static let plateA = CGPoint(x: 150, y: 128)
    static let plateB = CGPoint(x: 310, y: 128)
    static let tileRestY: CGFloat = 112
    static let liftAmount: CGFloat = 20

    /// Cartesia's transition curve, measured from their deploy stack.
    static let glide = Animation.timingCurve(0.5, 0.06, 0.18, 1, duration: 0.75)

    private var onB: Bool { (2...4).contains(step) }
    private var lifted: Bool { [1, 2, 4, 5].contains(step) }
    private var esContent: Bool { (2...4).contains(step) }

    // Extrusion tones: tops from the shared palette; sides one step darker
    // in light, one step deeper in dark (the shadowed face).
    private static let plateSide = Palette.dynamic(0xD9D9D9, 0x151515)
    private static let tileTop = Palette.dynamic(0xFFFFFF, 0x2E2E2E)
    private static let tileSide = Palette.dynamic(0xE0E0E0, 0x191919)

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid
            cornerLabels

            // The two territories — anchored, they never move.
            IsoSlab(size: 92, radius: 14, depth: 9, top: Palette.elevated, side: Self.plateSide, stroke: Palette.border) {}
                .position(Self.plateA)
            IsoSlab(size: 92, radius: 14, depth: 9, top: Palette.elevated, side: Self.plateSide, stroke: Palette.border) {}
                .position(Self.plateB)

            Text("[ EN ]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.tertiary)
                .position(x: Self.plateA.x, y: 196)
            Text("[ ES ]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.tertiary)
                .position(x: Self.plateB.x, y: 196)

            shadow
            tile
        }
        .frame(width: Self.stage.width, height: Self.stage.height)
    }

    /// The word tile in flight: y (lift) and x (glide) ride separate
    /// animations — each step only ever changes one of them, so lift, glide
    /// and settle read as distinct beats of one gesture. Mid-glide the tile
    /// SPINS a half turn around its vertical axis (same curve as the glide),
    /// landing turned over — the transformation made visible; the ES bars
    /// are drawn pre-rotated so they arrive upright.
    private var tile: some View {
        IsoSlab(
            size: 40, radius: 8, depth: 6,
            top: Self.tileTop, side: Self.tileSide, stroke: Palette.border,
            spin: onB ? .degrees(180) : .zero
        ) {
            ZStack {
                VStack(alignment: .leading, spacing: 5) {
                    bar(20); bar(13)
                }
                .opacity(esContent ? 0 : 1)
                VStack(alignment: .leading, spacing: 5) {
                    bar(14); bar(19)
                }
                .rotationEffect(.degrees(180))
                .opacity(esContent ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.4), value: step)
        }
        // Innermost claim: the spin follows the glide curve, not the lift's.
        .animation(Self.glide, value: step)
        .offset(y: lifted ? -Self.liftAmount : 0)
        .animation(.easeInOut(duration: 0.32), value: step)
        .offset(x: onB ? Self.plateB.x - Self.plateA.x : 0)
        .animation(Self.glide, value: step)
        .position(x: Self.plateA.x, y: Self.tileRestY)
    }

    private func bar(_ w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Palette.foreground.opacity(0.4))
            .frame(width: w, height: 3.5)
            .frame(width: 24, alignment: .leading)
    }

    /// Contact shadow on the plate below — detaches (smaller, fainter) while
    /// the tile is airborne, and glides on the same curve.
    private var shadow: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(lifted ? 0.05 : 0.10))
            .frame(width: 40, height: 40)
            .rotationEffect(.degrees(45))
            .scaleEffect(x: lifted ? 0.8 : 1, y: 0.577 * (lifted ? 0.8 : 1))
            .animation(.easeInOut(duration: 0.32), value: step)
            .offset(x: onB ? Self.plateB.x - Self.plateA.x : 0)
            .animation(Self.glide, value: step)
            .position(x: Self.plateA.x, y: Self.plateA.y - 4)
    }

    /// Faint cell-grid furniture behind everything.
    private var grid: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 58
            var path = Path()
            var x = pitch
            while x < size.width {
                path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); x += pitch
            }
            var y = pitch
            while y < size.height {
                path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)); y += pitch
            }
            ctx.stroke(path, with: .color(Palette.border.opacity(0.55)), lineWidth: 1)
        }
    }

    private var cornerLabels: some View {
        ZStack(alignment: .topLeading) {
            Text("[ TRANSLATE ]").offset(x: 6, y: 6)
            Text("[ AUTO-DETECT ]").offset(x: Self.stage.width - 122, y: Self.stage.height - 22)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Palette.tertiary.opacity(0.8))
    }
}

/// An extruded isometric rounded square: flat content projected to 30° iso
/// (rotate 45° + squash to 0.577) and raised by stacking side-colored slices
/// in screen space — ui-foundry's SVG iso-extrusion technique, in SwiftUI.
private struct IsoSlab<Content: View>: View {
    var size: CGFloat
    var radius: CGFloat
    var depth: CGFloat
    var top: Color
    var side: Color
    var stroke: Color
    /// Extra plan-view rotation on top of the projection's own 45° — spinning
    /// the slab around its vertical axis, extrusion staying screen-down.
    var spin: Angle = .zero
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            // Base silhouette stroke (the bottom slice), then the side band
            // stacked slice by slice up to the top face's seat.
            isoProject(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
            .offset(y: depth)

            ForEach(0..<Int(depth), id: \.self) { i in
                isoProject(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(side)
                )
                .offset(y: depth - CGFloat(i))
            }

            // Top face: fill, flat content, edge stroke.
            isoProject(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(top)
                    content()
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                }
            )
        }
    }

    private func isoProject<V: View>(_ v: V) -> some View {
        v.frame(width: size, height: size)
            .rotationEffect(.degrees(45) + spin)
            .scaleEffect(x: 1, y: 0.577)
    }
}

// MARK: - Pick-a-word hint

/// The empty-state affordance under a fresh translation — a wireframe
/// illustration in the app's own primitives (Firecrawl's lab-sketch grammar:
/// boxes, 1px borders, radius as volume, skeleton pills as content, mono
/// bracket labels as furniture) whose animation IS the gesture being taught:
/// an arrow cursor glides to a word on a folded-corner paper sheet, drags
/// across it — the selection highlight and the text's inking sweep locked to
/// the same curve as the pointer — and on release the annotation lead draws
/// itself left→right; the meaning card fills in the moment the line lands,
/// in place, no vertical travel. The card idles as an empty ghost silhouette
/// (the reference's ghost-morph idiom) so the composition stays balanced
/// through the loop. Composition verified phase-by-phase against rendered
/// PNGs of the reference components.
private struct PickWordHint: View {
    @State private var phase = PickPhase.rest

    var body: some View {
        VStack(spacing: 18) {
            PickWordIllustration(phase: phase)
            Text("Select any word to see its meaning")
                .font(.system(size: 14))
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
        // The gesture loop, auto-cancelled with the view: rest → glide to
        // the word → drag across it → meaning holds → release. Sleeps cover
        // each move plus a natural beat before the next.
        .task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                phase = .aim
                try? await Task.sleep(nanoseconds: 950_000_000)
                phase = .sweep
                try? await Task.sleep(nanoseconds: 800_000_000)
                phase = .revealed
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                phase = .rest
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

/// The selection gesture's phases: cursor at rest, gliding to the word,
/// dragging across it, meaning revealed.
private enum PickPhase {
    case rest, aim, sweep, revealed

    var swept: Bool { self == .sweep || self == .revealed }
    var isRevealed: Bool { self == .revealed }
}

/// The stage. Fixed coordinates ARE the parametric model — the cursor's
/// waypoints, the lead's anchor and the card's seat all derive from the
/// picked word's rect, so the pieces can't drift apart.
private struct PickWordIllustration: View {
    let phase: PickPhase

    static let stage = CGSize(width: 460, height: 232)
    static let docOrigin = CGPoint(x: 44, y: 26)
    static let docSize = CGSize(width: 140, height: 180)
    /// The picked word bar, in doc coordinates.
    static let picked = CGRect(x: 76, y: 84, width: 42, height: 5)
    /// The selection highlight's padding around the word.
    static let selPad = CGSize(width: 4, height: 5.5)
    static let cardOrigin = CGPoint(x: 240, y: 81)
    static let cardSize = CGSize(width: 146, height: 60)

    /// Cursor tip per phase (stage coords): resting low between doc and
    /// card, at the word's start, at its end while sweeping/holding.
    private var cursorTip: CGPoint {
        let wordY = Self.docOrigin.y + Self.picked.midY + 3
        switch phase {
        case .rest: return CGPoint(x: 236, y: 196)
        case .aim: return CGPoint(x: Self.docOrigin.x + Self.picked.minX - 2, y: wordY)
        case .sweep, .revealed: return CGPoint(x: Self.docOrigin.x + Self.picked.maxX + 2, y: wordY)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid
            cornerLabels
            document
                .offset(x: Self.docOrigin.x, y: Self.docOrigin.y)
            lead
            meaningCard
                .offset(x: Self.cardOrigin.x, y: Self.cardOrigin.y)
            cursor
        }
        .frame(width: Self.stage.width, height: Self.stage.height)
    }

    /// Faint cell-grid furniture behind everything.
    private var grid: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 58
            var path = Path()
            var x = pitch
            while x < size.width {
                path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); x += pitch
            }
            var y = pitch
            while y < size.height {
                path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)); y += pitch
            }
            ctx.stroke(path, with: .color(Palette.border.opacity(0.55)), lineWidth: 1)
        }
    }

    /// Barely-legible mono bracket labels in opposite corners.
    private var cornerLabels: some View {
        ZStack(alignment: .topLeading) {
            Text("[ TRANSLATE ]")
                .offset(x: 6, y: 6)
            Text("[ EN → ES ]")
                .offset(x: Self.stage.width - 86, y: Self.stage.height - 22)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Palette.tertiary.opacity(0.8))
    }

    /// The paper sheet: folded corner, soft shadow, skeleton text rows laid
    /// out absolutely so the pick anchor math stays exact.
    private var document: some View {
        ZStack(alignment: .topLeading) {
            SheetShape()
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
            SheetShape()
                .stroke(Palette.border, lineWidth: 1)
            FoldFlap()
                .fill(Palette.elevated)
            FoldFlap()
                .stroke(Palette.border, lineWidth: 1)

            Group {
                bar(16, 22, 72, 7, 0.13)                        // heading
                bar(16, 42, 46, 5, 0.07); bar(66, 42, 58, 5, 0.07)
                bar(16, 54, 98, 5, 0.07)
                bar(16, 66, 30, 5, 0.07); bar(50, 66, 62, 5, 0.07)

                bar(16, 84, 58, 5, 0.07)                        // picked row
                selection
                bar(16, 96, 88, 5, 0.07)
                bar(16, 108, 40, 5, 0.07); bar(60, 108, 48, 5, 0.07)
                bar(16, 120, 76, 5, 0.07)

                bar(16, 150, 14, 4, 0.06); bar(34, 150, 14, 4, 0.06); bar(52, 150, 14, 4, 0.06)
            }
        }
        .frame(width: Self.docSize.width, height: Self.docSize.height)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ alpha: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: h / 2, style: .continuous)
            .fill(Palette.foreground.opacity(alpha))
            .frame(width: w, height: h)
            .offset(x: x, y: y)
    }

    /// The target word under the drag: a skeleton bar always; a selection
    /// highlight box plus an ink overlay whose widths sweep on the SAME
    /// curve driving the cursor, so highlight, inking and pointer move as
    /// one locked gesture. Collapsing back reads as deselection.
    private var selection: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Palette.foreground.opacity(0.07))
                .frame(width: Self.picked.width, height: Self.picked.height)
                .offset(x: Self.picked.minX, y: Self.picked.minY)

            // Squarish highlight, like real text selection.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.foreground.opacity(0.12))
                .frame(
                    width: phase.swept ? Self.picked.width + Self.selPad.width * 2 : 0,
                    height: Self.picked.height + Self.selPad.height * 2
                )
                .offset(x: Self.picked.minX - Self.selPad.width, y: Self.picked.minY - Self.selPad.height)

            // The swept text inking up under the highlight, same width run.
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Palette.foreground.opacity(0.8))
                .frame(width: phase.swept ? Self.picked.width : 0, height: Self.picked.height)
                .offset(x: Self.picked.minX, y: Self.picked.minY)
        }
        .animation(.easeInOut(duration: 0.58), value: phase)
    }

    /// The actor: a classic arrow pointer, ink-filled with a paper outline
    /// so it reads over anything, positioned by its tip. Its glide shares
    /// the selection sweep's curve — that lock is what sells the drag.
    private var cursor: some View {
        CursorShape()
            .fill(Palette.foreground.opacity(0.92))
            .overlay(CursorShape().stroke(Palette.surface, lineWidth: 1.4))
            .frame(width: 13, height: 19)
            .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1.5)
            .offset(x: cursorTip.x, y: cursorTip.y)
            .animation(.easeInOut(duration: 0.58), value: phase)
    }

    /// How long the lead takes to draw, and when it starts after release —
    /// the card's appearance is chained exactly to the line's arrival.
    private static let leadDelay = 0.12
    private static let leadDraw = 0.35

    /// Anchor dot + horizontal dashed annotation lead. The dot pops first,
    /// then the line DRAWS itself left→right out of it (trim, not fade). The
    /// dot floats a touch off the selection so ink doesn't melt into ink.
    private var lead: some View {
        let anchor = CGPoint(
            x: Self.docOrigin.x + Self.picked.maxX + Self.selPad.width + 8,
            y: Self.docOrigin.y + Self.picked.midY
        )
        let endX = Self.cardOrigin.x - 5
        return ZStack(alignment: .topLeading) {
            LeadLine(y: anchor.y, x0: anchor.x + 7, x1: endX)
                .trim(from: 0, to: phase.isRevealed ? 1 : 0)
                .stroke(Palette.tertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3.5]))
                .animation(
                    .easeOut(duration: Self.leadDraw).delay(phase.isRevealed ? Self.leadDelay : 0),
                    value: phase
                )

            Circle()
                .fill(Palette.foreground.opacity(0.88))
                .frame(width: 5, height: 5)
                .offset(x: anchor.x - 2.5, y: anchor.y - 2.5)
                .opacity(phase.isRevealed ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: phase)
        }
    }

    /// The meaning card: an empty ghost silhouette holding its seat at rest;
    /// when the lead's tip arrives at its edge, headword + meanings (and the
    /// shadow) materialize in place — no vertical travel.
    private var meaningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Palette.foreground.opacity(0.72))
                .frame(width: 42, height: 6.5)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Palette.foreground.opacity(0.18))
                .frame(width: 92, height: 5)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Palette.foreground.opacity(0.11))
                .frame(width: 64, height: 5)
        }
        .opacity(phase.isRevealed ? 1 : 0)
        .padding(14)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(phase.isRevealed ? 0.07 : 0), radius: 9, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
        .animation(
            .easeOut(duration: 0.3).delay(phase.isRevealed ? Self.leadDelay + Self.leadDraw : 0),
            value: phase
        )
    }
}

/// A straight horizontal lead in stage coordinates — a Shape so it can be
/// trimmed, drawing itself from its anchor toward the card.
private struct LeadLine: Shape {
    let y: CGFloat
    let x0: CGFloat
    let x1: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y))
        p.addLine(to: CGPoint(x: x1, y: y))
        return p
    }
}

/// The classic arrow pointer, tip at the shape's top-left.
private struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 13
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 16 * s))
        p.addLine(to: CGPoint(x: 4.3 * s, y: 12.6 * s))
        p.addLine(to: CGPoint(x: 7.0 * s, y: 18.8 * s))
        p.addLine(to: CGPoint(x: 9.8 * s, y: 17.5 * s))
        p.addLine(to: CGPoint(x: 7.1 * s, y: 11.4 * s))
        p.addLine(to: CGPoint(x: 12.6 * s, y: 11.4 * s))
        p.closeSubpath()
        return p
    }
}

// (SheetShape and FoldFlap moved to PageParts.swift — shared with Improve's
// empty-state illustration.)

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
                            sourceSize: 16,
                            targetSize: 15,
                            rowSpacing: 14,
                            speakerAlignment: .center,
                            showsMarkers: true
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
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Palette.foreground)
                    + Text("  →  ")
                        .font(.system(size: 17))
                        .foregroundColor(Palette.tertiary)
                    + Text(card.meanings.joined(separator: " / "))
                        .font(.system(size: 17))
                        .foregroundColor(Palette.muted)
                } else {
                    Text(term.text)
                        .font(.system(size: 22, weight: .semibold))
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

/// Right-side history drawer. Rows are self-contained hover cards (no
/// separators): the rounded hover fill matches the row bounds exactly, the
/// modern list treatment (Raycast/Linear-style).
private struct HistoryPanel: View {
    @ObservedObject var model: TranslatePageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 16, weight: .semibold))
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
                    .font(.system(size: 14))
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
            VStack(alignment: .leading, spacing: 3) {
                Text("\(QuickTranslateModel.languageName(entry.detectedLang)) → \(QuickTranslateModel.languageName(entry.translateLang))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                Text(entry.source)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                Text(entry.target)
                    .font(.system(size: 14))
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
