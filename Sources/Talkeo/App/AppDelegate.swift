import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var mouseMonitor: MouseUpMonitor!
    private var quickTranslate: QuickTranslatePanel!
    private var floatingBar: FloatingBarPanel!
    private let reader = SelectionReader()
    private let permission = AccessibilityPermission()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Compact translation popover. The full TranslatePanel and the selection
        // tooltip both exist in the tree but stay disconnected for now.
        quickTranslate = QuickTranslatePanel()

        // Selection UI is the persistent right-edge floating bar; its Translate
        // reads the current selection on demand.
        floatingBar = FloatingBarPanel()
        floatingBar.onTranslate = { [weak self] in self?.translateCurrentSelection() }
        floatingBar.show()

        statusBar = StatusBarController(
            isTrusted: { [weak self] in self?.permission.isTrusted ?? false },
            requestPermission: { [weak self] in self?.permission.requestIfNeeded() },
            isFloatingBarVisible: { [weak self] in self?.floatingBar.isVisible ?? false },
            toggleFloatingBar: { [weak self] in self?.toggleFloatingBar() },
            isAutoHide: { [weak self] in self?.floatingBar.isAutoHide ?? false },
            toggleAutoHide: { [weak self] in
                guard let self else { return }
                self.floatingBar.setAutoHide(!self.floatingBar.isAutoHide)
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
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
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
}
