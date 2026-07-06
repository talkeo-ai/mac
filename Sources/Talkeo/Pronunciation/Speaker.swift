import AVFoundation

/// Local, offline text-to-speech for the small "Listen" buttons in the
/// explain/improve cards. Fire-and-forget: speak a phrase once, or stop. It
/// picks the highest-quality installed voice (premium → enhanced → default) so
/// it sounds natural rather than robotic.
///
/// A single shared instance owns the synthesizer, so speaking a new phrase
/// cancels the previous one (only one utterance plays at a time). The richer
/// Listen card uses `TTSAudioPlayer` (real Talkeo voices); this stays small.
final class Speaker: @unchecked Sendable {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]

    private func speak(_ text: String, lang: String, rate: Float) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(lang)
        utterance.rate = rate
        synth.speak(utterance)
    }

    // MARK: Static shims (the small Listen buttons in explain/improve cards)

    /// Speak `text` once. Cancels anything already playing so taps feel immediate.
    static func speak(_ text: String, lang: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        shared.speak(trimmed, lang: lang, rate: rate)
    }

    /// Stop any in-progress speech (e.g. when the popover closes).
    static func stop() { shared.synth.stopSpeaking(at: .immediate) }

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
