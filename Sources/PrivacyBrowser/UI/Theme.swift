import AppKit
import SwiftUI

/// Lumen's design tokens: a dark, flat interface — near-black surfaces one tone apart, hairline
/// borders at low white alpha, one restrained blue for selection, links and focus, and a light
/// monochrome primary button. No gradients, glows or blur.
///
/// The app's own windows are always dark (`Theme.chromeAppearance`). Web content is not: it
/// follows this Mac's light/dark setting, as it does in Safari (see `WebContentAppearance`), so
/// pages see the same `prefers-color-scheme` they would in Safari.
enum Theme {
    // MARK: Surfaces — each one tone lighter than the one below it

    /// Behind everything (launch screen, empty window areas).
    static let backdrop = Color(hex: 0x0B0C0F)
    static let sidebar = Color(hex: 0x121419)
    /// A window's content.
    static let surface = Color(hex: 0x161920)
    static let toolbar = Color(hex: 0x1A1D24)
    /// Cards and tiles on `surface`.
    static let card = Color(hex: 0x1B1F27)
    /// Sheets, popovers, menus.
    static let raised = Color(hex: 0x1E222A)
    /// A panel inside a sheet (the editor's location row).
    static let raisedInset = Color(hex: 0x252A33)
    static let field = Color(hex: 0x0F1115)

    // MARK: Lines

    static let hairline = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.06)
    static let fieldBorder = Color.white.opacity(0.10)
    static let strongBorder = Color.white.opacity(0.14)

    // MARK: Text (contrast measured against `surface`)

    /// 14.6 : 1
    static let textPrimary = Color(hex: 0xECEEF2)
    /// 7.5 : 1
    static let textSecondary = Color(hex: 0xA2A9B6)
    /// 4.6 : 1 — captions and column headers
    static let textTertiary = Color(hex: 0x7C8494)
    static let textDisabled = Color(hex: 0x555D6C)

    // MARK: Accent and states

    /// Links, the selected sidebar icon, focus.
    static let accent = Color(hex: 0x6F8FEA)
    /// Fills: toggles on, the highlighted menu item, progress.
    static let accentFill = Color(hex: 0x5E84EB)
    static let accentTint = Color(hex: 0x6F8FEA, opacity: 0.14)
    static let accentTintStrong = Color(hex: 0x6F8FEA, opacity: 0.24)
    static let running = Color(hex: 0x4CC38A)
    static let warning = Color(hex: 0xD9A441)
    static let danger = Color(hex: 0xE5635C)

    static let rowHover = Color.white.opacity(0.04)
    static let rowSelected = Color(hex: 0x5E84EB, opacity: 0.14)
    static let controlFill = Color.white.opacity(0.06)
    static let controlHover = Color.white.opacity(0.09)

    /// The primary button is light and monochrome; the accent stays for selection and links.
    static let primaryFill = Color(hex: 0xE6E8ED)
    static let primaryHover = Color(hex: 0xF2F3F6)
    static let primaryText = Color(hex: 0x121419)

    // MARK: Brand

    static let markTile = Color(hex: 0x16181D)
    static let markGlyph = Color(hex: 0xF4F5F7)

    // MARK: Names the other views have used since the light theme

    static var pageBackground: Color { surface }
    static var cardBackground: Color { card }
    static var fieldBackground: Color { field }
    static var separator: Color { hairline }
    static var runningDot: Color { running }

    // MARK: Metrics — a 4/8 grid; one radius per kind of thing

    static let cornerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let spacing: CGFloat = 12
    static let controlHeight: CGFloat = 28

    // MARK: Motion — short, calm, no springs

    /// Hover and state changes: a tone change only.
    static let hoverAnimation = Animation.easeOut(duration: 0.16)
    /// Content appearing (a sheet's body, a list filtered).
    static let appearAnimation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)

    // MARK: AppKit

    /// The appearance of every window the app draws itself.
    static let chromeAppearance = NSAppearance(named: .darkAqua)

    /// Makes an AppKit window part of Lumen's dark chrome.
    @MainActor
    static func applyChrome(to window: NSWindow) {
        window.appearance = chromeAppearance
    }

    /// The same tokens for AppKit-drawn chrome (browser windows, the tab strip).
    enum NS {
        static let surface = NSColor(hex: 0x161920)
        static let toolbar = NSColor(hex: 0x1A1D24)
        static let raised = NSColor(hex: 0x1E222A)
        static let tabSelected = NSColor(hex: 0x22262E)
        static let hairline = NSColor.white.withAlphaComponent(0.08)
        static let divider = NSColor.white.withAlphaComponent(0.07)
        static let hover = NSColor.white.withAlphaComponent(0.05)
        static let textPrimary = NSColor(hex: 0xECEEF2)
        static let textSecondary = NSColor(hex: 0xA2A9B6)
        static let textTertiary = NSColor(hex: 0x7C8494)
        static let accent = NSColor(hex: 0x6F8FEA)
    }
}

// MARK: - Typography

extension Font {
    /// Window and page titles: 20 / semibold.
    static let lumenTitle = Font.system(size: 20, weight: .semibold)
    /// Sheet titles: 15 / semibold.
    static let lumenSheetTitle = Font.system(size: 15, weight: .semibold)
    /// Section titles and group headers: 13 / semibold.
    static let lumenSection = Font.system(size: 13, weight: .semibold)
    static let lumenBody = Font.system(size: 13)
    static let lumenLabel = Font.system(size: 13, weight: .medium)
    static let lumenSecondary = Font.system(size: 12)
    static let lumenCaption = Font.system(size: 11)
    /// Column headers: 11 / medium, sentence case.
    static let lumenColumn = Font.system(size: 11, weight: .medium)
}

