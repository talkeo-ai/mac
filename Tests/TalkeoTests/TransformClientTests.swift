import XCTest
@testable import Talkeo

/// Verifies `TalkeoTransformClient` builds the right request (URL, method, body)
/// and passes deltas through, using the injected transport seam — no network.
final class TransformClientTests: XCTestCase {
    /// Captures the request handed to the transport and replays canned deltas.
    private final class Capture {
        var request: URLRequest?
        func send(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
            self.request = request
            return AsyncThrowingStream { continuation in
                continuation.yield("ho")
                continuation.yield("la")
                continuation.finish()
            }
        }
    }

    private func body(_ request: URLRequest?) -> [String: String] {
        guard
            let data = request?.httpBody,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async -> String {
        var out = ""
        do { for try await delta in stream { out += delta } } catch { out += "<error>" }
        return out
    }

    func testTranslateAutoDetectOmitsSourceLang() async {
        let capture = Capture()
        let client = TalkeoTransformClient(config: TalkeoConfig(baseURL: URL(string: "http://localhost:8000")!), send: capture.send)

        let result = await collect(client.translate(text: "hello", sourceLang: nil, targetLang: "ES"))

        XCTAssertEqual(result, "hola")
        XCTAssertEqual(capture.request?.httpMethod, "POST")
        XCTAssertEqual(capture.request?.url?.path, "/api/v1/transform/translate")
        XCTAssertEqual(body(capture.request), ["text": "hello", "target_lang": "ES"])
    }

    func testTranslateIncludesSourceLangWhenSet() async {
        let capture = Capture()
        let client = TalkeoTransformClient(config: TalkeoConfig(baseURL: URL(string: "http://localhost:8000")!), send: capture.send)

        _ = await collect(client.translate(text: "hello", sourceLang: "EN", targetLang: "ES"))

        XCTAssertEqual(body(capture.request), ["text": "hello", "target_lang": "ES", "source_lang": "EN"])
    }

    func testExplainBodyShape() async {
        let capture = Capture()
        let client = TalkeoTransformClient(config: TalkeoConfig(baseURL: URL(string: "http://localhost:8000")!), send: capture.send)

        _ = await collect(client.explain(term: "tentative", sentence: "a tentative deal", sourceLang: "EN", targetLang: "ES"))

        XCTAssertEqual(capture.request?.url?.path, "/api/v1/transform/explain")
        XCTAssertEqual(
            body(capture.request),
            ["term": "tentative", "sentence": "a tentative deal", "source_lang": "EN", "target_lang": "ES"]
        )
    }
}
