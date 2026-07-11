import AppKit
import SwiftUI

/// The main window's Listen feature: paste/type text, hear it in the real
/// Talkeo voice with a karaoke word highlight, and a history drawer of past
/// listens — one full-width compose slot with an ElevenLabs-style player bar
/// docked at the bottom once a text is loaded. Lives beside the popover's own
/// Listen card in UI/ — the two surfaces share the playback engine
/// (`TTSAudioPlayer`) and the decorative waveform, not their view code (the
/// popover keeps `ListenPlaybackControls`; the bar here is this page's own).
/// Read-only display — no picking or selection of any kind.

/// State for the in-app listener. Mirrors the popover's Listen flow (detect
/// language, load + play the real voice, record history) but owns its own
/// compose/playback split rather than reusing `QuickTranslateModel`'s — this
/// page has no translate/improve modes to coordinate with. Owned by
/// `MainWindowModel` so switching sections doesn't stop playback or lose the
/// compose text.
final class ListenPageModel: ObservableObject {
    @Published var sourceText = ""
    @Published private(set) var detectedLang: String = "EN"
    /// True while showing the empty, editable compose box; false once a text
    /// is loaded/playing (read-only). Same split as the popover's
    /// `listenComposing`, and for the same reason: the box's meaning changes
    /// between the two states.
    @Published var composing: Bool = true
    @Published var speechRate: QuickTranslateModel.SpeechRate = .normal
    @Published private(set) var entries: [ListenHistoryEntry] = []
    @Published var historyOpen = false

    private let history: ListenHistoryStore

    init(history: ListenHistoryStore = LocalListenHistoryStore.shared) {
        self.history = history
    }

    /// Commit the compose box: detect the language, record it to history, and
    /// load + play the real voice. Mirrors the popover's `listen(_:)`.
    func play(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sourceText = trimmed
        detectedLang = QuickTranslateModel.detectLanguage(trimmed)
        composing = false
        record()
        TTSAudioPlayer.shared.load(sourceText, lang: detectedLang, rate: speechRate.value)
    }

    /// Back to an empty, editable compose box. Mirrors the popover's
    /// `showListenHistory()` — stopping playback so nothing keeps running
    /// silently under the box the user is about to type into.
    func newListen() {
        TTSAudioPlayer.shared.stop()
        sourceText = ""
        composing = true
    }

    /// Replay a history entry straight into the player (no re-typing).
    func select(_ entry: ListenHistoryEntry) {
        sourceText = entry.text
        detectedLang = entry.detectedLang
        composing = false
        TTSAudioPlayer.shared.load(sourceText, lang: detectedLang, rate: speechRate.value)
    }

    /// Programmatic text handoff (captured text routed from the capture
    /// preview): back to the editable compose box with the new text loaded —
    /// playback of the old text stops; nothing plays until the user asks.
    /// Unchanged text is a no-op, so re-capturing the same text keeps the
    /// loaded playback view.
    func replaceSource(_ text: String) {
        guard text != sourceText else { return }
        if !composing { TTSAudioPlayer.shared.stop() }
        sourceText = text
        composing = true
    }

    func refreshHistory() { entries = history.all() }

    func delete(_ entry: ListenHistoryEntry) {
        history.remove(id: entry.id)
        refreshHistory()
    }

    private func record() {
        history.add(ListenHistoryEntry(id: UUID().uuidString, text: sourceText, detectedLang: detectedLang, timestamp: Date()))
        refreshHistory()
    }
}

/// The in-app listener: one full-width source slot (compose, then the karaoke
/// highlight once loaded) with the run bar under it and the docked player bar
/// at the bottom of the page once a text is loaded — ElevenLabs'
/// generation-player arrangement in this app's own chrome — plus a
/// collapsible history drawer on the right.
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
                .frame(height: 240)

            actionBar

            Spacer(minLength: 0)

            if !model.composing {
                ListenPlayerBar(model: model)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: PageGrid.maxWidth)
        .frame(maxWidth: .infinity)
    }

    /// Fixed-height run bar under the grid, mirroring Improve's: the Listen
    /// CTA while composing, New (back to an empty compose) once loaded.
    private var actionBar: some View {
        HStack {
            Spacer()
            if model.composing {
                listenCTA
            } else {
                Button(action: model.newListen) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("New")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Palette.elevated))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var listenCTA: some View {
        let hasText = !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ctaText = hasText ? Palette.primaryForeground : Palette.tertiary
        return Button(action: { model.play(model.sourceText) }) {
            HStack(spacing: 6) {
                Text("Listen")
                    .font(.system(size: 13, weight: .semibold))
                Text("⏎")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ctaText.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ctaText.opacity(0.18)))
            }
            .foregroundStyle(ctaText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hasText ? Palette.primary : Palette.elevated))
        }
        .buttonStyle(.plain)
        .disabled(!hasText)
    }
}

