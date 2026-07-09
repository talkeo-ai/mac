import XCTest
@testable import Talkeo

/// Locks in the select-to-explain semantics both surfaces (popover, app
/// translator) relied on before the state machine was extracted — including
/// the deliberate quirks (cards keyed by term text across panes, shared-key
/// removal dropping a twin's card).
final class ExplainSessionTests: XCTestCase {

    // MARK: Stub client

    /// Scriptable TransformClient: counts explain calls, returns a canned
    /// card or throws, optionally delaying so cancellation/dedupe are
    /// observable mid-flight.
    private final class StubClient: TransformClient {
        var explainCalls = 0
        var error: Error?
        var delayNanos: UInt64 = 0

        func translate(text: String, sourceLang: String?, targetLang: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func explainCard(term: String, sentence: String, sourceLang: String?, targetLang: String) async throws -> ExplainCard {
            explainCalls += 1
            if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
            if let error { throw error }
            return ExplainCard(term: term, category: "noun", meanings: ["meaning"], examples: [], insight: nil)
        }
    }

    private var client: StubClient!
    private var session: ExplainSession!

    override func setUp() {
        super.setUp()
        client = StubClient()
        session = ExplainSession(client: client)
    }

    private func term(
        _ text: String,
        at location: Int,
        length: Int? = nil,
        pane: ExplainPane = .source
    ) -> ExplainTerm {
        ExplainTerm(
            text: text,
            sentence: "context sentence",
            sourceLang: "EN",
            targetLang: "ES",
            pane: pane,
            range: NSRange(location: location, length: length ?? (text as NSString).length)
        )
    }

    private func awaitLoad(_ key: String) async {
        await session.explainTasks[key]?.value
    }

    // MARK: Pick + cache

    func testPickLoadsAndCachesCardByTextAcrossPanes() async {
        session.pick(term("hello", at: 0))
        await awaitLoad("hello")
        XCTAssertEqual(client.explainCalls, 1)
        XCTAssertEqual(session.cards["hello"]?.term, "hello")
        XCTAssertTrue(session.loadingTerms.isEmpty)

        // Same text in the other pane: second term, no second request —
        // overlap replacement is same-pane only, the card is shared by key.
        session.pick(term("hello", at: 12, pane: .target))
        await awaitLoad("hello")
        XCTAssertEqual(session.terms.count, 2)
        XCTAssertEqual(session.activeTermIndex, 1)
        XCTAssertEqual(client.explainCalls, 1)
    }

    func testRemoveActiveDropsTwinsCardAndStepReloads() async {
        session.pick(term("hello", at: 0))
        session.pick(term("hello", at: 12, pane: .target))
        await awaitLoad("hello")

        // Removing one twin clears the shared card (keyed by text)...
        session.removeActive()
        XCTAssertEqual(session.terms.count, 1)
        XCTAssertNil(session.cards["hello"])

        // ...and stepping onto the survivor requests it again.
        session.step(by: 0)
        await awaitLoad("hello")
        XCTAssertEqual(client.explainCalls, 2)
        XCTAssertNotNil(session.cards["hello"])
    }

    func testRepickSameRangeRefocusesWithoutMutation() async {
        session.pick(term("alpha", at: 0))
        session.pick(term("beta", at: 10))
        await awaitLoad("alpha")
        await awaitLoad("beta")

        session.pick(term("alpha", at: 0))
        XCTAssertEqual(session.terms.count, 2)
        XCTAssertEqual(session.activeTermIndex, 0)
        XCTAssertEqual(client.explainCalls, 2) // cached, no reload
    }

    func testRepickAfterFailureRetries() async {
        client.error = TalkeoError.transport("down")
        session.pick(term("alpha", at: 0))
        await awaitLoad("alpha")
        XCTAssertNotNil(session.cardErrors["alpha"])

        // Same-range re-pick hits the refocus branch, but the load guard sees
        // no card and no in-flight task — the error clears and it retries.
        client.error = nil
        session.pick(term("alpha", at: 0))
        XCTAssertNil(session.cardErrors["alpha"])
        await awaitLoad("alpha")
        XCTAssertEqual(client.explainCalls, 2)
        XCTAssertNotNil(session.cards["alpha"])
    }

    // MARK: Overlap

    func testOverlapReplacesSamePaneOnly() {
        session.pick(term("first", at: 0, length: 5), loadCard: false)   // 0..<5
        session.pick(term("touch", at: 7, length: 3), loadCard: false)   // 7..<10, only touches next
        session.pick(term("other", at: 3, length: 4, pane: .target), loadCard: false)

        // Overlaps `first` (3..<7 ∩ 0..<5) in the same pane → replaces it;
        // `touch` (intersection empty) and the other-pane term survive.
        session.pick(term("newer", at: 3, length: 4), loadCard: false)
        XCTAssertEqual(session.terms.map(\.text), ["touch", "other", "newer"])
        XCTAssertEqual(session.activeTermIndex, 2)

        // Highlights follow the shifted indices: only the new pick is active.
        let source = session.highlights(for: .source)
        XCTAssertEqual(source.map(\.active), [false, true])
        let target = session.highlights(for: .target)
        XCTAssertEqual(target.map(\.active), [false])
    }

    // MARK: Step

