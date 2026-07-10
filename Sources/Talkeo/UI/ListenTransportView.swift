import SwiftUI

/// Listen's playback transport — shared by the popover and the app page (the
/// "aura" Joaquin pointed at: ElevenLabs' generation player). Monochrome only
/// (no `Color.accentColor`, matching the rest of the app): a waveform with a
/// played/unplayed contrast, a big central play/pause, ±5s skip either side,
/// and a speed menu. Time labels flank the waveform.
///
/// There's no real amplitude data from the TTS endpoint, so the waveform is
/// decorative — a stable shape generated from the text itself (see
/// `waveformHeights`), not a true analysis of the audio.
struct ListenPlaybackControls: View {
    let text: String
    let detectedLang: String
    @Binding var speechRate: QuickTranslateModel.SpeechRate
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
    }

    // MARK: Waveform

    private var waveform: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 2
            let count = max(12, Int(geo.size.width / (barWidth + spacing)))
            let heights = waveformHeights(for: text, count: count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let played = Double(i) / Double(max(count - 1, 1)) <= progress
                    Capsule()
                        .fill(played ? Palette.foreground : Palette.elevated)
                        .frame(width: barWidth, height: max(3, heights[i] * 26))
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
                            player.load(text, lang: detectedLang, rate: speechRate.value, fromFraction: frac)
                        }
                    }
            )
            .handCursor()
        }
        .frame(height: 26)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(width, 1))))
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
        player.seek(toFraction: max(0, min(1, (elapsed + delta) / duration)))
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
