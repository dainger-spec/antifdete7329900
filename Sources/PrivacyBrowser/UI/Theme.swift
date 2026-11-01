import AppKit
import BrowserCore
import SwiftUI

/// Lumen's design tokens — "Eclipse" (the design approved on 1 November 2026): a monochrome near-
/// black interface. Five surfaces a shade apart, hairlines of white at low alpha, white text.
/// There is no accent colour: selection, focus and the main button are white; colour appears
/// only where a state needs it — green for running, red for failed, amber for attention. Depth
/// comes from hairlines and from the one light effect (`EclipseLight`), not from shadows.
///
/// The app's own windows are always dark (`Theme.chromeAppearance`). Web content is not: it
/// follows this Mac's light/dark setting, as it does in Safari (see `WebContentAppearance`), so
/// pages see the same `prefers-color-scheme` they would in Safari.
enum Theme {
    // MARK: The black scale — each a shade lighter than the one below it

    /// `bg` — the window, the lock screen, under everything.
    static let backdrop = Color(hex: 0x08090B)
    /// `bg2` — side panels (sidebar, inspector), drawn at 80 % over the light (`frost`).
    static let sidebar = Color(hex: 0x0B0C0F)
    /// A window's content: the same black as the window; panels and light give it depth.
    static let surface = Color(hex: 0x08090B)
    static let toolbar = Color(hex: 0x08090B)
    /// `bg3` — buttons, the mark's tile, menus and popovers, the few tiles left.
    static let card = Color(hex: 0x111216)
    /// Floating panels: the command palette, the bulk bar, menus, toasts.
    static let raised = Color(hex: 0x121317)
    /// `bg4` — a button under the pointer; a panel inside a sheet.
    static let raisedInset = Color(hex: 0x17181D)
    /// Text fields.
    static let field = Color(hex: 0x0D0E11)
    /// A profile's letters' circle.
    static let avatarFill = Color(hex: 0x141519)

    // MARK: Lines — white at 6 / 10 / 16 %, and a button's edge at 32 / 50 %

    /// `line` — separators between rows.
    static let divider = Color.white.opacity(0.06)
    /// `line2` — the edges of fields, cards and segments.
    static let hairline = Color.white.opacity(0.10)
    static let fieldBorder = Color.white.opacity(0.10)
    /// `line3` — contours of chips, checkboxes, a field's edge on the lock screen.
    static let strongBorder = Color.white.opacity(0.16)
    /// `edge` — a button's contour: 3 : 1 against the window.
    static let edge = Color.white.opacity(0.32)
    /// `edge2` — the contour under the pointer, and of a focused field.
    static let edgeStrong = Color.white.opacity(0.50)

    // MARK: Text (contrast against `backdrop`)

    /// `t1` — 18.1 : 1
    static let textPrimary = Color(hex: 0xF4F4F5)
    /// `t2` — 7.8 : 1: explanations, counters, secondary text.
    static let textSecondary = Color(hex: 0xA1A1AA)
    /// `t3` — 5.5 : 1: section captions, meta, footnotes.
    static let textTertiary = Color(hex: 0x85858E)
    /// `t4` — 2.7 : 1: only what is inactive.
    static let textDisabled = Color(hex: 0x56565E)

    // MARK: Selection and states — white for selection; colour only for a state

    /// What used to be the accent: links, the selected item, focus — white now.
    static let accent = Color(hex: 0xF4F4F5)
    /// Fills: a switch that is on, progress.
    static let accentFill = Color(hex: 0xF4F4F5)
    /// A selected row or item.
    static let accentTint = Color.white.opacity(0.065)
    static let accentTintStrong = Color.white.opacity(0.09)
    /// "Running": the dot, with its glow (`greenDot`), and running text.
    static let running = Color(hex: 0x5FD39B)
    static let greenDot = Color(hex: 0x4ADE80)
    /// "Needs a login", attention.
    static let warning = Color(hex: 0xE3A53C)
    /// "Did not start", errors, deletion.
    static let danger = Color(hex: 0xF2706A)
    static let dangerTint = Color(hex: 0xF2706A, opacity: 0.07)
    static let dangerLine = Color(hex: 0xF2706A, opacity: 0.24)
    static let warningTint = Color(hex: 0xE3A53C, opacity: 0.06)
    static let warningLine = Color(hex: 0xE3A53C, opacity: 0.24)

