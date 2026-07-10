import AppKit
import QuartzCore
import SwiftUI

/// Persistent, non-activating floating bar pinned to the right edge of the
/// screen — an always-available alternative to the selection tooltip. The same
/// actions (Translate, Improve, Capture) live here, but instead of appearing on
/// selection they sit in a vertical pill the user can reach any time; the action
/// reads the current selection on demand.
///
/// Kept deliberately unobtrusive: it stays out of the way via Dock-style
/// auto-hide rather than fading. This is an MVP to A/B the ergonomics against
/// `TooltipPanel`, so it reuses that file's brand styling and is toggled
/// on/off from the status-bar menu.
///
/// The bar never touches the pointer image: cursor authority belongs to the
/// active app (the platform contract — Apple's own non-activating panels
/// live with it too), and fighting that from a background app proved both
/// unwinnable and a steady source of bugs. Interactivity is signalled by the
/// buttons' hover ring and the hover tip instead.
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
    /// Label of the button currently under the cursor (nil = none), so a
    /// stale exit event can't hide the tip a newer enter just requested.
    private var hoveredButton: String?
    /// shadcn-style tip beside the bar naming the hovered button.
    private let tooltip = BarTooltipPanel()
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
        var onButtonHoverRef: ((String, Bool) -> Void)?
        let view = FloatingBarView(
            model: model,
            onOpenApp: { onOpenAppRef?() },
            onTranslate: { onTranslateRef?() },
            onImprove: { onImproveRef?() },
            onListen: { onListenRef?() },
            onButtonHover: { onButtonHoverRef?($0, $1) }
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
        onOpenAppRef = { [weak self] in self?.onOpenApp?() }
        onTranslateRef = { [weak self] in self?.tooltip.hide(); self?.onTranslate?() }
        onImproveRef = { [weak self] in self?.tooltip.hide(); self?.onImprove?() }
        onListenRef = { [weak self] in self?.tooltip.hide(); self?.onListen?() }
        onButtonHoverRef = { [weak self] label, hovering in
            self?.buttonHovered(label, hovering: hovering)
        }
    }

    /// Hover reported by a bar control: show its tip on enter, hide it on
    /// exit. SwiftUI's tracking works fine on a non-activating panel — only
    /// forcing the cursor image from a background app didn't (see the class
    /// note). Stays quiet while an option popover is open — the tip would sit
    /// on top of it.
    private func buttonHovered(_ label: String, hovering: Bool) {
        if hovering {
            hoveredButton = label
            guard !holdRevealed,
                  let button = model.buttons.first(where: { $0.label == label }) else { return }
            tooltip.request(text: label, pointingAt: screenRect(of: button.frame))
        } else if hoveredButton == label {
            // Guarded: moving between buttons can report the next enter
            // before this exit, and that fresher tip must survive.
            hoveredButton = nil
            tooltip.hide()
        }
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
        hoveredButton = nil
        tooltip.hide()
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
        if !value {
            // Retracting slides the buttons out from under a possibly
            // stationary cursor — tracking may never fire an exit for that.
            hoveredButton = nil
            tooltip.hide()
        }

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
    /// True while translatable text is selected somewhere — drives the subtle
    /// "ready to translate" accent on the Translate action.
    @Published var hasSelection = false
    /// The action buttons' labels + frames (content SwiftUI space, top-left
    /// origin), written by the view's layout and read by the panel to anchor
    /// each button's hover tip. Deliberately not `@Published` — no view reads
    /// it, and it must be capturable before the view exists (a callback wired
    /// after init loses the one-and-only preference fire for these static
    /// frames).
    var buttons: [BarButtonInfo] = []
}

/// A bar button's label and frame (in `FloatingBarView.spaceName` space),
/// reported to the panel so it can anchor each control's hover tip.
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

