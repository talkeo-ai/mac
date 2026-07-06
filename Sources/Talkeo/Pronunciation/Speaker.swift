import AVFoundation
import Combine

/// Local text-to-speech with a small transport: play / pause / resume / stop,
/// plus live progress so the UI can show a timeline and let the user scrub. Uses
/// `AVSpeechSynthesizer` (offline) and picks the highest-quality installed voice
/// (premium → enhanced → default) so it sounds natural rather than robotic.
///
/// A single shared instance owns the synthesizer (only one utterance plays at a
/// time). Progress comes from the synth's per-word callback; AVSpeech can't seek,
/// so "seek" re-speaks the loaded text from the chosen character offset.
final class Speaker: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]

    /// Actively producing audio (not paused).
    @Published private(set) var isPlaying = false
    /// Paused mid-utterance (resume continues from here).
    @Published private(set) var isPaused = false
    /// 0…1 position over `currentText`.
    @Published private(set) var progress: Double = 0
    /// The text currently loaded in the transport (so a view can tell whether the
    /// thing playing is *its* text).
    @Published private(set) var currentText: String = ""

    /// True while this text is the one loaded and it is playing or paused.
    func isActive(_ text: String) -> Bool {
        (isPlaying || isPaused) && currentText == text
    }

    private var lang = "EN"
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Character offset of the current utterance within `currentText` (it may have
    /// been started part-way through by a seek), so progress is absolute.
    private var offset = 0
    /// Set while we cancel-then-restart, so the cancel doesn't reset UI state.
    private var restarting = false

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Transport

    /// Load `text` and start speaking it, optionally from a fraction in (0…1).
    func load(_ text: String, lang: String, rate: Float, fromFraction fraction: Double = 0) {
        currentText = text
        self.lang = lang
        self.rate = rate
        let length = (text as NSString).length
        speak(from: Int((Double(length) * max(0, min(1, fraction))).rounded()))
    }

    func pause() { synth.pauseSpeaking(at: .word) }
    func resume() { synth.continueSpeaking() }

    func stop() {
        restarting = false
        synth.stopSpeaking(at: .immediate)
        isPlaying = false
        isPaused = false
        progress = 0
        offset = 0
        currentText = ""
    }

    /// Jump within the loaded text and keep playing from there.
    func seek(toFraction fraction: Double) {
        guard !currentText.isEmpty else { return }
        let length = (currentText as NSString).length
        speak(from: Int((Double(length) * max(0, min(1, fraction))).rounded()))
    }

    /// Change speed; if something is loaded, keep playing from the current spot.
    func setRate(_ rate: Float) {
        self.rate = rate
        guard isPlaying || isPaused else { return }
        speak(from: offset)
    }

    private func speak(from index: Int) {
        let ns = currentText as NSString
        let start = max(0, min(index, ns.length))
        offset = start
        let remainder = ns.substring(from: start)
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stop()
            return
        }
        restarting = true
        synth.stopSpeaking(at: .immediate)
        restarting = false

        let utterance = AVSpeechUtterance(string: remainder)
        utterance.voice = bestVoice(lang)
        utterance.rate = rate
        synth.speak(utterance)
        isPlaying = true
        isPaused = false
        progress = ns.length > 0 ? Double(start) / Double(ns.length) : 0
    }

    // MARK: Fire-and-forget (the small Listen buttons in explain/improve cards)

    /// Speak `text` once. Shares the transport, so it reflects in the UI like any
    /// other playback. Cancels anything already playing so taps feel immediate.
    static func speak(_ text: String, lang: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        shared.load(trimmed, lang: lang, rate: rate)
    }

    /// Stop any in-progress speech (e.g. when the popover closes).
    static func stop() { shared.stop() }

    // MARK: Voice selection

    /// The best installed voice for `lang`: premium beats enhanced beats default.
    /// Premium/enhanced voices may need a one-time download in System Settings;
    /// when absent this gracefully falls back to the default system voice.
    private func bestVoice(_ lang: String) -> AVSpeechSynthesisVoice? {
        let code = Speaker.bcp47(lang)
        if let cached = voiceCache[code] { return cached }
        let prefix = String(code.prefix(2)).lowercased()
        let voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .max { rank($0.quality) < rank($1.quality) }
            ?? AVSpeechSynthesisVoice(language: code)
        voiceCache[code] = voice
        return voice
    }

    private func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private static func bcp47(_ code: String) -> String {
        switch code.uppercased() {
        case "ES": return "es-ES"
        case "EN": return "en-US"
        default: return "en-US"
        }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // The range is relative to the (possibly mid-text) utterance; make it
        // absolute over `currentText` for the timeline.
        let length = (currentText as NSString).length
        guard length > 0 else { return }
        let location = offset + characterRange.location
        DispatchQueue.main.async { self.progress = min(1, Double(location) / Double(length)) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
            self.progress = self.currentText.isEmpty ? 0 : 1
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isPlaying = false; self.isPaused = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isPlaying = true; self.isPaused = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Programmatic cancels (seek / rate change / restart) manage their own
        // state; only a user stop should reset, and that's done in `stop()`.
    }
}
