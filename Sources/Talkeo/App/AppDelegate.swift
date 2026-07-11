import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var mouseMonitor: MouseUpMonitor!
    private var quickTranslate: QuickTranslatePanel!
    private var floatingBar: FloatingBarPanel!
    private var mainWindow: MainWindowController!
    private var capturePreview: CapturePreviewPanel!
    private let screenCapturer: ScreenCapturing = CLIScreenCapturer()
    private let reader = SelectionReader()
    private let permission = AccessibilityPermission()
    private let settings: SettingsStore = LocalSettingsStore.shared

    /// Where the next capture's recognized text lands: the popover (floating
    /// bar's Capture) or the main window (a page's own Capture button).
    /// Captures are one-at-a-time, so a single flag carries the origin
    /// through the async crosshair → preview → verb hop.
    private enum CaptureDestination { case popover, mainWindow }
    private var captureDestination: CaptureDestination = .popover

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Compact translate + learn popover. (The selection tooltip still exists
        // in the tree but stays disconnected for now.)
        quickTranslate = QuickTranslatePanel()

        // The main app window: opened at launch (normal-app behavior), from the
        // bar's brand button, and on Dock/Finder reopen.
        mainWindow = MainWindowController()
        // The pages' Capture buttons run the same TCC-gated flow as the
        // floating bar's; the preview's verbs then route the recognized text
        // back into the main window instead of the popover.
        mainWindow.onPageCapture = { [weak self] in self?.captureScreen(destination: .mainWindow) }

        // Selection UI is the persistent right-edge floating bar; its Translate
        // reads the current selection on demand.
        floatingBar = FloatingBarPanel()
        floatingBar.onOpenApp = { [weak self] in self?.mainWindow.show() }
        floatingBar.onTranslate = { [weak self] in self?.translateCurrentSelection() }
        floatingBar.onImprove = { [weak self] in self?.improveCurrentSelection() }
        floatingBar.onListen = { [weak self] in self?.listenCurrentSelection() }
        floatingBar.onCapture = { [weak self] in self?.captureScreen() }

        // Capture's verbs land in the popover (bar-initiated) or the main
        // window (page-initiated) — the preview resolves WHICH text (in-image
        // selection vs. full transcript); the routing lives here where all
        // the panels are owned.
        capturePreview = CapturePreviewPanel()
        capturePreview.onTranslate = { [weak self] text in self?.routeCapturedText(text, verb: .translate) }
        capturePreview.onImprove = { [weak self] text in self?.routeCapturedText(text, verb: .improve) }
        capturePreview.onListen = { [weak self] text in self?.routeCapturedText(text, verb: .listen) }
        // An auto-hiding bar must never retract from under its open popover.
        quickTranslate.onVisibilityChange = { [weak self] visible in
            self?.floatingBar.setHoldRevealed(visible)
        }
        // "Full history" in the popover opens the app's Translate view with its
        // history drawer open.
        quickTranslate.onOpenFullHistory = { [weak self] in self?.mainWindow.openTranslateHistory() }
        // "Full history" in Improve's compose opens the app's Improve view
        // with its history drawer open (past rewrites live there, not in the
        // popover) — same deep-link shape as Translate's.
        quickTranslate.onOpenImproveHistory = { [weak self] in self?.mainWindow.openImproveHistory() }
        // "Full history" in Listen's compose opens the app's Listen view with
        // its history drawer open (past listens live there, not the popover).
        quickTranslate.onOpenFullListenHistory = { [weak self] in self?.mainWindow.openListenHistory() }
        // Restore persisted preferences before the first show, so an auto-hiding
        // bar starts retracted instead of flashing revealed.
        floatingBar.setAutoHide(settings.barAutoHide)
        floatingBar.show()

        statusBar = StatusBarController(
            isTrusted: { [weak self] in self?.permission.isTrusted ?? false },
            requestPermission: { [weak self] in self?.permission.requestIfNeeded() },
            isFloatingBarVisible: { [weak self] in self?.floatingBar.isVisible ?? false },
            toggleFloatingBar: { [weak self] in self?.toggleFloatingBar() },
            isAutoHide: { [weak self] in self?.floatingBar.isAutoHide ?? false },
            toggleAutoHide: { [weak self] in
                guard let self else { return }
                let value = !self.floatingBar.isAutoHide
                self.floatingBar.setAutoHide(value)
                self.settings.barAutoHide = value
            },
            quit: { NSApp.terminate(nil) }
        )

        mouseMonitor = MouseUpMonitor(
            onSelection: { [weak self] in self?.handleSelection() },
            onDeselect: { [weak self] in self?.floatingBar.setHasSelection(false) }
        )

        if permission.isTrusted {
            mouseMonitor.start()
        } else {
            permission.requestIfNeeded()
            startMonitorWhenTrusted()
        }

        mainWindow.show()
    }

    /// Reopening from the Finder or the Dock icon brings the main window back,
    /// like a normal app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    private func startMonitorWhenTrusted() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.permission.isTrusted {
                self.mouseMonitor.start()
                timer.invalidate()
            }
        }
    }

    private func handleSelection() {
        // Never react to selections inside Talkeo's own windows
        // (e.g. painting text in the translate panel) — only on other apps.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        reader.readSelectedText { [weak self] text in
            guard let self else { return }
            let hasText = (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            self.floatingBar.setHasSelection(hasText)
        }
    }

    private func toggleFloatingBar() {
        if floatingBar.isVisible {
            floatingBar.hide()
        } else {
            floatingBar.show()
        }
    }

    /// Reads the selection in the frontmost app and, if any, opens the quick
    /// translation popover. The bar has no captured text, so it reads on demand.
    private func translateCurrentSelection() {
        reader.readSelectedText { [weak self] text in
            guard let self else { return }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.quickTranslate.show(text: text)
            } else {
                // Nothing selected — open the local history instead.
                self.quickTranslate.showHistory()
            }
        }
    }

    /// Reads the selection in the frontmost app and, if any, opens the improve
    /// popover. With nothing selected it opens improve's compose/history
    /// instead, mirroring Translate.
    private func improveCurrentSelection() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Capture terminal-ness now (the frontmost app owns the selection); it
        // turns Replace into a safe Copy since terminals can't be edited in place.
        let isTerminal = SelectionReplacer.isTerminal(frontmost)
        reader.readSelectedText { [weak self] text in
            guard let self else { return }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.quickTranslate.improve(text: text, targetIsTerminal: isTerminal)
            } else {
                // Nothing selected — open the compose box + recent rewrites.
                self.quickTranslate.showImproveHistory()
            }
        }
    }

    /// Reads the selection in the frontmost app and, if any, opens the listen
    /// (TTS) popover. Nothing selected opens Listen's own history instead,
    /// mirroring `translateCurrentSelection()`.
    private func listenCurrentSelection() {
        reader.readSelectedText { [weak self] text in
            guard let self else { return }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.quickTranslate.listen(text: text)
            } else {
                self.quickTranslate.showListenHistory()
            }
        }
    }

    /// Route a capture's recognized text where the capture was initiated
    /// from: the popover's entry points (floating bar) or the tapped verb's
    /// page in the main window.
    private func routeCapturedText(_ text: String, verb: TextVerb) {
        switch captureDestination {
        case .popover:
            switch verb {
            case .translate: quickTranslate.show(text: text)
            case .improve: quickTranslate.improve(text: text)
            case .listen: quickTranslate.listen(text: text)
            }
        case .mainWindow:
            mainWindow.openPage(verb: verb, capturedText: text)
        }
    }

    /// Runs the interactive region capture and opens the Live Text preview.
    /// Talkeo's own chrome (popover, an earlier preview, the bar — plus the
    /// main window for a page-initiated capture, since it likely fills the
    /// screen) hides first so it can't end up inside the screenshot;
    /// everything restores whatever the outcome.
    private func captureScreen(destination: CaptureDestination = .popover) {
        guard ScreenRecordingPermission.ensureAccess() else {
            showScreenRecordingDeniedAlert()
            return
        }
        captureDestination = destination
        quickTranslate.hide()
        capturePreview.hide() // a re-capture supersedes an open preview
        let mainWasVisible = destination == .mainWindow && mainWindow.isWindowVisible
        if mainWasVisible { mainWindow.hideForCapture() }
        let barWasVisible = floatingBar.isVisible
        if barWasVisible { floatingBar.hide() } // poll-proof: evaluate() guards on featureVisible
        screenCapturer.captureInteractive { [weak self] outcome in
            guard let self else { return }
            if barWasVisible { self.floatingBar.show() }
            if mainWasVisible { self.mainWindow.show() }
            switch outcome {
            case .cancelled:
                break // Esc in the crosshair — a user choice, stay silent
            case .failed(let reason):
                NSLog("Capture failed: %@", reason) // rare decode failure; silent for now
            case .image(let image):
                self.capturePreview.show(image: image)
            }
        }
    }

    /// The one-shot system prompt was already consumed by the time we get
    /// here (CGRequestScreenCaptureAccess only ever shows it once); from now
    /// on the user must flip the toggle manually. The app is LSUIElement, so
    /// activate before the modal or it opens behind the frontmost app — the
    /// single sanctioned NSApp.activate in the codebase, acceptable because a
    /// permission modal IS a context switch.
    private func showScreenRecordingDeniedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Talkeo captures a region of the screen to read its text. "
            + "Enable Talkeo under Privacy & Security → Screen Recording, then relaunch Talkeo."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
