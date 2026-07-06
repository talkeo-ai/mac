import AVFoundation
import Combine
import Foundation

/// The word currently being spoken, in its own object so the text view can
/// observe it (changing a few times per second) without re-rendering on the
/// 60 fps progress ticks the transport observes.
final class SpokenWord: ObservableObject {
    @Published var range: NSRange?
}

/// Plays real Talkeo-voiced audio for the Listen card. It fetches the full clip
/// from the TTS endpoint (raw PCM), wraps it as WAV, and drives an
/// `AVAudioPlayer` — which gives a known duration, frame-accurate seek, smooth
/// `currentTime`, and rate control. That's what makes the timeline behave like a
/// real player (scrub to where you tap, no word-by-word jumps).
///
/// Buffering means a wait while the backend synthesizes; the result is cached by
/// text so replays and re-seeks are instant. Progress is sampled ~60 fps for a
/// smooth bar; the spoken word is derived from progress (the endpoint has no word
/// timings) and published separately so the highlight updates only per word.
final class TTSAudioPlayer: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = TTSAudioPlayer()

    private let client: TTSClient
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var fetch: Task<Void, Never>?
    /// Synthesized WAV per text, so repeats don't re-hit the backend.
    private var cache: [String: Data] = [:]
    private var wordRanges: [NSRange] = []
    private var rate: Float = 1.0

    @Published private(set) var currentText: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var failed = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    /// Observed by the text view to highlight the current word (per-word updates).
    let spoken = SpokenWord()

    init(client: TTSClient = TalkeoTTSClient()) {
        self.client = client
        super.init()
    }

    /// True when `text` is loaded and has audio ready (playing, paused, or ended).
    func hasAudio(_ text: String) -> Bool { currentText == text && player != nil }
    func isActive(_ text: String) -> Bool { currentText == text && (isPlaying || isPaused) }

    // MARK: Load / playback

    /// Fetch (or reuse) the clip for `text` and start playing, optionally from a
    /// fraction in 0…1.
    func load(_ text: String, lang: String, rate: Float, fromFraction fraction: Double = 0) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        teardown()
        currentText = clean
        self.rate = rate
        wordRanges = TTSAudioPlayer.wordRanges(in: clean)
        spoken.range = nil
        failed = false
        progress = 0
        duration = 0

        if let wav = cache[clean] {
            start(wav, fromFraction: fraction)
            return
        }
        isLoading = true
        fetch = Task { [weak self] in
            guard let self else { return }
            do {
                let pcm = try await self.client.synthesize(text: clean, voice: nil)
                let wav = TTSAudioPlayer.wav(fromPCM: pcm)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentText == clean else { return } // superseded
                    self.cache[clean] = wav
                    self.isLoading = false
                    self.start(wav, fromFraction: fraction)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentText == clean else { return }
                    self.isLoading = false
                    self.failed = true
                }
            }
        }
    }

    private func start(_ wav: Data, fromFraction fraction: Double) {
        guard let player = try? AVAudioPlayer(data: wav) else { failed = true; return }
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        if fraction > 0 { player.currentTime = max(0, min(1, fraction)) * duration }
        player.play()
        isPlaying = true
        isPaused = false
        progress = duration > 0 ? player.currentTime / duration : 0
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        isPaused = true
        stopTicker()
    }

    func resume() {
        guard let player else { return }
        if !player.isPlaying { player.play() }
        isPlaying = true
        isPaused = false
        startTicker()
    }

    /// Resume / pause / replay-from-end, depending on state.
    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            if progress >= 0.999 { player.currentTime = 0; progress = 0 }
            resume()
        }
    }

    func stop() {
        fetch?.cancel()
        teardown()
        currentText = ""
        isLoading = false
        failed = false
        progress = 0
        duration = 0
        spoken.range = nil
    }

    /// Scrub to a fraction of the clip and keep the current play/pause state.
    func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let f = max(0, min(1, fraction))
        player.currentTime = f * duration
        progress = f
        updateSpokenWord()
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player?.rate = rate
    }

    private func teardown() {
        stopTicker()
        player?.stop()
        player = nil
        isPlaying = false
        isPaused = false
    }

    // MARK: Progress sampling

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player, duration > 0 else { return }
        progress = min(1, player.currentTime / duration)
        updateSpokenWord()
    }

    /// Map the elapsed fraction onto a character position and highlight the word
    /// there. Time-proportional (no per-word timings from the endpoint), so it
    /// tracks closely but isn't sample-accurate.
    private func updateSpokenWord() {
        guard !wordRanges.isEmpty else { return }
        let length = (currentText as NSString).length
        let position = Int(progress * Double(length))
        var current: NSRange?
        for range in wordRanges {
            if range.location <= position { current = range } else { break }
        }
        if let current, spoken.range != current { spoken.range = current }
    }

    // MARK: Helpers

    /// Word ranges over `text` (for the karaoke-style highlight).
    static func wordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .localized]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    /// Wrap raw PCM (s16le, 24 kHz, mono) in a 44-byte WAV header so
    /// `AVAudioPlayer` can decode it.
    static func wav(fromPCM pcm: Data) -> Data {
        let sampleRate = UInt32(TalkeoTTSClient.sampleRate)
        let channels = TalkeoTTSClient.channels
        let bits = TalkeoTTSClient.bitsPerSample
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataLength = UInt32(pcm.count)

        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + dataLength); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bits)
        ascii("data"); u32(dataLength)
        return header + pcm
    }
}

extension TTSAudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        isPaused = false
        progress = 1
        spoken.range = nil
        stopTicker()
    }
}
