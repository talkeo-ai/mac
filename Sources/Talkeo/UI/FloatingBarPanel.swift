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
    /// While true the bar stays revealed regardless of the cursor — set while
    /// one of its option popovers is open, so the bar never retracts from
    /// under the UI it just opened.
    private var holdRevealed = false
    /// Whether the feature itself is on (the separate show/hide toggle).
    private var featureVisible = true
    /// Current revealed/retracted state, for hysteresis + animation gating.
    private var revealed = true
    private var pollTimer: Timer?
    private var slideTimer: Timer?
    private var cursorMonitors: [Any] = []
    /// Ticks while the cursor sits over the bar, reasserting the pointing-hand.
    /// Even with `BackgroundCursor` granted, the active app behind (e.g. a
    /// terminal) keeps receiving the mouse-moved events — key stays with it by
    /// design — and re-sets its own cursor on each one. That's a cross-process
    /// last-writer race with no ordering primitive: our per-move set wins only
    /// some exchanges, so during movement the cursor would visibly strobe
    /// between ours and theirs. Reasserting at display rate bounds any loss to
    /// ~8ms — below perception. The timer only runs while the cursor is over
    /// the bar, so the steady-state cost elsewhere is zero.
    private var cursorReassertTimer: Timer?
    private static let cursorReassertInterval: TimeInterval = 1.0 / 120.0
    /// Whether the last sync found the cursor over the visible pill, so leaving
    /// it restores the arrow exactly once (a background-set cursor that nobody
    /// else corrects would otherwise stick, e.g. over the desktop).
    private var cursorIsOverBar = false
    /// Label of the button currently under the cursor (nil = none), so the
    /// hover tip reacts to changes only, not to every reassert tick.
    private var hoveredButton: String?
    /// shadcn-style tip beside the bar naming the hovered button.
    private let tooltip = BarTooltipPanel()
    /// Whether the panel already carries the per-window cursor tag (see
    /// `BackgroundCursor.tagWindow`). Tagging needs a live window number, so
    /// it's applied on show and retried until it takes.
    private var windowTagged = false
    /// The screen the bar is pinned to. Cached so it never flips to an adjacent
    /// display when auto-hide slides the panel partly off the edge.
    private var homeScreen: NSScreen?
    /// Slide duration for the reveal/retract.
    private static let slideDuration: CFTimeInterval = 0.16

    init() {
        let model = FloatingBarModel()
        self.model = model

        var onTranslateRef: (() -> Void)?
        var onImproveRef: (() -> Void)?
        var onListenRef: (() -> Void)?
        let view = FloatingBarView(
            model: model,
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

        // Acting on a button dismisses its tip right away (the popover the
        // action opens would otherwise appear under it).
        onTranslateRef = { [weak self] in self?.tooltip.hide(); self?.onTranslate?() }
        onImproveRef = { [weak self] in self?.tooltip.hide(); self?.onImprove?() }
        onListenRef = { [weak self] in self?.tooltip.hide(); self?.onListen?() }
        // Without this the window server is free to ignore cursor sets from a
        // non-active app outright — the bar could never fix the cursor at all
        // while e.g. a focused terminal asserts its I-beam.
        _ = BackgroundCursor.isEnabled
        installCursorMonitor()
    }

    deinit { removeCursorMonitor() }

    /// SwiftUI's hover tracking can't own the cursor on a non-key,
    /// non-activating panel, so we watch mouse-moves ourselves (global for
    /// moves delivered to other apps, local for our own) and keep the cursor
    /// in sync with where it sits. `BackgroundCursor` makes those sets stick.
    /// The screen position is queried fresh, NOT read off the event: a global
    /// monitor's `locationInWindow` is relative to the *receiving app's*
    /// window (unresolvable from here), so treating it as screen coordinates
    /// put the cursor in the wrong zone on most moves — visible as a rapid
    /// arrow/hand strobe.
    private func installCursorMonitor() {
        removeCursorMonitor()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.syncCursor()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.syncCursor()
            return event
        }
        cursorMonitors = [global, local].compactMap { $0 }
    }

    private func removeCursorMonitor() {
        cursorMonitors.forEach { NSEvent.removeMonitor($0) }
        cursorMonitors = []
        stopCursorReassertTimer()
    }

    /// The region where the hand cursor applies: the panel frame minus the
    /// transparent shadow padding — just the visible glass. Clicks in the
    /// padding fall through to the app behind, so the cursor should match.
    private var cursorRect: NSRect {
        panel.frame.insetBy(dx: Self.shadowPad, dy: Self.shadowPad)
    }

    /// Keep the cursor truthful around the bar with standard hover semantics:
    /// pointing-hand over the action buttons, plain arrow over the rest of the
    /// glass, and the app behind's own cursor once it leaves (arrow restored
    /// exactly once on exit). Over the bar the cursor is always *asserted*,
    /// never left alone — the active app keeps re-setting its own cursor
    /// (e.g. a terminal's I-beam) on every move it receives, and ours must
    /// land on top.
    private func syncCursor() {
        let point = NSEvent.mouseLocation
        guard panel.isVisible, cursorRect.contains(point) else {
            stopCursorReassertTimer()
            if cursorIsOverBar {
                cursorIsOverBar = false
                NSCursor.arrow.set()
            }
            if hoveredButton != nil {
                hoveredButton = nil
                tooltip.hide()
            }
            return
        }
        cursorIsOverBar = true
        let local = barPoint(point)
        let hovered = model.buttons.first { $0.frame.contains(local) }
        (hovered != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        updateTooltip(hovered)
        startCursorReassertTimer()
    }

    /// Show/swap/hide the hover tip when the hovered button changes. Stays
    /// quiet while an option popover is open — the tip would sit on top of it.
    private func updateTooltip(_ hovered: BarButtonInfo?) {
        guard hovered?.label != hoveredButton else { return }
        hoveredButton = hovered?.label
        guard let hovered, !holdRevealed else {
            tooltip.hide()
            return
        }
        tooltip.request(text: hovered.label, pointingAt: screenRect(of: hovered.frame))
    }

    /// A view-reported (SwiftUI top-left) frame in screen coordinates.
    private func screenRect(of rect: CGRect) -> NSRect {
        let frame = panel.frame
        return NSRect(
            x: frame.origin.x + rect.minX,
            y: frame.origin.y + frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Convert a screen point into the bar content's SwiftUI space (top-left
    /// origin, spans the whole window), where the button frames are reported.
    private func barPoint(_ screenPoint: NSPoint) -> CGPoint {
        let frame = panel.frame
        return CGPoint(
            x: screenPoint.x - frame.origin.x,
            y: frame.height - (screenPoint.y - frame.origin.y)
        )
    }

    private func startCursorReassertTimer() {
        guard cursorReassertTimer == nil else { return }
        cursorReassertTimer = Timer.scheduledTimer(withTimeInterval: Self.cursorReassertInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.syncCursor()
        }
    }

    private func stopCursorReassertTimer() {
        cursorReassertTimer?.invalidate()
        cursorReassertTimer = nil
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
        // Tag on the NEXT run-loop turn: window-server state set in the same
        // turn a window is ordered in can get dropped, and AppKit may rewrite
        // tags on re-order — so re-apply on every show.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowTagged = BackgroundCursor.tagWindow(self.panel)
        }
        refreshTracking()
        evaluate(animated: false)
        syncCursor() // the bar may have appeared under a stationary cursor
    }

    func hide() {
        featureVisible = false
        stopTracking()
        tooltip.hide()
        panel.orderOut(nil)
        syncCursor() // hidden now — restores the arrow if the bar owned the cursor
    }

    /// Turn Dock-style auto-hide on/off. Off restores the always-visible bar.
    func setAutoHide(_ value: Bool) {
        guard autoHide != value else { return }
        autoHide = value
        guard featureVisible else { return }
        refreshTracking()
        evaluate(animated: true)
    }

    /// Hold the bar revealed while an option popover is open (and let it
    /// retract again once released). Safe to call redundantly.
    func setHoldRevealed(_ value: Bool) {
        guard holdRevealed != value else { return }
        holdRevealed = value
        if value { tooltip.hide() } // the popover opens where the tip sits
        guard featureVisible else { return }
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
    /// cursor crosses left past the bar's width line. A live selection or an
    /// open option popover also keeps it out. With auto-hide off, it's always
    /// revealed.
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
        let shouldReveal = !autoHide || inZone || model.hasSelection || holdRevealed
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
            syncCursor() // the bar may have jumped under (or away from) a stationary cursor
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
            if p >= 1 {
                timer.invalidate(); self.slideTimer = nil
                // A reveal can slide the bar in under a stationary cursor (no
                // mouse-move fires); retracts self-correct via the reassert timer.
                self.syncCursor()
            }
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
    /// The action buttons' labels + frames (content SwiftUI space, top-left
    /// origin), written by the view's layout and read by the panel's cursor
    /// sync. Deliberately not `@Published` — no view reads it, and it must be
    /// capturable before the view exists (a callback wired after init loses
    /// the one-and-only preference fire for these static frames).
    var buttons: [BarButtonInfo] = []
}

/// A bar button's label and frame (in `FloatingBarView.spaceName` space),
/// reported to the panel so it can scope the hand cursor to the actual
/// controls and anchor each one's hover tip.
struct BarButtonInfo: Equatable {
    let label: String
    let frame: CGRect
}

private struct BarButtonFramesKey: PreferenceKey {
    static var defaultValue: [BarButtonInfo] = []
    static func reduce(value: inout [BarButtonInfo], nextValue: () -> [BarButtonInfo]) {
        value.append(contentsOf: nextValue())
    }
}

struct FloatingBarView: View {
    @ObservedObject var model: FloatingBarModel
    var onTranslate: () -> Void = {}
    var onImprove: () -> Void = {}
    var onListen: () -> Void = {}
    /// Coordinate space covering the whole bar content including the shadow
    /// padding — window coordinates by construction.
    static let spaceName = "bar"

    private var stack: some View {
        VStack(spacing: 5) {
            FloatingBrandIcon()
                .frame(width: 20, height: 20)
                .padding(.bottom, 1)

            // Translate, Improve and Listen all act on the selection, so they light
            // up when there's text to work with. Capture (OCR) doesn't depend on it.
            BarButton(system: "character.bubble", help: "Translate selection", isActive: model.hasSelection) {
                onTranslate()
            }
            BarButton(system: "text.badge.checkmark", help: "Improve copy", isActive: model.hasSelection) {
                onImprove()
            }
            BarButton(system: "speaker.wave.2", help: "Listen", isActive: model.hasSelection) {
                onListen()
            }
            BarButton(system: "text.viewfinder", help: "Capture text") {
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
            .coordinateSpace(name: FloatingBarView.spaceName)
            // Straight into the model: it exists before this view, so even the
            // very first layout's fire (these frames never change, so it's the
            // only one) lands somewhere the panel can read.
            .onPreferenceChange(BarButtonFramesKey.self) { [model] in model.buttons = $0 }
        // Full opacity for a clean, native glass look — staying out of the way
        // is handled by auto-hide, not by fading the bar. No hover tracking at
        // this level either: the cursor is owned by FloatingBarPanel.syncCursor,
        // and extra per-move SwiftUI tracking made fast in-bar movement laggy.
    }

    /// Native Liquid Glass on macOS 26+ (a single Dock-like capsule slab that
    /// refracts the content behind it), falling back to a vibrancy material on
    /// older systems.
    @ViewBuilder
    private var glassPill: some View {
        if #available(macOS 26.0, *) {
            stack
                .glassEffect(.regular, in: Capsule(style: .continuous))
                // Hairline edge: pure glass melts into light windows (e.g. a
                // Finder window reaching the right edge); this keeps the pill
                // legible there without losing the native look.
                .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                // Symmetric shadow (no vertical offset) so the bar reads as
                // centered — an offset shadow made the retracted sliver look low.
                .shadow(color: .black.opacity(0.20), radius: 8)
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
        // Highlight only — the hand cursor is owned by FloatingBarPanel.syncCursor,
        // and the custom hover tip replaces the native .help tag.
        .onHover { isHover = $0 }
        // Report where this button sits (and its label) so the hand cursor and
        // the hover tip apply exactly here.
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: BarButtonFramesKey.self,
                value: [BarButtonInfo(label: help, frame: geo.frame(in: .named(FloatingBarView.spaceName)))]
            )
        })
        .animation(.easeOut(duration: 0.18), value: isActive)
    }
}

private struct FloatingBrandIcon: View {
    /// Loaded once — resolving the bundle URL and decoding the PNG in `body`
    /// meant disk I/O on the main thread on every re-render.
    private static let iconImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let nsImage = Self.iconImage {
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