    func testStepWrapsBothWaysAndZeroKeepsIndex() {
        session.pick(term("a", at: 0), loadCard: false)
        session.pick(term("b", at: 5), loadCard: false)
        session.pick(term("c", at: 10), loadCard: false)
        XCTAssertEqual(session.activeTermIndex, 2)

        session.step(by: 1, loadCard: false)
        XCTAssertEqual(session.activeTermIndex, 0) // wraps forward
        session.step(by: -1, loadCard: false)
        XCTAssertEqual(session.activeTermIndex, 2) // wraps backward
        session.step(by: 0, loadCard: false)
        XCTAssertEqual(session.activeTermIndex, 2) // Listen's "jump here"
    }

    func testMarkWithoutLoadNeverCallsClient() {
        session.pick(term("a", at: 0), loadCard: false)
        session.pick(term("b", at: 5), loadCard: false)
        session.step(by: 1, loadCard: false)
        session.removeActive()
        XCTAssertEqual(client.explainCalls, 0)
        XCTAssertTrue(session.explainTasks.isEmpty)
    }

    // MARK: Remove

    func testRemoveActiveClampsFocus() {
        session.pick(term("a", at: 0), loadCard: false)
        session.pick(term("b", at: 5), loadCard: false)
        session.pick(term("c", at: 10), loadCard: false)

        session.step(by: -1, loadCard: false) // focus "b"
        session.removeActive()
        XCTAssertEqual(session.terms.map(\.text), ["a", "c"])
        XCTAssertEqual(session.activeTermIndex, 1) // stays at i → "c"

        session.removeActive() // remove last
        XCTAssertEqual(session.activeTermIndex, 0)

        session.removeActive() // remove only
        XCTAssertNil(session.activeTermIndex)
        XCTAssertTrue(session.terms.isEmpty)

        session.removeActive() // no active → no-op, no crash
        XCTAssertTrue(session.terms.isEmpty)
    }

    // MARK: Errors

    func testErrorPathMapsMessageAndRetryReloads() async {
        client.error = TalkeoError.stream(code: "provider_error", message: "The voice provider hiccuped.")
        session.pick(term("alpha", at: 0))
        await awaitLoad("alpha")
        XCTAssertEqual(session.cardErrors["alpha"], "The voice provider hiccuped.")
        XCTAssertTrue(session.loadingTerms.isEmpty)
        XCTAssertEqual(session.terms.count, 1) // term retained

        client.error = nil
        session.retryActiveCard()
        await awaitLoad("alpha")
        XCTAssertNil(session.cardErrors["alpha"])
        XCTAssertNotNil(session.cards["alpha"])
        XCTAssertEqual(client.explainCalls, 2)
    }

    func testUnknownErrorGetsGenericMessage() async {
        client.error = URLError(.timedOut)
        session.pick(term("alpha", at: 0))
        await awaitLoad("alpha")
        XCTAssertEqual(session.cardErrors["alpha"], "Something went wrong.")
    }

    func testRetryWithNoActiveTermIsNoOp() {
        session.retryActiveCard()
        XCTAssertEqual(client.explainCalls, 0)
    }

    // MARK: Clear + in-flight

    func testClearCancelsInflightLoad() async {
        client.delayNanos = 200_000_000
        session.pick(term("alpha", at: 0))
        let inflight = session.explainTasks["alpha"]
        XCTAssertNotNil(inflight)

        session.clear()
        await inflight?.value
        XCTAssertTrue(session.cards.isEmpty)
        XCTAssertTrue(session.cardErrors.isEmpty)
        XCTAssertTrue(session.loadingTerms.isEmpty)
        XCTAssertTrue(session.terms.isEmpty)
        XCTAssertNil(session.activeTermIndex)
    }

    func testInflightDedupe() async {
        client.delayNanos = 100_000_000
        session.pick(term("alpha", at: 0))
        // The in-flight guard is set synchronously, before the load task runs.
        XCTAssertTrue(session.loadingTerms.contains("alpha"))
        // Same text elsewhere while the first load is in flight: the
        // loadingTerms guard prevents a second request.
        session.pick(term("alpha", at: 20, pane: .target))
        await awaitLoad("alpha")
        XCTAssertEqual(client.explainCalls, 1)
        XCTAssertNotNil(session.cards["alpha"])
    }

    // MARK: Hygiene

    func testWhitespaceOnlyTermIsIgnored() {
        session.pick(term("  \n ", at: 0, length: 4))
        XCTAssertTrue(session.terms.isEmpty)
        XCTAssertEqual(client.explainCalls, 0)
    }

    func testTermTextIsTrimmedButRawRangeKept() {
        session.pick(term(" hello ", at: 5, length: 7), loadCard: false)
        XCTAssertEqual(session.terms.first?.text, "hello")
        XCTAssertEqual(session.terms.first?.range, NSRange(location: 5, length: 7))
    }

    func testHighlightsFilterByPaneAndFlagActive() {
        session.pick(term("a", at: 0), loadCard: false)
        session.pick(term("b", at: 5, pane: .target), loadCard: false)
        session.pick(term("c", at: 10), loadCard: false)

        let source = session.highlights(for: .source)
        XCTAssertEqual(source.count, 2)
        XCTAssertEqual(source.map(\.active), [false, true]) // "c" is active
        let target = session.highlights(for: .target)
        XCTAssertEqual(target.map(\.active), [false])
    }
}
