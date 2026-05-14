import AppKit
import ApplicationServices

final class AccessibilityPermission {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the macOS system prompt + opens System Settings if needed.
    func requestIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
