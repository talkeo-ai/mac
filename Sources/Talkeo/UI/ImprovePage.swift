import AppKit
import SwiftUI

/// The main window's Improve feature: side-by-side original/improved panes
/// (diff-tinted fragments in the original), every correction as a teaching
/// card underneath, and the history drawer of past rewrites — the popover's
/// improve + learn core on the app's roomier canvas. Shares the popover's
/// store, so rewrites made there show up here and vice versa.

/// State for the in-app improver. Mirrors the popover's flow (one-shot JSON
/// call, record history, diff highlights) but is its own model: text is typed
/// rather than captured, and there's no replace-in-place — the app has no
/// selection to write back into. Owned by `MainWindowModel` so switching
/// sections doesn't lose the text.
final class ImprovePageModel: ObservableObject {
    @Published var sourceText = ""
    @Published private(set) var result: ImproveResult?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var entries: [ImproveHistoryEntry] = []
    /// Whether the history drawer (right side) is open.
    @Published var historyOpen = false

    private let client: TransformClient
    private let history: ImproveHistoryStore
    private var task: Task<Void, Never>?
    /// Invalidates in-flight tasks when a newer rewrite supersedes them.
    private var generation = 0

    init(client: TransformClient = TalkeoTransformClient(), history: ImproveHistoryStore = LocalImproveHistoryStore.shared) {
        self.client = client
        self.history = history
    }

    func improveNow() {
        task?.cancel()
        generation += 1
        let gen = generation

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Improve always rewrites English; detection picks the explanation
        // language (the user's own — the other of the EN/ES pair).
        let explainLang = QuickTranslateModel.detectLanguage(text) == "EN" ? "ES" : "EN"
        errorMessage = nil
        result = nil
        isLoading = true

        task = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let result = try await self.client.improve(text: text, targetLang: explainLang)
                guard self.generation == gen else { return }
                self.isLoading = false
                self.result = result
                self.record(source: text, result: result)
            } catch {
                guard let self, self.generation == gen else { return }
                self.isLoading = false
                self.errorMessage = QuickTranslateModel.message(error)
            }
        }
    }

    /// Typing invalidates the last rewrite — its diff belonged to the text as
    /// it was. No re-run here: improve is a heavier one-shot than translate,
    /// so it stays behind the explicit button / ⌘⏎, not a keystroke debounce.
    func sourceEdited() {
        task?.cancel()
        generation += 1
        isLoading = false
        result = nil
        errorMessage = nil
    }

    /// Load a history entry back into the improver — the entry carries the
    /// full changes, so restoring the diff and its cards needs no API call.
    func select(_ entry: ImproveHistoryEntry) {
        task?.cancel()
        generation += 1
        isLoading = false
        errorMessage = nil
        sourceText = entry.source
        result = ImproveResult(improved: entry.improved, changes: entry.changes)
    }

    /// Programmatic text handoff (captured text routed from the capture
    /// preview): replace the source without running. Same invalidation as
    /// typing — the old diff belonged to the old text. Unchanged text is a
    /// no-op, so re-capturing the same text keeps the last result.
    func replaceSource(_ text: String) {
        guard text != sourceText else { return }
        sourceText = text
        sourceEdited()
    }

    func refreshHistory() {
        entries = history.all()
    }

    func delete(_ entry: ImproveHistoryEntry) {
        history.remove(id: entry.id)
        refreshHistory()
    }

    func clear() {
        task?.cancel()
        generation += 1
        sourceText = ""
        result = nil
        isLoading = false
        errorMessage = nil
    }

    /// Ranges of every correction's `original` within `sourceText` — the
    /// popover's walk (in order, whitespace-tolerant). All tinted alike:
    /// there's no paged emphasis here, every card is laid out at once.
    func highlights() -> [(range: NSRange, active: Bool)] {
        guard let result else { return [] }
        let ns = sourceText as NSString
        var out: [(range: NSRange, active: Bool)] = []
        var cursor = 0
        for change in result.changes {
            let found = QuickTranslateModel.flexibleRange(of: change.original, in: ns, from: cursor)
            guard found.location != NSNotFound else { continue }
            out.append((found, true))
            cursor = NSMaxRange(found)
        }
        return out
    }

    /// Same store discipline as the popover: skip "already natural" results —
    /// a "text → same text" row teaches nothing.
    private func record(source: String, result: ImproveResult) {
        guard !result.changes.isEmpty else { return }
        history.add(ImproveHistoryEntry(
            id: UUID().uuidString,
            source: source,
            improved: result.improved.trimmingCharacters(in: .whitespacesAndNewlines),
            changes: result.changes,
            timestamp: Date()
        ))
        refreshHistory()
    }
}

