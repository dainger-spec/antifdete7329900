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

    // MARK: Light on raised things — computed: a stored gradient may not be Sendable under Swift 6

    /// A contour lit from above, like the eclipse's rim: brighter at its top edge, never under `edge`
    /// at its foot (3 : 1 kept). Under the pointer: `edgeLitStrong`.
    static var edgeLit: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.46), Color.white.opacity(0.32)], startPoint: .top, endPoint: .bottom)
    }
    static var edgeLitStrong: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.64), Color.white.opacity(0.50)], startPoint: .top, endPoint: .bottom)
    }
    /// A raised control's face (a contour button, the chosen segment, a key cap): a shade lighter at the top.
    static var faceLit: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x16171C), Color(hex: 0x101115)], startPoint: .top, endPoint: .bottom)
    }
    static var faceLitHover: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x1C1D23), Color(hex: 0x15161B)], startPoint: .top, endPoint: .bottom)
    }
    /// The chosen segment's or a key cap's quieter edge.
    static var pillEdge: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.07)], startPoint: .top, endPoint: .bottom)
    }
    /// The lit top edge of anything raised (a contour button, a sheet, a floating bar): 1 pt, white
    /// 9 % at the top, clear by the middle.
    static var lipLight: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0)], startPoint: .top, endPoint: .center)
    }
    /// A sheet's footer band: a shade under `raised` (#0E0F12 over it), so the footer reads recessed.
    static let sheetFooterBand = Color.black.opacity(0.22)

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
    /// "All in order": the running green's tint and line, for a box that says nothing is wrong.
    static let runningTint = Color(hex: 0x5FD39B, opacity: 0.07)
    static let runningLine = Color(hex: 0x5FD39B, opacity: 0.24)

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

/// The system's SF Pro: large titles semibold and dense, with negative tracking (`lumenPageTitle()`
/// and its siblings set it); section captions small capitals with wide tracking (`lumenCaps()`);
/// paragraphs with room between their lines (`lumenProse()`).
extension Font {
    /// The lock screen's title: 32 / semibold (tracking −3 %: `lumenDisplayTitle()`).
    static let lumenDisplay = Font.system(size: 32, weight: .semibold)
    /// Window and page titles: 30 / semibold (tracking −3 %: `lumenPageTitle()`).
    static let lumenTitle = Font.system(size: 30, weight: .semibold)
    /// A profile's name in its inspector and editor: 22 / semibold (−2.3 %: `lumenHeadingTitle()`).
    static let lumenHeading = Font.system(size: 22, weight: .semibold)
    /// Sheet titles: 17 / semibold (`SheetHeader` tightens it by 0.2).
    static let lumenSheetTitle = Font.system(size: 17, weight: .semibold)
    /// A page's sentence under its title (Settings): 14.
    static let lumenLead = Font.system(size: 14)
    /// A 28 pt button's or a segment's words: 12.5 / medium.
    static let lumenControl = Font.system(size: 12.5, weight: .medium)
    /// Chips, "+N", badges: 10.5 / medium.
    static let lumenMicro = Font.system(size: 10.5, weight: .medium)
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
    /// 32 / semibold, tracking −3 %.
    func lumenDisplayTitle() -> some View { font(.lumenDisplay).tracking(-1.0) }
    /// 30 / semibold, tracking −3 %.
    func lumenPageTitle() -> some View { font(.lumenTitle).tracking(-0.9) }
    /// 22 / semibold, tracking −2.3 %.
    func lumenHeadingTitle() -> some View { font(.lumenHeading).tracking(-0.5) }
    /// A section caption: 11 / semibold, capitals, tracking +8 %, `t3` (`red` for attention); its
    /// figures of one width, so that counts in captions line up.
    func lumenCaps(_ color: Color = Theme.textTertiary) -> some View {
        font(.lumenColumn).monospacedDigit().tracking(0.88).textCase(.uppercase).foregroundStyle(color)
    }

