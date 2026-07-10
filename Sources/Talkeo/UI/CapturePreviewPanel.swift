import AppKit
import SwiftUI
import VisionKit

/// Post-capture preview — the Mac-screenshot-style window showing what was
/// just grabbed, with Apple's Live Text selection over the image and Talkeo's
/// verbs underneath. Capture extends the selection system to pixels: the
/// verbs are the same ones the floating bar speaks (Translate / Improve /
/// Listen, plus Copy), acting on the in-image selection when there is one and
/// on the full transcript otherwise.
///
/// Same key-but-non-activating contract as `QuickTranslatePanel` (key for
/// text interaction, never `NSApp.activate()`), but unlike the popover there
/// is NO outside-click dismissal: a capture isn't reproducible — a stray
/// click must not destroy work the user just did with a drag gesture.
/// Dismissal paths: Esc, the close button, choosing a verb, or a new capture.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Esc lands here as `cancelOperation` once no responder eats it first
    /// (the Live Text overlay consumes it while a selection is active, which
    /// reads naturally: first Esc clears the selection, second closes).
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class CapturePreviewPanel {
    /// Verb taps, already resolved to the text they act on (selection or
    /// transcript). The owner routes these into the popover entry points.
    var onTranslate: ((String) -> Void)?
    var onImprove: ((String) -> Void)?
    var onListen: ((String) -> Void)?

    private let panel: CapturePanel
    private let model = CapturePreviewModel()
    /// Fallback OCR for when the VisionKit analyzer can't produce an
    /// analysis — injected so tests can fake it (house style).
    private let recognizer: TextRecognizing
    /// Reused across captures per Apple's guidance — the analyzer holds
    /// warmed-up models.
    private let analyzer = ImageAnalyzer()
    private var analysisTask: Task<Void, Never>?

    /// Same rationale as the popover's `previousApp`: we become key without
    /// activating, and hand focus back on hide only if we still hold it.
    private var previousApp: NSRunningApplication?

    /// The image never exceeds this fraction of the screen — the preview is
    /// a working surface beside the user's context, not a viewer.
    private static let maxScreenFraction: CGFloat = 0.58

    init(recognizer: TextRecognizing = VisionTextRecognizer()) {
        self.recognizer = recognizer
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false // the SwiftUI chrome draws its own
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // NOT movable-by-background: AppKit asks the clicked view's
        // `mouseDownCanMoveWindow`, and the Live Text overlay's internals
        // default to true (non-opaque views) — a drag meant to SELECT text
        // would move the window instead. The preview is placed centered and
        // stays put.
        panel.isMovableByWindowBackground = false
        self.panel = panel
        panel.onCancel = { [weak self] in self?.hide() }
    }

    /// Present a fresh capture. A new capture supersedes whatever the panel
    /// was showing — content, analysis and selection all reset.
    func show(image: NSImage) {
        analysisTask?.cancel()
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        model.reset()

        // The mouse is where the user just finished dragging the region, so
        // its screen is "where the capture happened" without extra plumbing.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        let displaySize = Self.displaySize(for: image.size, on: screen)

        // Fresh hosting per presentation (the `BarTooltipPanel` pattern): the
        // Live Text overlay and its selection state reset with the view tree.
        let view = CapturePreviewView(
            image: image,
            imageDisplaySize: displaySize,
            model: model,
            onVerb: { [weak self] verb in self?.perform(verb) },
            onCopy: { [weak self] in self?.copyText() },
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(Self.frame(for: size, on: screen), display: true)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        // Key only — never NSApp.activate(): activation would raise the main
        // window too, yanking the user out of their context (see the same
        // note in QuickTranslatePanel.present()).
        panel.makeKey()
        // SwiftUI hands initial key focus to the first focusable control —
        // the ✕ button gets a focus ring nobody asked for. Nothing needs
        // keyboard focus up front (Esc works from the window itself), so
        // drop it; deferred a turn because SwiftUI assigns focus after the
        // window becomes key.
        DispatchQueue.main.async { [weak panel] in
            panel?.makeFirstResponder(nil)
        }

        analyze(image)
    }

    func hide() {
        // A superseded or dismissed preview must not assign its analysis to
        // an overlay that now belongs to newer content.
        analysisTask?.cancel()
        analysisTask = nil
        guard panel.isVisible, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
        restoreFocus()
    }

    /// Mirrors `QuickTranslatePanel.restoreFocus()` — deferred a beat so a
    /// dismissal caused by focusing another app doesn't get its activation
    /// stolen back.
    private func restoreFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, NSApp.isActive else { return }
            self.previousApp?.activate()
        }
    }

    // MARK: Verbs

    private func perform(_ verb: CaptureVerb) {
        guard let text = model.actionText() else { return }
        // Close first, then route: the popover makes itself key on present,
        // and the preview must already be on its way out so the two panels
        // don't fight over focus restoration.
        hide()
        switch verb {
        case .translate: onTranslate?(text)
        case .improve: onImprove?(text)
        case .listen: onListen?(text)
        }
    }

    private func copyText() {
        guard let text = model.actionText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Copy keeps the preview up — unlike the verbs it doesn't navigate
        // anywhere, and the capture may still be wanted for a second action.
    }

    // MARK: Text recognition

    private func analyze(_ image: NSImage) {
        guard ImageAnalyzer.isSupported else {
            fallBackToVision(image)
            return
        }
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The analyzer suspends and does its work off-main
                // internally; everything we touch afterwards resumes on
                // MainActor. Screenshots are always upright, and macOS's
                // analyze() has no orientation-less convenience.
                let analysis = try await self.analyzer.analyze(
                    image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text])
                )
                guard !Task.isCancelled else { return }
                self.model.apply(analysis)
            } catch {
                guard !Task.isCancelled else { return }
                // Diagnosable: a thrown analyzer looks identical to "no Live
                // Text" from the outside, and the Vision fallback masks it.
                NSLog("Capture: ImageAnalyzer failed, falling back to Vision: %@",
                      String(describing: error))
                self.fallBackToVision(image)
            }
        }
    }

    /// No Live Text (nothing selectable in the image), but the verbs still
    /// work off the plain Vision transcript.
    private func fallBackToVision(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            model.setTranscript(nil)
            return
        }
        recognizer.recognizeText(in: cgImage) { [weak self] text in
            self?.model.setTranscript(text)
        }
    }

    // MARK: Layout

    /// Fit the image (whose `size` is in points — screencapture's Retina dpi
    /// metadata guarantees that) inside the screen budget. Down-only: a tiny
    /// capture renders 1:1, upscaling would just blur it.
    private static func displaySize(for imageSize: NSSize, on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let budget = NSSize(
            width: visible.width * maxScreenFraction,
            height: visible.height * maxScreenFraction
        )
        let scale = min(
            1,
            budget.width / max(imageSize.width, 1),
            budget.height / max(imageSize.height, 1)
        )
        return NSSize(
            width: max(floor(imageSize.width * scale), 40),
            height: max(floor(imageSize.height * scale), 40)
        )
    }

    /// Centered on the capture's screen with a slight upward bias, so it
    /// reads as a presentation rather than a dialog. Clamped to the visible
    /// frame for captures near the size budget.
    private static func frame(for size: NSSize, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.03
        )
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - 8 - size.width))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - 8 - size.height))
        return NSRect(origin: origin, size: size)
    }
}