struct ImprovePage: View {
    @ObservedObject var model: ImprovePageModel
    /// The screen-capture entry point, injected by the window (the TCC-gated
    /// flow lives in the AppDelegate); nil hides the button.
    var onCapture: (() -> Void)? = nil

    /// The popover's diff tint (its constant is private to that surface).
    private static let diffColor = NSColor.systemRed.withAlphaComponent(0.32)

    var body: some View {
        HStack(spacing: 0) {
            improver
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Shown/hidden instantly — same call as Translate's drawer.
            if model.historyOpen {
                Divider().overlay(Palette.border)
                ImproveHistoryPanel(model: model)
                    .frame(width: 320)
            }
        }
        .onAppear { model.refreshHistory() }
    }

    private var improver: some View {
        VStack(spacing: 16) {
            PageTitleHeader(
                title: "Improve",
                subtitle: "Rewrite your English to sound natural — see what changed and why."
            ) {
                if let onCapture { CaptureButton(action: onCapture) }
                HistoryToggle(isOpen: model.historyOpen) {
                    model.historyOpen.toggle()
                    // The popover writes to the same store while this page is
                    // mounted — re-read on open so the drawer is never stale.
                    if model.historyOpen { model.refreshHistory() }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                sourcePane
                outputPane
            }
            .frame(height: 280)

            actionBar

            changesArea
        }
        .padding(.horizontal, 48)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: PageGrid.maxWidth)
        .frame(maxWidth: .infinity)
        // ⌘⏎ runs the rewrite (same shortcut as Translate's force-translate).
        .background(
            Button("") { model.improveNow() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        )
    }

    private var sourcePane: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: $model.sourceText,
                onUserEdit: { model.sourceEdited() },
                markers: model.highlights(),
                markerColor: Self.diffColor
            )
                .padding(.top, 14)
                .padding(.leading, 14)
                .padding(.bottom, 14)
                // Keep typed text clear of the ✕ button in the corner.
                .padding(.trailing, 40)