    /// A paragraph (an explanation, a page's or a sheet's sentence): `t2` by default, its lines
    /// `spacing` apart, wrapped rather than cut — a block of grey with no room between its lines
    /// read as one slab.
    func lumenProse(_ color: Color = Theme.textSecondary, font: Font = .lumenBody, spacing: CGFloat = 2.5) -> some View {
        self.font(font).foregroundStyle(color).lineSpacing(spacing).fixedSize(horizontal: false, vertical: true)
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
/// radius 10, a 1 pt edge lit from above (`edgeLit`, 46 → 32 % white) on a face lit the same way
/// (`faceLit`), with a lip of light along its top (`lipLight`) and a faint light resting under it;
/// under the pointer the edge goes to 64 → 50 %, the face a shade lighter, and the light under it
/// gathers. `secondary` — the same, 28 pt (radius 9), with light under it only under the pointer.
/// With Increase Contrast both are flat: the 50 % edge, a flat fill, no lip and no light.
/// `ghost` — quiet: text only until the pointer is over it. `destructive` — red: quiet at 28 pt
/// (rows, the selection bar); at 32 pt (a sheet's main action) a red contour, `dangerLine`,
/// `danger` under the pointer or with Increase Contrast. A press sinks to 98 % for 80 ms (not
/// under Reduce Motion); a disabled button is at 40 %.
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
                .font(height >= Theme.buttonHeight ? Font.lumenLabel : Font.lumenControl)
                .lineLimit(1)
                .fixedSize(horizontal: !fullWidth, vertical: false)
                .padding(.horizontal, height >= Theme.buttonHeight ? 14 : 11)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                // The lip over the contour: the top edge reads brighter than the sides, while the
                // contour itself keeps its 3 : 1.
                .overlay {
                    if isLit { shape.strokeBorder(Theme.lipLight, lineWidth: 1) }
                }
                .shadow(color: Theme.rim.opacity(glow), radius: 15, y: 8)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !Motion.isReduced(reduceMotion) ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
                .animation(Motion.hover(hovered), value: hovered)
                .animation(Motion.press, value: configuration.isPressed)
        }

        private var radius: CGFloat { height >= Theme.buttonHeight ? Theme.cornerRadius : Theme.controlRadius }
        private var isContour: Bool { kind == .primary || kind == .secondary }
        /// A contour drawn lit from above; Increase Contrast keeps it flat.
        private var isLit: Bool { isContour && contrast != .increased }

        /// The light under a contour: under the main button always (6 %, 18 % under the pointer),
        /// under a secondary one only under the pointer; none when disabled or with Increase Contrast.
        private var glow: Double {
            guard isEnabled, isLit else { return 0 }
            if kind == .primary { return hovered ? 0.18 : 0.06 }
            return hovered ? 0.16 : 0
        }

        private var foreground: Color {
            switch kind {
            case .primary, .secondary: return Theme.textPrimary
            case .ghost: return hovered ? Theme.textPrimary : Theme.textSecondary
            case .destructive: return Theme.danger
            }
        }

        private var fill: AnyShapeStyle {
            switch kind {
            case .primary, .secondary:
                if !isLit { return AnyShapeStyle(hovered ? Theme.raisedInset : Theme.card) }
                return AnyShapeStyle(hovered ? Theme.faceLitHover : Theme.faceLit)
            case .ghost: return AnyShapeStyle(hovered ? Theme.rowHover : Color.clear)
            case .destructive: return AnyShapeStyle(hovered ? Theme.dangerTint : Color.clear)
            }
        }

        private var border: AnyShapeStyle {
            if kind == .destructive {
                // A destructive main action (32 pt, a sheet's footer): a red contour; the quiet one in rows has none.
                guard height >= Theme.buttonHeight else { return AnyShapeStyle(Color.clear) }
                return AnyShapeStyle(hovered || contrast == .increased ? Theme.danger : Theme.dangerLine)
            }
            guard isContour else { return AnyShapeStyle(Color.clear) }
            // Increase Contrast: the flat contour at the strength it has under the pointer.
            if !isLit { return AnyShapeStyle(Theme.edgeStrong) }
            return AnyShapeStyle(hovered ? Theme.edgeLitStrong : Theme.edgeLit)
        }
    }
}

