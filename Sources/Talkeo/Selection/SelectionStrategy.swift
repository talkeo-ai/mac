import Foundation

/// Outcome of asking a strategy for the current selection.
///   - `.text`        — there is a selection; show it.
///   - `.empty`       — authoritative: there is NO selection. Stop; show nothing,
///                      and do NOT fall through to a more invasive strategy.
///   - `.unsupported` — the strategy can't tell. Try the next strategy.
///
/// The `.empty` vs `.unsupported` distinction is what lets us suppress the tooltip
/// when an app authoritatively reports an empty selection (e.g. an empty drag in a
/// real text field) without breaking apps where we simply can't read the selection
/// (e.g. pure Chrome web content), which must keep falling through to the clipboard.
enum SelectionResult: Equatable {
    case text(String)
    case empty
    case unsupported
}

/// One way of reading the current selection. Strategies are tried in order; a
/// `.unsupported` result falls through to the next one.
///
/// Completions may be delivered synchronously (Accessibility) or asynchronously
/// (clipboard polling). `SelectionReader` always re-dispatches the final result
/// to the main queue before handing it to the UI.
protocol SelectionStrategy {
    func readSelection(completion: @escaping (SelectionResult) -> Void)
}
