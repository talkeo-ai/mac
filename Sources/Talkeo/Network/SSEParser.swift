import Foundation

/// Incremental, **pure** parser for the Talkeo SSE wire contract (#2). It holds
/// no networking — you feed it the lines of an `text/event-stream` body one at a
/// time (as delivered by `URLSession.AsyncBytes.lines`) and it emits `SSEEvent`s
/// as each message completes. This keeps the framing logic fully unit-testable.
///
/// Wire shape (`app/api/sse.py`):
///
///     data: <chunk>\n\n                            # content (default event)
///     event: done\n   data: [DONE]\n\n             # clean end-of-stream
///     event: error\n  data: {"code","message"}\n\n # mid-stream failure
///
/// A message ends on a blank line. A chunk that contained internal newlines is
/// split across repeated `data:` lines within one message; we rejoin them with
/// `\n`, per the SSE spec.
struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    /// Feed one line (without its trailing newline). Returns the events that this
    /// line completed — empty until a blank line closes the current message.
    mutating func push(_ line: String) -> [SSEEvent] {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return [] // comment line — ignore
        }
        if let value = fieldValue(line, field: "data") {
            dataLines.append(value)
        } else if let value = fieldValue(line, field: "event") {
            event = value
        }
        // Unknown fields are ignored, per the SSE spec.
        return []
    }

    /// Close out the accumulated message and reset for the next one.
    private mutating func dispatch() -> [SSEEvent] {
        defer {
            event = nil
            dataLines = []
        }
        // A stray blank line with nothing buffered carries no message.
        guard !dataLines.isEmpty || event != nil else { return [] }

        let data = dataLines.joined(separator: "\n")
        switch event {
        case "done":
            return [.done]
        case "error":
            return [decodeError(data)]
        default:
            return [.delta(data)]
        }
    }

    /// Strips a `"<field>:"` prefix and the single optional leading space the SSE
    /// framing adds, preserving any further leading spaces that belong to the
    /// payload (LLM deltas often legitimately start with a space).
    private func fieldValue(_ line: String, field: String) -> String? {
        let prefix = field + ":"
        guard line.hasPrefix(prefix) else { return nil }
        var value = Substring(line.dropFirst(prefix.count))
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }

    private func decodeError(_ data: String) -> SSEEvent {
        guard
            let json = data.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            return .error(code: "internal_error", message: data.isEmpty ? "stream failed" : data)
        }
        let code = object["code"] as? String ?? "internal_error"
        let message = object["message"] as? String ?? "stream failed"
        return .error(code: code, message: message)
    }
}
