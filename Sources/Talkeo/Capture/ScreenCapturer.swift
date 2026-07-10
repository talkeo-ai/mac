import AppKit

/// Outcome of one interactive capture. Cancel (Esc in the system UI) is a
/// first-class case, not an error — it's the normal "never mind" path.
enum CaptureOutcome {
    case image(NSImage)
    case cancelled
    case failed(String)
}

/// Seam for the interactive region capture, mirroring `SelectionStrategy`:
/// callers talk to the protocol so tests can fake the system UI, and the
/// implementation can later swap to ScreenCaptureKit without touching them.
protocol ScreenCapturing: AnyObject {
    /// Runs the system's interactive capture UI. The completion always lands
    /// on the main queue. Re-entrant calls while a capture is already up are
    /// dropped — their completion never fires.
    func captureInteractive(completion: @escaping (CaptureOutcome) -> Void)
}

/// `/usr/sbin/screencapture -i` — the native crosshair/window picker, with
/// Retina resolution and Esc-to-cancel for free. Spawning the system CLI
/// keeps us on public API (the alternatives are the deprecated CGWindowList
/// captures or ScreenCaptureKit plus a hand-rolled region-selection overlay)
/// while the selection UX stays exactly the ⌘⇧4 the user already knows.
final class CLIScreenCapturer: ScreenCapturing {
    /// How the tool gets run — injected so tests can fake it by writing (or
    /// not writing) the output file and invoking the exit callback; the same
    /// constructor-injection seam the other system boundaries use.
    typealias Launcher = (_ arguments: [String], _ onExit: @escaping (Int32) -> Void) -> Void

    private let launch: Launcher
    private var isCapturing = false

    init(launch: @escaping Launcher = CLIScreenCapturer.launchProcess) {
        self.launch = launch
    }

    func captureInteractive(completion: @escaping (CaptureOutcome) -> Void) {
        guard !isCapturing else { return } // e.g. a double-click on the bar button
        isCapturing = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkeo-capture-\(UUID().uuidString).png")
        // -i interactive region/window selection · -o no window shadow in
        // window mode (the shadow padding is noise for OCR) · -t png pinned
        // so the format can't drift with OS defaults. No -x: the shutter
        // sound is the feedback users expect from the native crosshair. No
        // -r: the 144dpi metadata screencapture stamps on Retina makes
        // `NSImage.size` come back in points, which the preview's sizing
        // relies on.
        launch(["-i", "-o", "-t", "png", url.path]) { [weak self] _ in
            // The exit callback arrives on a background queue. Do the file
            // I/O here, then hop to main. Cancellation is detected by the
            // ABSENCE of the file, not the exit status — screencapture's
            // codes aren't contractual.
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self?.isCapturing = false
                guard let data else {
                    completion(.cancelled)
                    return
                }
                // Decode from the already-read bytes: NSImage(contentsOf:)
                // maps the file lazily, which would race the delete above.
                guard let image = NSImage(data: data) else {
                    completion(.failed("Could not decode the capture"))
                    return
                }
                completion(.image(image))
            }
        }
    }

    private static func launchProcess(_ arguments: [String], onExit: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        // The handler closure captures `process`, keeping it alive for the run.
        process.terminationHandler = { onExit($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            onExit(-1)
        }
    }
}

/// Screen Recording is TCC-gated like Accessibility, and attributed to the
/// *responsible process* (Talkeo) even though the pixels are read by the
/// spawned CLI. There is no Info.plist usage-description key for it — the
/// system prompt is entirely OS-managed and only ever shown once.
enum ScreenRecordingPermission {
    /// Preflight → one-shot system prompt → re-check. False means the user
    /// must flip the toggle manually in System Settings.
    static func ensureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