// MARK: - Model

/// State shared between the controller (which produces the analysis) and the
/// SwiftUI content (which renders phase and owns the overlay view).
final class CapturePreviewModel: ObservableObject {
    enum Phase {
        /// Analysis in flight — verbs disabled, "Reading text…" hint.
        case recognizing
        /// Text available — verbs enabled.
        case ready
        /// Analysis finished empty — verbs stay disabled, the preview is
        /// still useful as a plain image.
        case noText
    }

    @Published var phase: Phase = .recognizing
    /// Whether a Live Text selection is active in the image right now —
    /// drives the hint that tells the user what the verbs will act on.
    /// Only ever flips on macOS 14+ (the selection-change delegate callback
    /// is 14+, same as reading the selection itself).
    @Published var hasSelection = false
    /// Full recognized text (analyzer transcript or Vision fallback).
    private(set) var transcript: String?
    /// VisionKit analysis, attached to the overlay by the representable on
    /// its next update (the analysis usually lands after the first layout).
    private(set) var analysis: ImageAnalysis?
    /// Registered by `LiveTextImageView.makeNSView`; read lazily at
    /// verb-click time for the current selection.
    weak var overlayView: ImageAnalysisOverlayView?

    func reset() {
        phase = .recognizing
        hasSelection = false
        transcript = nil
        analysis = nil
        overlayView = nil
    }

    func apply(_ analysis: ImageAnalysis) {
        self.analysis = analysis
        // Attach directly: the overlay registered during the panel's initial
        // layout (before the analysis could possibly land), and relying on a
        // SwiftUI update pass here is fragile — the representable's stored
        // properties are the same references before and after, so SwiftUI
        // may well skip `updateNSView` entirely.
        if let overlay = overlayView {
            MainActor.assumeIsolated { overlay.analysis = analysis }
        }
        setTranscript(analysis.transcript)
    }

    func setTranscript(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = (trimmed?.isEmpty == false) ? text : nil
        phase = transcript != nil ? .ready : .noText
    }

