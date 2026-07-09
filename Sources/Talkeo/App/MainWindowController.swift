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
        // AppKit hands initial key focus to the first toolbar control — the
        // sidebar toggle — which draws a focus ring on it. Clear it back to
        // the window; async because SwiftUI assigns focus after key.
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Talkeo"
        // The sidebar carries the app's identity, so the chrome stays minimal.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 500)
        window.backgroundColor = Palette.nsDynamic(0xFFFFFF, 0x1C1C1C)
        window.contentViewController = NSHostingController(rootView: MainWindowView())
        // Open filling the screen (minus menu bar / Dock), like a full-size SPA.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrame(screen.visibleFrame, display: true)
        } else {
            window.center()
        }
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

// MARK: - Navigation

/// Sections of the main window's left-hand menu. The first four mirror the
/// floating bar's actions; the last two are the user-facing record (transcript
/// of past translations, estimated English level).
enum MainSection: String, CaseIterable, Identifiable {
    case translate, improve, listen, capture, transcript, englishLevel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: return "Translate"
        case .improve: return "Improve"
        case .listen: return "Listen"
        case .capture: return "Capture"
        case .transcript: return "Transcript"
        case .englishLevel: return "English level"
        }
    }

    var icon: String {
        switch self {
        case .translate: return "character.bubble"
        case .improve: return "wand.and.stars"
        case .listen: return "speaker.wave.2"
        case .capture: return "camera.viewfinder"
        case .transcript: return "list.bullet.rectangle"
        case .englishLevel: return "chart.bar"
        }
    }

    static let tools: [MainSection] = [.translate, .improve, .listen, .capture]
    static let progress: [MainSection] = [.transcript, .englishLevel]
}

// MARK: - Root view (SPA: sidebar + detail)

struct MainWindowView: View {
    @State private var selection: MainSection? = .translate

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Tools") {
                    ForEach(MainSection.tools) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                Section("Your English") {
                    ForEach(MainSection.progress) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .translate {
        case .translate:
            ToolPage(
                section: .translate,
                summary: "Instant translation of whatever you select, in any app.",
                steps: [
                    "Select text anywhere — browser, editor, terminal.",
                    "Click the translate button in the floating bar.",
                    "Read the translation in place; it's saved to your transcript."
                ]
            )
        case .improve:
            ToolPage(
                section: .improve,
                summary: "Rewrite your English and replace it right where you wrote it.",
                steps: [
                    "Select something you wrote.",
                    "Click the improve button in the floating bar.",
                    "Review the diff and replace in place (or copy)."
                ]
            )
        case .listen:
            ToolPage(
                section: .listen,
                summary: "Hear any text out loud with word-by-word highlight.",
                steps: [
                    "Select the text you want to hear.",
                    "Click the listen button in the floating bar.",
                    "Follow along as each word lights up."
                ]
            )
        case .capture:
            ToolPage(
                section: .capture,
                summary: "Grab text straight from the screen — even where you can't select.",
                steps: [],
                comingSoon: true
            )
        case .transcript:
            TranscriptPage()
        case .englishLevel:
            EnglishLevelPage()
        }
    }
}

// MARK: - Tool pages

/// Detail page for one of the floating-bar tools. Today these document the
/// tool; they'll grow direct input (paste text here, no selection needed).
private struct ToolPage: View {
    let section: MainSection
    let summary: String
    let steps: [String]
    var comingSoon: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(icon: section.icon, title: section.title, subtitle: summary)

                if comingSoon {
                    Text("Coming soon")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.elevated))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Palette.elevated))
                                Text(step)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.foreground)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Transcript

/// Everything the user has translated, straight from the local history store.
private struct TranscriptPage: View {
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    icon: MainSection.transcript.icon,
                    title: MainSection.transcript.title,
                    subtitle: "Everything you've translated with Talkeo."
                )

                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing here yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.foreground)
                        Text("Translations you make from the floating bar will show up here.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.top, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            TranscriptRow(entry: entry)
                            if entry.id != entries.last?.id {
                                Divider().overlay(Palette.border)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { entries = LocalHistoryStore.shared.all() }
    }
}

private struct TranscriptRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.source)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.foreground)
                .lineLimit(2)
            Text(entry.target)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("\(entry.detectedLang.uppercased()) → \(entry.translateLang.uppercased())")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Palette.elevated))
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - English level

/// The user's estimated English level. No signal is collected yet, so this is
/// the honest empty state over the CEFR scale; estimation from real usage
/// (translations, improvements) comes later.
private struct EnglishLevelPage: View {
    private static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    icon: MainSection.englishLevel.icon,
                    title: MainSection.englishLevel.title,
                    subtitle: "Talkeo estimates your level from how you actually use English."
                )

                HStack(spacing: 6) {
                    ForEach(Self.levels, id: \.self) { level in
                        Text(level)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.elevated))
                    }
                }
                .frame(maxWidth: 480)

                Text("Not enough data yet. Keep translating, improving and listening — your estimated level will appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared page chrome

private struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.foreground)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.elevated)
                )
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - Xcode Preview

#Preview("Main window") {
    MainWindowView()
        .frame(width: 1100, height: 700)
}