    /// A row or item under the pointer: 3.5 % white.
    static let rowHover = Color.white.opacity(0.035)
    /// A selected row: 6.5 % white.
    static let rowSelected = Color.white.opacity(0.065)
    static let controlFill = Color(hex: 0x111216)
    static let controlHover = Color(hex: 0x17181D)

    /// The main button is a contour, not a fill (`LumenButtonStyle`); these remain for what still
    /// needs a light surface.
    static let primaryFill = Color(hex: 0x111216)
    static let primaryHover = Color(hex: 0x17181D)
    static let primaryText = Color(hex: 0xF4F4F5)

    /// The light at an eclipse's edge (`rim`): a cool white, rgb 236 240 248.
    static let rim = Color(.sRGB, red: 236 / 255, green: 240 / 255, blue: 248 / 255, opacity: 1)

    // MARK: Brand

    static let markTile = Color(hex: 0x111216)
    static let markGlyph = Color(hex: 0xF4F4F5)

    // MARK: Names the other views have used since the light theme

    static var pageBackground: Color { surface }
    static var cardBackground: Color { card }
    static var fieldBackground: Color { field }
    static var separator: Color { divider }
    static var runningDot: Color { greenDot }

    // MARK: Metrics — a 4/8 grid; one radius per kind of thing

    /// Rows, cards, buttons, search fields.
    static let cornerRadius: CGFloat = 10
    /// Small controls: fields, popups, segments, small buttons.
    static let controlRadius: CGFloat = 9
    static let spacing: CGFloat = 12
    static let controlHeight: CGFloat = 28
    /// A main button.
    static let buttonHeight: CGFloat = 32

    // MARK: Motion — calm, short; see `Motion` for what Reduce Motion keeps

    /// Hover and state changes: a tone change only — appears at once, fades in 150 ms.
    static let hoverAnimation = Animation.easeOut(duration: 0.15)
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

    /// The app's own windows (Profiles, Settings): dark, and the window itself in the backdrop's
    /// tone, so that nothing of the system's grey can show where the content does not reach — the
    /// owner's Settings window had a light grey band at its foot (1 November). A profile's window
    /// keeps its own (`ProfileWindowTheme`).
    @MainActor
    static func applyAppWindow(to window: NSWindow) {
        applyChrome(to: window)
        window.backgroundColor = NS.backdrop
    }

    /// The same tokens for AppKit-drawn chrome (browser windows, the tab strip).
    enum NS {
        static let backdrop = NSColor(hex: 0x08090B)
        static let surface = NSColor(hex: 0x0B0C0F)
        static let toolbar = NSColor(hex: 0x0B0C0F)
        static let raised = NSColor(hex: 0x121317)
        static let tabSelected = NSColor(hex: 0x17181D)
        static let hairline = NSColor.white.withAlphaComponent(0.10)
        static let divider = NSColor.white.withAlphaComponent(0.06)
        static let hover = NSColor.white.withAlphaComponent(0.035)
        static let field = NSColor(hex: 0x0D0E11)
        static let fieldBorder = NSColor.white.withAlphaComponent(0.10)
        static let textPrimary = NSColor(hex: 0xF4F4F5)
        static let textSecondary = NSColor(hex: 0xA1A1AA)
        static let textTertiary = NSColor(hex: 0x85858E)
        static let accent = NSColor(hex: 0xF4F4F5)
    }
}

// MARK: - Typography