extension ButtonStyle where Self == LumenButtonStyle {
    static var lumenPrimary: LumenButtonStyle { LumenButtonStyle(kind: .primary) }
    static var lumenSecondary: LumenButtonStyle { LumenButtonStyle(kind: .secondary) }
    static var lumenGhost: LumenButtonStyle { LumenButtonStyle(kind: .ghost) }
    static var lumenDestructive: LumenButtonStyle { LumenButtonStyle(kind: .destructive) }
    /// Beside a 32 pt field (Check, Apply, Add, Icons…): the field's height, so that their edges line up.
    static var lumenFieldButton: LumenButtonStyle { LumenButtonStyle(kind: .secondary, height: Theme.buttonHeight) }
}

/// An icon-only button (the design's `ib`: ⋯, close, the inspector's toggle): `t2`, a tone of white
/// under the pointer; `isOn` stands raised — a lit face (`faceLit`) with a hairline (`strongBorder`
/// with Increase Contrast). A press sinks to 94 %.
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
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered || isOn ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(shape.fill(isOn ? AnyShapeStyle(Theme.faceLit)
                                            : AnyShapeStyle(hovered ? Theme.rowHover : Color.clear)))
                .overlay(shape.strokeBorder(isOn ? (contrast == .increased ? Theme.strongBorder : Theme.hairline) : Color.clear,
                                            lineWidth: 1))
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
    /// Lumen's text field look for a `TextField` or `SecureField`: `field` black, a 10 % edge, a faint
    /// shadow inside its top edge (recessed), radius 9; focused — the edge at 50 % and a 3 pt ring of
    /// 6 % white; `error` — a red edge and ring. `height` nil: as tall as its lines (a multi-line
    /// field). `takesFocus`: the cursor starts in it — one field per screen.
    func lumenField(height: CGFloat? = 32, error: Bool = false, takesFocus: Bool = false) -> some View {
        modifier(LumenField(height: height, placeholder: nil, error: error, takesFocus: takesFocus))
    }

    /// The same, with `placeholder` drawn in the tertiary colour while the field is empty. Give
    /// the field an empty prompt: macOS draws the prompt of an unfocused field almost as bright as
    /// its text, so an example there reads as a value.
    func lumenField(_ placeholder: String, isEmpty: Bool, height: CGFloat? = 32, error: Bool = false,
                    takesFocus: Bool = false) -> some View {
        modifier(LumenField(height: height, placeholder: isEmpty ? placeholder : nil, error: error, takesFocus: takesFocus))
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
    var takesFocus = false
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
            // Recessed: a faint shadow just inside the top edge. Not with Increase Contrast, where
            // the edge alone draws the field.
            .overlay {
                if contrast != .increased {
                    shape.inset(by: 1)
                        .stroke(LinearGradient(colors: [Color.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center),
                                lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 3, style: .continuous)
                .stroke(ring, lineWidth: 3)
                .padding(-3))
            .animation(Theme.hoverAnimation, value: focused)
            // The cursor starts here: one field per screen, as `LockPasswordField.takesFocus`.
            .onAppear { if takesFocus { focused = true } }
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

/// A pane's empty, blocked or failed state: a light symbol in a small eclipse (`EclipseRing`), a
/// title, a sentence, an optional quiet note and the action that leads on, centred in the room it
/// is given — one recipe, so that "nothing yet", "nothing found" and "could not" read alike.
/// `LumenEmptyHint` stays for an inspector's placeholder.
struct LumenEmptyState<Actions: View>: View {
    let symbol: String
    var tint: Color
    let title: String
    let text: String
    var note: String?
    let actions: Actions

    init(symbol: String, tint: Color = Theme.textTertiary, title: String, text: String, note: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.text = text
        self.note = note
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            EclipseRing(size: 64) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(tint)
            }
            .padding(.bottom, 18)
            .accessibilityHidden(true)
            Text(title)
                .font(.lumenSheetTitle)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: 400)
                .padding(.top, 6)
            if let note {
                Text(note)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .padding(.top, 8)
            }
            // No actions (the init without them): no empty row and no 20 pt gap under the text.
            if !(actions is EmptyView) {
                HStack(spacing: 8) { actions }
                    .padding(.top, 20)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension LumenEmptyState where Actions == EmptyView {
    init(symbol: String, tint: Color = Theme.textTertiary, title: String, text: String, note: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, text: text, note: note) { EmptyView() }
    }
}

/// A profile's glyph (the design's `av`): its letters — the first of its name, or the ones the
/// person chose — on a circle in the profile's colour, dark, with the letters in a light tone of it;
/// its face lit a little from above and its rim lit from above, as the eclipse's edge is (a flat
/// `strongBorder` with Increase Contrast). `running`: the green dot at its corner, ringed in the
/// window's black, with its glow. The colour is the person's choice (`ProfileConfiguration.avatar`)
/// or, without one, one from its id: the quickest way to tell profiles apart by eye among dozens,
/// which nothing else in the design does without reading or a click (the owner, 1 November).
struct ProfileAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 28
    /// The letters the person chose (`ProfileConfiguration.avatar`); nil: the first of the name.
    var style: ProfileAvatarStyle?
    var running = false
    @Environment(\.colorSchemeContrast) private var contrast

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
            // An emoji fills more of the circle than a letter does: it has no colour of the
            // palette's to stand out with.
            .font(.system(size: size * (isEmoji ? 0.5 : (glyph.count > 1 ? 0.34 : 0.4)), weight: .semibold))
            // Two letters ("NW") a little closer, so that they read as one mark.
            .tracking(glyph.count > 1 && !isEmoji ? -0.3 : 0)
            .foregroundStyle(Color(hex: colors.text))
            .frame(width: size, height: size)
            // The face: the letters' tone at 12 % from the top to the middle (the lightest spot
            // keeps the letters at 5.3 : 1).
            .background(Circle().fill(Color(hex: colors.fill))
                .overlay(Circle().fill(LinearGradient(colors: [Color(hex: colors.text).opacity(0.12), .clear],
                                                      startPoint: .top, endPoint: .center))))
            .overlay(Circle().strokeBorder(rim(large), lineWidth: 1))
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

    /// The rim, lit from above; flat `strongBorder` with Increase Contrast.
    private func rim(_ large: Bool) -> AnyShapeStyle {
        guard contrast != .increased else { return AnyShapeStyle(Theme.strongBorder) }
        return AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(large ? 0.24 : 0.18), Color.white.opacity(0.04)],
                                            startPoint: .top, endPoint: .bottom))
    }

    /// The glyph is a picture (an emoji, a flag), not letters or a sign drawn in the text's colour.
    private var isEmoji: Bool {
        glyph.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
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
                    .font(.lumenMicro)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

/// Turns off the system's selection highlight in the table a SwiftUI `List` is drawn with, so that
/// its rows show the design's tone instead (`listRowBackground`): the system's was a grey bar of
/// its own (CI run 555's proxies) or, under the app's white tint, white behind white words (the
/// editor's saved proxies, the passwords). The selection itself — a click, ⌘ and ⇧, the arrow
/// keys, the context menu, Delete — is still the table's. Found no table: nothing.
struct SystemListHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view {
                    if let table = current as? NSTableView {
                        if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                        return
                    }
                    view = current.superview
                }
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
                .font(.lumenMicro)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    // The whole height of the chip, not the 8 pt glyph alone, takes the click.
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: L("editor.tags.remove"), text))
            }
        }
        // The × carries its own room on the right: a removable chip keeps (almost) its width.
        .padding(.leading, 7)
        .padding(.trailing, onRemove == nil ? 7 : 2)
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

/// Something happening now (warming up, syncing, recording, a check): a 6 pt dot that breathes from
/// 100 to 40 % and back every 1.6 s while `active`. Still under Reduce Motion, with the animations
/// off in Settings → Appearance, and in the self-test's still frame. Beside words that say the
/// state: the dot never tells it alone.
struct LiveDot: View {
    var tone: Color = Theme.textSecondary
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame
    @State private var dim = false

    private var moves: Bool { active && !stillFrame && !Motion.isReduced(reduceMotion) }

    var body: some View {
        Circle().fill(tone)
            .frame(width: 6, height: 6)
            .opacity(moves && dim ? 0.4 : 1)
            // The repeating animation runs only while it moves; stopping sets `dim` back under a
            // plain one, which replaces the repeating one.
            .animation(moves ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : Animation.default,
                       value: dim)
            .onAppear { dim = moves }
            .onChange(of: moves) { _, now in dim = now }
            .accessibilityHidden(true)
    }
}
