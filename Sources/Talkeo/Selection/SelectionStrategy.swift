import Foundation

/// One way of reading the current selection. Strategies are tried in order; a
/// `nil` result means "I couldn't get it, fall through to the next one".
///
/// Completions may be delivered synchronously (Accessibility) or asynchronously
/// (clipboard polling). `SelectionReader` always re-dispatches the final result
/// to the main queue before handing it to the UI.
protocol SelectionStrategy {
    func readSelection(completion: @escaping (String?) -> Void)
}