            if model.sourceText.isEmpty {
                // Sits exactly where the editor's text starts (padding +
                // container inset 2 + line fragment padding 5).
                Text("Type or paste English to improve…")
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
                    Button("Try again") { model.improveNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().stroke(Palette.border, lineWidth: 1))
                }
                .padding(.top, 16)
                .padding(.horizontal, 21)
            } else if let result = model.result {
                // Read-only native text view: real selection/copy behavior.
                PlainTextEditor(
                    text: .constant(result.improved),
                    isEditable: false
                )
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .padding(.trailing, 14)
                    // Keep the last line clear of the speaker/copy buttons.
                    .padding(.bottom, 36)
            } else if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 18)
                    .padding(.leading, 21)
            } else {
                // Mirrors the source placeholder's exact text position.
                Text("Improved text")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 15)
                    .padding(.leading, 21)
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
            if let result = model.result {
                HStack(spacing: 2) {
                    // Improve is English-in, English-out — safe to read aloud.
                    SpeakerButton(english: result.improved)
                    CopyButton(text: result.improved, help: "Copy improved text")
                }
                .padding(10)
            }
        }
    }

    /// The explicit run bar. Improve stays behind a deliberate action (button
    /// or ⌘⏎), not a keystroke debounce — same CTA language as the popover's
    /// compose bar, with the shortcut as the badge.
    private var actionBar: some View {
        let hasText = !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Disabled reads muted, not faded: tertiary label on the secondary
        // surface, matching how native controls gray out.
        let ctaText = hasText ? Palette.primaryForeground : Palette.tertiary
        return HStack {
            Spacer()
            Button(action: { model.improveNow() }) {
                HStack(spacing: 7) {
                    Text("Improve")
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

    /// Under the run bar: every correction as its own teaching card (the app
    /// has the room the popover's one-at-a-time pager doesn't), or the trust-
    /// critical "already natural" note when the backend returned none. While
    /// idle, the empty space plays the draft→natural illustration instead.
    @ViewBuilder
    private var changesArea: some View {
        if let result = model.result {
            if result.changes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.green.opacity(0.8))
                    Text("Already natural — no changes needed.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                Spacer(minLength: 0)
            } else {
                // Capped to the same reading measure as Translate's explain
                // card and centered — full grid width stretched each card's
                // lines a whole screen wide.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(result.changes) { change in
                            ImproveChangeCard(change: change)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }
        } else if !model.isLoading && model.errorMessage == nil {
            ImproveFlowHint()
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            Spacer(minLength: 0)
        } else {
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Draft→natural hint

/// The idle-state illustration under the panes — the same wireframe grammar
/// as Translate's pick-a-word hint (boxes, 1px borders, skeleton pills, mono
/// bracket furniture) telling Improve's own story instead of a gesture: a
/// TRANSFORMATION. The draft sheet carries the real diff tint on its rough
/// fragments; a reading pass sweeps down it; then the natural rewrite
/// materializes on the ghost sheet across the arrow — the change cards'
/// "original → fixed" motif at illustration scale, with the fixed fragments
/// inked and, deliberately, a different length: rewrites change the words.
private struct ImproveFlowHint: View {
    @State private var phase = ImproveHintPhase.rest

    var body: some View {
        VStack(spacing: 18) {
            ImproveFlowIllustration(phase: phase)
            Text("Every fix explained — see what changed and why")
                .font(.system(size: 14))
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
        // The process loop, auto-cancelled with the view: read the draft,
        // reveal the rewrite, hold, release.
        .task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                phase = .scan
                try? await Task.sleep(nanoseconds: 1_150_000_000)
                phase = .reveal
                try? await Task.sleep(nanoseconds: 2_900_000_000)
                phase = .rest
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

/// The transformation's phases: at rest (marked draft, ghost rewrite),
/// the reading pass, the rewrite revealed.
private enum ImproveHintPhase {
    case rest, scan, reveal
    var isReveal: Bool { self == .reveal }
}

/// One skeleton row fragment: position plus whether it's a diff target, and
/// its rewritten width on the natural sheet.
private struct ImproveHintRow {
    let x: CGFloat, y: CGFloat, w: CGFloat
    var h: CGFloat = 5
    var marked = false
    var fixedW: CGFloat? = nil
}

/// The stage: draft sheet → arrow → natural sheet, over the grid furniture.
/// Both sheets share one row table so the "after" is visibly the same text.
private struct ImproveFlowIllustration: View {
    let phase: ImproveHintPhase

    static let stage = CGSize(width: 460, height: 232)
    static let leftOrigin = CGPoint(x: 44, y: 26)
    static let rightOrigin = CGPoint(x: 276, y: 26)
    static let sheet = CGSize(width: 140, height: 180)

    /// The real source-pane diff tint, at illustration quietness.
    static let diffTint = Color(nsColor: .systemRed).opacity(0.19)

    static let rows: [ImproveHintRow] = [
        ImproveHintRow(x: 16, y: 22, w: 72, h: 7),              // heading
        ImproveHintRow(x: 16, y: 42, w: 46), ImproveHintRow(x: 66, y: 42, w: 58, marked: true, fixedW: 44),
        ImproveHintRow(x: 16, y: 54, w: 98),
        ImproveHintRow(x: 16, y: 66, w: 30), ImproveHintRow(x: 50, y: 66, w: 62),
        ImproveHintRow(x: 16, y: 84, w: 58), ImproveHintRow(x: 78, y: 84, w: 34),
        ImproveHintRow(x: 16, y: 96, w: 88),
        ImproveHintRow(x: 16, y: 108, w: 40), ImproveHintRow(x: 60, y: 108, w: 48, marked: true, fixedW: 60),
        ImproveHintRow(x: 16, y: 120, w: 76),
        ImproveHintRow(x: 16, y: 150, w: 14, h: 4), ImproveHintRow(x: 34, y: 150, w: 14, h: 4), ImproveHintRow(x: 52, y: 150, w: 14, h: 4),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid
            cornerLabels
            draftSheet
                .offset(x: Self.leftOrigin.x, y: Self.leftOrigin.y)
            arrow
            naturalSheet
                .offset(x: Self.rightOrigin.x, y: Self.rightOrigin.y)
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

    private var cornerLabels: some View {
        ZStack(alignment: .topLeading) {
            Text("[ IMPROVE ]").offset(x: 6, y: 6)
            Text("[ DRAFT → NATURAL ]").offset(x: Self.stage.width - 148, y: Self.stage.height - 22)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Palette.tertiary.opacity(0.8))
    }

    // MARK: The draft — diff marks on its rough fragments

    private var draftSheet: some View {
        ZStack(alignment: .topLeading) {
            SheetShape().fill(Palette.surface).shadow(color: .black.opacity(0.07), radius: 10, y: 4)
            SheetShape().stroke(Palette.border, lineWidth: 1)
            FoldFlap().fill(Palette.elevated)
            FoldFlap().stroke(Palette.border, lineWidth: 1)

            ForEach(Self.rows.indices, id: \.self) { i in
                let r = Self.rows[i]
                ZStack(alignment: .topLeading) {
                    if r.marked {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Self.diffTint)
                            .frame(width: r.w + 6, height: r.h + 7)
                            .offset(x: r.x - 3, y: r.y - 3.5)
                    }
                    RoundedRectangle(cornerRadius: r.h / 2, style: .continuous)
                        .fill(Palette.foreground.opacity(r.marked ? 0.34 : (r.h == 7 ? 0.13 : 0.07)))
                        .frame(width: r.w, height: r.h)
                        .offset(x: r.x, y: r.y)
                }
            }

            scanBand
        }
        .frame(width: Self.sheet.width, height: Self.sheet.height)
        .clipShape(SheetShape())
    }

    /// The reading pass: a soft band travelling down the draft during .scan,
    /// invisible (and silently resetting) otherwise.
    private var scanBand: some View {
        let travel = Self.sheet.height - 30
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Palette.foreground.opacity(0.06))
            .frame(width: Self.sheet.width - 12, height: 22)
            .offset(x: 6, y: 4 + (phase == .rest ? 0 : travel))
            .animation(.easeInOut(duration: 0.95), value: phase)
            .opacity(phase == .scan ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: phase)
    }

    // MARK: The arrow — the change cards' "original → fixed", drawn

    private var arrow: some View {
        ArrowShape()
            .stroke(
                phase.isReveal ? Palette.foreground.opacity(0.75) : Palette.tertiary.opacity(0.8),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 48, height: 14)
            .offset(x: 206, y: 109)
            .animation(.easeOut(duration: 0.3).delay(phase.isReveal ? 0.05 : 0), value: phase)
    }

    // MARK: The natural rewrite — a ghost until the pass completes

    private var naturalSheet: some View {
        ZStack(alignment: .topLeading) {
            // Filled even while ghosted — a blank page waiting to be written,
            // rather than a bare outline; the shadow still waits for reveal.
            SheetShape()
                .fill(Palette.surface)
                .shadow(color: .black.opacity(phase.isReveal ? 0.07 : 0), radius: 10, y: 4)
            SheetShape().stroke(Palette.border, lineWidth: 1)
            FoldFlap().fill(Palette.elevated).opacity(phase.isReveal ? 1 : 0)
            FoldFlap().stroke(Palette.border, lineWidth: 1).opacity(phase.isReveal ? 1 : 0)

            ForEach(Self.rows.indices, id: \.self) { i in
                let r = Self.rows[i]
                RoundedRectangle(cornerRadius: r.h / 2, style: .continuous)
                    .fill(Palette.foreground.opacity(r.marked ? 0.7 : (r.h == 7 ? 0.13 : 0.07)))
                    .frame(width: r.fixedW ?? r.w, height: r.h)
                    .offset(x: r.x, y: r.y)
                    .opacity(phase.isReveal ? 1 : 0)
                    // Rows cascade in top→bottom — the rewrite "writing
                    // itself" onto the clean sheet.
                    .animation(.easeOut(duration: 0.25).delay(phase.isReveal ? 0.04 * Double(i) : 0), value: phase)
            }
        }
        .animation(.easeOut(duration: 0.3), value: phase)
        .frame(width: Self.sheet.width, height: Self.sheet.height)
    }
}

/// Horizontal arrow: shaft + chevron head — the change card's "→" as a shape.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midY = rect.midY
        p.move(to: CGPoint(x: 0, y: midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: midY))
        p.move(to: CGPoint(x: rect.maxX - 7, y: midY - 6))
        p.addLine(to: CGPoint(x: rect.maxX, y: midY))
        p.addLine(to: CGPoint(x: rect.maxX - 7, y: midY + 6))
        return p
    }
}

/// One correction as a teaching card: `original → fixed`, the why, and the
/// examples when the backend sent them — the popover's changeCard on the
/// app's canvas (no pager/dismiss; every card is laid out at once).
private struct ImproveChangeCard: View {
    let change: ImproveResult.Change

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text(change.original)
                .font(.system(size: 16))
                .strikethrough(color: Palette.tertiary)
                .foregroundColor(Palette.muted)
             + Text("  →  ")
                .font(.system(size: 16))
                .foregroundColor(Palette.tertiary)
             + Text(change.fixed)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Palette.foreground))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !change.why.isEmpty {
                Text(change.why)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let examples = change.examples, !examples.isEmpty {
                ExplainExamplesList(
                    examples: examples,
                    sourceSize: 15,
                    targetSize: 14,
                    rowSpacing: 10,
                    speakerAlignment: .center,
                    showsMarkers: true
                ) { english in
                    SpeakerButton(english: english)
                }
                .padding(.top, 6)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.elevated)
        )
    }
}

/// Right-side history drawer of past rewrites. Same self-contained hover-card
/// rows as Translate's drawer.
private struct ImproveHistoryPanel: View {
    @ObservedObject var model: ImprovePageModel

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
                Text("Texts you improve will show up here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.entries) { entry in
                            ImproveHistoryRow(
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

/// One past rewrite; clicking it loads source + diff + cards back (no API
/// call — the entry carries the full changes).
private struct ImproveHistoryRow: View {
    let entry: ImproveHistoryEntry
    let select: () -> Void
    let delete: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.changes.count == 1 ? "1 correction" : "\(entry.changes.count) corrections")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                Text(entry.source)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                Text(entry.improved)
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

// MARK: - Xcode Preview

#Preview("Improve page") {
    ImprovePage(model: ImprovePageModel())
        .frame(width: 980, height: 640)
        .background(Palette.surface)
}
