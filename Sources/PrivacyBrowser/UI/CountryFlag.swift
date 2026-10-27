import SwiftUI

/// A country's flag as a small flat circle, shown next to a proxy's exit location.
///
/// Flags made of bands, crosses and discs (and a few simple others) are drawn from their colours,
/// flat, adapted to the circle the way round flag sets do it. Any other country uses the system's
/// emoji flag clipped to the circle; a code that is not a country shows a globe. Every flag has a
/// 1 pt ring of 22 % white so it holds its edge on a dark surface, and black bands are drawn as
/// a dark gray for the same reason.
struct CountryFlag: View {
    /// ISO 3166-1 alpha-2, e.g. "DE".
    let code: String
    var size: CGFloat = 14

    var body: some View {
        let region = code.uppercased()
        content(region)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: size >= 14 ? 1 : 0.75))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: CountryNames.name(for: region)))
    }

    @ViewBuilder
    private func content(_ region: String) -> some View {
        if let art = FlagArt.table[region] {
            Canvas { context, canvasSize in art.draw(in: &context, side: min(canvasSize.width, canvasSize.height)) }
        } else if let emoji = Self.emoji(for: region) {
            // The emoji's flag is about 0.62 em tall: this size covers the circle.
            Text(verbatim: emoji)
                .font(.system(size: size * 1.65))
                .fixedSize()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.78))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: size, height: size)
                .background(Theme.controlFill)
        }
    }

    /// Whether `code` gets a drawn flag (the self-test checks the common proxy countries do).
    static func isDrawn(_ code: String) -> Bool { FlagArt.table[code.uppercased()] != nil }

    /// The regional-indicator emoji for an ISO country code, nil for anything else.
    static func emoji(for code: String) -> String? {
        let letters = code.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ ("A"..."Z").contains($0) }),
              Locale.Region.isoRegions.contains(where: { $0.identifier == code.uppercased() }) else { return nil }
        let base: UInt32 = 0x1F1E6 - 0x41
        return String(String.UnicodeScalarView(letters.compactMap { Unicode.Scalar(base + $0.value) }))
    }
}

/// Country names in the app's UI language ("Germany", "Германия").
enum CountryNames {
    static func name(for code: String) -> String {
        Locale(identifier: Localization.languageCode).localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }
}

/// How a flag is drawn into a square (the circle clips it). Coordinates are fractions of the side.
private enum FlagArt {
    /// Equal or weighted bands, top to bottom (`horizontal`) or hoist to fly.
    case bands(horizontal: Bool, colors: [UInt32], weights: [CGFloat]?)
    /// A Nordic cross: the vertical bar towards the hoist.
    case nordic(field: UInt32, cross: UInt32, inner: UInt32?)
    /// A centred cross (Switzerland).
    case centredCross(field: UInt32, cross: UInt32)
    /// A disc on a field (Japan, Bangladesh, Palau).
    case disc(field: UInt32, disc: UInt32, x: CGFloat, radius: CGFloat)
    /// The flags that need their own few shapes.
    case special(Special)

    enum Special {
        case unitedStates, unitedKingdom, portugal, czechia, greece, turkey, china, india, argentina, chile,
             emirates, israel
    }

    // Flat colours, a step softer than the printed ones so they sit calmly in the dark UI.
    static let black: UInt32 = 0x3A3A3F
    static let white: UInt32 = 0xF4F5F7
    static let red: UInt32 = 0xD7383B
    static let gold: UInt32 = 0xF2C13D

    static func h(_ colors: UInt32..., weights: [CGFloat]? = nil) -> FlagArt { .bands(horizontal: true, colors: colors, weights: weights) }
    static func v(_ colors: UInt32..., weights: [CGFloat]? = nil) -> FlagArt { .bands(horizontal: false, colors: colors, weights: weights) }

