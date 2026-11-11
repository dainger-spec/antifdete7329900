import SwiftUI

/// The look of the app — "Eclipse" (the owner's design, 10 November 2026): a near-black ground with
/// the rim of an eclipse beyond the corners, panes of glass over it, white for the one action that
/// confirms, and colour only where it says something: green works, amber is locked, red is gone.
/// The app is dark whatever the iPhone's appearance is; a site still sees the iPhone's own
/// (BrowserTab).
enum Theme {
    static let ground = Color(red: 8 / 255, green: 9 / 255, blue: 11 / 255)
    static let text = Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
    static let secondary = Color(red: 161 / 255, green: 161 / 255, blue: 170 / 255)
    static let tertiary = Color(red: 133 / 255, green: 133 / 255, blue: 142 / 255)
    static let ok = Color(red: 95 / 255, green: 211 / 255, blue: 155 / 255)
    static let warn = Color(red: 227 / 255, green: 165 / 255, blue: 60 / 255)
    static let bad = Color(red: 242 / 255, green: 112 / 255, blue: 106 / 255)
    static let rim = Color(red: 236 / 255, green: 240 / 255, blue: 248 / 255)
    /// A row of a group on a sheet: glass where nothing lies behind but the sheet.
    static let row = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.12)
}

/// The ground of every screen: near-black, and two eclipsed discs beyond the top right and the
/// bottom left corners — only their lit rims reach into the screen. It never moves (a screen that
/// animates for ever never comes to rest).
struct EclipseBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            ZStack {
                Theme.ground
                // Only the discs are softened: the ground stays the ground, whatever lies behind.
                ZStack {
                    EclipseDisc(light: CGSize(width: -6, height: 4))
                        .frame(width: 660, height: 660)
                        .position(x: width + 130, y: -130)
                    EclipseDisc(light: CGSize(width: 6, height: -4))
                        .frame(width: 600, height: 600)
                        .position(x: -140, y: height + 120)
                }
                .opacity(0.9)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// One eclipsed disc: a soft halo, a glow, the bright rim — each a little off the centre toward the
/// light — and the dark body over them.
struct EclipseDisc: View {
    var light: CGSize

    var body: some View {
        ZStack {
            Circle().fill(Theme.rim.opacity(0.13)).blur(radius: 28).offset(x: light.width * 3.4, y: light.height * 3.4)
            Circle().fill(Theme.rim.opacity(0.3)).blur(radius: 5).offset(x: light.width * 1.4, y: light.height * 1.4)
            Circle().fill(Theme.rim.opacity(0.6)).blur(radius: 0.6).offset(light)
            Circle().fill(Color(red: 43 / 255, green: 46 / 255, blue: 53 / 255)).blur(radius: 11)
            Circle().fill(Theme.ground).blur(radius: 22).offset(x: -light.width * 5, y: -light.height * 5)
        }
    }
}

/// A pane of glass: the system's Liquid Glass where the iPhone has it (iOS 26), a thin material
/// with a lit edge before that.
struct GlassPane: ViewModifier {
    var radius: CGFloat
    /// Smoked glass: over a page that may be white, the pane stays dark and its white signs
    /// readable (the design's bottom bar).
    var smoked = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(smoked ? .regular.tint(Theme.ground.opacity(0.7)) : .regular, in: shape)
        } else {
            content
                .background(smoked ? AnyShapeStyle(Theme.ground.opacity(0.75)) : AnyShapeStyle(.clear), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }
}

/// The button that confirms: white, the one bright thing on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(red: 11 / 255, green: 12 / 255, blue: 15 / 255))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                LinearGradient(colors: [.white, Color(red: 226 / 255, green: 226 / 255, blue: 231 / 255)], startPoint: .top, endPoint: .bottom),
                in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// The round badge with a name's first letter (a session's card, the account).
struct InitialBadge: View {
    var name: String
    var size: CGFloat = 42

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.05), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A small capsule beside a name: a country, a proxy's kind.
struct Chip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// How many of how many: a thin bar, amber when full.
struct Meter: View {
    var part: Double
    var full: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(full ? Theme.warn : Theme.text)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, part))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Lumen's mark: two halves of a disc, slid apart along a slanted cut.
struct LumenMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 32
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 16) * scale, y: rect.midY + (y - 16) * scale)
        }
        var path = Path()
        path.move(to: point(14.435, 23.858))
        path.addLine(to: point(20.728, 4.98))
        path.addCurve(to: point(26.119, 17.265), control1: point(25.413, 7.083), control2: point(27.743, 12.393))
        path.addCurve(to: point(14.435, 23.858), control1: point(24.495, 22.137), control2: point(19.445, 24.987))
        path.closeSubpath()
        path.move(to: point(11.272, 27.02))
        path.addLine(to: point(17.565, 8.142))
        path.addCurve(to: point(5.881, 14.735), control1: point(12.555, 7.013), control2: point(7.505, 9.863))
        path.addCurve(to: point(11.272, 27.02), control1: point(4.257, 19.607), control2: point(6.587, 24.917))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// A pane of glass behind this view.
    func glassPane(radius: CGFloat = 24, smoked: Bool = false) -> some View { modifier(GlassPane(radius: radius, smoked: smoked)) }

    /// A list or a form on the app's ground: the system's grey gone, the eclipse behind.
    func eclipseScreen() -> some View {
        scrollContentBackground(.hidden).background(EclipseBackground())
    }

    /// A list or a form on a sheet: the sheet's own glass behind, the system's grey gone.
    func eclipseSheet() -> some View {
        scrollContentBackground(.hidden).background(Theme.ground.opacity(0.55).ignoresSafeArea())
    }

    /// A row of a group, as glass.
    func glassRow() -> some View { listRowBackground(Theme.row) }
}
