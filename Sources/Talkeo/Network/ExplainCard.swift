import Foundation

/// Structured vocabulary card returned by `POST /api/v1/transform/explain`
/// (talkeo-ai/talkeo#27). The shape is generic — `source`/`target` rather than
/// fixed languages — so it works in either direction. Examples mark the term on
/// the source side with markdown `**bold**`.
struct ExplainCard: Codable, Equatable {
    let term: String
    let category: String
    let meanings: [String]
    let examples: [Example]
    let insight: Insight?

    struct Example: Codable, Equatable {
        let source: String
        let target: String
    }

    struct Insight: Codable, Equatable {
        let type: String
        let text: String

        /// Typed note so the UI can style it (a false friend reads as a warning).
        enum Kind: String { case falseFriend = "false_friend", pattern, register, confusable }
        var kind: Kind { Kind(rawValue: type) ?? .pattern }
    }
}
