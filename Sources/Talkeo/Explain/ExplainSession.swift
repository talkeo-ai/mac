import SwiftUI

/// A word/phrase the user picked to learn: the term itself, the sentence it
/// was picked from, the explain direction, and where it sits (pane + range)
/// so the text view can draw a persistent marker over it.
struct ExplainTerm {
    let text: String
    let sentence: String
    let sourceLang: String
    let targetLang: String
    let pane: ExplainPane
    let range: NSRange
}

/// Which text box a term was picked from — the original text or the
/// translation. Each surface maps its own panes onto this.
enum ExplainPane: Equatable { case source, target }

/// The select-to-explain state machine shared by the popover and the app's
/// translator: picked terms, the focused one (‹ › pager), and their vocab
/// cards — loaded once per term text and cached, so re-picking a word reuses
/// its card instead of re-requesting.
///
/// Pure state, no animation: callers wrap the sync calls in `withAnimation`
/// to match their surface. The one exception is the async card arrival —
/// it happens inside the session's own task, out of any caller's reach — so
/// the wrapping animation for it is injected via `cardAnimation`.
///
/// Not `@MainActor` as a class (mirrors the models that host it); async
/// completions hop to the main actor explicitly.
final class ExplainSession: ObservableObject {
    @Published private(set) var terms: [ExplainTerm] = []
    @Published private(set) var activeTermIndex: Int?
    @Published private(set) var cards: [String: ExplainCard] = [:]
    @Published private(set) var loadingTerms: Set<String> = []
    @Published private(set) var cardErrors: [String: String] = [:]
    /// In-flight loads by term text. Internal (not private) so tests can
    /// `await` a load deterministically instead of polling.
    var explainTasks: [String: Task<Void, Never>] = [:]

    private let client: TransformClient
    private let cardAnimation: Animation?

    init(client: TransformClient, cardAnimation: Animation? = nil) {
        self.client = client
        self.cardAnimation = cardAnimation
    }

    var activeTerm: ExplainTerm? {
        guard let i = activeTermIndex, terms.indices.contains(i) else { return nil }
        return terms[i]
    }

    /// Marker ranges (and which is focused) for a pane, so its text view can
    /// highlight the picked words.
    func highlights(for pane: ExplainPane) -> [(range: NSRange, active: Bool)] {
        terms.enumerated().compactMap { idx, term in
            term.pane == pane ? (term.range, idx == activeTermIndex) : nil
        }
    }

    /// Add `term` and focus it, or just refocus if that exact span is already
    /// picked. A new span replaces any picks it overlaps in its pane (no
    /// stacking). `loadCard: false` marks without explaining — Listen's picks,
    /// and the popover's animation split (load kicked off separately, outside
    /// its `withAnimation`).
    func pick(_ term: ExplainTerm, loadCard: Bool = true) {
        let clean = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let item = ExplainTerm(
            text: clean,
            sentence: term.sentence,
            sourceLang: term.sourceLang,
            targetLang: term.targetLang,
            pane: term.pane,
            range: term.range
        )
        if let i = terms.firstIndex(where: { $0.pane == item.pane && NSEqualRanges($0.range, item.range) }) {
            activeTermIndex = i
        } else {
            terms.removeAll { $0.pane == item.pane && NSIntersectionRange($0.range, item.range).length > 0 }
            terms.append(item)
            activeTermIndex = terms.count - 1
        }
        if loadCard, let focused = activeTerm { loadCardIfNeeded(for: focused) }
    }

    /// Move focus across the picked terms (wraps; `by: 0` re-asserts the
    /// current one — Listen's "jump here"). With `loadCard`, also reload a
    /// card the shared-key removal may have dropped (see `removeActive`).
    func step(by delta: Int, loadCard: Bool = true) {
        guard !terms.isEmpty else { return }
        let current = activeTermIndex ?? 0
        activeTermIndex = (current + delta + terms.count) % terms.count
        if loadCard, let term = activeTerm { loadCardIfNeeded(for: term) }
    }

    /// Remove the focused term and its per-term card state, focusing a
    /// neighbour. The cache is keyed by term text, so a twin term with the
    /// same text loses its card too and reloads when focused — long-standing
    /// behavior on both surfaces, locked in by the tests.
    func removeActive() {
        guard let i = activeTermIndex, terms.indices.contains(i) else { return }
        let key = terms[i].text
        explainTasks[key]?.cancel()
        explainTasks[key] = nil
        cards[key] = nil
        loadingTerms.remove(key)
        cardErrors[key] = nil
        terms.remove(at: i)
        activeTermIndex = terms.isEmpty ? nil : min(i, terms.count - 1)
    }

    /// Drop the focused term's failed/stale card and request it again.
    func retryActiveCard() {
        guard let term = activeTerm else { return }
        cards[term.text] = nil
        cardErrors[term.text] = nil
        loadCardIfNeeded(for: term)
    }

    /// Load the vocab card for `term` unless it's cached or already loading.
    /// Exposed so the popover can keep its exact animation scope: pick/step
    /// inside `withAnimation`, the load kickoff after it.
    func loadCardIfNeeded(for term: ExplainTerm) {
        let key = term.text
        guard cards[key] == nil, !loadingTerms.contains(key) else { return }
        cardErrors[key] = nil
        loadingTerms.insert(key)
        explainTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let card = try await self.client.explainCard(
                    term: term.text,
                    sentence: term.sentence,
                    sourceLang: term.sourceLang,
                    targetLang: term.targetLang
                )
                guard !Task.isCancelled else { return }
                self.store(card, forKey: key)
            } catch {
                guard !Task.isCancelled else { return }
                self.loadingTerms.remove(key)
                self.cardErrors[key] = ExplainSession.message(error)
            }
        }
    }

    /// Drop every picked term and its card state, cancelling in-flight loads.
    /// Any change to the underlying text invalidates the ranges.
    func clear() {
        explainTasks.values.forEach { $0.cancel() }
        explainTasks = [:]
        terms = []
        activeTermIndex = nil
        cards = [:]
        loadingTerms = []
        cardErrors = [:]
    }

    private func store(_ card: ExplainCard, forKey key: String) {
        if let cardAnimation {
            withAnimation(cardAnimation) {
                cards[key] = card
                loadingTerms.remove(key)
            }
        } else {
            cards[key] = card
            loadingTerms.remove(key)
        }
    }

    /// User-facing line for a failed card load (the mapping both surfaces
    /// already used).
    static func message(_ error: Error) -> String {
        (error as? TalkeoError)?.userMessage ?? "Something went wrong."
    }
}
