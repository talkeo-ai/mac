import AppKit

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let isTrusted: () -> Bool
    private let requestPermission: () -> Void
    private let quit: () -> Void

    init(isTrusted: @escaping () -> Bool,
         requestPermission: @escaping () -> Void,
         quit: @escaping () -> Void) {
        self.isTrusted = isTrusted
        self.requestPermission = requestPermission
        self.quit = quit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = buildMenu()
    }

    private func configureButton() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "TalkeoSelect")
            image?.isTemplate = true
            button.image = image
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

        let perm = NSMenuItem(title: "Solicitar permiso de Accesibilidad", action: #selector(MenuActions.requestPermission(_:)), keyEquivalent: "")
        perm.target = MenuActions.shared
        MenuActions.shared.controller = self
        menu.addItem(perm)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TalkeoSelect", action: #selector(MenuActions.quit(_:)), keyEquivalent: "q")
        quitItem.target = MenuActions.shared
        menu.addItem(quitItem)

        return menu
    }

    fileprivate func statusLine() -> String {
        isTrusted() ? "TalkeoSelect · listo" : "TalkeoSelect · sin permiso"
    }

    fileprivate func refreshStatus() {
        guard let menu = statusItem.menu, let first = menu.items.first else { return }
        first.title = statusLine()
    }

    fileprivate func triggerRequest() { requestPermission() }
    fileprivate func triggerQuit() { quit() }
}

// MARK: - Menu plumbing (target/action requires NSObject)

final class MenuActions: NSObject {
    static let shared = MenuActions()
    weak var controller: StatusBarController?

    @objc func requestPermission(_ sender: Any?) { controller?.triggerRequest() }
    @objc func quit(_ sender: Any?) { controller?.triggerQuit() }
}

final class MenuRefresher: NSObject, NSMenuDelegate {
    static let shared = MenuRefresher()
    weak var controller: StatusBarController?

    func menuWillOpen(_ menu: NSMenu) {
        controller?.refreshStatus()
    }
}
