import Foundation

/// Text-transformation features the UI consumes. The view model talks to this
/// protocol, never to a concrete HTTP/provider implementation (repo rule:
/// providers behind protocols) — so a BYO adapter or Talkeo Cloud can be swapped
/// in without touching the panel. Each call returns a stream of content deltas;
/// the stream finishes cleanly on success and throws a `TalkeoError` on failure.
protocol TransformClient {
    func translate(
        text: String,
        sourceLang: String?,
        targetLang: String
    ) -> AsyncThrowingStream<String, Error>

    /// Highlight-to-explain: a structured vocabulary card for `term` as used in
    /// `sentence` (talkeo-ai/talkeo#27). Unlike translate/improve this is a short
    /// JSON response, not a stream. Throws `TalkeoError` on failure.
    func explainCard(
        term: String,
        sentence: String,
        sourceLang: String?,
        targetLang: String
    ) async throws -> ExplainCard
}

extension TransformClient {
    /// Default so non-network conformers (e.g. SwiftUI previews) need not provide
    /// it. The real network client overrides this.
    func explainCard(
        term: String,
        sentence: String,
        sourceLang: String?,
        targetLang: String
    ) async throws -> ExplainCard {
        throw TalkeoError.transport("explainCard not implemented")
    }
}

/// Default `TransformClient` backed by the Talkeo HTTP API over SSE. It is a
/// generic, OpenAI-compatible-style HTTP adapter — it names no production
/// provider; the brand the user sees is "Talkeo". `source_lang` is omitted from
/// the body when `nil`, which tells the backend to auto-detect.
struct TalkeoTransformClient: TransformClient {
    private let config: TalkeoConfig
    /// Seam over the SSE transport so the request building can be unit-tested
    /// without a network (the test injects a fake that captures the request).
    private let send: (URLRequest) -> AsyncThrowingStream<String, Error>

    init(
        config: TalkeoConfig = .default,
        send: @escaping (URLRequest) -> AsyncThrowingStream<String, Error> = { StreamingClient().deltas(for: $0) }
    ) {
        self.config = config
        self.send = send
    }

    func translate(
        text: String,
        sourceLang: String?,
        targetLang: String
    ) -> AsyncThrowingStream<String, Error> {
        var body: [String: String] = ["text": text, "target_lang": targetLang]
        if let sourceLang { body["source_lang"] = sourceLang }
        return stream(path: "/api/v1/transform/translate", body: body)
    }

    func explainCard(
        term: String,
        sentence: String,
        sourceLang: String?,
        targetLang: String
    ) async throws -> ExplainCard {
        var body: [String: String] = [
            "term": term,
            "sentence": sentence,
            "target_lang": targetLang,
        ]
        if let sourceLang { body["source_lang"] = sourceLang }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw TalkeoError.transport("invalid request")
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("/api/v1/transform/explain"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data

        let response: (Data, URLResponse)
        do {
            response = try await URLSession.shared.data(for: request)
        } catch {
            throw TalkeoError.transport((error as? URLError)?.localizedDescription ?? "network error")
        }
        let (payload, urlResponse) = response
        guard let http = urlResponse as? HTTPURLResponse else {
            throw TalkeoError.transport("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The API returns {code, message} on error.
            if let err = try? JSONDecoder().decode(APIError.self, from: payload) {
                throw TalkeoError.http(status: http.statusCode, code: err.code, message: err.message)
            }
            throw TalkeoError.http(status: http.statusCode, code: "http_error", message: "Request failed.")
        }
        do {
            return try JSONDecoder().decode(ExplainCard.self, from: payload)
        } catch {
            throw TalkeoError.transport("Couldn't read the response.")
        }
    }

    private struct APIError: Decodable {
        let code: String
        let message: String
    }

    private func stream(path: String, body: [String: String]) -> AsyncThrowingStream<String, Error> {
        guard let request = makeRequest(path: path, body: body) else {
            return AsyncThrowingStream { $0.finish(throwing: TalkeoError.transport("invalid request")) }
        }
        return send(request)
    }

    private func makeRequest(path: String, body: [String: String]) -> URLRequest? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = data
        return request
    }
}
