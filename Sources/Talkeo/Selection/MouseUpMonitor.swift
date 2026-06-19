import AppKit
import CoreGraphics

/// Listens for global mouse events and fires `onSelection` after a mouse-up
/// that looks like a text selection (drag with non-zero distance OR a
/// multi-click word/line selection).
final class MouseUpMonitor {
    private let onSelection: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var downLocation: CGPoint?
    private var didDrag: Bool = false
    private var started: Bool = false

    init(onSelection: @escaping () -> Void) {
        self.onSelection = onSelection
    }

    func start() {
        guard !started else { return }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MouseUpMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            NSLog("[Talkeo] CGEvent.tapCreate failed — Accessibility permission missing?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        started = true
        NSLog("[Talkeo] mouse monitor started")
    }

    /// Whether a mouse-up looks like it produced/changed a text selection.
    ///   - drag selection: moved > 3px while dragging.
    ///   - multi-click: double/triple click selects word/line/paragraph.
    ///   - shift+click: extends an existing selection to the click point — a real
    ///     OS selection that has no drag and a single click, so it was previously
    ///     missed (mac#13). The downstream reader validates that a selection
    ///     actually exists, so a stray shift+click on non-text yields no tooltip.
    static func isSelectionCandidate(
        didDrag: Bool,
        dragDistanceSquared: Double,
        clickState: Int64,
        shiftHeld: Bool
    ) -> Bool {
        let isDragSelection = didDrag && dragDistanceSquared > 9 // >3px movement
        let isMultiClick = clickState >= 2
        let isShiftClick = shiftHeld
        return isDragSelection || isMultiClick || isShiftClick
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            downLocation = event.location
            didDrag = false
        case .leftMouseDragged:
            didDrag = true
        case .leftMouseUp:
            let location = event.location
            let clickState = event.getIntegerValueField(.mouseEventClickState)
            let distanceSquared: Double
            if let down = downLocation {
                let dx = location.x - down.x
                let dy = location.y - down.y
                distanceSquared = dx * dx + dy * dy
            } else {
                distanceSquared = 0
            }
            let candidate = Self.isSelectionCandidate(
                didDrag: didDrag,
                dragDistanceSquared: distanceSquared,
                clickState: clickState,
                shiftHeld: event.flags.contains(.maskShift)
            )
            downLocation = nil
            didDrag = false
            if candidate {
                DispatchQueue.main.async { [onSelection] in
                    onSelection()
                }
            }
        default:
            break
        }
    }
}
