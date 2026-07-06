import Foundation

/// Structured result of `POST /api/v1/transform/improve` (talkeo-ai/talkeo#8):
/// a more native/natural rewrite of the user's English, plus the individual
/// changes so the UI can diff-highlight and teach. Improve is a fast glance, not
/// a grammar dump — `changes` is empty when the original is already natural.
struct ImproveResult: Codable, Equatable {
    /// The full rewritten text. Equal to the input when nothing needed changing.
    let improved: String
    /// One entry per edit. Empty = "already natural".
    let changes: [Change]

    /// A single edit. `original`/`fixed` let the client mark the fragment in the
    /// source and show the replacement; `why` is the teaching value; `examples`
    /// are included only where they teach (naturalness, word choice), like the
    /// explain card's nullable insight.
    struct Change: Codable, Equatable, Identifiable {
        /// Local, client-side identity — the backend sends no id. Used so the UI
        /// can track per-change dismissals and clear the matching highlight.
        let id: UUID
        let original: String
        let fixed: String
        let why: String
        /// "spelling" | "grammar" | "naturalness" (see `kind` for a typed view).
        let type: String
        let examples: [ExplainCard.Example]?

        enum CodingKeys: String, CodingKey {
            case original, fixed, why, type, examples
        }

        /// Defensive decode: a missing/odd `why` or `type` never fails the whole
        /// payload (same robustness lesson as ExplainCard's optional `category`).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            original = try c.decode(String.self, forKey: .original)
            fixed = try c.decode(String.self, forKey: .fixed)
            why = (try? c.decode(String.self, forKey: .why)) ?? ""
            type = (try? c.decode(String.self, forKey: .type)) ?? "naturalness"
            examples = try? c.decode([ExplainCard.Example].self, forKey: .examples)
        }

        /// Memberwise init for stubs/tests (the synthesized one is unavailable
        /// once a custom `init(from:)` exists).
        init(
            id: UUID = UUID(),
            original: String,
            fixed: String,
            why: String,
            type: String = "naturalness",
            examples: [ExplainCard.Example]? = nil
        ) {
            self.id = id
            self.original = original
            self.fixed = fixed
            self.why = why
            self.type = type
            self.examples = examples
        }

        /// Typed view of `type` so the UI can pick an icon/tone; unknown → naturalness.
        enum Kind: String { case spelling, grammar, naturalness }
        var kind: Kind { Kind(rawValue: type) ?? .naturalness }
    }
}
