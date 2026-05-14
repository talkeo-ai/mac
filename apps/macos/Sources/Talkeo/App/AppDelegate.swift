import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var mouseMonitor: MouseUpMonitor!
    private var tooltip: TooltipPanel!
    private let reader = SelectionReader()
    private let permission = AccessibilityPermission()

    func applicationDidFinishLaunching(_ notification: Notification) {
        tooltip = TooltipPanel()
        statusBar = StatusBarController(
            isTrusted: { [weak self] in self?.permission.isTrusted ?? false },
            requestPermission: { [weak self] in self?.permission.requestIfNeeded() },
            quit: { NSApp.terminate(nil) }
        )

        mouseMonitor = MouseUpMonitor { [weak self] in
            self?.handleSelection()
        }

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
        let anchor = NSEvent.mouseLocation
        reader.readSelectedText { [weak self] text in
            guard let self, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self?.tooltip.hide()
                return
            }
            self.tooltip.show(text: text, near: anchor)
        }
    }
}
