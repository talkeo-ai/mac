import Foundation

/// A single parsed Server-Sent Event from a Talkeo stream (#2 contract).
///
/// - `delta`: a content chunk (the default, un-named SSE event).
/// - `done`: the clean end-of-stream sentinel (`event: done` / `data: [DONE]`).
/// - `error`: a mid-stream failure frame (`event: error` / `data: {code,message}`).
enum SSEEvent: Equatable {
    case delta(String)
    case done
    case error(code: String, message: String)
}
