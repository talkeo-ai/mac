import AppKit
import QuartzCore
import SwiftUI

/// Persistent, non-activating floating bar pinned to the right edge of the
/// screen — an always-available alternative to the selection tooltip. The same
/// actions (Translate, Improve, Capture) live here, but instead of appearing on
/// selection they sit in a vertical pill the user can reach any time; the action
/// reads the current selection on demand.
///
/// Kept deliberately unobtrusive: dimmed at rest, full opacity on hover. This is
/// an MVP to A/B the ergonomics against `TooltipPanel`, so it reuses that file's
/// brand styling and is toggled on/off from the status-bar menu.
final class FloatingBarPanel {
    private let panel: NSPanel
    private let model: FloatingBarModel

    /// Invoked when the user taps the Talkeo brand icon. The owner opens the
    /// main app window.
    var onOpenApp: (() -> Void)?

    /// Invoked when the user taps Translate. The owner reads the current
    /// selection and opens the translate panel.
    var onTranslate: (() -> Void)?

    /// Invoked when the user taps Improve. The owner reads the current selection
    /// and opens the improve panel.
    var onImprove: (() -> Void)?

    /// Invoked when the user taps Listen. The owner reads the current selection
    /// and opens the listen (TTS) panel.
    var onListen: (() -> Void)?

    /// Panel size, derived from the SwiftUI content's fitting size so the window
    /// hugs the pill exactly (no vertical slack that could shift centering). The
    /// content carries symmetric padding for the shadow, included here.
    private let size: NSSize
    /// Transparent inset the content reserves around the pill for its shadow.
    /// The retracted sliver must clear this to actually show glass.
    private static let shadowPad: CGFloat = 8
    /// Gap from the screen's right edge (on top of the shadow pad).
    private static let edgeMargin: CGFloat = 0
    /// How far left of the bar the cursor may go before an auto-hidden bar
    /// retracts (the "stay revealed" margin past its width line).
    private static let peekPad: CGFloat = 12
    /// How close to the physical right edge the cursor must get to reveal it.
    private static let revealThreshold: CGFloat = 3
    /// Poll interval for the Dock-style cursor hot-zone while auto-hiding.
    private static let pollInterval: TimeInterval = 0.06

    /// When true the bar behaves like the Dock: hidden off the right edge and
    /// revealed when the cursor reaches the edge (at any height), retracting once
    /// the cursor crosses back past its width line. Off = always visible.
    private var autoHide = false
    /// Whether the feature itself is on (the separate show/hide toggle).
    private var featureVisible = true
    /// Current revealed/retracted state, for hysteresis + animation gating.
    private var revealed = true
    private var pollTimer: Timer?
    private var slideTimer: Timer?
    private var cursorMonitors: [Any] = []
    /// The screen the bar is pinned to. Cached so it never flips to an adjacent
    /// display when auto-hide slides the panel partly off the edge.
    private var homeScreen: NSScreen?
    /// Slide duration for the reveal/retract.
    private static let slideDuration: CFTimeInterval = 0.16

    init() {
        let model = FloatingBarModel()
        self.model = model

        var onOpenAppRef: (() -> Void)?
        var onTranslateRef: (() -> Void)?
        var onImproveRef: (() -> Void)?
        var onListenRef: (() -> Void)?
        let view = FloatingBarView(
            model: model,
            onOpenApp: { onOpenAppRef?() },
            onTranslate: { onTranslateRef?() },
            onImprove: { onImproveRef?() },
            onListen: { onListenRef?() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        var fitting = hosting.fittingSize
        if fitting.width < 10 || fitting.height < 10 { fitting = NSSize(width: 64, height: 160) }
        self.size = fitting

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: fitting),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false

        hosting.frame = NSRect(origin: .zero, size: fitting)
        panel.contentView = hosting

        self.panel = panel

        onOpenAppRef = { [weak self] in self?.onOpenApp?() }
        onTranslateRef = { [weak self] in self?.onTranslate?() }
        onImproveRef = { [weak self] in self?.onImprove?() }
        onListenRef = { [weak self] in self?.onListen?() }
        installCursorMonitor()
    }

    deinit { removeCursorMonitor() }

    /// SwiftUI's `onContinuousHover` sets the cursor, but a non-key panel loses
    /// the race: the key app behind (e.g. Terminal) reasserts its I-beam on every
    /// mouse move. So we watch mouse-moves ourselves — running *after* that app —
    /// and force the pointing-hand whenever the cursor is over the visible bar.
    private func installCursorMonitor() {
        removeCursorMonitor()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateCursorOverBar()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateCursorOverBar()
            return event
        }
        cursorMonitors = [global, local].compactMap { $0 }
    }

