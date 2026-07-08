import Foundation

/// Text-to-speech the Listen card consumes. The view model talks to this
/// protocol, never to a concrete HTTP implementation (repo rule: providers
/// behind protocols), so a BYO adapter or Talkeo Cloud can be swapped in.
///
/// `POST /api/v1/tts/speak` streams raw PCM (s16le, 24 kHz, mono — the fixed wire
/// contract). We read the whole stream into one buffer so the player gets a
/// seekable clip with a known duration (the price is waiting for synthesis; the
/// player caches by text so replays are instant).
protocol TTSClient {
    /// Synthesize `text` and return the raw PCM bytes (s16le, 24 kHz, mono).
    func synthesize(text: String, voice: String?) async throws -> Data
}

struct TalkeoTTSClient: TTSClient {
    /// PCM wire contract advertised by the endpoint (`X-Sample-Rate` etc.).
    static let sampleRate: Double = 24000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    private let config: TalkeoConfig

    init(config: TalkeoConfig = .default) {
        self.config = config
    }

    func synthesize(text: String, voice: String?) async throws -> Data {
        var body: [String: String] = ["text": text]
        if let voice { body["voice"] = voice }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw TalkeoError.transport("invalid request")
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("/api/v1/tts/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 30

        let response: (Data, URLResponse)
        do {
            response = try await URLSession.shared.data(for: request)
        } catch {
            throw TalkeoError.transport((error as? URLError)?.localizedDescription ?? "network error")
        }
        let (pcm, urlResponse) = response
        guard let http = urlResponse as? HTTPURLResponse else {
            throw TalkeoError.transport("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(APIError.self, from: pcm) {
                throw TalkeoError.http(status: http.statusCode, code: err.code, message: err.message)
            }
            throw TalkeoError.http(status: http.statusCode, code: "http_error", message: "Speech failed.")
        }
        guard !pcm.isEmpty else { throw TalkeoError.transport("empty audio") }
        return pcm
    }

    private struct APIError: Decodable {
        let code: String
        let message: String
    }
}
