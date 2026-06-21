import Foundation

/// Errors surfaced by the networking layer. The three cases map to the three
/// ways a Talkeo streaming request can fail (the #2 SSE contract):
///
/// - `http`: a **pre-stream** failure — the server answered with a non-2xx
///   status and a `{code, message}` body before committing the 200 stream
///   (e.g. a `400 bad_request` for empty text).
/// - `stream`: a **mid-stream** failure — the stream started, then emitted an
///   `event: error` frame carrying `{code, message}` (e.g. a provider/config
///   error during generation).
/// - `transport`: the request never produced a usable response (DNS, refused
///   connection, dropped socket) — a `URLError` or similar.
enum TalkeoError: Error, Equatable {
    case http(status: Int, code: String, message: String)
    case stream(code: String, message: String)
    case transport(String)

    /// A short, client-safe line to show in the UI. Backend messages are already
    /// written to be user-facing (no internals), so we surface them directly and
    /// only synthesize copy for the transport case.
    var userMessage: String {
        switch self {
        case let .http(_, _, message), let .stream(_, message):
            return message
        case .transport:
            return "Couldn't reach Talkeo. Check your connection and try again."
        }
    }
}