private extension View {
    /// Report this control's frame + label so the panel can anchor its hover
    /// tip. Anything clickable in the bar must opt in.
    func reportsAsBarButton(_ label: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(
                key: BarButtonFramesKey.self,
                value: [BarButtonInfo(label: label, frame: geo.frame(in: .named(FloatingBarView.spaceName)))]
            )
        })
    }

    /// Pointing hand via the public pointer-style API (macOS 15+). Honored
    /// whenever macOS grants this app cursor authority; it has no effect
    /// while another app is active — that's the platform contract, and the
    /// hover ring + tip carry the affordance there.
    @ViewBuilder
    func linkPointer() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

struct FloatingBarView: View {
    @ObservedObject var model: FloatingBarModel
    var onOpenApp: () -> Void = {}
    var onTranslate: () -> Void = {}
    var onImprove: () -> Void = {}
    var onListen: () -> Void = {}
    /// A control's hover changed (label, entered/exited) — drives the panel's
    /// hover tip.
    var onButtonHover: (String, Bool) -> Void = { _, _ in }
    /// Coordinate space covering the whole bar content including the shadow
    /// padding — window coordinates by construction.
    static let spaceName = "bar"

    private var stack: some View {
        VStack(spacing: 5) {
            // Same affordances as every other bar control (hover ring, tip) —
            // without them the brand icon didn't read as clickable at all.
            BrandButton(action: onOpenApp, onHoverChange: onButtonHover)
                .padding(.bottom, 1)

            // Translate, Improve and Listen all act on the selection, so they light
            // up when there's text to work with. Capture (OCR) doesn't depend on it.
            BarButton(system: "character.bubble", help: "Translate selection", isActive: model.hasSelection, onHoverChange: onButtonHover) {
                onTranslate()
            }
            BarButton(system: "text.badge.checkmark", help: "Improve copy", isActive: model.hasSelection, onHoverChange: onButtonHover) {
                onImprove()
            }
            BarButton(system: "speaker.wave.2", help: "Listen", isActive: model.hasSelection, onHoverChange: onButtonHover) {
                onListen()
            }
            BarButton(system: "text.viewfinder", help: "Capture text", onHoverChange: onButtonHover) {
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
        // is handled by auto-hide, not by fading the bar. No whole-bar hover
        // tracking: per-move work at this level made fast in-bar movement
        // laggy; each button tracks its own hover instead.
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
    var onHoverChange: (String, Bool) -> Void = { _, _ in }
    let action: () -> Void
    @State private var isHover = false

    private var tint: Color {
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
                .background(
                    ZStack {
                        // Near-solid neutral base under the active tint: the
                        // glass refracts whatever sits behind the bar, and a
                        // same-hue backdrop (e.g. the blue of a text
                        // selection) washed the accent glyph out. The material
                        // pins the chip's luminance to the appearance instead
                        // of the backdrop — per the Liquid Glass guidance:
                        // solid fills inside glass, never glass on glass.
                        if isActive { Circle().fill(.thickMaterial) }
                        Circle().fill(tint)
                    }
                )
        }
        .buttonStyle(.plain)
        // Ring highlight + hover report; the custom hover tip replaces the
        // native .help tag.
        .onHover { isHover = $0; onHoverChange(help, $0) }
        .reportsAsBarButton(help)
        .linkPointer()
        .animation(.easeOut(duration: 0.18), value: isActive)
    }
}

/// The bar's Talkeo button (opens the main app): the brand PNG in place of an
/// SF glyph, in the same 30pt circle with the same hover ring and tip plumbing
/// as `BarButton`, so it reads as clickable like the rest of the column.
private struct BrandButton: View {
    let action: () -> Void
    var onHoverChange: (String, Bool) -> Void = { _, _ in }
    @State private var isHover = false

    private static let label = "Open Talkeo"

    var body: some View {
        Button(action: action) {
            FloatingBrandIcon()
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .background(Circle().fill(isHover ? Color.primary.opacity(0.10) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0; onHoverChange(Self.label, $0) }
        .reportsAsBarButton(Self.label)
        .linkPointer()
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