    static let table: [String: FlagArt] = [
        // Horizontal bands
        "DE": h(black, red, gold),
        "NL": h(0xC7333E, white, 0x3B5FB0),
        "AT": h(red, white, red),
        "RU": h(white, 0x2A5DB0, red),
        "UA": h(0x2F6BC1, 0xF5CF3A),
        "PL": h(white, red),
        "HU": h(red, white, 0x3C8A4E),
        "BG": h(white, 0x2E8B57, red),
        "LT": h(gold, 0x2E7D4F, 0xC7333E),
        "EE": h(0x3A7DD1, black, white),
        "LV": h(0x9E3039, white, 0x9E3039, weights: [2, 1, 2]),
        "LU": h(red, white, 0x3BA3DB),
        "ID": h(red, white),
        "MC": h(red, white),
        "YE": h(red, white, black),
        "AM": h(red, 0x2B4FA3, 0xF2A33A),
        "CO": h(gold, 0x2B4FA3, red, weights: [2, 1, 1]),
        "BO": h(red, gold, 0x2E8B57),
        "GA": h(0x2E9A5B, gold, 0x3B5FB0),
        "SL": h(0x2E9A5B, white, 0x3B7DD1),
        "TH": h(red, white, 0x2D3D78, white, red, weights: [1, 1, 2, 1, 1]),
        "ES": h(red, gold, red, weights: [1, 2, 1]),
        // Vertical bands
        "FR": v(0x2E4FA3, white, red),
        "IT": v(0x2E8B57, white, red),
        "IE": v(0x2E9A5B, white, 0xF08A3C),
        "BE": v(black, 0xF2CF3A, red),
        "RO": v(0x2B4FA3, gold, red),
        "NG": v(0x1F8A4C, white, 0x1F8A4C),
        "PE": v(red, white, red),
        "CI": v(0xF28C28, white, 0x2E9A5B),
        "ML": v(0x2E9A5B, gold, red),
        "GN": v(red, gold, 0x2E9A5B),
        // Crosses and discs
        "SE": .nordic(field: 0x2B6CB5, cross: gold, inner: nil),
        "FI": .nordic(field: white, cross: 0x1F4F9E, inner: nil),
        "DK": .nordic(field: red, cross: white, inner: nil),
        "NO": .nordic(field: red, cross: white, inner: 0x1F3F8F),
        "IS": .nordic(field: 0x24519E, cross: white, inner: red),
        "CH": .centredCross(field: red, cross: white),
        "JP": .disc(field: white, disc: red, x: 0.5, radius: 0.3),
        "BD": .disc(field: 0x1F6B47, disc: red, x: 0.45, radius: 0.3),
        "PW": .disc(field: 0x4AA8E8, disc: gold, x: 0.45, radius: 0.3),
        // Their own shapes
        "US": .special(.unitedStates), "GB": .special(.unitedKingdom), "PT": .special(.portugal),
        "CZ": .special(.czechia), "GR": .special(.greece), "TR": .special(.turkey), "CN": .special(.china),
        "IN": .special(.india), "AR": .special(.argentina), "CL": .special(.chile), "AE": .special(.emirates),
        "IL": .special(.israel),
    ]

