import SwiftUI

/// Listen's playback transport — shared by the popover and the app page (the
/// "aura" Joaquin pointed at: ElevenLabs' generation player). Monochrome only
/// (no `Color.accentColor`, matching the rest of the app): a waveform with a
/// played/unplayed contrast, a big central play/pause, ±5s skip either side,
/// a trim toggle, and a speed menu. Time labels flank the waveform.
///
/// There's no real amplitude data from the TTS endpoint, so the waveform is
/// decorative — a stable shape generated from the text itself (see
/// `waveformHeights`), not a true analysis of the audio.
struct ListenPlaybackControls: View {
    let text: String
    let detectedLang: String
    @Binding var speechRate: QuickTranslateModel.SpeechRate
    /// The trimmed region of the clip, if trim mode is on (fractions 0...1;
    /// `nil` = off). This view is the single place that syncs the value onto
    /// `TTSAudioPlayer`'s playback window — callers only ever read/write their
    /// own copy of this binding.
    @Binding var trimRange: ClosedRange<Double>?
    @ObservedObject private var player = TTSAudioPlayer.shared

    private var mine: Bool { player.currentText == text }
    private var loading: Bool { mine && player.isLoading }
    private var failed: Bool { mine && player.failed }
    private var hasAudio: Bool { player.hasAudio(text) }
    private var playing: Bool { mine && player.isPlaying }
    private var progress: Double { mine ? player.progress : 0 }
    private var duration: Double { mine ? player.duration : 0 }
    private var elapsed: Double { progress * duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(Self.time(elapsed))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
                waveform
                Text(Self.time(duration))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
            }

