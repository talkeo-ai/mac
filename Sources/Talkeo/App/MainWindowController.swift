import AppKit
import SwiftUI

/// Talkeo's main application window — the normal-app surface, as opposed to
/// the ambient selection UI (floating bar, popovers).
///
/// Talkeo runs as a regular app (Dock icon, Cmd-Tab). Closing this window
/// doesn't quit or hide the app: the ambient feature keeps running and the
/// Dock icon stays, Discord-style — clicking it brings the window back.
final class MainWindowController: NSObject {
    private var window: NSWindow?

    override init() {
        super.init()
        installMainMenuIfNeeded()
    }

    /// Order the main window front and focus the app.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Talkeo"
        // The hero header carries the brand, so the chrome stays minimal.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 380)
        window.backgroundColor = Palette.nsDynamic(0xFFFFFF, 0x1C1C1C)
        window.contentViewController = NSHostingController(rootView: MainWindowView())
        window.setFrameAutosaveName("TalkeoMainWindow")
        window.center()
        return window
    }

    /// The executable builds its menu bar in code (no nib). Without one the
    /// window has no Cmd+W/Cmd+Q and text fields lose the standard Edit
    /// shortcuts.
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Talkeo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Talkeo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Talkeo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

// MARK: - SwiftUI content

/// Home view of the main window. For now a brand hero plus a guide to the
/// floating-bar actions; settings, history and account will grow in here.
struct MainWindowView: View {
    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
                .padding(.bottom, 28)

            Divider().overlay(Palette.border)

            VStack(alignment: .leading, spacing: 14) {
                Text("From the floating bar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .textCase(.uppercase)
                    .kerning(0.6)

                actionRow(system: "character.bubble", title: "Translate",
                          detail: "Select text anywhere and get an instant translation.")
                actionRow(system: "wand.and.stars", title: "Improve",
                          detail: "Rewrite your English and replace it in place.")
                actionRow(system: "speaker.wave.2", title: "Listen",
                          detail: "Hear the selection with word-by-word highlight.")
                actionRow(system: "camera.viewfinder", title: "Capture",
                          detail: "Grab text from the screen (coming soon).")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 24)

            Spacer(minLength: 0)

            Text("Talkeo lives in the floating bar on the right edge of your screen and in the menu bar.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            BrandMark()
                .frame(width: 56, height: 56)
            Text("Talkeo")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Text("English, woven into your day.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
    }

    private func actionRow(system: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.foreground)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

/// Bundle brand icon with a symbol fallback, mirroring the status bar and
/// floating bar treatment.
private struct BrandMark: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
    }
}

// MARK: - Xcode Preview

#Preview("Main window") {
    MainWindowView()
        .frame(width: 520, height: 440)
}
