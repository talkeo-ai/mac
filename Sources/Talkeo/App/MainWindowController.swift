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
    /// Selection state shared with the SwiftUI tree, so callers can deep-link
    /// into a section (e.g. the popover's "Full history" → Translate).
    private let model = MainWindowModel()

    override init() {
        super.init()
        installMainMenuIfNeeded()
    }

    /// Deep-link for the popover's "Full history": the Translate page with
    /// its history drawer open.
    func openTranslateHistory() {
        model.translate.historyOpen = true
        // The page may already be mounted (no onAppear) while the popover was
        // writing to the shared store, so the drawer re-reads it here.
        model.translate.refreshHistory()
        show(section: .translate)
    }

    /// Same deep-link for Improve's compose bar — its page, drawer open.
    func openImproveHistory() {
        model.improve.historyOpen = true
        model.improve.refreshHistory()
        show(section: .improve)
    }

    /// Deep-link for the popover's Listen "Full history" — its page, drawer
    /// open.
    func openListenHistory() {
        model.listen.historyOpen = true
        model.listen.refreshHistory()
        show(section: .listen)
    }

    /// The pages' Capture buttons route through here — the AppDelegate
    /// injects the TCC-gated capture flow (same seam as the deep-links).
    var onPageCapture: (() -> Void)? {
        get { model.onCaptureRequest }
        set { model.onCaptureRequest = newValue }
    }

    /// Captured text handed back by the AppDelegate: land on `verb`'s page
    /// with the text as its source. Not auto-run — each page's own CTA stays
    /// the trigger.
    func openPage(verb: TextVerb, capturedText: String) {
        model.insertCaptured(capturedText, verb: verb)
        show(section: MainSection(verb))
    }

    /// Whether the window is on screen — a page-initiated capture hides it
    /// so Talkeo doesn't cover what the user wants to grab.
    var isWindowVisible: Bool { window?.isVisible ?? false }

    func hideForCapture() {
        window?.orderOut(nil)
    }

    /// Order the main window front and focus the app. Pass a section to land
    /// on it; nil keeps whatever the user last had open.
    func show(section: MainSection? = nil) {
        if let section { model.selection = section }
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
        window.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
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

/// The three text verbs — the feature pages a captured text can land on.
/// Narrower than `MainSection` (no Chat/Progress/Settings): the capture
/// preview's buttons and the pages' `replaceSource` handoff only ever target
/// these three.
enum TextVerb {
    case translate, improve, listen
}

/// Sections of the main window's left-hand rail: the three text verbs as
/// separate features, AI conversation (chat, voice teacher), the user-facing
/// record (Progress), and settings pinned at the bottom.
enum MainSection: String, CaseIterable, Identifiable {
    case translate, improve, listen, chat, teacher, progress, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: return "Translate"
        case .improve: return "Improve"
        case .listen: return "Listen"
        case .chat: return "Chat"
        case .teacher: return "Teacher"
        case .progress: return "Progress"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .translate: return "character.bubble.fill"
        // Same glyph as the floating bar's Improve button — one icon per verb
        // across surfaces.
        case .improve: return "text.badge.checkmark"
        case .listen: return "waveform"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .teacher: return "graduationcap.fill"
        case .progress: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }

    static let verbs: [MainSection] = [.translate, .improve, .listen]
    static let ai: [MainSection] = [.chat, .teacher]

    /// The rail section hosting a capture/deep-link verb.
    init(_ verb: TextVerb) {
        switch verb {
        case .translate: self = .translate
        case .improve: self = .improve
        case .listen: self = .listen
        }
    }
}

// MARK: - Root view (SPA: icon rail + floating content card)

/// Shared navigation state: the controller writes it for deep-links, the rail
/// writes it on clicks, the detail pane reads it. Owns the per-page models
/// and the capture seam, so switching sections loses nothing (e.g. the
/// translator keeps its text).
final class MainWindowModel: ObservableObject {
    @Published var selection: MainSection = .translate
    let translate = TranslatePageModel()
    let improve = ImprovePageModel()
    let listen = ListenPageModel()

    /// Injected by the AppDelegate (same seam as the popover deep-links): the
    /// pages' Capture buttons run the TCC-gated screen-capture flow, whose
    /// text comes back through `insertCaptured(_:verb:)`.
    var onCaptureRequest: (() -> Void)?

    func requestCapture() {
        onCaptureRequest?()
    }

    /// Captured text lands in `verb`'s page as its source, without
    /// auto-running anything — the page's own CTA stays the trigger.
    func insertCaptured(_ text: String, verb: TextVerb) {
        switch verb {
        case .translate: translate.replaceSource(text)
        case .improve: improve.replaceSource(text)
        case .listen: listen.replaceSource(text)
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel

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
            ForEach(MainSection.verbs) { item in
                RailItem(item: item, isSelected: model.selection == item) { model.selection = item }
            }

            railDivider

            ForEach(MainSection.ai) { item in
                RailItem(item: item, isSelected: model.selection == item) { model.selection = item }
            }

            railDivider

            RailItem(item: .progress, isSelected: model.selection == .progress) { model.selection = .progress }

            Spacer(minLength: 0)

            RailItem(item: .settings, isSelected: model.selection == .settings) { model.selection = .settings }
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
        switch model.selection {
        case .translate:
            TranslatePage(model: model.translate, onCapture: { model.requestCapture() })
        case .improve:
            ImprovePage(model: model.improve, onCapture: { model.requestCapture() })
        case .listen:
            ListenPage(model: model.listen, onCapture: { model.requestCapture() })
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
        case .progress:
            ProgressPage()
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
                Text(item.title)
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

// MARK: - Progress

/// The user-facing record: estimated English level and (soon) the listening
/// transcript, stacked as sections of one page. Level is the honest empty
/// state over the CEFR scale — estimation from real usage (translations,
/// improvements) comes later; Transcript is coming soon.
private struct ProgressPage: View {
    private static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    section: .progress,
                    subtitle: "Your English over time — estimated level and everything you've heard."
                )

                VStack(alignment: .leading, spacing: 16) {
                    sectionHeader(
                        title: "English level",
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

                Divider().overlay(Palette.border)

                VStack(alignment: .leading, spacing: 16) {
                    sectionHeader(
                        title: "Transcript",
                        subtitle: "Real-time transcription of what you hear — live subtitles for meetings, videos and calls."
                    )

                    Text("Coming soon")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Palette.elevated))
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
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
    MainWindowView(model: MainWindowModel())
        .frame(width: 1100, height: 700)
}
