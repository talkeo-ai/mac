import AppKit
import Combine
import SwiftUI

/// Floating non-activating chip that expands into a vertical menu on hover.
/// Anchors the top-left corner so the first menu row sits exactly where the
/// collapsed chip was — i.e. the cursor lands on row 1 the moment it expands.
final class TooltipPanel {
    private let panel: NSPanel
    private let hosting: NSHostingView<TooltipView>
    private let model: TooltipModel
    private var dismissMonitor: Any?
    private var autoDismissTimer: Timer?
    private var hideToken = 0
    private var cancellables = Set<AnyCancellable>()
    private var leftAnchor: CGFloat = 0
    private var topAnchor: CGFloat = 0

    /// Invoked when the user picks Translate from the menu, carrying the
    /// currently-selected text. The owner opens the translate panel.
    var onTranslate: ((String) -> Void)?

    private static let collapsedSize = NSSize(width: 34, height: 34)
    private static let maxSize = NSSize(width: 240, height: 220)
    /// How long the collapsed chip stays up untouched before fading out.
    private static let autoDismissDelay: TimeInterval = 4

    init() {
        let model = TooltipModel()
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.maxSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false

        var onResizeRef: ((CGSize) -> Void)?
        var onTranslateRef: (() -> Void)?
        let view = TooltipView(
            model: model,
            onResize: { onResizeRef?($0) },
            onTranslate: { onTranslateRef?() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.maxSize)
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting

        onResizeRef = { [weak self] size in
            self?.resizePanel(to: size)
        }

        // Hand the selected text to the owner and dismiss the chip, so the
        // translate panel takes over (it's activating; the chip isn't).
        onTranslateRef = { [weak self] in
            guard let self else { return }
            let text = self.model.text
            self.hide()
            self.onTranslate?(text)
        }

        // Once the user expands the chip into the menu they're actively using it,
        // so stop the idle auto-dismiss. Click/scroll outside still closes it.
        model.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                if expanded { self?.cancelAutoDismiss() }
            }
            .store(in: &cancellables)
    }

    func show(text: String, near point: NSPoint) {
        model.text = text
        model.isExpanded = false
        let origin = clampedOrigin(near: point, size: Self.collapsedSize)
        leftAnchor = origin.x
        topAnchor = origin.y + Self.collapsedSize.height // bottom-left coords → top edge
        hideToken += 1 // invalidate any in-flight fade-out
        panel.alphaValue = 1
        panel.setFrame(NSRect(origin: origin, size: Self.collapsedSize), display: true)
        panel.orderFrontRegardless()
        installDismissMonitor()
        startAutoDismiss()
    }

    func hide() {
        removeDismissMonitor()
        cancelAutoDismiss()
        guard panel.isVisible, panel.alphaValue > 0 else { return }

        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideToken == token else { return } // re-shown meanwhile
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    private func startAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: Self.autoDismissDelay, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    /// Called on every SwiftUI layout pass (incl. each animation frame).
    /// Top-left anchored: width grows rightward, height grows downward.
    private func resizePanel(to size: CGSize) {
        let width = min(max(size.width, Self.collapsedSize.width), Self.maxSize.width)
        let height = min(max(size.height, Self.collapsedSize.height), Self.maxSize.height)
        var origin = NSPoint(x: leftAnchor, y: topAnchor - height)

        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: leftAnchor, y: topAnchor)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if origin.x + width > visible.maxX { origin.x = visible.maxX - width - 4 }
        if origin.y < visible.minY { origin.y = visible.minY + 4 }

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: false)
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }

    private func clampedOrigin(near point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = point.x + 10
        var y = point.y - size.height - 10

        // Pre-bias: leave space for the expanded menu growing rightward + down
        if x + Self.maxSize.width > visible.maxX { x = point.x - Self.maxSize.width - 10 }
        if x < visible.minX { x = visible.minX + 6 }
        if y - (Self.maxSize.height - size.height) < visible.minY { y = point.y + 14 }
        if y + size.height > visible.maxY { y = visible.maxY - size.height - 6 }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - SwiftUI content

final class TooltipModel: ObservableObject {
    @Published var text: String = ""
    @Published var isExpanded: Bool = false
}

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private enum Brand {
    static let iconImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct TooltipView: View {
    @ObservedObject var model: TooltipModel
    let onResize: (CGSize) -> Void
    var onTranslate: () -> Void = {}

    var body: some View {
        container
            .fixedSize()
            // The panel is a non-activating borderless panel, so it never becomes
            // the key window and AppKit's cursor-rect machinery never applies — the
            // I-beam set by the text view underneath (e.g. a terminal) would linger.
            // Reclaim the cursor from SwiftUI's own hover tracking (the same one the
            // row highlights use), reasserting the arrow on every move so the system
            // can't revert it. Done here rather than via an NSHostingView subclass so
            // it doesn't fight SwiftUI's tracking areas (which broke hover on reuse).
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.arrow.set() }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: SizePreferenceKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(SizePreferenceKey.self) { size in
                onResize(size)
            }
    }

    @ViewBuilder
    private var container: some View {
        if model.isExpanded {
            menuView
        } else {
            collapsedChip
        }
    }

    private var collapsedChip: some View {
        BrandIcon()
            .frame(width: 24, height: 24)
            .padding(5)
            .background(pillBackground(corner: 10))
            .contentShape(Rectangle())
            .onTapGesture {
                guard !model.isExpanded else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    model.isExpanded = true
                }
            }
    }

    private var menuView: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(
                kind: .system("text.viewfinder"),
                title: "Capture text",
                subtitle: "OCR on a screen region"
            ) {
                // TODO: screenshot + Vision OCR
            }
            Divider().opacity(0.4)
            MenuRow(
                kind: .system("character.bubble"),
                title: "Translate",
                subtitle: "Auto ES ⇄ EN"
            ) {
                onTranslate()
            }
            Divider().opacity(0.4)
            MenuRow(
                kind: .system("text.badge.checkmark"),
                title: "Improve copy",
                subtitle: "Polish the selected text"
            ) {
                // TODO: Groq rewrite + replace-in-place
            }
            Divider().opacity(0.4)
            MenuRow(
                kind: .brand,
                title: "Open Talkeo",
                subtitle: "Settings & history"
            ) {
                // TODO: open main window
            }
        }
        .frame(width: 224)
        .padding(4)
        .background(pillBackground(corner: 14))
    }

    private func pillBackground(corner: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

private enum MenuIcon {
    case system(String)
    case brand
}

private struct MenuRow: View {
    let kind: MenuIcon
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHover ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        switch kind {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        case .brand:
            BrandIcon()
        }
    }
}

private struct BrandIcon: View {
    var body: some View {
        Group {
            if let nsImage = Brand.iconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Xcode Previews
// Live, build-free iteration on the tooltip's look (open the canvas with ⌥⌘↩).
// The brand icon falls back to an SF Symbol here because the preview host has no
// icon.png in its bundle — these previews are for layout/sizing, not the asset.

private struct TooltipPreview: View {
    let expanded: Bool
    @StateObject private var model = TooltipModel()

    var body: some View {
        TooltipView(model: model, onResize: { _ in })
            .padding(40)
            .onAppear {
                model.text = "Selected text"
                model.isExpanded = expanded
            }
    }
}

#Preview("Collapsed chip") { TooltipPreview(expanded: false) }
#Preview("Expanded menu") { TooltipPreview(expanded: true) }