/// The docked player: one horizontal bar at the bottom of the page —
/// ElevenLabs' generation player in this app's chrome. Skip/play/skip on the
/// left, the seekable waveform stretched across the middle flanked by the
/// time labels, the speed chip on the right. Same engine and decorative
/// waveform as the popover's transport (`ListenPlaybackControls`); only the
/// arrangement is this page's own.
private struct ListenPlayerBar: View {
    @ObservedObject var model: ListenPageModel
    @ObservedObject private var player = TTSAudioPlayer.shared

    private var mine: Bool { player.currentText == model.sourceText }
    private var loading: Bool { mine && player.isLoading }
    private var failed: Bool { mine && player.failed }
    private var hasAudio: Bool { player.hasAudio(model.sourceText) }
    private var playing: Bool { mine && player.isPlaying }
    private var progress: Double { mine ? player.progress : 0 }
    private var duration: Double { mine ? player.duration : 0 }
    private var elapsed: Double { progress * duration }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                skipButton(system: "gobackward.5") { seek(by: -5) }
                playButton
                skipButton(system: "goforward.5") { seek(by: 5) }
            }

            Text(Self.time(elapsed))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiary)

            waveform

            Text(Self.time(duration))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiary)

            speed
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
    }

    private var playButton: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle().fill(Palette.primary).frame(width: 40, height: 40)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "arrow.clockwise" : (playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: 15, weight: .semibold))
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hasAudio ? Palette.muted : Palette.tertiary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasAudio)
        .handCursor()
    }

    /// The seekable decorative waveform, stretched across the bar. Unplayed
    /// bars use the border tone — the elevated tone of the pane variant would
    /// vanish against this bar's own elevated fill.
    private var waveform: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 2
            let count = max(12, Int(geo.size.width / (barWidth + spacing)))
            let heights = waveformHeights(for: model.sourceText, count: count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let played = Double(i) / Double(max(count - 1, 1)) <= progress
                    Capsule()
                        .fill(played ? Palette.foreground : Palette.border)
                        .frame(width: barWidth, height: max(3, heights[i] * 28))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hasAudio else { return }
                        player.seek(toFraction: fraction(value.location.x, geo.size.width))
                    }
                    .onEnded { value in
                        let frac = fraction(value.location.x, geo.size.width)
                        if hasAudio {
                            player.seek(toFraction: frac)
                        } else if !loading {
                            player.load(model.sourceText, lang: model.detectedLang, rate: model.speechRate.value, fromFraction: frac)
                        }
                    }
            )
            .handCursor()
        }
        .frame(height: 28)
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
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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

/// The Listen source slot: the editable compose editor while composing, the
/// same text read-only with the karaoke word highlight once loaded. Its own
/// subview so the spoken-word ticks (a few per second) only re-render this
/// pane. Chrome and metrics match the other pages' source panes exactly —
/// the verb pages share one fixed input geometry.
private struct ListenSourcePane: View {
    @ObservedObject var model: ListenPageModel
    @ObservedObject private var spoken = TTSAudioPlayer.shared.spoken

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: $model.sourceText,
                isEditable: model.composing,
                spokenRange: model.composing ? nil : spoken.range,
                onCommit: { model.play(model.sourceText) }
            )
                .padding(.top, 14)
                .padding(.leading, 14)
                .padding(.bottom, 14)
                // Keep typed text clear of the ✕ button in the corner — and
                // wrapping identical between compose and playback.
                .padding(.trailing, 40)

            if model.composing && model.sourceText.isEmpty {
                // Sits exactly where the editor's text starts (padding +
                // container inset 2 + line fragment padding 5).
                Text("Type or paste text to listen to…")
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
            if model.composing && !model.sourceText.isEmpty {
                PaneIconButton(system: "xmark", help: "Clear") { model.newListen() }
                    .padding(10)
            }
        }
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

/// Right-side history drawer — mirrors `TranslatePage`'s `HistoryPanel`.
private struct ListenHistoryPanel: View {
    @ObservedObject var model: ListenPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 15, weight: .semibold))
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
                    .font(.system(size: 13))
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
                .font(.system(size: 13, weight: .medium))
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