    private func removeCursorMonitor() {
        cursorMonitors.forEach { NSEvent.removeMonitor($0) }
        cursorMonitors = []
    }

    private func updateCursorOverBar() {
        guard panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.pointingHand.set()
    }

    var isVisible: Bool { featureVisible }
    var isAutoHide: Bool { autoHide }

    /// Reflects whether translatable text is currently selected, so the bar can
    /// nudge the selection-driven actions to signal they're ready. The accent
    /// stays as long as the selection does and clears when it goes away. While
    /// auto-hiding, a selection also makes the bar peek out. Safe to call off-main.
    func setHasSelection(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.model.hasSelection = value }
            self.evaluate(animated: true)
        }
    }

    func show() {
        featureVisible = true
        revealed = true
        panel.setFrame(NSRect(origin: shownOrigin(), size: size), display: true)
        panel.orderFrontRegardless()
        refreshTracking()
        evaluate(animated: false)
    }

    func hide() {
        featureVisible = false
        stopTracking()
        panel.orderOut(nil)
    }

    /// Turn Dock-style auto-hide on/off. Off restores the always-visible bar.
    func setAutoHide(_ value: Bool) {
        guard autoHide != value else { return }
        autoHide = value
        guard featureVisible else { return }
        refreshTracking()
        evaluate(animated: true)
    }

    // MARK: Dock-style hot-zone

    private func refreshTracking() {
        if autoHide, featureVisible { startTracking() } else { stopTracking() }
    }

    private func startTracking() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.evaluate(animated: true)
        }
    }

    private func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Decide whether the bar should be revealed, mirroring the Dock's invisible
    /// hot-zone — rotated 90° for a right-edge vertical bar. Reveal triggers
    /// anywhere along the right edge (any Y); once revealed it stays until the
    /// cursor crosses left past the bar's width line. A live selection also keeps
    /// it out. With auto-hide off, it's always revealed.
    private func evaluate(animated: Bool) {
        guard featureVisible else { return }
        let screen = barScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = screen?.frame ?? visible

        let shownX = visible.maxX - size.width - Self.edgeMargin
        let hideLineX = shownX - Self.peekPad
        let revealEdgeX = frame.maxX - Self.revealThreshold
        let mouseX = NSEvent.mouseLocation.x

        // Hysteresis: harder to trigger (edge), easier to keep (width line).
        let inZone = revealed ? (mouseX >= hideLineX) : (mouseX >= revealEdgeX)
        let shouldReveal = !autoHide || inZone || model.hasSelection
        setRevealed(shouldReveal, animated: animated)
    }

    private func setRevealed(_ value: Bool, animated: Bool) {
        guard value != revealed else { return }
        revealed = value

        let targetX = (value ? shownOrigin() : hiddenOrigin()).x
        if animated {
            slideX(to: targetX)
        } else {
            slideTimer?.invalidate(); slideTimer = nil
            panel.setFrameOrigin(NSPoint(x: targetX, y: shownOrigin().y))
        }
    }

    /// Slide the panel purely horizontally (Y and size fixed) with an easeOut
    /// curve. Manual interpolation because `NSPanel.animator().setFrame` moves
    /// borderless panels diagonally and snaps at the end.
    private func slideX(to targetX: CGFloat) {
        slideTimer?.invalidate()
        let y = shownOrigin().y
        let startX = panel.frame.origin.x
        // Lock Y immediately so the motion is strictly horizontal.
        if panel.frame.origin.y != y { panel.setFrameOrigin(NSPoint(x: startX, y: y)) }

        let dx = targetX - startX
        guard abs(dx) > 0.5 else {
            panel.setFrameOrigin(NSPoint(x: targetX, y: y))
            return
        }
        let start = CACurrentMediaTime()
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - start) / Self.slideDuration)
            let eased = 1 - pow(1 - p, 3) // easeOutCubic
            self.panel.setFrameOrigin(NSPoint(x: startX + dx * eased, y: y))
            if p >= 1 { timer.invalidate(); self.slideTimer = nil }
        }
    }

    /// The screen the bar lives on, pinned for the session. Picked once from the
    /// panel's frame and cached, so auto-hide sliding the panel past the right
    /// edge (where it can overlap an adjacent display) never makes it jump
    /// screens. Re-picks only if the cached screen was disconnected.
    private func barScreen() -> NSScreen? {
        if let homeScreen, NSScreen.screens.contains(homeScreen) { return homeScreen }
        let f = panel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(f) }
            ?? NSScreen.main ?? NSScreen.screens.first
        homeScreen = screen
        return screen
    }

    /// Shared vertical center, so shown and hidden states never disagree on Y.
    private func centerY() -> CGFloat {
        let visible = barScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return visible.midY - size.height / 2
    }

    /// Right edge, vertically centered.
    private func shownOrigin() -> NSPoint {
        let visible = barScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - Self.edgeMargin, y: centerY())
    }

    /// Tucked off the right edge, leaving a few px of *glass* (past the shadow
    /// pad) so it stays discoverable. Same Y as shown.
    private func hiddenOrigin() -> NSPoint {
        let frame = barScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - Self.shadowPad - 4, y: centerY())
    }
}

