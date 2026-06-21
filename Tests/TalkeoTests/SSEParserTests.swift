import XCTest
@testable import Talkeo

/// Exercises the SSE framing contract (#2) the Mac client must parse. Feeds the
/// parser the lines of a `text/event-stream` body (as `AsyncBytes.lines` would,
/// without trailing newlines) and asserts the emitted `SSEEvent`s.
final class SSEParserTests: XCTestCase {
    /// Feeds every line through the parser and collects the events, the way
    /// `StreamingClient` consumes the byte stream.
    private func events(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var out: [SSEEvent] = []
        for line in lines { out.append(contentsOf: parser.push(line)) }
        return out
    }

    func testContentDelta() {
        // `data: Hello\n\n`
        XCTAssertEqual(events(["data: Hello", ""]), [.delta("Hello")])
    }

    func testLeadingSpaceStrippedOnce() {
        // The framing adds one space after the colon; a delta that itself starts
        // with a space (e.g. " world") must keep that intended space.
        XCTAssertEqual(events(["data:  world", ""]), [.delta(" world")])
    }

    func testMultipleDeltas() {
        let lines = ["data: Hello", "", "data:  there", ""]
        XCTAssertEqual(events(lines), [.delta("Hello"), .delta(" there")])
    }

    func testMultiLineDataRejoinedWithNewline() {
        // One message whose chunk contained an internal newline is split across
        // repeated `data:` lines and must rejoin with `\n`.
        let lines = ["data: line1", "data: line2", ""]
        XCTAssertEqual(events(lines), [.delta("line1\nline2")])
    }

    func testDoneSentinel() {
        XCTAssertEqual(events(["event: done", "data: [DONE]", ""]), [.done])
    }

    func testErrorFrameDecoded() {
        let lines = ["event: error", #"data: {"code": "config", "message": "no LLM model configured"}"#, ""]
        XCTAssertEqual(events(lines), [.error(code: "config", message: "no LLM model configured")])
    }

    func testContentThenError() {
        let lines = [
            "data: partial",
            "",
            "event: error",
            #"data: {"code": "rate_limit", "message": "slow down"}"#,
            "",
        ]
        XCTAssertEqual(events(lines), [.delta("partial"), .error(code: "rate_limit", message: "slow down")])
    }

    func testMalformedErrorFallsBack() {
        // A non-JSON error payload still yields an error event, not a crash.
        let lines = ["event: error", "data: boom", ""]
        XCTAssertEqual(events(lines), [.error(code: "internal_error", message: "boom")])
    }

    func testCommentAndBlankLinesIgnored() {
        // A leading keep-alive comment and stray blank lines produce no events.
        let lines = [": keep-alive", "", "data: hi", ""]
        XCTAssertEqual(events(lines), [.delta("hi")])
    }
}
