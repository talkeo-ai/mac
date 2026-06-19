import AppKit

/// Reads the currently selected text on the system by trying strategies in order:
///   1. `AccessibilityStrategy` — non-destructive, covers native apps and (lazily)
///      Electron apps; never touches the clipboard. Can authoritatively report an
///      empty selection, which stops the pipeline.
///   2. `ClipboardStrategy` — race-safe transient Cmd+C, the safety net for
///      everything AX can't read.
///
/// Before any strategy runs, the frontmost app is checked against an exclusion
/// list (media/consumption apps) so those never receive a synthetic Cmd+C.
///
/// If a newer read starts before an in-flight one finishes, the stale result is
/// dropped. The completion is always delivered on the main queue.
final class SelectionReader {
    private let strategies: [SelectionStrategy]
    private let exclusions: AppExclusionList
    private let frontmostBundleID: () -> String?
    private var generation = 0

    init(
        strategies: [SelectionStrategy] = [AccessibilityStrategy(), ClipboardStrategy()],
        exclusions: AppExclusionList = AppExclusionList(),
        frontmostBundleID: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.strategies = strategies
        self.exclusions = exclusions
        self.frontmostBundleID = frontmostBundleID
    }

    func readSelectedText(completion: @escaping (String?) -> Void) {
        generation += 1
        let token = generation

        if exclusions.isExcluded(bundleID: frontmostBundleID()) {
            deliver(nil, token: token, completion: completion)
            return
        }

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
            switch result {
            case .text(let text) where !text.isEmpty:
                self.deliver(text, token: token, completion: completion)
            case .text, .empty:
                // Authoritative "nothing selected" — stop, do not fall through.
                self.deliver(nil, token: token, completion: completion)
            case .unsupported:
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