/// The system's SF Pro: large titles dense, with negative tracking (`lumenPageTitle()` and its
/// siblings set it); section captions small capitals with wide tracking (`lumenCaps()`).
extension Font {
    /// The lock screen's title: 32 / bold (tracking −2.5 %: `lumenDisplayTitle()`).
    static let lumenDisplay = Font.system(size: 32, weight: .bold)
    /// Window and page titles: 30 / bold (tracking −2.5 %: `lumenPageTitle()`).
    static let lumenTitle = Font.system(size: 30, weight: .bold)
    /// A profile's name in its inspector and editor: 22 / bold (−2 %: `lumenHeadingTitle()`).
    static let lumenHeading = Font.system(size: 22, weight: .bold)
    /// Sheet titles: 15 / semibold.
    static let lumenSheetTitle = Font.system(size: 15, weight: .semibold)
    /// Section titles and group headers: 13 / semibold.
    static let lumenSection = Font.system(size: 13, weight: .semibold)
    /// A setting's title: 14 / medium.
    static let lumenRowTitle = Font.system(size: 14, weight: .medium)
    static let lumenBody = Font.system(size: 13)
    static let lumenLabel = Font.system(size: 13, weight: .medium)
    static let lumenSecondary = Font.system(size: 12)
    static let lumenCaption = Font.system(size: 11)
    /// Column headers and section captions: 11 / semibold, small capitals (`lumenCaps()`).
    static let lumenColumn = Font.system(size: 11, weight: .semibold)
    /// Addresses, hosts, user agents: SF Mono 12.
    static let lumenMono = Font.system(size: 12, design: .monospaced)
}

extension View {
    /// 32 / bold, tracking −2.5 %.
    func lumenDisplayTitle() -> some View { font(.lumenDisplay).tracking(-0.8) }
    /// 30 / bold, tracking −2.5 %.
    func lumenPageTitle() -> some View { font(.lumenTitle).tracking(-0.75) }
    /// 22 / bold, tracking −2 %.
    func lumenHeadingTitle() -> some View { font(.lumenHeading).tracking(-0.44) }
    /// A section caption: 11 / semibold, capitals, tracking +8 %, `t3` (`red` for attention).
    func lumenCaps(_ color: Color = Theme.textTertiary) -> some View {
        font(.lumenColumn).tracking(0.88).textCase(.uppercase).foregroundStyle(color)
    }
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

/// Lumen's buttons (the design's `btn`): a contour, not a fill. `primary` — the main button: 32 pt,
/// radius 10, a 1 pt edge of 32 % white on `bg3`; under the pointer the edge goes to 50 %, the fill
/// a shade lighter, and a faint light gathers under it. `secondary` — the same, 28 pt (radius 9).
/// `ghost` — quiet: text only until the pointer is over it. `destructive` — quiet, in red. A
/// press sinks to 98 % for 80 ms (not under Reduce Motion); a disabled button is at 40 %.
struct LumenButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }

    var kind: Kind = .secondary
    /// Stretches to the width it is offered (sidebar Lock, sheet footers).
    var fullWidth = false
    /// Nil: 32 pt for the main button, 28 for the others.
    var height: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, fullWidth: fullWidth,
                     height: height ?? (kind == .primary ? Theme.buttonHeight : Theme.controlHeight))
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let fullWidth: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(height >= Theme.buttonHeight ? Font.lumenLabel : Font.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: !fullWidth, vertical: false)
                .padding(.horizontal, height >= Theme.buttonHeight ? 14 : 11)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .shadow(color: Theme.rim.opacity(isContour && hovered ? 0.16 : 0), radius: 15, y: 8)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !Motion.isReduced(reduceMotion) ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
                .animation(Motion.hover(hovered), value: hovered)
                .animation(Motion.press, value: configuration.isPressed)
        }

        private var radius: CGFloat { height >= Theme.buttonHeight ? Theme.cornerRadius : Theme.controlRadius }
        private var isContour: Bool { kind == .primary || kind == .secondary }

        private var foreground: Color {
            switch kind {
            case .primary, .secondary: return Theme.textPrimary
            case .ghost: return hovered ? Theme.textPrimary : Theme.textSecondary
            case .destructive: return Theme.danger
            }
        }

        private var fill: Color {
            switch kind {
            case .primary, .secondary: return hovered ? Theme.raisedInset : Theme.card
            case .ghost: return hovered ? Theme.rowHover : .clear
            case .destructive: return hovered ? Theme.dangerTint : .clear
            }
        }

        private var border: Color {
            guard isContour else { return .clear }
            // Increase Contrast: the contour at the strength it has under the pointer.
            return hovered || contrast == .increased ? Theme.edgeStrong : Theme.edge
        }
    }
}

