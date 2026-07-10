import AppKit
import SwiftUI

/// Talkeo's web palette ported to native. The brand is monochrome: near-black /
/// near-white foreground over neutral gray surfaces, no colored accent. Each
/// token resolves per light/dark appearance.
enum Palette {
    static let surface = dynamic(0xFFFFFF, 0x1C1C1C)   // popover
    static let elevated = dynamic(0xF5F5F5, 0x242424)  // muted / secondary surface
    static let foreground = dynamic(0x111111, 0xDEDEDE)
    static let muted = dynamic(0x555555, 0x8A8A8A)     // muted-foreground
    static let tertiary = dynamic(0xBBBBBB, 0x606060)
    static let border = dynamic(0xEBEBEB, 0x3A3A3A)
    // Solid CTA fill, shadcn's "primary": the inverted monochrome chip — the
    // brand has no colored accent, so primary actions read by contrast, not hue.
    static let primary = dynamic(0x111111, 0xDEDEDE)
    static let primaryForeground = dynamic(0xFAFAFA, 0x1C1C1C)

    static func dynamic(_ light: UInt, _ dark: UInt) -> Color {
        Color(nsColor: nsDynamic(light, dark))
    }

    static func nsDynamic(_ light: UInt, _ dark: UInt) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    static func rgb(_ hex: UInt) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Neutral marker; the focused span reads stronger.
    static func marker(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = rgb(isDark ? 0xDEDEDE : 0x111111)
            return base.withAlphaComponent(active ? 0.18 : 0.08)
        }
    }

    static let nsForeground = nsDynamic(0x111111, 0xDEDEDE)
}
