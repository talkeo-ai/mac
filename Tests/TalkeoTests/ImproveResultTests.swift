import XCTest
@testable import Talkeo

/// Verifies `ImproveResult` decodes the `/api/v1/transform/improve` payload
/// (talkeo-ai/talkeo#8) and tolerates the optional/odd fields without throwing.
final class ImproveResultTests: XCTestCase {
    private func decode(_ json: String) throws -> ImproveResult {
        try JSONDecoder().decode(ImproveResult.self, from: Data(json.utf8))
    }

    func testDecodesFullPayload() throws {
        let result = try decode("""
        {
          "improved": "I work out every morning.",
          "changes": [
            { "original": "train", "fixed": "work out", "why": "natives say work out",
              "type": "naturalness",
              "examples": [ {"source": "I **work out**.", "target": "Hago ejercicio."} ] }
          ]
        }
        """)

        XCTAssertEqual(result.improved, "I work out every morning.")
        XCTAssertEqual(result.changes.count, 1)
        let change = result.changes[0]
        XCTAssertEqual(change.original, "train")
        XCTAssertEqual(change.fixed, "work out")
        XCTAssertEqual(change.kind, .naturalness)
        XCTAssertEqual(change.examples?.count, 1)
        XCTAssertEqual(change.examples?.first?.target, "Hago ejercicio.")
    }

    func testEmptyChangesIsAlreadyNatural() throws {
        let result = try decode(#"{ "improved": "Looks good.", "changes": [] }"#)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.improved, "Looks good.")
    }

    func testMissingExamplesDecodesAsNil() throws {
        let result = try decode("""
        { "improved": "x", "changes": [ {"original": "a", "fixed": "b", "why": "w", "type": "grammar"} ] }
        """)
        XCTAssertNil(result.changes[0].examples)
        XCTAssertEqual(result.changes[0].kind, .grammar)
    }

    func testUnknownTypeDoesNotThrowAndFallsBack() throws {
        let result = try decode("""
        { "improved": "x", "changes": [ {"original": "a", "fixed": "b", "why": "w", "type": "style"} ] }
        """)
        // Unknown type is preserved as a string but maps to a safe default kind.
        XCTAssertEqual(result.changes[0].type, "style")
        XCTAssertEqual(result.changes[0].kind, .naturalness)
    }

    func testMissingWhyAndTypeTolerated() throws {
        let result = try decode("""
        { "improved": "x", "changes": [ {"original": "a", "fixed": "b"} ] }
        """)
        XCTAssertEqual(result.changes[0].why, "")
        XCTAssertEqual(result.changes[0].kind, .naturalness)
    }

    func testEachChangeGetsDistinctID() throws {
        let result = try decode("""
        { "improved": "x", "changes": [
            {"original": "a", "fixed": "b"},
            {"original": "a", "fixed": "b"}
        ] }
        """)
        XCTAssertNotEqual(result.changes[0].id, result.changes[1].id)
    }
}
