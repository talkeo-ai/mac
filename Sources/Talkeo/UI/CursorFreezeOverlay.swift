import AppKit

/// Pixel-perfect stand-in for the real cursor while the mouse rests over the
/// floating bar.
///
/// The active app behind the bar (e.g. a terminal) re-asserts its own cursor
/// whenever its key window redraws — a TUI streaming output does so every few
/// seconds even with the mouse completely still. Cursor arbitration in the
/// window server is last-writer-wins, so each exchange we lose flashes the
/// wrong cursor for a few ms, and no re-assert frequency can fully hide that
/// (the hardware cursor updates instantly). The bar can't take key status to
/// silence the app behind — that would steal the keyboard on mere hover.
///
/// So while the mouse is at rest we take the cursor off the board instead:
/// hide the real one (`CGDisplayHideCursor` — public API; works from a
/// background app thanks to `BackgroundCursor`, the same combination Pixel
/// Picker ships) and show the identical cursor image in a tiny
/// non-interactive window at the exact same spot. The app behind can stomp
/// the invisible cursor all it wants. Any real mouse move unfreezes first,
/// so the visible cursor never lags motion.
///
/// Known trade-off: the stand-in uses the cursor's base image, so a user with
/// the accessibility "large cursor" setting would see it shrink while resting
/// on the bar. Acceptable for now; revisit if reported.
final class CursorFreezeOverlay {
    private let window: NSWindow
    private var hidden = false

    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver // above everything the bar can overlap
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        self.window = window
    }

    var isFrozen: Bool { hidden }

    /// Show `cursor`'s image with its hotspot exactly at `screenPoint`, then
    /// hide the real cursor. No-op when already frozen.
    func freeze(_ cursor: NSCursor, at screenPoint: NSPoint) {
        guard !hidden else { return }
        let image = cursor.image
        let hotSpot = cursor.hotSpot // top-left origin within the image
        let view = NSImageView(image: image)
        view.frame = NSRect(origin: .zero, size: image.size)
        window.setContentSize(image.size)
        window.contentView = view
        window.setFrameOrigin(NSPoint(
            x: screenPoint.x - hotSpot.x,
            y: screenPoint.y - (image.size.height - hotSpot.y)
        ))
        window.orderFrontRegardless()
        CGDisplayHideCursor(CGMainDisplayID()) // global despite the parameter
        hidden = true
    }

    /// Put the real cursor back and drop the stand-in. The caller re-asserts
    /// the proper cursor right after, so the swap happens within one frame.
    func unfreeze() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        window.orderOut(nil)
        hidden = false
    }

    // Hide/show calls must balance system-wide — never exit while hidden.
    deinit {
        if hidden { CGDisplayShowCursor(CGMainDisplayID()) }
    }
}