    /// The text a verb acts on right now. Reading `selectedText` is macOS
    /// 14+ (`hasActiveTextSelection` itself is 13) — on macOS 13 the user
    /// can make an in-image selection but verbs act on the full transcript.
    func actionText() -> String? {
        var selected: String?
        if #available(macOS 14.0, *), let overlay = overlayView {
            // Verb clicks arrive on main; the overlay's members are
            // MainActor-isolated and VisionKit enforces it even in this
            // language mode, hence the explicit assume.
            selected = MainActor.assumeIsolated {
                overlay.hasActiveTextSelection ? overlay.selectedText : nil
            }
        }
        return CaptureActionText.resolve(selected: selected, transcript: transcript)
    }
}

// MARK: - SwiftUI content

private enum CaptureVerb {
    case translate, improve, listen
}

private struct CapturePreviewView: View {
    let image: NSImage
    let imageDisplaySize: NSSize
    @ObservedObject var model: CapturePreviewModel
    var onVerb: (CaptureVerb) -> Void
    var onCopy: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            LiveTextImageView(image: image, model: model)
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .center)
            actionRow
        }
        .padding(16)
        // Wide enough that the verb row never wraps under a narrow capture;
        // the image centers itself in the leftover width.
        .frame(minWidth: 360)
        .background(
            ZStack {
                QuickVisualEffectView()
                Palette.surface.opacity(0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 14, y: 4)
        // Headroom so the shadow isn't clipped by the tight window (the
        // BarTooltipPanel trick); it doubles as the window's drag margin.
        .padding(18)
        .fixedSize()
    }

    private var header: some View {
        HStack {
            Text("Capture")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Spacer()
            QuickIconButton(system: "xmark") { onClose() }
        }
        .frame(height: 26)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            statusHint
            Spacer(minLength: 12)
            QuickIconButton(system: "doc.on.doc") { onCopy() }
                .disabled(model.phase != .ready)
                .opacity(model.phase == .ready ? 1 : 0.4)
            verbButton("Translate") { onVerb(.translate) }
            verbButton("Improve") { onVerb(.improve) }
            verbButton("Listen") { onVerb(.listen) }
        }
    }

    /// Quiet caption at the row's far left telling the user what the verbs
    /// will act on. Present in every phase so the row never jumps when
    /// recognition lands or a selection starts.
    @ViewBuilder
    private var statusHint: some View {
        Group {
            switch model.phase {
            case .recognizing:
                Text("Reading text…")
            case .noText:
                Text("No text found")
            case .ready:
                if model.hasSelection {
                    Text("Acting on your selection")
                } else {
                    Text("Select text to act on just that part")
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Palette.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func verbButton(_ title: String, action: @escaping () -> Void) -> some View {
        let enabled = model.phase == .ready
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(enabled ? Palette.primaryForeground : Palette.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // Same muted-not-faded disabled treatment as the popover's
                // compose CTAs (`.disabled` alone renders nothing on a
                // custom-styled button).
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(enabled ? Palette.primary : Palette.elevated)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .handCursor()
    }
}

/// The captured image with VisionKit's Live Text overlay glued on top.
/// Static per presentation — a new capture builds a fresh hosting view.
private struct LiveTextImageView: NSViewRepresentable {
    let image: NSImage
    let model: CapturePreviewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    /// Forwards the overlay's selection changes into the model so the hint
    /// can say what the verbs will act on. The callback is macOS 14+ — on 13
    /// the hint just never switches to "your selection", consistent with
    /// verbs acting on the full transcript there.
    final class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
        private let model: CapturePreviewModel

        init(model: CapturePreviewModel) {
            self.model = model
        }

        @available(macOS 14.0, *)
        func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
            model.hasSelection = overlayView.hasActiveTextSelection
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let imageView = NSImageView()
        imageView.image = image
        // Down-only: the frame already fits the image, and upscaling a small
        // capture would just blur it.
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection]
        overlay.delegate = context.coordinator
        // Our verb row replaces the system's Live Text pill — two competing
        // affordances in one small panel is one too many.
        overlay.isSupplementaryInterfaceHidden = true
        // Sibling above the image view; the framework keeps the overlay's
        // geometry synced to the drawn image rect.
        overlay.trackingImageView = imageView
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]

        container.addSubview(imageView)
        container.addSubview(overlay)
        model.overlayView = overlay
        attachAnalysisIfReady(to: overlay)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The analysis usually lands after the first layout; the phase
        // publish brings us back here to attach it once it exists.
        if let overlay = model.overlayView {
            attachAnalysisIfReady(to: overlay)
        }
    }

    private func attachAnalysisIfReady(to overlay: ImageAnalysisOverlayView) {
        guard overlay.analysis == nil, let analysis = model.analysis else { return }
        overlay.analysis = analysis
    }
}