    func draw(in context: inout GraphicsContext, side s: CGFloat) {
        func color(_ hex: UInt32) -> GraphicsContext.Shading { .color(Color(hex: hex)) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32) {
            context.fill(Path(CGRect(x: x * s, y: y * s, width: w * s, height: h * s)), with: color(hex))
        }
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32) {
            context.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: color(hex))
        }
        func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32, rotation: CGFloat = -.pi / 2) {
            var path = Path()
            for index in 0..<10 {
                let radius = index.isMultiple(of: 2) ? r : r * 0.382
                let angle = rotation + CGFloat(index) * .pi / 5
                let point = CGPoint(x: (x + radius * cos(angle)) * s, y: (y + radius * sin(angle)) * s)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.fill(path, with: color(hex))
        }
        func stripes(_ count: Int, _ first: UInt32, _ second: UInt32) {
            for index in 0..<count {
                rect(0, CGFloat(index) / CGFloat(count), 1, 1 / CGFloat(count) + 0.001, index.isMultiple(of: 2) ? first : second)
            }
        }

        switch self {
        case let .bands(horizontal, colors, weights):
            let parts = weights ?? Array(repeating: 1, count: colors.count)
            let total = parts.reduce(0, +)
            var start: CGFloat = 0
            for (hex, weight) in zip(colors, parts) {
                let length = weight / total
                // A hair of overlap so no seam shows between bands.
                if horizontal { rect(0, start, 1, length + 0.002, hex) } else { rect(start, 0, length + 0.002, 1, hex) }
                start += length
            }
        case let .nordic(field, cross, inner):
            rect(0, 0, 1, 1, field)
            rect(0, 0.4, 1, 0.2, cross)
            rect(0.3, 0, 0.2, 1, cross)
            if let inner {
                rect(0, 0.45, 1, 0.1, inner)
                rect(0.35, 0, 0.1, 1, inner)
            }
        case let .centredCross(field, cross):
            rect(0, 0, 1, 1, field)
            rect(0.2, 0.4, 0.6, 0.2, cross)
            rect(0.4, 0.2, 0.2, 0.6, cross)
        case let .disc(field, hex, x, radius):
            rect(0, 0, 1, 1, field)
            disc(x, 0.5, radius, hex)
        case let .special(special):
            switch special {
            case .unitedStates:
                stripes(7, FlagArt.red, FlagArt.white)
                rect(0, 0, 0.5, 4.0 / 7.0, 0x2C3E7A)
            case .unitedKingdom:
                rect(0, 0, 1, 1, 0x24357A)
                for angle in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                    var diagonal = context
                    diagonal.translateBy(x: s / 2, y: s / 2)
                    diagonal.rotate(by: .radians(Double(angle)))
                    diagonal.fill(Path(CGRect(x: -s, y: -0.1 * s, width: 2 * s, height: 0.2 * s)), with: color(FlagArt.white))
                    diagonal.fill(Path(CGRect(x: -s, y: -0.035 * s, width: 2 * s, height: 0.07 * s)), with: color(FlagArt.red))
                }
                rect(0, 0.36, 1, 0.28, FlagArt.white)
                rect(0.36, 0, 0.28, 1, FlagArt.white)
                rect(0, 0.42, 1, 0.16, FlagArt.red)
                rect(0.42, 0, 0.16, 1, FlagArt.red)
            case .portugal:
                rect(0, 0, 0.4, 1, 0x2F7A52)
                rect(0.4, 0, 0.6, 1, FlagArt.red)
                disc(0.4, 0.5, 0.17, FlagArt.gold)
                disc(0.4, 0.5, 0.08, FlagArt.red)
            case .czechia:
                rect(0, 0, 1, 0.5, FlagArt.white)
                rect(0, 0.5, 1, 0.5, FlagArt.red)
                var triangle = Path()
                triangle.move(to: CGPoint(x: 0, y: 0))
                triangle.addLine(to: CGPoint(x: 0.5 * s, y: 0.5 * s))
                triangle.addLine(to: CGPoint(x: 0, y: s))
                triangle.closeSubpath()
                context.fill(triangle, with: color(0x1F4F9E))
            case .greece:
                stripes(9, 0x1F5DAF, FlagArt.white)
                rect(0, 0, 5.0 / 9.0, 5.0 / 9.0, 0x1F5DAF)
                rect(0, 2.0 / 9.0, 5.0 / 9.0, 1.0 / 9.0, FlagArt.white)
                rect(2.0 / 9.0, 0, 1.0 / 9.0, 5.0 / 9.0, FlagArt.white)
            case .turkey:
                rect(0, 0, 1, 1, FlagArt.red)
                disc(0.42, 0.5, 0.25, FlagArt.white)
                disc(0.48, 0.5, 0.2, FlagArt.red)
                star(0.68, 0.5, 0.09, FlagArt.white, rotation: .pi)
            case .china:
                rect(0, 0, 1, 1, 0xD8322B)
                star(0.3, 0.33, 0.15, 0xF5CF3A)
                for (x, y) in [(0.52, 0.16), (0.6, 0.27), (0.6, 0.41), (0.52, 0.52)] as [(CGFloat, CGFloat)] {
                    star(x, y, 0.045, 0xF5CF3A)
                }
            case .india:
                rect(0, 0, 1, 1 / 3 + 0.002, 0xF29A3A)
                rect(0, 1 / 3, 1, 1 / 3 + 0.002, FlagArt.white)
                rect(0, 2 / 3, 1, 1 / 3, 0x2E8B47)
                let wheel = Path(ellipseIn: CGRect(x: 0.38 * s, y: 0.38 * s, width: 0.24 * s, height: 0.24 * s))
                context.stroke(wheel, with: color(0x1E3A8A), lineWidth: max(0.6, 0.035 * s))
                disc(0.5, 0.5, 0.035, 0x1E3A8A)
            case .argentina:
                rect(0, 0, 1, 1, FlagArt.white)
                rect(0, 0, 1, 1 / 3, 0x74ACDF)
                rect(0, 2 / 3, 1, 1 / 3, 0x74ACDF)
                disc(0.5, 0.5, 0.085, FlagArt.gold)
            case .chile:
                rect(0, 0, 1, 0.5, FlagArt.white)
                rect(0, 0.5, 1, 0.5, FlagArt.red)
                rect(0, 0, 0.5, 0.5, 0x2B4FA3)
                star(0.25, 0.25, 0.11, FlagArt.white)
            case .emirates:
                rect(0, 0, 1, 1 / 3 + 0.002, 0x2E8B57)
                rect(0, 1 / 3, 1, 1 / 3 + 0.002, FlagArt.white)
                rect(0, 2 / 3, 1, 1 / 3, FlagArt.black)
                rect(0, 0, 0.28, 1, FlagArt.red)
            case .israel:
                rect(0, 0, 1, 1, FlagArt.white)
                rect(0, 0.14, 1, 0.12, 0x2C5BB6)
                rect(0, 0.74, 1, 0.12, 0x2C5BB6)
                for rotation in [-CGFloat.pi / 2, CGFloat.pi / 2] {
                    var triangle = Path()
                    for index in 0..<3 {
                        let angle = rotation + CGFloat(index) * 2 * .pi / 3
                        let point = CGPoint(x: (0.5 + 0.16 * cos(angle)) * s, y: (0.5 + 0.16 * sin(angle)) * s)
                        if index == 0 { triangle.move(to: point) } else { triangle.addLine(to: point) }
                    }
                    triangle.closeSubpath()
                    context.stroke(triangle, with: color(0x2C5BB6), lineWidth: max(0.6, 0.035 * s))
                }
            }
        }
    }
}
