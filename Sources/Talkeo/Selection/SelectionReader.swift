import AppKit

/// Reads the currently selected text on the system by trying strategies in order:
///   1. `AccessibilityStrategy` — non-destructive, covers native apps and (lazily)
///      Electron apps; never touches the clipboard.
///   2. `ClipboardStrategy` — race-safe transient Cmd+C, the safety net for
///      everything AX can't read.
///
/// If a newer read starts before an in-flight one finishes, the stale result is
/// dropped (a slow app must not pop a tooltip for an old selection). The
/// completion is always delivered on the main queue.
final class SelectionReader {
    private let strategies: [SelectionStrategy]
    private var generation = 0

    init(strategies: [SelectionStrategy] = [AccessibilityStrategy(), ClipboardStrategy()]) {
        self.strategies = strategies
    }

    func readSelectedText(completion: @escaping (String?) -> Void) {
        generation += 1
        let token = generation
        tryStrategies(strategies[...], token: token, completion: completion)
    }

    private func tryStrategies(
        _ remaining: ArraySlice<SelectionStrategy>,
        token: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard let head = remaining.first else {
            deliver(nil, token: token, completion: completion)
            return
        }
        head.readSelection { [weak self] result in
            guard let self else { return }
            if let result, !result.isEmpty {
                self.deliver(result, token: token, completion: completion)
            } else {
                self.tryStrategies(remaining.dropFirst(), token: token, completion: completion)
            }
        }
    }

    private func deliver(_ text: String?, token: Int, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.generation else { return }
            completion(text)
        }
    }
}
