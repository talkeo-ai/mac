import Foundation

/// Shared SSE transport for every streaming Talkeo feature (translate, explain,
/// and later Improve). It owns the HTTP concerns the #2 contract puts on the
/// client: check the status before the body (pre-stream errors arrive as an HTTP
/// status with a `{code,message}` JSON body), then frame the `text/event-stream`
/// body through `SSEParser`, surfacing content deltas and translating the
/// terminal frames — `done` finishes the stream, `error` throws.
struct StreamingClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sends `request` and streams the content deltas. `done` ends the stream
    /// cleanly; an HTTP error or an `event: error` frame finishes it by throwing
    /// the matching `TalkeoError`. Cancelling the consuming task tears down the
    /// underlying connection.
    func deltas(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw TalkeoError.transport("invalid response")
                    }

                    if !(200..<300).contains(http.statusCode) {
                        // Pre-stream failure: the body is a small {code,message}.
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        let (code, message) = Self.decodeErrorBody(body)
                        throw TalkeoError.http(status: http.statusCode, code: code, message: message)
                    }

                    // Split the byte stream on `\n` ourselves rather than using
                    // `bytes.lines`: `AsyncLineSequence` drops blank lines, and
                    // the SSE contract dispatches each message *on* the blank line
                    // (`\n\n`) — so `.lines` would silently never emit a message.
                    var parser = SSEParser()
                    var line: [UInt8] = []

                    func consume(_ raw: [UInt8]) throws -> Bool {
                        var bytes = raw
                        if bytes.last == 0x0D { bytes.removeLast() } // strip trailing \r
                        let text = String(decoding: bytes, as: UTF8.self)
                        for event in parser.push(text) {
                            switch event {
                            case let .delta(delta):
                                continuation.yield(delta)
                            case .done:
                                return true
                            case let .error(code, message):
                                throw TalkeoError.stream(code: code, message: message)
                            }
                        }
                        return false
                    }

                    for try await byte in bytes {
                        if byte == 0x0A { // \n ends a line (which may be empty)
                            if try consume(line) {
                                continuation.finish()
                                return
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    // Flush a trailing line with no final newline, then finish.
                    if !line.isEmpty { _ = try consume(line) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as TalkeoError {
                    continuation.finish(throwing: error)
                } catch let urlError as URLError where urlError.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TalkeoError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes a non-2xx body into a `{code, message}` pair, falling back to
    /// sensible defaults when the body isn't the expected JSON shape.
    static func decodeErrorBody(_ data: Data) -> (code: String, message: String) {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = object["code"] as? String,
            let message = object["message"] as? String
        {
            return (code, message)
        }
        return ("http_error", "Request failed.")
    }
}
