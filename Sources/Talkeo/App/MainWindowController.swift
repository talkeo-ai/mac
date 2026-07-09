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
        // Don't let AppKit hand initial key focus to a control (it draws a
        // focus ring); async because SwiftUI assigns focus after key.
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
        // The SPA draws its own chrome (icon rail + floating content card);
        // the titlebar is just the traffic lights floating over it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        window.backgroundColor = Palette.nsDynamic(0xF7F7F8, 0x161616)
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

/// Sections of the main window's left-hand rail: AI conversation (chat,
/// voice teacher), the floating bar's tools, the user-facing record
/// (transcript, estimated English level), and settings pinned at the bottom.
enum MainSection: String, CaseIterable, Identifiable {
    case chat, teacher, translate, improve, listen, capture, transcript, englishLevel, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .teacher: return "Teacher"
        case .translate: return "Translate"
        case .improve: return "Improve"
        case .listen: return "Listen"
        case .capture: return "Capture"
        case .transcript: return "Transcript"
        case .englishLevel: return "English level"
        case .settings: return "Settings"
        }
    }

    /// Short label for the narrow icon rail (the page keeps the full title).
    var railTitle: String {
        switch self {
        case .englishLevel: return "Level"
        default: return title
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .teacher: return "graduationcap.fill"
        case .translate: return "character.bubble.fill"
        case .improve: return "text.badge.checkmark"
        case .listen: return "speaker.wave.2.fill"
        case .capture: return "text.viewfinder"
        case .transcript: return "waveform"
        case .englishLevel: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }

    static let ai: [MainSection] = [.chat, .teacher]
    static let tools: [MainSection] = [.translate, .improve, .listen, .capture]
    static let progress: [MainSection] = [.transcript, .englishLevel]
}

// MARK: - Root view (SPA: icon rail + floating content card)

struct MainWindowView: View {
    @State private var selection: MainSection = .translate

    /// Window backdrop — the rail sits directly on it and the content card
    /// floats over it (Palette.surface is one step lighter, so the card
    /// reads as raised in both appearances).
    private static let backdrop = Palette.dynamic(0xF7F7F8, 0x161616)

    var body: some View {
        HStack(spacing: 0) {
            rail

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                )
                .padding([.top, .trailing, .bottom], 14)
        }
        .background(Self.backdrop)
        // Full-bleed SPA: the backdrop owns the titlebar strip too; the rail's
        // top padding keeps the brand clear of the traffic lights.
        .ignoresSafeArea()
    }

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(MainSection.ai) { item in
                RailItem(item: item, isSelected: selection == item) { selection = item }
            }

            railDivider

            ForEach(MainSection.tools) { item in
                RailItem(item: item, isSelected: selection == item) { selection = item }
            }

            railDivider

            ForEach(MainSection.progress) { item in
                RailItem(item: item, isSelected: selection == item) { selection = item }
            }

            Spacer(minLength: 0)

            RailItem(item: .settings, isSelected: selection == .settings) { selection = .settings }
                .padding(.bottom, 14)
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .frame(width: 92)
        .frame(maxHeight: .infinity)
    }

    private var railDivider: some View {
        Divider()
            .overlay(Palette.border)
            .frame(width: 30)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .chat:
            ToolPage(
                section: .chat,
                summary: "Ask anything, ChatGPT-style — a chat that knows you're learning English.",
                steps: [],
                comingSoon: true
            )
        case .teacher:
            ToolPage(
                section: .teacher,
                summary: "Talk out loud with an AI teacher — real voice conversation, adapted to your level.",
                steps: [],
                comingSoon: true
            )
        case .translate:
            TranslatePage()
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
            ToolPage(
                section: .transcript,
                summary: "Real-time transcription of what you hear — live subtitles for meetings, videos and calls.",
                steps: [],
                comingSoon: true
            )
        case .englishLevel:
            EnglishLevelPage()
        case .settings:
            ToolPage(
                section: .settings,
                summary: "Providers, voices and behavior — configure how Talkeo works.",
                steps: [],
                comingSoon: true
            )
        }
    }
}

/// One entry of the icon rail: big icon with its label underneath, monochrome.
/// Selected lifts to full foreground on a soft tile; the rest stay muted.
private struct RailItem: View {
    let item: MainSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(item.railTitle)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Palette.foreground : Palette.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected || isHover ? Palette.elevated : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .animation(.easeOut(duration: 0.12), value: isHover)
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
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(section: section, subtitle: summary)

                if comingSoon {
                    Text("Coming soon")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Palette.elevated))
                } else {
                    StepsList(steps: steps)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Numbered how-to steps shared by the tool pages.
private struct StepsList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .center, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.foreground)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.elevated))
                    Text(step)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.foreground)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.elevated)
                )
            }
        }
    }
}

// MARK: - Translate

/// The translate tool page: how it works plus the local translation history
/// (the history lives here, where it's produced — Transcript is a different,
/// future feature: real-time transcription).
private struct TranslatePage: View {
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    section: .translate,
                    subtitle: "Instant translation of whatever you select, in any app."
                )

                StepsList(steps: [
                    "Select text anywhere — browser, editor, terminal.",
                    "Click the translate button in the floating bar.",
                    "Read the translation in place; it's saved to your history."
                ])

                Text("History".uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.1)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 8)

                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing here yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.foreground)
                        Text("Translations you make from the floating bar will show up here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.elevated)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { entries = LocalHistoryStore.shared.all() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.source)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.foreground)
                .lineLimit(2)
            Text(entry.target)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text("\(entry.detectedLang.uppercased()) → \(entry.translateLang.uppercased())")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().stroke(Palette.border, lineWidth: 1))
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.elevated)
        )
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
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    section: .englishLevel,
                    subtitle: "Talkeo estimates your level from how you actually use English."
                )

                HStack(spacing: 8) {
                    ForEach(Self.levels, id: \.self) { level in
                        Text(level)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Palette.elevated)
                            )
                    }
                }
                .frame(maxWidth: 560)

                Text("Not enough data yet. Keep translating, improving and listening — your estimated level will appear here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared page chrome

private struct PageHeader: View {
    let section: MainSection
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.elevated)
                Image(systemName: section.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
            .frame(width: 54, height: 54)

            Text(section.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Palette.foreground)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - Xcode Preview

#Preview("Main window") {
    MainWindowView()
        .frame(width: 1100, height: 700)
}
