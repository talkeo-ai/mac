import AppKit
import SwiftUI

/// The main window's Listen feature: paste/type text, hear it in the real
/// Talkeo voice with a karaoke word highlight, and a history drawer of past
/// listens — one full-width, always-editable compose pane (same shape and
/// triggers as Translate/Improve: a button and ⌘⏎ commit it) with an
/// ElevenLabs-style player bar docked at the bottom once that text has been
/// played. Lives beside the popover's own Listen card in UI/ — the two
/// surfaces share the playback engine (`TTSAudioPlayer`) and the decorative
/// waveform, not their view code (the popover keeps `ListenPlaybackControls`;
/// the bar here is this page's own).

/// State for the in-app listener. Mirrors the popover's Listen flow (detect
/// language, load + play the real voice, record history) but owns its own
/// state rather than reusing `QuickTranslateModel`'s — this page has no
/// translate/improve modes to coordinate with. Owned by `MainWindowModel` so
/// switching sections doesn't stop playback or lose the source text.
final class ListenPageModel: ObservableObject {
    @Published var sourceText = ""
    @Published private(set) var detectedLang: String = "EN"
    @Published var speechRate: QuickTranslateModel.SpeechRate = .normal
    @Published private(set) var entries: [ListenHistoryEntry] = []
    @Published var historyOpen = false

    private let history: ListenHistoryStore

    init(history: ListenHistoryStore = LocalListenHistoryStore.shared) {
        self.history = history
    }

    /// Commit the current text: detect its language, record it to history,
    /// and load + play the real voice. Mirrors Translate's `translateNow()` /
    /// Improve's `improveNow()` — the pane stays editable throughout; this
    /// only starts playback of what's in it right now.
    func play() {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sourceText = trimmed
        detectedLang = QuickTranslateModel.detectLanguage(trimmed)
        record()
        TTSAudioPlayer.shared.load(sourceText, lang: detectedLang, rate: speechRate.value)
    }

    /// Typing invalidates whatever's loaded — same rule as Improve's
    /// `sourceEdited()`: the playing/loaded audio (and its karaoke ranges)
    /// belonged to the text as it was, so it stops rather than run on under
    /// text that no longer matches it. The player bar disappears along with
    /// it (it only shows for the text that's actually loaded).
    func sourceEdited() {
        TTSAudioPlayer.shared.stop()
    }

    /// Load a history entry straight into the player (no re-typing).
    func select(_ entry: ListenHistoryEntry) {
        sourceText = entry.text
        detectedLang = entry.detectedLang
        TTSAudioPlayer.shared.load(sourceText, lang: detectedLang, rate: speechRate.value)
    }

    /// Programmatic text handoff (captured text routed from the capture
    /// preview): replace the source and stop whatever was playing — nothing
    /// plays until the user asks. Unchanged text is a no-op, so re-capturing
    /// the same text keeps the current playback.
    func replaceSource(_ text: String) {
        guard text != sourceText else { return }
        TTSAudioPlayer.shared.stop()
        sourceText = text
    }

    func refreshHistory() { entries = history.all() }

    func delete(_ entry: ListenHistoryEntry) {
        history.remove(id: entry.id)
        refreshHistory()
    }

    /// Same "✕" affordance as Translate/Improve's source panes.
    func clear() {
        TTSAudioPlayer.shared.stop()
        sourceText = ""
    }

    private func record() {
        history.add(ListenHistoryEntry(id: UUID().uuidString, text: sourceText, detectedLang: detectedLang, timestamp: Date()))
        refreshHistory()
    }
}

