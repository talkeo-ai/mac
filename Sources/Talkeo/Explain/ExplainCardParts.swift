import SwiftUI

/// Shared rendering pieces of the explain card. Each surface (popover, app
/// window) keeps its own card *composition* — headword, pager, buttons and
/// states are deliberate per-surface design — and builds the identical parts
/// from here: the examples list, the insight note, the loading shimmer, and
/// the text helpers.
enum ExplainCardText {
    /// Render the backend's light markdown (`**term**` bold) inline.
    static func bold(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string) {
            return Text(attributed)
        }
        return Text(string)
    }

    /// Strip markdown bold markers so spoken text is clean.
    static func plainSpoken(_ string: String) -> String {
        string.replacingOccurrences(of: "**", with: "")
    }

    /// The English side of a card to read aloud: the term itself when it's
    /// English, otherwise its English equivalent (first meaning).
    static func spokenEnglish(term: ExplainTerm, card: ExplainCard) -> String {
        term.sourceLang == "EN" ? card.term : (card.meanings.first ?? card.term)
    }
}

/// The card's example pairs: the term's side (term bolded) over the user's
/// side, each with a speaker for the English. Fonts/spacing/alignment are the
/// surface's knobs; the speaker button is injected so each surface keeps its
/// own control style.
struct ExplainExamplesList<Speaker: View>: View {
    let examples: [ExplainCard.Example]
    var sourceSize: CGFloat = 14.5
    var targetSize: CGFloat = 13.5
    var rowSpacing: CGFloat = 12
    /// `.top` hugs the speaker to the first line (popover); `.center` sits it
    /// between the pair (app).
    var speakerAlignment: VerticalAlignment = .top
    /// A small bullet at each pair's leading edge, so multiple examples read
    /// as a structured list (the app's roomier card); off on the popover.
    var showsMarkers = false
    /// Builds the surface's speaker button for the (markdown-stripped)
    /// English text of an example.
    @ViewBuilder var speaker: (String) -> Speaker

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(examples.indices, id: \.self) { i in
                let ex = examples[i]
                // The marker rides its own top-aligned rail so it hugs the
                // first line even when the speaker centers on the pair.
                HStack(alignment: .top, spacing: 0) {
                    if showsMarkers {
                        Circle()
                            .fill(Palette.tertiary)
                            .frame(width: 5, height: 5)
                            // Optically centered on the source line's cap
                            // height, whatever the surface's font size.
                            .padding(.top, sourceSize * 0.45)
                            .padding(.trailing, 10)
                    }
                    HStack(alignment: speakerAlignment, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            ExplainCardText.bold(ex.source)
                                .font(.system(size: sourceSize))
                                .foregroundStyle(Palette.foreground)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                            ExplainCardText.bold(ex.target)
                                .font(.system(size: targetSize))
                                .foregroundStyle(Palette.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        speaker(ExplainCardText.plainSpoken(ex.source))
                    }
                }
            }
        }
    }
}

/// The card's typed insight note: lightbulb for patterns/register, warning
/// triangle for false friends. `fill` adapts to the surface it sits on.
struct ExplainInsightNote: View {
    let insight: ExplainCard.Insight
    var fill: Color = Palette.elevated.opacity(0.6)
    var iconTopPadding: CGFloat = 1

    var body: some View {
        let warning = insight.kind == .falseFriend
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                .font(.system(size: 12))
                .foregroundStyle(warning ? Color.orange.opacity(0.9) : Palette.tertiary)
                .padding(.top, iconTopPadding)
            Text(insight.text)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fill)
        )
    }
}

/// Loading placeholder shaped like the card it stands in for — a meanings
/// line plus two example pairs (the typical payload) — so the swap to real
/// content is a small settle, not a big grow.
struct ExplainCardShimmer: View {
    /// Five bar widths: the meanings line, then two example pairs (source
    /// over target). Wider on the app's roomier canvas.
    var widths: [CGFloat] = [230, 280, 220, 260, 200]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            bar(widths[0], 14)
            VStack(alignment: .leading, spacing: 5) {
                bar(widths[1], 12)
                bar(widths[2], 11)
            }
            VStack(alignment: .leading, spacing: 5) {
                bar(widths[3], 12)
                bar(widths[4], 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Palette.elevated)
            .frame(width: width, height: height)
    }
}