// MARK: - SwiftUI content

final class FloatingBarModel: ObservableObject {
    @Published var isHovering = false
    /// True while translatable text is selected somewhere — drives the subtle
    /// "ready to translate" accent on the Translate action.
    @Published var hasSelection = false
}

struct FloatingBarView: View {
    @ObservedObject var model: FloatingBarModel
    var onOpenApp: () -> Void = {}
    var onTranslate: () -> Void = {}
    var onImprove: () -> Void = {}
    var onListen: () -> Void = {}

    private var stack: some View {
        VStack(spacing: 5) {
            Button(action: onOpenApp) {
                FloatingBrandIcon()
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open Talkeo")
            .padding(.bottom, 1)

            // Translate, Improve and Listen all act on the selection, so they light
            // up when there's text to work with. Capture (OCR) doesn't depend on it.
            BarButton(system: "character.bubble", help: "Translate selection", isActive: model.hasSelection) {
                onTranslate()
            }
            BarButton(system: "wand.and.stars", help: "Improve copy", isActive: model.hasSelection) {
                onImprove()
            }
            BarButton(system: "speaker.wave.2", help: "Listen", isActive: model.hasSelection) {
                onListen()
            }
            BarButton(system: "camera.viewfinder", help: "Capture text") {
                // TODO: screenshot + Vision OCR
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 7)
    }

    var body: some View {
        glassPill
            .fixedSize()
            // Symmetric padding gives the shadow room and makes the pill sit dead
            // center in the window (the panel sizes to this), so shown and
            // auto-hidden states share the exact same vertical center.
            .padding(8)
            // Full opacity for a clean, native glass look — staying out of the way
            // is handled by auto-hide, not by fading the bar.
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.pointingHand.set() }
            }
    }

    /// Native Liquid Glass on macOS 26+ (a single Dock-like capsule slab that
    /// refracts the content behind it), falling back to a vibrancy material on
    /// older systems.
    @ViewBuilder
    private var glassPill: some View {
        if #available(macOS 26.0, *) {
            stack
                .glassEffect(.regular, in: Capsule(style: .continuous))
                // Symmetric shadow (no vertical offset) so the bar reads as
                // centered — an offset shadow made the retracted sliver look low.
                .shadow(color: .black.opacity(0.14), radius: 6)
        } else {
            stack
                .background(
                    ZStack {
                        Capsule(style: .continuous).fill(.ultraThinMaterial)
                        Capsule(style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                )
        }
    }
}

private struct BarButton: View {
    let system: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void
    @State private var isHover = false

    private var fillColor: Color {
        if isHover { return Color.primary.opacity(0.10) }
        if isActive { return Color.accentColor.opacity(0.14) }
        return Color.clear
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .background(Circle().fill(fillColor))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHover = $0 }
        // Force the hand cursor on every move; in a non-activating panel AppKit's
        // cursor-rect machinery doesn't run, so a stray I-beam could otherwise show.
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.pointingHand.set() }
        }
        .animation(.easeOut(duration: 0.18), value: isActive)
    }
}

private struct FloatingBrandIcon: View {
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Xcode Preview

#Preview("Floating bar") {
    FloatingBarView(model: FloatingBarModel())
        .padding(40)
}
