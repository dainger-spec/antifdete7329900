import AppKit
import SwiftUI

/// The colours of what Lumen itself draws in or for a profile's window: its own chrome when
/// Safari's is not hosted ("Simplified mode", `BrowserChrome`, the tab strip, the address bar),
/// that mode's chip and its explanation, and the profile's library window. The owner, 1 November:
/// a profile's window must look like Safari, not like Lumen — the redesign ("Eclipse",
/// `Theme`, docs/DESIGN.md) is for the app's own windows and does not go a step inside a
/// profile's. So these keep the values they had before it, on purpose, and do not follow `Theme`.
enum ProfileWindowTheme {
    static let surface = Color(hex: 0x161920)
    static let card = Color(hex: 0x1B1F27)
    static let raised = Color(hex: 0x1E222A)
    static let field = Color(hex: 0x0F1115)
    static let hairline = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.06)
    static let fieldBorder = Color.white.opacity(0.10)
    static let strongBorder = Color.white.opacity(0.14)
    static let textPrimary = Color(hex: 0xECEEF2)
    static let textSecondary = Color(hex: 0xA2A9B6)
    static let textTertiary = Color(hex: 0x7C8494)
    static let accent = Color(hex: 0x6F8FEA)
    static let accentTint = Color(hex: 0x6F8FEA, opacity: 0.14)
    static let warning = Color(hex: 0xD9A441)
    static let danger = Color(hex: 0xE5635C)
    static let rowHover = Color.white.opacity(0.04)
    static let controlRadius: CGFloat = 6
    static let hoverAnimation = Animation.easeOut(duration: 0.16)

    /// The same, for AppKit-drawn chrome (the window, the tab strip, the address bar).
    enum NS {
        static let surface = NSColor(hex: 0x161920)
        static let toolbar = NSColor(hex: 0x1A1D24)
        static let raised = NSColor(hex: 0x1E222A)
        static let tabSelected = NSColor(hex: 0x22262E)
        static let hairline = NSColor.white.withAlphaComponent(0.08)
        static let divider = NSColor.white.withAlphaComponent(0.07)
        static let hover = NSColor.white.withAlphaComponent(0.05)
        static let field = NSColor(hex: 0x0F1115)
        static let fieldBorder = NSColor.white.withAlphaComponent(0.10)
        static let textPrimary = NSColor(hex: 0xECEEF2)
        static let textSecondary = NSColor(hex: 0xA2A9B6)
        static let textTertiary = NSColor(hex: 0x7C8494)
        static let accent = NSColor(hex: 0x6F8FEA)
    }
}

extension View {
    /// A tone of white under the pointer, as the profile's window has always had it.
    func profileWindowHoverHighlight(cornerRadius: CGFloat = 0, isOn: Bool = true) -> some View {
        modifier(ProfileWindowHoverHighlight(cornerRadius: cornerRadius, isOn: isOn))
    }
}

private struct ProfileWindowHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let isOn: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isOn && hovered ? ProfileWindowTheme.rowHover : .clear))
            .onHover { hovered = $0 }
            .animation(ProfileWindowTheme.hoverAnimation, value: hovered)
    }
}
