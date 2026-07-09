import XCTest
@testable import Talkeo

final class ImproveHistoryStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkeo-improve-history-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func entry(
        id: String = UUID().uuidString,
        source: String,
        improved: String = "improved",
        changes: [ImproveResult.Change] = [ImproveResult.Change(original: "a", fixed: "b", why: "w")]
    ) -> ImproveHistoryEntry {
        ImproveHistoryEntry(id: id, source: source, improved: improved, changes: changes, timestamp: Date())
    }

    func testPersistsAcrossInstances() {
        LocalImproveHistoryStore(url: url).add(entry(source: "I go gym", improved: "I go to the gym"))
        let reloaded = LocalImproveHistoryStore(url: url).all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].source, "I go gym")
        XCTAssertEqual(reloaded[0].improved, "I go to the gym")
    }

    /// The changes ride along so re-opening restores the diff + teaching cards
    /// without re-hitting the API.
    func testChangesSurviveTheRoundTrip() {
        let change = ImproveResult.Change(
            original: "borrow me",
            fixed: "lend me",
            why: "You borrow FROM someone; they lend TO you.",
            type: "naturalness",
            examples: [ExplainCard.Example(source: "Can you **lend me** a pen?", target: "¿Me prestás una lapicera?")]
        )
        LocalImproveHistoryStore(url: url).add(entry(source: "borrow", changes: [change]))
        let restored = LocalImproveHistoryStore(url: url).all()[0].changes
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].original, "borrow me")
        XCTAssertEqual(restored[0].fixed, "lend me")
        XCTAssertEqual(restored[0].examples?.count, 1)
    }

    func testReimprovingSameSourceCollapsesToTop() {
        let store = LocalImproveHistoryStore(url: url)
        store.add(entry(source: "Same text"))
        store.add(entry(source: "Other text"))
        store.add(entry(source: "  same TEXT ")) // whitespace/case-insensitive repeat
        let all = store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].source, "  same TEXT ")
        XCTAssertEqual(all[1].source, "Other text")
    }

    func testRemoveAndClear() {
        let store = LocalImproveHistoryStore(url: url)
        let e = entry(id: "victim", source: "one")
        store.add(e)
        store.add(entry(source: "two"))
        store.remove(id: "victim")
        XCTAssertEqual(store.all().map(\.source), ["two"])
        store.clear()
        XCTAssertTrue(LocalImproveHistoryStore(url: url).all().isEmpty)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(LocalImproveHistoryStore(url: url).all().isEmpty)
    }

    func testSchemaMismatchFallsBackToEmpty() throws {
        try Data(#"{"schemaVersion": 99, "entries": []}"#.utf8).write(to: url)
        XCTAssertTrue(LocalImproveHistoryStore(url: url).all().isEmpty)
    }
}