extension ButtonStyle where Self == LumenButtonStyle {
    static var lumenPrimary: LumenButtonStyle { LumenButtonStyle(kind: .primary) }
    static var lumenSecondary: LumenButtonStyle { LumenButtonStyle(kind: .secondary) }
    static var lumenGhost: LumenButtonStyle { LumenButtonStyle(kind: .ghost) }
    static var lumenDestructive: LumenButtonStyle { LumenButtonStyle(kind: .destructive) }
}

/// An icon-only button (the design's `ib`: ⋯, close, the inspector's toggle): `t2`, a tone of white
/// under the pointer; `isOn` keeps the selected tone. A press sinks to 94 %.
struct LumenIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        StyledIconButton(configuration: configuration, size: size, isOn: isOn)
    }

    private struct StyledIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered || isOn ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(isOn ? Theme.rowSelected : (hovered ? Theme.rowHover : .clear)))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed && !Motion.isReduced(reduceMotion) ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
                .animation(Motion.hover(hovered), value: hovered)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

// MARK: - Fields

extension View {
    /// Lumen's text field look for a `TextField` or `SecureField`: `field` black, a 10 % edge,
    /// radius 9; focused — the edge at 50 % and a 3 pt ring of 6 % white; `error` — a red edge and
    /// ring. `height` nil: as tall as its lines (a multi-line field).
    func lumenField(height: CGFloat? = 32, error: Bool = false) -> some View {
        modifier(LumenField(height: height, placeholder: nil, error: error))
    }

    /// The same, with `placeholder` drawn in the tertiary colour while the field is empty. Give
    /// the field an empty prompt: macOS draws the prompt of an unfocused field almost as bright as
    /// its text, so an example there reads as a value.
    func lumenField(_ placeholder: String, isEmpty: Bool, height: CGFloat? = 32, error: Bool = false) -> some View {
        modifier(LumenField(height: height, placeholder: isEmpty ? placeholder : nil, error: error))
    }

    /// The same, for a field whose text holds a secret (a proxy string's password): while the field
    /// is not being edited, `masked` — the text with the secret as dots — covers it. Nil: nothing
    /// in the text is secret.
    func lumenField(_ placeholder: String, isEmpty: Bool, masked: String?, error: Bool = false) -> some View {
        modifier(LumenField(height: 32, placeholder: isEmpty ? placeholder : nil, masked: masked, error: error))
    }
}

private struct LumenField: ViewModifier {
    let height: CGFloat?
    let placeholder: String?
    var masked: String?
    var error = false
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(.lumenBody)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .overlay(alignment: height == nil ? .topLeading : .leading) {
                if let placeholder {
                    Text(placeholder)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 11)
            .overlay(alignment: .leading) {
                // Opaque, over the text and the field's margins inside its border: AppKit draws the
                // text past the text field's own edge (views do not clip to their bounds since
                // macOS 14), so a mask only the text's width let the real line's last glyph show
                // beside it — a password's, where the password reaches the edge. A click goes
                // through to the field, which then shows it all.
                if let masked, !focused {
                    Text(verbatim: masked)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(Theme.field)
                        .padding(.horizontal, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, height == nil ? 7 : 0)
            .frame(height: height)
            .frame(minHeight: height == nil ? 32 : nil)
            .background(shape.fill(Theme.field))
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 3, style: .continuous)
                .stroke(ring, lineWidth: 3)
                .padding(-3))
            .animation(Theme.hoverAnimation, value: focused)
    }

    private var edge: Color {
        if error { return Theme.danger }
        if focused { return Theme.edgeStrong }
        return contrast == .increased ? Theme.strongBorder : Theme.fieldBorder
    }

    private var ring: Color {
        if error { return Theme.dangerTint }
        return focused ? Color.white.opacity(0.06) : .clear
    }
}

// MARK: - Containers and small parts

extension View {
    /// A tile (`bg3` on a window, `bg4` in a sheet), a 10 % hairline, radius 12. The design keeps
    /// few: most of what was a card is now rows on separators.
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = 12, fill: Color = Theme.card) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// The tone of a row under the pointer: at once on, 150 ms off; no lift.
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
            .animation(Motion.hover(hovered), value: hovered)
    }
}