// MARK: - Colours from hex

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Buttons

/// Lumen's buttons: 28 pt high, radius 6, 13 / medium. Hover changes the tone (160 ms), a press
/// dims to 85 %. `primary` is the light monochrome button (one per view), `secondary` a quiet
/// filled one with a hairline, `ghost` text only until hovered, `destructive` a ghost in red.
struct LumenButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }

    var kind: Kind = .secondary
    /// Stretches to the width it is offered (sidebar Lock, sheet footers).
    var fullWidth = false
    var height: CGFloat = Theme.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, fullWidth: fullWidth, height: height)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let fullWidth: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.lumenLabel)
                .lineLimit(1)
                .fixedSize(horizontal: !fullWidth, vertical: false)
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.45))
                .onHover { hovered = isEnabled && $0 }
                .animation(Theme.hoverAnimation, value: hovered)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Theme.primaryText
            case .secondary: return Theme.textPrimary
            case .ghost: return hovered ? Theme.textPrimary : Theme.textSecondary
            case .destructive: return Theme.danger
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: return hovered ? Theme.primaryHover : Theme.primaryFill
            case .secondary: return hovered ? Theme.controlHover : Theme.controlFill
            case .ghost, .destructive: return hovered ? Theme.controlFill : .clear
            }
        }

        private var border: Color {
            kind == .secondary ? Theme.fieldBorder : .clear
        }
    }
}

extension ButtonStyle where Self == LumenButtonStyle {
    static var lumenPrimary: LumenButtonStyle { LumenButtonStyle(kind: .primary) }
    static var lumenSecondary: LumenButtonStyle { LumenButtonStyle(kind: .secondary) }
    static var lumenGhost: LumenButtonStyle { LumenButtonStyle(kind: .ghost) }
    static var lumenDestructive: LumenButtonStyle { LumenButtonStyle(kind: .destructive) }
}

/// A 28 × 28 icon-only button (⋯, close, toolbar-like actions): secondary tone, filled on hover.
struct LumenIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        StyledIconButton(configuration: configuration, size: size)
    }

    private struct StyledIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(hovered ? Theme.controlFill : .clear))
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.45))
                .onHover { hovered = isEnabled && $0 }
                .animation(Theme.hoverAnimation, value: hovered)
        }
    }
}

// MARK: - Fields

extension View {
    /// Lumen's text field look for a `TextField` or `SecureField`: darker than the surface it sits
    /// on, a hairline, radius 6; the accent ring while focused. `height` nil: as tall as its lines
    /// (a multi-line field).
    func lumenField(height: CGFloat? = 32) -> some View {
        modifier(LumenField(height: height))
    }
}

private struct LumenField: ViewModifier {
    let height: CGFloat?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.lumenBody)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, height == nil ? 7 : 0)
            .frame(height: height)
            .frame(minHeight: height == nil ? 32 : nil)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.fieldBorder, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 2, style: .continuous)
                .stroke(Theme.accent.opacity(focused ? 0.30 : 0), lineWidth: 3)
                .padding(-2))
            .animation(Theme.hoverAnimation, value: focused)
    }
}

// MARK: - Containers and small parts

extension View {
    /// A tile one tone lighter than what it sits on (`fill`: `Theme.card` on a window,
    /// `Theme.raisedInset` in a sheet), a hairline, radius 10.
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = Theme.cornerRadius, fill: Color = Theme.card) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// The tone change of a hovered row (160 ms, no lift).
    func hoverHighlight(cornerRadius: CGFloat = 0, isOn: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isOn: isOn))
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let isOn: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isOn && hovered ? Theme.rowHover : .clear))
            .onHover { hovered = $0 }
            .animation(Theme.hoverAnimation, value: hovered)
    }
}

/// A flat SF Symbol tile used for section headers (a light tint of `tint`, no shadow).
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// A profile's glyph: its initial on one of five flat dark tints, chosen from its id so it stays
/// the same everywhere (Profiles list, editor, a browser window's profile chip).
struct ProfileAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 28

    private static let palette: [(fill: UInt32, text: UInt32)] = [
        (0x273553, 0xB9C8F0), // blue
        (0x243A33, 0x9FD4BB), // green
        (0x3B332A, 0xE0CDB3), // sand
        (0x312C45, 0xC9BCEB), // lavender
        (0x2A2F3A, 0xC3C9D4), // gray
    ]

    static func colors(for id: UUID) -> (fill: UInt32, text: UInt32) {
        // A stable index from the UUID's bytes (hashValue is seeded per launch).
        let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return palette[sum % palette.count]
    }

    var body: some View {
        let colors = Self.colors(for: id)
        Text(initial)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(Color(hex: colors.text))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color(hex: colors.fill)))
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "·"
    }
}

/// A 2 pt progress bar: track at 10 % white, accent fill.
struct LumenProgressBar: View {
    /// 0…1
    let fraction: Double
    var width: CGFloat = 72

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10))
            Capsule().fill(Theme.accentFill)
                .frame(width: max(2, width * min(max(fraction, 0), 1)))
        }
        .frame(width: width, height: 2)
        .animation(Theme.hoverAnimation, value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((min(max(fraction, 0), 1) * 100).rounded())) %"))
    }
}

/// The 7 pt status dot of a running profile (static; no pulsing).
struct RunningDot: View {
    var body: some View {
        Circle().fill(Theme.running).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}
