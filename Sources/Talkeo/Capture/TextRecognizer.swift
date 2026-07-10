import AppKit
import Vision

/// OCR seam. `VisionTextRecognizer` is both the fallback when the VisionKit
/// analyzer can't run (unsupported hardware, thrown error) and the
/// unit-testable OCR surface — Vision runs headless under `swift test`,
/// VisionKit's Live Text overlay doesn't.
protocol TextRecognizing: AnyObject {
    /// Full-image transcript, recognized lines joined with newlines.
    /// Completion on main; nil when nothing was recognized.
    func recognizeText(in image: CGImage, completion: @escaping (String?) -> Void)
}

final class VisionTextRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage, completion: @escaping (String?) -> Void) {
        // Vision is synchronous on whatever queue performs the request; keep
        // the main thread free while it chews on a Retina-sized bitmap.
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate // screenshots are static; favor quality over speed
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "es-ES"] // Talkeo's two languages
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let text = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async {
                completion(text?.isEmpty == false ? text : nil)
            }
        }
    }
}

/// Which text a preview verb acts on: a live selection wins over the full
/// transcript; whitespace-only counts as nothing. Pure so it's unit-testable —
/// the overlay's selection state itself can't run under `swift test`.
enum CaptureActionText {
    static func resolve(selected: String?, transcript: String?) -> String? {
        if let selected = selected?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            return selected
        }
        if let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
            return transcript
        }
        return nil
    }
}