/// A section's symbol: a thin icon, no tile (the design replaced the coloured tiles). `tint` colours
/// the symbol for a state (amber for attention, red for a problem); the default is `t2`.
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A quiet empty state: a symbol over a line or two of text, centred in the room it is given.
struct LumenEmptyHint: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A profile's glyph (the design's `av`): its letters — the first of its name, or the ones the
/// person chose — on a circle in the profile's colour, dark, with the letters in a light tone of it,
/// and a hairline. `running`: the green dot at its corner, ringed in the window's black, with its
/// glow. The colour is the person's choice (`ProfileConfiguration.avatar`) or, without one, one
/// from its id: the quickest way to tell profiles apart by eye among dozens, which nothing else in
/// the design does without reading or a click (the owner, 1 November).
struct ProfileAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 28
    /// The letters the person chose (`ProfileConfiguration.avatar`); nil: the first of the name.
    var style: ProfileAvatarStyle?
    var running = false

    /// The profiles' colours, `ProfileAvatarStyle.colorCount` of them: a dark fill and a light tone
    /// for the letters. The first `ProfileAvatarStyle.idColorCount` are given by an id.
    static let palette: [(fill: UInt32, text: UInt32)] = [
        (0x273553, 0xB9C8F0), // blue
        (0x243A33, 0x9FD4BB), // green
        (0x3B332A, 0xE0CDB3), // sand
        (0x312C45, 0xC9BCEB), // lavender
        (0x2A2F3A, 0xC3C9D4), // gray
        (0x1F3A3D, 0x9ED8DB), // teal
        (0x3D2630, 0xEAB8C8), // rose
        (0x34361F, 0xD6D9A0), // olive
    ]
    static func colors(for id: UUID) -> (fill: UInt32, text: UInt32) {
        palette[ProfileAvatarStyle.color(for: id)]
    }

    static func colors(for id: UUID, style: ProfileAvatarStyle?) -> (fill: UInt32, text: UInt32) {
        guard let index = style?.color, palette.indices.contains(index) else { return colors(for: id) }
        return palette[index]
    }

    /// The same palette for anything named by a string (a site's host).
    static func colors(forKey key: String) -> (fill: UInt32, text: UInt32) {
        palette[key.utf8.reduce(0) { $0 &+ Int($1) } % ProfileAvatarStyle.idColorCount]
    }

    var body: some View {
        let large = size >= 44
        let colors = Self.colors(for: id, style: style)
        Text(glyph)
            .font(.system(size: size * (glyph.count > 1 ? 0.34 : 0.4), weight: .semibold))
            .foregroundStyle(Color(hex: colors.text))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: colors.fill)))
            .overlay(Circle().strokeBorder(large ? Theme.strongBorder : Theme.hairline, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if running {
                    let dot = large ? 12.0 : max(7, size * 0.3)
                    Circle().fill(Theme.greenDot)
                        .frame(width: dot, height: dot)
                        .shadow(color: Theme.greenDot.opacity(0.55), radius: 4)
                        .overlay(Circle().stroke(Theme.backdrop, lineWidth: large ? 3 : 2))
                        .offset(x: large ? -1 : 1, y: large ? -1 : 1)
                }
            }
            .accessibilityHidden(true)
    }

    /// The letters chosen, else the first letter of the name.
    private var glyph: String {
        if let letters = style?.letters, !letters.isEmpty { return letters }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "·"
    }
}

/// A profile's tags as small chips, at most `limit` and "+N" for the rest — and only as many whole
/// chips as there is room for: a chip squeezed to "…" or to one letter says nothing.
struct TagChips: View {
    let tags: [String]
    var limit = Int.max
    @Environment(\.tagColors) private var tagColors

