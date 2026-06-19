import AppKit
import QuartzCore

/// Race-safe transient copy: snapshots the pasteboard, triggers a copy, reads the
/// result, and restores the snapshot **only if nobody else wrote in the meantime**.
///
/// The original implementation always restored in a `defer`, which silently
/// destroyed the user's clipboard in the dominant case (select text, then press
/// Cmd+C while the snapshot window was open). The fix:
///   1. Poll `changeCount` instead of waiting a fixed delay — adapts to slow apps.
///   2. Restore only when the current `changeCount` equals the count produced by
///      our own copy. If it advanced, the user/another app owns the clipboard now.
///   3. Two-write detection: if more than one write lands during the wait, skip
///      restore conservatively — we never destroy fresh data, we only occasionally
///      decline to restore stale data.
final class PasteboardCopyService {
    private let pasteboard: PasteboardProtocol
    private let triggerCopy: () -> Void
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - pasteboard: pasteboard to operate on (real = `NSPasteboard.general`).
    ///   - triggerCopy: performs the copy (real = synthetic Cmd+C).
    ///   - now: monotonic clock (injectable for tests).
    ///   - schedule: defers a closure by an interval (real = main-queue asyncAfter).
    init(
        pasteboard: PasteboardProtocol,
        triggerCopy: @escaping () -> Void,
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        pollInterval: TimeInterval = 0.015,
        timeout: TimeInterval = 0.4
    ) {
        self.pasteboard = pasteboard
        self.triggerCopy = triggerCopy
        self.now = now
        self.schedule = schedule
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Performs the transient copy and delivers the copied string (or nil).
    func transientCopy(completion: @escaping (String?) -> Void) {
        let snapshot = pasteboard.snapshotItems()
        let priorCount = pasteboard.changeCount

        triggerCopy()

        poll(priorCount: priorCount, snapshot: snapshot, deadline: now() + timeout, completion: completion)
    }

    private func poll(
        priorCount: Int,
        snapshot: [[NSPasteboard.PasteboardType: Data]],
        deadline: TimeInterval,
        completion: @escaping (String?) -> Void
    ) {
        let current = pasteboard.changeCount

        if current > priorCount {
            // A write landed. We presume it is ours (the copy we triggered).
            let ourCount = current
            let types = pasteboard.availableTypes()
            let text = pasteboard.string(forType: .string)

            // Two-write detection: if the count jumped by more than one since the
            // snapshot, another write interleaved with ours — don't risk restoring
            // over fresh data.
            let singleWrite = (ourCount == priorCount + 1)

            // Conditional restore: only if nobody wrote after our copy. Runs even
            // for a file payload — a Finder file copy dirtied the user's clipboard
            // and must be undone — we only suppress the tooltip, not the restore.
            if singleWrite, pasteboard.changeCount == ourCount {
                pasteboard.restore(items: snapshot)
            }

            // A file drag (Finder) copies a file reference, not a text selection.
            // Reject by type, not by string-parsing: a path string is a legitimate
            // text selection in a terminal.
            if Self.isFilePayload(types) {
                completion(nil)
                return
            }

            completion(nonEmpty(text))
            return
        }

        guard now() < deadline else {
            // Nothing was copied (no selection / slow app). Snapshot == current,
            // so there is nothing to restore.
            completion(nil)
            return
        }

        schedule(pollInterval) { [weak self] in
            self?.poll(priorCount: priorCount, snapshot: snapshot, deadline: deadline, completion: completion)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func isFilePayload(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let fileTypes: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ]
        return types.contains { fileTypes.contains($0) }
    }
}