/// The in-app listener: one full-width, always-editable source pane with the
/// run bar under it and the docked player bar at the bottom of the page once
/// that exact text has been played — ElevenLabs' generation-player
/// arrangement in this app's own chrome — plus a collapsible history drawer
/// on the right. Same interaction model as Translate/Improve: the pane never
/// locks, and the button / ⌘⏎ is what commits it.
struct ListenPage: View {
    @ObservedObject var model: ListenPageModel
    /// The screen-capture entry point, injected by the window (the TCC-gated
    /// flow lives in the AppDelegate); nil hides the button.
    var onCapture: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            listener
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.historyOpen {
                Divider().overlay(Palette.border)
                ListenHistoryPanel(model: model)
                    .frame(width: 320)
            }
        }
        .onAppear { model.refreshHistory() }
    }

    private var listener: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                PageTitleHeader(
                    title: "Listen",
                    subtitle: "Hear any text out loud with word-by-word highlighting."
                ) {
                    if let onCapture { CaptureButton(action: onCapture) }
                    ListenHistoryToggle(isOpen: model.historyOpen) {
                        model.historyOpen.toggle()
                        // The popover writes to the same store while this page
                        // is mounted — re-read on open so it's never stale.
                        if model.historyOpen { model.refreshHistory() }
                    }
                }

                ListenSourcePane(model: model)
                    .frame(height: 280)

                actionBar

                // While nothing (matching) is loaded, the empty space plays
                // the text→speech illustration; it yields to the player bar
                // the moment a listen actually starts.
                ListenIdleHint(model: model)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 48)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: PageGrid.maxWidth)
            .frame(maxWidth: .infinity)

            // The docked player: OUTSIDE the padded, width-capped column —
            // flush against the page's edges and bottom, squared, spanning
            // everything (only renders once the loaded audio matches the
            // current text; see `ListenPlayerBar.mine`).
            ListenPlayerBar(model: model)
        }
        // ⌘⏎ plays the current text — same shortcut as Translate's
        // force-translate and Improve's rewrite.
        .background(
            Button("") { model.play() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        )
    }

    /// The explicit run bar, mirroring Translate/Improve's CTA exactly:
    /// always the same button, disabled on empty text.
    private var actionBar: some View {
        let hasText = !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ctaText = hasText ? Palette.primaryForeground : Palette.tertiary
        return HStack {
            Spacer()
            Button(action: { model.play() }) {
                HStack(spacing: 7) {
                    Text("Listen")
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
}

/// The docked player: ElevenLabs' bottom bar in this app's chrome — squared,
/// flush against the page's edges (no outer padding, no rounded shell), a
/// hairline on top. What's playing + its metadata on the left, the transport
/// dead-centre (skip/play/skip over a thin seekable progress line flanked by
/// the times), the speed chip on the right. Always mounted; draws nothing
/// until `mine` — this page and the popover share one playback engine, so a
/// listen started elsewhere, or an edit that invalidated this page's own
/// listen, must not show a transport for audio that no longer matches the
/// pane.
private struct ListenPlayerBar: View {
    @ObservedObject var model: ListenPageModel
    @ObservedObject private var player = TTSAudioPlayer.shared

    private var mine: Bool {
        !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && player.currentText == model.sourceText
    }
    private var loading: Bool { mine && player.isLoading }
    private var failed: Bool { mine && player.failed }
    private var hasAudio: Bool { mine && player.hasAudio(model.sourceText) }
    private var playing: Bool { mine && player.isPlaying }
    private var progress: Double { mine ? player.progress : 0 }
    private var duration: Double { mine ? player.duration : 0 }
    private var elapsed: Double { progress * duration }

    var body: some View {
        if mine {
            VStack(spacing: 0) {
                Divider().overlay(Palette.border)

                // Fixed height sized to the transport (46 controls + 8 gap +
                // 14 progress row + clearance) — an intrinsic row height cut
                // the progress line off at the bottom edge.
                ZStack {
                    HStack(alignment: .center) {
                        titleBlock
                        Spacer()
                        speed
                    }
                    .padding(.horizontal, 24)

                    // Centred on the PAGE, not on whatever width the side
                    // blocks leave over.
                    transport
                }
                .frame(height: 96)
            }
            .background(Palette.elevated)
        }
    }

    /// What's playing: the text's first line over its metadata (language ·
    /// rate), the reference bar's title block.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.sourceText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(QuickTranslateModel.languageName(model.detectedLang)) · \(model.speechRate.label)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    /// Skip/play/skip with the progress line + times right beneath.
    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                skipButton(system: "gobackward.5") { seek(by: -5) }
                playButton
                skipButton(system: "goforward.5") { seek(by: 5) }
            }

            HStack(spacing: 10) {
                Text(Self.time(elapsed))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)

                progressTrack
                    .frame(width: 320)

                Text(Self.time(duration))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    /// The thin seekable progress line (the reference's plain track — the
    /// decorative waveform stays the popover transport's own).
    private var progressTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.foreground.opacity(0.12))
                    .frame(height: 3.5)
                Capsule()
                    .fill(Palette.foreground.opacity(0.8))
                    .frame(width: max(3.5, geo.size.width * progress), height: 3.5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hasAudio else { return }
                        player.seek(toFraction: fraction(value.location.x, geo.size.width))
                    }
                    .onEnded { value in
                        guard hasAudio else { return }
                        player.seek(toFraction: fraction(value.location.x, geo.size.width))
                    }
            )
            .handCursor()
        }
        .frame(height: 14)
    }

    private var playButton: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle().fill(Palette.primary).frame(width: 46, height: 46)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "arrow.clockwise" : (playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.primaryForeground)
                        // Optical centering: a filled play triangle reads
                        // slightly left-heavy in a perfect circle.
                        .offset(x: (playing || failed) ? 0 : 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .help(failed ? "Retry" : (playing ? "Pause" : "Play"))
        .handCursor()
    }

    private func skipButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(hasAudio ? Palette.muted : Palette.tertiary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasAudio)
        .handCursor()
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(width, 1))))
    }

    /// A chip that opens a menu — seven speeds wouldn't fit as buttons.
    private var speed: some View {
        Menu {
            ForEach(QuickTranslateModel.SpeechRate.allCases, id: \.self) { rate in
                Button(rate.label) {
                    model.speechRate = rate
                    player.setRate(rate.value)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.speechRate.label)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.surface))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .handCursor()
    }

    private func seek(by delta: Double) {
        guard hasAudio, duration > 0 else { return }
        player.seek(toFraction: max(0, min(1, (elapsed + delta) / duration)))
    }

    private func primaryAction() {
        if failed || !hasAudio {
            player.load(model.sourceText, lang: model.detectedLang, rate: model.speechRate.value)
        } else {
            player.togglePlayPause()
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The Listen source pane: always editable, like Translate's/Improve's — text
/// typed or pasted here is only ever committed to speech by the run bar's
/// button or ⌘⏎. The karaoke word highlight draws on top while it plays.
/// Its own subview so the spoken-word ticks (a few per second) only
/// re-render this pane. Chrome and metrics match the other pages' source
/// panes exactly — the verb pages share one fixed input geometry.
private struct ListenSourcePane: View {
    @ObservedObject var model: ListenPageModel
    @ObservedObject private var spoken = TTSAudioPlayer.shared.spoken

    /// The highlight only applies while the pane's own text is what's
    /// actually loaded — this page and the popover share one playback
    /// engine, so a listen started elsewhere must not paint markers over
    /// unrelated text.
    private var spokenRange: NSRange? {
        TTSAudioPlayer.shared.currentText == model.sourceText ? spoken.range : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: $model.sourceText,
                onUserEdit: { model.sourceEdited() },
                spokenRange: spokenRange
            )
                .padding(.top, 14)
                .padding(.leading, 14)
                .padding(.bottom, 14)
                // Keep typed text clear of the ✕ button in the corner.
                .padding(.trailing, 40)

            if model.sourceText.isEmpty {
                // Sits exactly where the editor's text starts (padding +
                // container inset 2 + line fragment padding 5).
                Text("Type or paste text to listen to…")
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
}


// MARK: - Text→speech hint

/// Gate for the idle illustration: shown exactly when the player bar is NOT
/// (the inverse of `ListenPlayerBar.mine`), so the two swap cleanly the
/// moment a listen starts or an edit invalidates it.
private struct ListenIdleHint: View {
    @ObservedObject var model: ListenPageModel
    @ObservedObject private var player = TTSAudioPlayer.shared

    private var mine: Bool {
        !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && player.currentText == model.sourceText
    }

    var body: some View {
        if !mine {
            ListenFlowHint()
        }
    }
}

/// The idle-state illustration — the same stage furniture as the other
/// pages' hints (grid, mono bracket labels) telling Listen's story as a
/// top-to-bottom pipeline: TEXT WRITES ITSELF (two centred lines of cursive
/// scrawl drawing left to right, pen-style), an arrow draws downward the
/// moment the writing finishes, and the AUDIO GENERATES beneath it — play
/// button plus a waveform whose bars rise left to right like a synthesis
/// pass.
private struct ListenFlowHint: View {
    @State private var step = 0

    var body: some View {
        VStack(spacing: 18) {
            ListenTypeIllustration(step: step)
            Text("Hear it read aloud — your text becomes a voice")
                .font(.system(size: 14))
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
        // The pipeline loop, auto-cancelled with the view: write the line at
        // a pen's pace, a beat, the arrow, the voice, then release.
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            while !Task.isCancelled {
                step = 1
                try? await Task.sleep(nanoseconds: 1_450_000_000)
                step = ListenTypeIllustration.arrowStep
                try? await Task.sleep(nanoseconds: 650_000_000)
                step = ListenTypeIllustration.audioStep
                try? await Task.sleep(nanoseconds: 2_300_000_000)
                step = 0
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

/// The stage: the writing→arrow→audio pipeline, top to bottom, everything
/// centred. `step` drives it: 0 = blank · 1 = the line written ·
/// arrowStep = arrow drawn · audioStep = audio generated.
private struct ListenTypeIllustration: View {
    let step: Int

    static let stage = CGSize(width: 460, height: 232)
    static let arrowStep = 2
    static let audioStep = 3

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid
            cornerLabels
            textBlock
            arrow
            audioRow
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
            Text("[ LISTEN ]").offset(x: 6, y: 6)
            Text("[ TEXT → SPEECH ]").offset(x: Self.stage.width - 132, y: Self.stage.height - 22)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Palette.tertiary.opacity(0.8))
    }

    // MARK: The text writing itself

    /// One centred line of cursive scrawl drawing itself left to right
    /// (trim = the pen's progress), kept quiet — tertiary-ish ink, hairline
    /// stroke. Fade is quick on release so the un-write never plays
    /// backwards visibly.
    private var textBlock: some View {
        CursiveLineShape(loops: 8)
            .trim(from: 0, to: step >= 1 ? 1 : 0)
            .stroke(Palette.foreground.opacity(0.35), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            .frame(width: 208, height: 17)
            .offset(x: (Self.stage.width - 208) / 2, y: 52)
            .animation(.easeInOut(duration: 1.2), value: step)
            .opacity(step >= 1 ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: step)
    }

    // MARK: The arrow — writing done, hand it to the voice

    private var arrow: some View {
        DownArrowShape()
            .trim(from: 0, to: step >= Self.arrowStep ? 1 : 0)
            .stroke(Palette.foreground.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 16, height: 40)
            .offset(x: 222, y: 92)
            .animation(.easeOut(duration: 0.45), value: step)
    }

    // MARK: The audio being generated

    private var audioRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.foreground.opacity(0.88)).frame(width: 26, height: 26)
                PlayGlyph().fill(Palette.surface).frame(width: 8, height: 10).offset(x: 1)
            }

            HStack(alignment: .center, spacing: 2.5) {
                let count = 40
                let heights = waveformHeights(for: "talkeo text to speech", count: count)
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Palette.foreground.opacity(0.72))
                        .frame(width: 3, height: step >= Self.audioStep ? max(3.5, heights[i] * 30) : 3.5)
                        // Bars rise left→right — the voice synthesizing.
                        .animation(.easeOut(duration: 0.3).delay(step >= Self.audioStep ? 0.015 * Double(i) : 0), value: step)
                }
            }
        }
        .opacity(step >= Self.audioStep ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: step)
        .position(x: Self.stage.width / 2, y: 168)
    }
}

