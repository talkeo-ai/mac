import AppKit
import QuartzCore
import SwiftUI

/// Small hover tip for the floating bar's buttons — an inverted rounded chip
/// with a tail pointing at the control (shadcn-style), shown beside the bar.
/// It lives in its own tiny non-activating window because the bar's window
/// hugs the pill exactly, with no room to draw outside it.
///
/// Behavior mirrors the usual tooltip conventions: the first appearance waits
/// a short delay; while a tip is up (or was up a moment ago) moving to another
/// button swaps it instantly; it never takes mouse events.
final class BarTooltipPanel {
    private let panel: NSPanel
    private var showTimer: Timer?
    private var lastHiddenAt: CFTimeInterval = 0

    /// Radix/shadcn's default `delayDuration` (700ms) — long enough to never
    /// bother a user who already knows the buttons, short enough to answer a
    /// genuine "what is this?" hover.
    private static let showDelay: TimeInterval = 0.7
    /// Grace period after hiding during which a new tip skips the delay
    /// (Radix's `skipDelayDuration` behavior).
    private static let stickyWindow: TimeInterval = 0.35

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
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
        panel.ignoresMouseEvents = true // never steal clicks or the cursor
        self.panel = panel
    }

    /// Ask for the tip on a (new) button. Applies the delay/sticky rules.
    /// `anchor` is evaluated when the tip actually presents — which can be up
    /// to `showDelay` after the hover — so the position always reflects where
    /// the button is *then*, not a rect captured while the owning window was
    /// still moving (the floating bar slides during auto-hide). Returning nil
    /// aborts the presentation.
    func request(text: String, anchor: @escaping () -> NSRect?) {
        showTimer?.invalidate()
        if panel.isVisible || CACurrentMediaTime() - lastHiddenAt < Self.stickyWindow {
            present(text: text, anchor: anchor)
        } else {
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
                self?.present(text: text, anchor: anchor)
            }
        }
    }

    func hide() {
        showTimer?.invalidate()
        showTimer = nil
        guard panel.isVisible else { return }
        lastHiddenAt = CACurrentMediaTime()
        panel.orderOut(nil)
    }

    /// Size to the label and sit to the button's left, tail vertically
    /// centered on it. Swapping text while visible repositions with no fade.
    private func present(text: String, anchor: () -> NSRect?) {
        guard let target = anchor() else { return }
        let hosting = NSHostingView(rootView: BarTooltipView(text: text))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let origin = NSPoint(
            x: target.minX - size.width,
            y: target.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // The entrance is animated by the SwiftUI content itself (fade + zoom
        // from the tail side, shadcn-style), so the window just appears.
        panel.orderFrontRegardless()
    }
}

// MARK: - SwiftUI content

struct BarTooltipView: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    /// Drives the entrance (fade + slight zoom from the tail side, shadcn's
    /// `fade-in zoom-in-95` pattern). The hosting view is fresh per
    /// presentation, so this runs on every appearance, including instant
    /// swaps between buttons.
    @State private var appeared = false

    /// shadcn-style inversion: dark chip on light appearance, light on dark —
    /// maximum contrast against whatever is behind, without being loud.
    private var chip: Color { colorScheme == .dark ? Color(white: 0.93) : Color(white: 0.13) }
    private var label: Color { colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.98) }

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(label)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chip))
            TooltipTail()
                .fill(chip)
                .frame(width: 5, height: 11)
                .offset(x: -0.5) // tuck under the chip edge so no hairline seam shows
        }
        .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
        .padding(5) // headroom for the shadow inside the tight window
        .fixedSize()
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.95, anchor: .trailing) // grow out of the tail, toward the button
        .onAppear {
            // Deferred one run-loop turn: flipping the state during the first
            // render pass races the initial commit — when both land in the
            // same transaction there's no visible entrance at all, so tips
            // popped in on fresh presentations (window just ordered front)
            // while swaps between neighbouring buttons animated. One frame
            // committed at the hidden state makes every path animate alike.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.18)) { appeared = true }
            }
        }
    }
}

/// Right-pointing triangle.
private struct TooltipTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Xcode Preview

#Preview("Bar tooltip") {
    VStack(spacing: 12) {
        BarTooltipView(text: "Translate selection")
        BarTooltipView(text: "Improve copy")
        BarTooltipView(text: "Listen")
    }
    .padding(30)
}
