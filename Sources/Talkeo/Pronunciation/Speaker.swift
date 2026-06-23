import AVFoundation

/// Speaks text in the right language. Uses the local `AVSpeechSynthesizer` so
/// pronunciation works offline; a later phase can swap this for a streamed cloud
/// voice without touching call sites.
enum Speaker {
    private static let synth = AVSpeechSynthesizer()

    static func speak(_ text: String, lang: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: bcp47(lang))
        synth.speak(utterance)
    }

    private static func bcp47(_ code: String) -> String {
        switch code.uppercased() {
        case "ES": return "es-ES"
        case "EN": return "en-US"
        default: return "en-US"
        }
    }
}