/// Stylized cursive handwriting: a looping trochoid — x = Rθ − a·sinθ,
/// y = d·cosθ with a > R, the classic connected "eeee" scrawl. Drawn left to
/// right so a trim writes it like a pen.
private struct CursiveLineShape: Shape {
    var loops: Int = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let total = CGFloat(loops) * 2 * .pi
        let R = rect.width / total
        let d = rect.height / 2 * 0.92
        let samples = loops * 40
        var first = true
        for s in 0...samples {
            let theta = total * CGFloat(s) / CGFloat(samples)
            let x = R * theta - d * 1.35 * sin(theta)
            let y = rect.midY - d * cos(theta)
            if first { p.move(to: CGPoint(x: x + d, y: y)); first = false }
            else { p.addLine(to: CGPoint(x: x + d, y: y)) }
        }
        return p
    }
}

/// Vertical arrow drawn top→bottom (shaft, then head strokes) so a trim
/// reveals it downward.
private struct DownArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midX = rect.midX
        p.move(to: CGPoint(x: midX, y: 0))
        p.addLine(to: CGPoint(x: midX, y: rect.maxY))
        p.move(to: CGPoint(x: midX - 6, y: rect.maxY - 7))
        p.addLine(to: CGPoint(x: midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: midX + 6, y: rect.maxY - 7))
        return p
    }
}
/// Small solid play triangle for the hint's transport button.
private struct PlayGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}

/// Labeled toggle for the history drawer — mirrors `TranslatePage`'s.
private struct ListenHistoryToggle: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Text("History")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isOpen || isHover ? Palette.foreground : Palette.muted)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Capsule().fill(Palette.elevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .help(isOpen ? "Hide history" : "Show history")
    }
}

/// Right-side history drawer — mirrors `TranslatePage`'s `HistoryPanel`.
private struct ListenHistoryPanel: View {
    @ObservedObject var model: ListenPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                Spacer()
                Button(action: { model.historyOpen = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.elevated))
                }
                .buttonStyle(.plain)
                .help("Close history")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            if model.entries.isEmpty {
                Text("Texts you listen to will show up here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.entries) { entry in
                            ListenHistoryRow(
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

/// One history entry; clicking it replays it. Mirrors `TranslatePage`'s
/// `HistoryRow`, minus the source → target line (Listen has no target).
private struct ListenHistoryRow: View {
    let entry: ListenHistoryEntry
    let select: () -> Void
    let delete: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: select) {
            Text(entry.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.foreground)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
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
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .help("Delete")
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

#Preview("Listen page") {
    ListenPage(model: ListenPageModel())
        .frame(width: 900, height: 640)
}
