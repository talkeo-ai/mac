import AppKit
import SwiftUI

/// The main window's Listen feature: paste/type text, hear it in the real
/// Talkeo voice with a karaoke word highlight, and a history drawer of past
/// listens — the same shape as `TranslatePage`, adapted for playback instead
/// of a second output pane. Lives beside the popover's own Listen card in
/// UI/ — the two surfaces share the playback engine (`TTSAudioPlayer`) and
/// the transport view (`ListenPlaybackControls`), not the rest of their view
/// code. Picking is Listen's own (a single `selectedRange`, not the shared
/// multi-term `ExplainSession` Translate/Improve use) — Listen only ever
/// jumps a playhead, it never explains a term.

/// State for the in-app listener. Mirrors the popover's Listen flow (detect
/// language, load + play the real voice, record history, tap-a-word-to-jump)
/// but owns its own compose/playback split rather than reusing
/// `QuickTranslateModel`'s — this page has no translate/improve modes to
/// coordinate with. Owned by `MainWindowModel` so switching sections doesn't
/// stop playback or lose the compose text.
final class ListenPageModel: ObservableObject {
    @Published var sourceText = ""
    @Published private(set) var detectedLang: String = "EN"
    /// True while showing the empty, editable compose box; false once a text
    /// is loaded/playing (read-only, tap-to-jump). Same split as the popover's
    /// `listenComposing`, and for the same reason: the box's meaning (typing
    /// vs. tapping a word to seek) genuinely changes between the two states.
    @Published var composing: Bool = true
    @Published var speechRate: QuickTranslateModel.SpeechRate = .normal
    @Published private(set) var entries: [ListenHistoryEntry] = []
    @Published var historyOpen = false
    /// The single word/phrase currently picked, if any (mirrors the popover):
    /// tapping a different one replaces it, tapping the same one clears it.
    /// Shown as a highlight on the waveform, not a separate row — one player.
    @Published var selectedRange: NSRange?

    private let history: ListenHistoryStore

    init(history: ListenHistoryStore = LocalListenHistoryStore.shared) {
        self.history = history
    }

    /// Commit the compose box: detect the language, record it to history, and
    /// load + play the real voice. Mirrors the popover's `listen(_:)`.
    func play(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedRange = nil
        TTSAudioPlayer.shared.setPlaybackWindow(nil) // stale window from a previous text doesn't carry over
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
        selectedRange = nil
        sourceText = ""
        composing = true
    }

    /// Replay a history entry straight into the player (no re-typing).
    func select(_ entry: ListenHistoryEntry) {
        selectedRange = nil
        TTSAudioPlayer.shared.setPlaybackWindow(nil)
        sourceText = entry.text
        detectedLang = entry.detectedLang
        composing = false
        TTSAudioPlayer.shared.load(sourceText, lang: detectedLang, rate: speechRate.value)
    }

    /// The user tapped a word/phrase: pick it and play just that part, like a
    /// video editor's in/out selection — reaching its end rewinds to its
    /// start instead of continuing into the rest of the clip. Tapping the
    /// exact same span again clears the pick and returns to the whole clip.
    func pick(term: String, range: NSRange) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let current = selectedRange, NSEqualRanges(current, range) {
            clearSelection()
            return
        }
        selectedRange = range
        playSelection(range)
    }

    /// Return to playing the whole clip, un-confined.
    func clearSelection() {
        selectedRange = nil
        TTSAudioPlayer.shared.setPlaybackWindow(nil)
    }

    /// Confine playback to `range` and start playing it from its start
    /// (loading the clip first if it isn't ready yet).
    private func playSelection(_ range: NSRange) {
        let length = (sourceText as NSString).length
        guard length > 0 else { return }
        let start = Double(range.location) / Double(length)
        let end = Double(NSMaxRange(range)) / Double(length)
        guard end > start else { return }
        let player = TTSAudioPlayer.shared
        player.setPlaybackWindow(start...end)
        if player.hasAudio(sourceText) {
            player.seek(toFraction: start)
            player.resume()
        } else {
            player.load(sourceText, lang: detectedLang, rate: speechRate.value, fromFraction: start)
        }
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

/// The in-app listener: a persistent card that mutates between an empty
/// compose box and the loaded playback view (mirrors the popover's Listen
/// card, at home in the app), plus a collapsible history drawer on the right
/// — the same shape as `TranslatePage`'s.
struct ListenPage: View {
    @ObservedObject var model: ListenPageModel

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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if !model.composing {
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
                Spacer()
                ListenHistoryToggle(isOpen: model.historyOpen) { model.historyOpen.toggle() }
            }

            if model.composing {
                composeBox
            } else {
                playbackArea
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Compose

    private var composeBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                PlainTextEditor(
                    text: $model.sourceText,
                    onCommit: { model.play(model.sourceText) }
                )
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)

                if model.sourceText.isEmpty {
                    Text("Type or paste text to listen to…")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 16)
                        .padding(.leading, 21)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 160)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            )

            HStack {
                Spacer()
                let hasText = !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let ctaText = hasText ? Palette.primaryForeground : Palette.tertiary
                Button(action: { model.play(model.sourceText) }) {
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
    }

    // MARK: Playback

    private var playbackArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            ListenPlaybackPane(
                text: model.sourceText,
                selectionOutline: model.selectedRange,
                onPick: { model.pick(term: $0, range: $1) }
            )
                .frame(height: 160)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                )

            ListenPlaybackControls(
                text: model.sourceText,
                detectedLang: model.detectedLang,
                speechRate: $model.speechRate,
                selectedRange: model.selectedRange
            )

            if model.selectedRange == nil {
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 10, weight: .medium))
                    Text("Tap a word or phrase to play just that part")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text("Playing just this part")
                        .font(.system(size: 11))
                    Button(action: model.clearSelection) {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10, weight: .medium))
                            Text("Clear")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

/// The Listen text, in its own subview so it can observe the spoken word (a
/// few updates per second) and highlight it karaoke-style without
/// re-rendering the whole page on every progress tick. Tapping a word jumps
/// the playhead there.
private struct ListenPlaybackPane: View {
    let text: String
    let selectionOutline: NSRange?
    let onPick: (String, NSRange) -> Void
    @ObservedObject private var spoken = TTSAudioPlayer.shared.spoken

    var body: some View {
        PlainTextEditor(
            text: .constant(text),
            isEditable: false,
            onWordSelect: onPick,
            spokenRange: spoken.range,
            selectionOutline: selectionOutline,
            picksOnPlainClick: true
        )
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
