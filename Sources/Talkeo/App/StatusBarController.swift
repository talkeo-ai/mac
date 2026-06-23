import AppKit

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let isTrusted: () -> Bool
    private let requestPermission: () -> Void
    private let isFloatingBarVisible: () -> Bool
    private let toggleFloatingBar: () -> Void
    private let isAutoHide: () -> Bool
    private let toggleAutoHide: () -> Void
    private let quit: () -> Void

    init(isTrusted: @escaping () -> Bool,
         requestPermission: @escaping () -> Void,
         isFloatingBarVisible: @escaping () -> Bool,
         toggleFloatingBar: @escaping () -> Void,
         isAutoHide: @escaping () -> Bool,
         toggleAutoHide: @escaping () -> Void,
         quit: @escaping () -> Void) {
        self.isTrusted = isTrusted
        self.requestPermission = requestPermission
        self.isFloatingBarVisible = isFloatingBarVisible
        self.toggleFloatingBar = toggleFloatingBar
        self.isAutoHide = isAutoHide
        self.toggleAutoHide = toggleAutoHide
        self.quit = quit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = buildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            let fallback = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Talkeo")
            fallback?.isTemplate = true
            button.image = fallback
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = MenuRefresher.shared
        MenuRefresher.shared.controller = self

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let perm = NSMenuItem(title: "Request Accessibility permission", action: #selector(MenuActions.requestPermission(_:)), keyEquivalent: "")
        perm.target = MenuActions.shared
        MenuActions.shared.controller = self
        menu.addItem(perm)

        menu.addItem(.separator())

        let bar = NSMenuItem(title: floatingBarLine(), action: #selector(MenuActions.toggleFloatingBar(_:)), keyEquivalent: "")
        bar.target = MenuActions.shared
        menu.addItem(bar)

        let auto = NSMenuItem(title: "Auto-hide bar", action: #selector(MenuActions.toggleAutoHide(_:)), keyEquivalent: "")
        auto.target = MenuActions.shared
        auto.state = isAutoHide() ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Talkeo", action: #selector(MenuActions.quit(_:)), keyEquivalent: "q")
        quitItem.target = MenuActions.shared
        menu.addItem(quitItem)

        return menu
    }

    fileprivate func statusLine() -> String {
        isTrusted() ? "Talkeo · ready" : "Talkeo · no permission"
    }

    fileprivate func floatingBarLine() -> String {
        isFloatingBarVisible() ? "Hide floating bar" : "Show floating bar"
    }

    fileprivate func refreshStatus() {
        guard let menu = statusItem.menu, let first = menu.items.first else { return }
        first.title = statusLine()
        if let bar = menu.items.first(where: { $0.action == #selector(MenuActions.toggleFloatingBar(_:)) }) {
            bar.title = floatingBarLine()
        }
        if let auto = menu.items.first(where: { $0.action == #selector(MenuActions.toggleAutoHide(_:)) }) {
            auto.state = isAutoHide() ? .on : .off
            auto.isEnabled = isFloatingBarVisible()
        }
    }

    fileprivate func triggerRequest() { requestPermission() }
    fileprivate func triggerToggleFloatingBar() { toggleFloatingBar() }
    fileprivate func triggerToggleAutoHide() { toggleAutoHide() }
    fileprivate func triggerQuit() { quit() }
}

// MARK: - Menu plumbing (target/action requires NSObject)

final class MenuActions: NSObject {
    static let shared = MenuActions()
    weak var controller: StatusBarController?

    @objc func requestPermission(_ sender: Any?) { controller?.triggerRequest() }
    @objc func toggleFloatingBar(_ sender: Any?) { controller?.triggerToggleFloatingBar() }
    @objc func toggleAutoHide(_ sender: Any?) { controller?.triggerToggleAutoHide() }
    @objc func quit(_ sender: Any?) { controller?.triggerQuit() }
}

final class MenuRefresher: NSObject, NSMenuDelegate {
    static let shared = MenuRefresher()
    weak var controller: StatusBarController?

    func menuWillOpen(_ menu: NSMenu) {
        controller?.refreshStatus()
    }
}
