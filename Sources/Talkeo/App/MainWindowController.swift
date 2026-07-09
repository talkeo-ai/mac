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
        // The SPA draws its own chrome (custom sidebar, full-bleed content);
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

/// Sections of the main window's left-hand menu. The first four mirror the
/// floating bar's actions; the last two are the user-facing record (transcript
/// of past translations, estimated English level).
///
/// Each section owns a solid accent color (Duolingo-style colorful menu): the
/// icon always sits on its colored tile, and the selected row picks the color
/// up in its background/label.
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
        case .translate: return "character.bubble.fill"
        case .improve: return "wand.and.stars"
        case .listen: return "speaker.wave.2.fill"
        case .capture: return "camera.viewfinder"
        case .transcript: return "list.bullet.rectangle.fill"
        case .englishLevel: return "chart.bar.fill"
        }
    }

    var accent: Color {
        switch self {
        case .translate: return Palette.dynamic(0x1C7CF2, 0x3F97FF)   // blue
        case .improve: return Palette.dynamic(0x8B5CF6, 0xA78BFA)     // violet
        case .listen: return Palette.dynamic(0x16A34A, 0x34C97A)      // green
        case .capture: return Palette.dynamic(0xF97316, 0xFF9040)     // orange
        case .transcript: return Palette.dynamic(0x0D9DA8, 0x2BC4CF)  // teal
        case .englishLevel: return Palette.dynamic(0xE0A800, 0xF5C518) // gold
        }
    }

    static let tools: [MainSection] = [.translate, .improve, .listen, .capture]
    static let progress: [MainSection] = [.transcript, .englishLevel]
}

// MARK: - Root view (SPA: custom solid sidebar + detail)

struct MainWindowView: View {
    @State private var selection: MainSection = .translate

    /// Sidebar surface, one step darker than the content like the reference
    /// SPAs (solid, no vibrancy material).
    private static let sidebarBackground = Palette.dynamic(0xF7F7F8, 0x161616)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Palette.border)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
        }
        // Full-bleed SPA: the sidebar owns the titlebar strip too; the brand
        // header's top padding keeps it clear of the traffic lights.
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brand
                .padding(.horizontal, 12)
                .padding(.top, 44)
                .padding(.bottom, 24)

            sectionLabel("Tools")
            ForEach(MainSection.tools) { item in
                SidebarRow(item: item, isSelected: selection == item) { selection = item }
            }

            sectionLabel("Your English")
                .padding(.top, 20)
            ForEach(MainSection.progress) { item in
                SidebarRow(item: item, isSelected: selection == item) { selection = item }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 248)
        .frame(maxHeight: .infinity)
        .background(Self.sidebarBackground)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(cornerRadius: 8)
                .frame(width: 30, height: 30)
            Text("talkeo")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.foreground)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(1.1)
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
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

/// One entry of the sidebar menu: colored icon tile + bold label, with a solid
/// selected state (tinted fill + accent border) and a quiet hover.
private struct SidebarRow: View {
    let item: MainSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(item.accent)
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? item.accent : Palette.muted)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? item.accent.opacity(0.13) : (isHover ? Palette.elevated : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? item.accent.opacity(0.5) : Color.clear, lineWidth: 1.5)
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(section.accent))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .center, spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(section.accent))
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
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 64)
            .padding(.bottom, 48)
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
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    section: .transcript,
                    subtitle: "Everything you've translated with Talkeo."
                )

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
                            TranscriptRow(entry: entry)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 64)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { entries = LocalHistoryStore.shared.all() }
    }
}

private struct TranscriptRow: View {
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MainSection.transcript.accent))
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
            .padding(.top, 64)
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
                    .fill(section.accent)
                Image(systemName: section.icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)

            Text(section.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Palette.foreground)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
        }
    }
}

/// Bundle brand icon with a symbol fallback, mirroring the status bar and
/// floating bar treatment.
private struct BrandMark: View {
    var cornerRadius: CGFloat = 8

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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
    }
}

// MARK: - Xcode Preview

#Preview("Main window") {
    MainWindowView()
        .frame(width: 1100, height: 700)
}