    var body: some View {
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: min(tags.count, limit), through: 0, by: -1)), id: \.self) { shown in
                    chips(shown)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func chips(_ shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(shown), id: \.self) { tag in
                TagChip(text: tag, color: tagColors.color(of: tag)).fixedSize()
            }
            if tags.count > shown {
                Text(verbatim: "+\(tags.count - shown)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

/// A tag's colour (`TagColors`): a small dot in the palette's light tone. A dot, never a circle with
/// letters, so that it is not read as a profile's glyph: tags group by meaning, a glyph tells
/// profiles apart within a group (the owner, 1 November). Decoration: the tag's name says it.
struct TagDot: View {
    let color: Int
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Self.tone(color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func tone(_ color: Int) -> Color {
        let palette = ProfileAvatar.palette
        return Color(hex: palette[((color % palette.count) + palette.count) % palette.count].text)
    }

    /// The colour's name, for the menu that chooses it.
    static func name(_ color: Int) -> String {
        L("tags.color.\(color)")
    }
}

/// A profile's tags as one line of text, each coloured one after its dot — a glyph inside the text,
/// so that the line still truncates as one: "● ads · DE".
enum TagLine {
    static func text(_ tags: [String], colors: TagColors) -> Text {
        var line = Text(verbatim: "")
        for (index, tag) in tags.enumerated() {
            if index > 0 { line = line + Text(verbatim: " · ") }
            if let color = colors.color(of: tag) {
                line = line
                    + Text(Image(systemName: "circle.fill")).font(.system(size: 6)).baselineOffset(1).foregroundStyle(TagDot.tone(color))
                    + Text(verbatim: "\u{2009}")
            }
            line = line + Text(verbatim: tag)
        }
        return line
    }
}

/// The tags' colours (`AppModel.tagColors`) for every view that shows tags.
private struct TagColorsKey: EnvironmentKey {
    static let defaultValue = TagColors()
}

extension EnvironmentValues {
    var tagColors: TagColors {
        get { self[TagColorsKey.self] }
        set { self[TagColorsKey.self] = newValue }
    }
}

/// One tag, with its colour's dot when it has one; with `onRemove`, a button that removes it.
struct TagChip: View {
    let text: String
    var color: Int?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            if let color {
                TagDot(color: color, size: 6)
                    .padding(.trailing, 1)
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: L("editor.tags.remove"), text))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .overlay(Capsule().strokeBorder(Theme.strongBorder, lineWidth: 1))
    }
}

/// Views in rows, as many as fit in each, wrapping to the next (tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A 2 pt progress bar: track at 12 % white, a white fill (`slow`: amber).
struct LumenProgressBar: View {
    /// 0…1
    let fraction: Double
    var width: CGFloat = 72
    var slow = false

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule().fill(slow ? Theme.warning : Theme.textPrimary)
                .frame(width: max(2, width * min(max(fraction, 0), 1)))
        }
        .frame(width: width, height: 2)
        .animation(Theme.hoverAnimation, value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((min(max(fraction, 0), 1) * 100).rounded())) %"))
    }
}

/// An indeterminate progress line: a short white segment sweeping along a 2 pt track (the
/// launch screen while the vault opens). Under Reduce Motion it stands still, centred.
struct LumenActivityLine: View {
    var width: CGFloat = 180
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let segment = width * 0.3
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let period = 1.4
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let eased = CGFloat(t * t * (3 - 2 * t))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Theme.textPrimary)
                    .frame(width: segment)
                    .offset(x: reduceMotion ? (width - segment) / 2 : -segment + (width + segment) * eased)
            }
            .frame(width: width, height: 2)
            .clipShape(Capsule())
        }
        .frame(width: width, height: 2)
        .accessibilityHidden(true)
    }
}

/// The 6 pt dot of "Running", with its glow. `ignites`: it lights up once, in 700 ms, when it
/// first appears (a profile that has just started); under Reduce Motion it simply appears.
struct RunningDot: View {
    var ignites = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        Circle().fill(Theme.greenDot)
            .frame(width: 6, height: 6)
            .shadow(color: Theme.greenDot.opacity(0.6), radius: 4)
            .scaleEffect(ignites && !lit && !Motion.isReduced(reduceMotion) ? 0.2 : 1)
            .opacity(ignites && !lit ? 0 : 1)
            .onAppear {
                guard ignites, !lit else { return }
                withAnimation(Motion.isReduced(reduceMotion) ? nil : Motion.ignite) { lit = true }
            }
            .accessibilityHidden(true)
    }
}