            ZStack {
                HStack(spacing: 20) {
                    skipButton(system: "gobackward.5") { seek(by: -5) }
                    primary
                    skipButton(system: "goforward.5") { seek(by: 5) }
                }
                HStack {
                    trimToggle
                    Spacer()
                    speed
                }
            }

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading the voice…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
            } else if failed {
                Text("Couldn't load the voice — tap ↻ to retry.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .onChange(of: trimRange) { newValue in
            player.setPlaybackWindow(newValue)
            if let range = newValue, hasAudio {
                let clamped = max(range.lowerBound, min(range.upperBound, player.progress))
                if clamped != player.progress { player.seek(toFraction: clamped) }
            }
        }
    }

    // MARK: Waveform

    private var waveform: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 2
            let count = max(12, Int(geo.size.width / (barWidth + spacing)))
            let heights = waveformHeights(for: text, count: count)
            let gap = minGap(for: geo.size.width)
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let frac = Double(i) / Double(max(count - 1, 1))
                        Capsule()
                            .fill(barColor(at: frac))
                            .frame(width: barWidth, height: max(3, heights[i] * 26))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                // Draggable in/out handles — video-editor-style trim points,
                // shown only while trim mode is on. Added after (on top of)
                // the bars in this ZStack so they win hit-testing for their
                // own small area over the whole-waveform scrub gesture below
                // (a descendant's own gesture takes priority over an
                // ancestor's, no `.highPriorityGesture` needed).
                if let range = trimRange {
                    TrimHandle(edge: .start, trimRange: $trimRange, width: geo.size.width, minGap: gap)
                        .offset(x: CGFloat(range.lowerBound) * geo.size.width - TrimHandle.hitWidth / 2)
                    TrimHandle(edge: .end, trimRange: $trimRange, width: geo.size.width, minGap: gap)
                        .offset(x: CGFloat(range.upperBound) * geo.size.width - TrimHandle.hitWidth / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hasAudio else { return }
                        player.seek(toFraction: clampedFraction(value.location.x, geo.size.width))
                    }
                    .onEnded { value in
                        let frac = clampedFraction(value.location.x, geo.size.width)
                        if hasAudio {
                            player.seek(toFraction: frac)
                        } else if !loading {
                            player.load(text, lang: detectedLang, rate: speechRate.value, fromFraction: frac)
                        }
                    }
            )
            .handCursor()
        }
        .frame(height: 30)
    }

    /// A bar's color: inside the trim range it reads bright (dimmed only by
    /// playback), outside it's pushed further back so the trimmed span reads
    /// as the active region, video-editor style. With trim off, just the
    /// ordinary played/unplayed contrast.
    private func barColor(at fraction: Double) -> Color {
        let played = fraction <= progress
        guard let range = trimRange else { return played ? Palette.foreground : Palette.elevated }
        let inRange = fraction >= range.lowerBound && fraction <= range.upperBound
        if inRange {
            return played ? Palette.foreground : Palette.foreground.opacity(0.55)
        }
        return Palette.elevated.opacity(0.5)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(width, 1))))
    }

    /// A drag position as a fraction, kept inside the trim range (if any) —
    /// while it's active, scrubbing can't escape it either.
    private func clampedFraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        let raw = fraction(x, width)
        guard let range = trimRange else { return raw }
        return max(range.lowerBound, min(range.upperBound, raw))
    }

    /// Minimum gap between the two handles, sized from the waveform's actual
    /// rendered width (not a fixed fraction) — a constant fraction would
    /// correspond to a different pixel width in the popover vs. the resizable
    /// app window, and if it ever dropped below the handles' own hit-target
    /// width their hit-zones would overlap near a tight trim, making the
    /// "underneath" handle ungrabbable.
    private func minGap(for width: CGFloat) -> Double {
        Double(TrimHandle.hitWidth * 1.5) / Double(max(width, 1))
    }

    // MARK: Controls

    private var primary: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle().fill(Palette.primary).frame(width: 52, height: 52)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "arrow.clockwise" : (playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: 18, weight: .semibold))
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hasAudio ? Palette.muted : Palette.tertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasAudio)
        .handCursor()
    }

    /// Enable/disable trim mode. Turning it on arms the full clip as the
    /// initial range (both handles at the extremes, matching QuickTime
    /// Player's ⌘T trim tool) — the user narrows it by dragging the handles.
    /// This deliberately changes what happens when the clip finishes playing
    /// while it's on: instead of freezing at the end, `TTSAudioPlayer` loops
    /// back to the trim's start and pauses there — that's what makes "trim
    /// mode is on" mean something even before either handle has moved.
    private var trimToggle: some View {
        Button(action: { trimRange = trimRange == nil ? 0...1 : nil }) {
            Image(systemName: "selection.pin.in.out")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(trimRange != nil ? Palette.primaryForeground : Palette.muted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(trimRange != nil ? Palette.primary : Palette.elevated))
        }
        .buttonStyle(.plain)
        .help("Select part of the clip to loop")
        .handCursor()
    }

    /// A chip that opens a menu — seven speeds wouldn't fit as buttons side
    /// by side.
    private var speed: some View {
        Menu {
            ForEach(QuickTranslateModel.SpeechRate.allCases, id: \.self) { rate in
                Button(rate.label) {
                    speechRate = rate
                    player.setRate(rate.value)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(speechRate.label)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.elevated.opacity(0.6)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .handCursor()
    }

    private func seek(by delta: Double) {
        guard hasAudio, duration > 0 else { return }
        var target = max(0, min(1, (elapsed + delta) / duration))
        if let range = trimRange {
            target = max(range.lowerBound, min(range.upperBound, target))
        }
        player.seek(toFraction: target)
    }

    private func primaryAction() {
        if failed || !hasAudio {
            player.load(text, lang: detectedLang, rate: speechRate.value)
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

/// One draggable in/out point on the trim waveform. Its own `View` (not a
/// method on `ListenPlaybackControls`) because it needs its own per-drag
/// `@State` to capture the handle's starting fraction once per continuous
/// drag — `DragGesture.translation` is cumulative from gesture-start, not
/// incremental, so recomputing from a `trimRange` that itself updates on
/// every `onChanged` would compound into a runaway drift instead of tracking
/// the pointer.
private struct TrimHandle: View {
    enum Edge { case start, end }

    let edge: Edge
    @Binding var trimRange: ClosedRange<Double>?
    let width: CGFloat
    let minGap: Double
    @State private var dragStartValue: Double?

    static let hitWidth: CGFloat = 24

    var body: some View {
        ZStack {
            Color.clear.frame(width: Self.hitWidth, height: 40)
            Capsule().fill(Palette.foreground).frame(width: 3, height: 34)
        }
        // The hit area must be sized to the wrapping frame explicitly — a
        // Capsule alone only hit-tests its own filled shape, so without this
        // the wider invisible padding does nothing and drags fall through to
        // the parent waveform's own scrub gesture instead.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in commit(translation: drag.translation.width, capture: true) }
                .onEnded { drag in
                    commit(translation: drag.translation.width, capture: false)
                    dragStartValue = nil
                }
        )
        .handCursor()
    }

    /// Always clamp the dragged bound against the OTHER handle's live
    /// position *before* constructing the range — `ClosedRange` traps at
    /// runtime if `lowerBound > upperBound`, and a fast flick can deliver a
    /// large translation in a single callback, so this must never
    /// construct-then-validate.
    private func commit(translation: CGFloat, capture: Bool) {
        guard let range = trimRange else { return }
        if capture, dragStartValue == nil {
            dragStartValue = edge == .start ? range.lowerBound : range.upperBound
        }
        guard let base = dragStartValue else { return }
        let proposed = base + Double(translation) / Double(width)
        switch edge {
        case .start:
            let clamped = max(0, min(range.upperBound - minGap, proposed))
            trimRange = clamped...range.upperBound
        case .end:
            let clamped = min(1, max(range.lowerBound + minGap, proposed))
            trimRange = range.lowerBound...clamped
        }
    }
}

/// Deterministic, decorative amplitude bars for `text` — there's no real
/// waveform data from the TTS endpoint, so this fakes a natural voice-cadence
/// shape (an envelope that tapers at both ends, plus per-bar jitter) seeded
/// by the text's own bytes (FNV-1a), so the same text always draws the same
/// shape instead of reshuffling on every render or every app launch.
func waveformHeights(for text: String, count: Int) -> [Double] {
    var hash: UInt64 = 1469598103934665603
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    var state: UInt64 = hash == 0 ? 0x9E3779B97F4A7C15 : hash
    func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1000) / 1000
    }
    guard count > 0 else { return [] }
    return (0..<count).map { i in
        let t = Double(i) / Double(max(count - 1, 1))
        let envelope = sin(.pi * t)
        let jitter = 0.35 + 0.65 * next()
        return max(0.12, envelope * jitter)
    }
}
