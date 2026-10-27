import SwiftUI

/// Lumen's mark: a disc cut once by a steep seam, its two halves slid apart along the seam so they
/// never touch — the seam is the boundary that keeps profiles apart. Flat, two-tone: a white
/// glyph on a near-black tile with a faint light ring (so the tile stays visible on dark
/// surfaces). Drawn from its construction rather than from a bitmap, so it is crisp at every size.
///
/// Three optical cuts, as on the brand sheet: the 64-grid drawing for 28 pt and up, a 16-grid
/// cut with a wider seam for the small sizes (title bar, tab, sidebar), and a heavier cut for the
/// bare glyph at small sizes.
enum LumenMarkGeometry {
    struct Cut {
        /// The grid the numbers below are drawn on (the tile is grid × grid).
        let grid: CGFloat
        let center: CGPoint
        let radius: CGFloat
        /// Width of the seam between the halves.
        let gap: CGFloat
        /// How far the halves are slid apart along the seam, in total.
        let slide: CGFloat
    }

    static let large = Cut(grid: 64, center: CGPoint(x: 32, y: 32), radius: 19, gap: 3, slide: 6)
    static let small = Cut(grid: 16, center: CGPoint(x: 8, y: 8), radius: 5, gap: 2, slide: 2)
    static let bareSmall = Cut(grid: 16, center: CGPoint(x: 8, y: 8), radius: 6, gap: 2, slide: 2.5)

    /// The seam rises steeply to the right: one across for three up (y points down).
    static let seam = CGVector(dx: 1, dy: -3)

    /// The cut for a mark drawn `size` points wide.
    static func cut(forTileSize size: CGFloat) -> Cut { size >= 28 ? large : small }
    static func cut(forBareSize size: CGFloat) -> Cut { size >= 28 ? large : bareSmall }

    /// Both halves of the disc, scaled into the square centred in `rect`.
    static func glyph(_ cut: Cut, in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / cut.grid
        let origin = CGPoint(x: rect.midX - cut.grid * scale / 2, y: rect.midY - cut.grid * scale / 2)
        let length = hypot(seam.dx, seam.dy)
        let d = CGVector(dx: seam.dx / length, dy: seam.dy / length)   // along the seam
        let n = CGVector(dx: -d.dy, dy: d.dx)                           // across it
        var path = Path()
        for side: CGFloat in [1, -1] {
            // Each half: the disc's segment on its side of the seam (offset by half the gap),
            // moved along the seam by half the slide.
            let h = side * cut.gap / 2
            let shift = side * cut.slide / 2
            let center = CGPoint(x: cut.center.x + d.dx * shift, y: cut.center.y + d.dy * shift)
            let half = (cut.radius * cut.radius - h * h).squareRoot()
            let a = CGVector(dx: n.dx * h - d.dx * half, dy: n.dy * h - d.dy * half)
            let b = CGVector(dx: n.dx * h + d.dx * half, dy: n.dy * h + d.dy * half)
            let m = CGVector(dx: n.dx * side * cut.radius, dy: n.dy * side * cut.radius)
            let angleA = atan2(a.dy, a.dx), angleB = atan2(b.dy, b.dx), angleM = atan2(m.dy, m.dx)
            // From B back to A the long way round, through M (the far side of this half).
            let positive = positiveAngle(angleA - angleB)
            let sweep = positiveAngle(angleM - angleB) < positive ? positive : positive - 2 * .pi
            func point(_ v: CGVector) -> CGPoint {
                CGPoint(x: origin.x + (center.x + v.dx) * scale, y: origin.y + (center.y + v.dy) * scale)
            }
            path.move(to: point(a))
            path.addLine(to: point(b))
            appendArc(to: &path, center: point(.zero), radius: cut.radius * scale, from: angleB, sweep: sweep)
            path.closeSubpath()
        }
        return path
    }

    private static func positiveAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value <= 0 { value += 2 * .pi }
        return value
    }

    /// A circular arc as cubic Béziers (at most 90° each); starts where the path currently is.
    private static func appendArc(to path: inout Path, center: CGPoint, radius: CGFloat, from start: CGFloat, sweep: CGFloat) {
        let segments = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let step = sweep / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        for index in 0..<segments {
            let s = start + step * CGFloat(index), e = s + step
            let control1 = CGPoint(x: center.x + radius * (cos(s) - k * sin(s)), y: center.y + radius * (sin(s) + k * cos(s)))
            let control2 = CGPoint(x: center.x + radius * (cos(e) + k * sin(e)), y: center.y + radius * (sin(e) - k * cos(e)))
            path.addCurve(to: CGPoint(x: center.x + radius * cos(e), y: center.y + radius * sin(e)),
                          control1: control1, control2: control2)
        }
    }
}

/// The two halves of the disc, filling `rect`'s centred square.
struct LumenGlyphShape: Shape {
    var cut: LumenMarkGeometry.Cut

    func path(in rect: CGRect) -> Path { LumenMarkGeometry.glyph(cut, in: rect) }
}

/// The app mark: near-black continuous-corner tile, white split disc, faint light ring.
struct LumenMark: View {
    var size: CGFloat

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.2235, style: .continuous)
        ZStack {
            tile.fill(Theme.markTile)
            tile.strokeBorder(Color.white.opacity(0.12), lineWidth: size >= 28 ? 1 : 0.5)
            LumenGlyphShape(cut: LumenMarkGeometry.cut(forTileSize: size)).fill(Theme.markGlyph)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Lumen"))
    }
}

/// The split disc alone, in one colour (empty states, small in-text use).
struct LumenGlyph: View {
    var size: CGFloat
    var color: Color = Theme.markGlyph

    var body: some View {
        LumenGlyphShape(cut: LumenMarkGeometry.cut(forBareSize: size))
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The caps logotype, drawn from its outlines (no font): even stems, a U with overshoot, an M
/// whose vertex stops short of the baseline. The small cut has heavier stems and a little more
/// room between letters, for a cap height of about 9–15 pt.
struct LumenWordmarkShape: Shape {
    enum Cut { case regular, small }
    var cut: Cut

    /// Width ÷ height of the drawing (its cap height is 100 of the 102 units; the U overshoots).
    static func aspect(_ cut: Cut) -> CGFloat { cut == .regular ? 406 / 102 : 414 / 102 }

    func path(in rect: CGRect) -> Path {
        let size = CGSize(width: Self.aspect(cut) * 102, height: 102)
        let scale = min(rect.width / size.width, rect.height / size.height)
        let x0 = rect.minX + (rect.width - size.width * scale) / 2
        let y0 = rect.minY + (rect.height - size.height * scale) / 2
        var path = Path()
        let pt: (CGFloat, CGFloat) -> CGPoint = { CGPoint(x: x0 + $0 * scale, y: y0 + $1 * scale) }
        switch cut {
        case .regular: Outlines.regular(&path, pt)
        case .small: Outlines.small(&path, pt)
        }
        return path
    }

    /// Generated from the brand sheet's SVG outlines (arcs converted to cubic Béziers).
    private enum Outlines {
        // regular: viewBox 406 x 102
        static func regular(_ p: inout Path, _ pt: (CGFloat, CGFloat) -> CGPoint) {
            p.move(to: pt(0, 0))
            p.addLine(to: pt(10.5, 0))
            p.addLine(to: pt(10.5, 100))
            p.addLine(to: pt(0, 100))
            p.closeSubpath()
            p.move(to: pt(0, 90))
            p.addLine(to: pt(54, 90))
            p.addLine(to: pt(54, 100))
            p.addLine(to: pt(0, 100))
            p.closeSubpath()
            p.move(to: pt(63, 0))
            p.addLine(to: pt(63, 64.5))
            p.addCurve(to: pt(100, 101.5), control1: pt(63, 84.935), control2: pt(79.565, 101.5))
            p.addCurve(to: pt(137, 64.5), control1: pt(120.435, 101.5), control2: pt(137, 84.935))
            p.addLine(to: pt(137, 0))
            p.addLine(to: pt(126.5, 0))
            p.addLine(to: pt(126.5, 61.5))
            p.addCurve(to: pt(100, 88), control1: pt(126.5, 76.136), control2: pt(114.636, 88))
            p.addCurve(to: pt(73.5, 61.5), control1: pt(85.364, 88), control2: pt(73.5, 76.136))
            p.addLine(to: pt(73.5, 0))
            p.closeSubpath()
            p.move(to: pt(154, 0))
            p.addLine(to: pt(166.2, 0))
            p.addLine(to: pt(197, 72.02))
            p.addLine(to: pt(227.8, 0))
            p.addLine(to: pt(240, 0))
            p.addLine(to: pt(240, 100))
            p.addLine(to: pt(229.5, 100))
            p.addLine(to: pt(229.5, 24))
            p.addLine(to: pt(197, 100))
            p.addLine(to: pt(164.5, 24))
            p.addLine(to: pt(164.5, 100))
            p.addLine(to: pt(154, 100))
            p.closeSubpath()
            p.move(to: pt(257, 0))
            p.addLine(to: pt(267.5, 0))
            p.addLine(to: pt(267.5, 100))
            p.addLine(to: pt(257, 100))
            p.closeSubpath()
            p.move(to: pt(257, 0))
            p.addLine(to: pt(315, 0))
            p.addLine(to: pt(315, 10))
            p.addLine(to: pt(257, 10))
            p.closeSubpath()
            p.move(to: pt(257, 43.5))
            p.addLine(to: pt(308, 43.5))
            p.addLine(to: pt(308, 53.5))
            p.addLine(to: pt(257, 53.5))
            p.closeSubpath()
            p.move(to: pt(257, 90))
            p.addLine(to: pt(315, 90))
            p.addLine(to: pt(315, 100))
            p.addLine(to: pt(257, 100))
            p.closeSubpath()
            p.move(to: pt(330, 0))
            p.addLine(to: pt(340.5, 0))
            p.addLine(to: pt(340.5, 100))
            p.addLine(to: pt(330, 100))
            p.closeSubpath()
            p.move(to: pt(395.5, 0))
            p.addLine(to: pt(406, 0))
            p.addLine(to: pt(406, 100))
            p.addLine(to: pt(395.5, 100))
            p.closeSubpath()
            p.move(to: pt(330, 0))
            p.addLine(to: pt(343.56, 0))
            p.addLine(to: pt(406, 100))
            p.addLine(to: pt(392.44, 100))
            p.closeSubpath()
        }

        // small: viewBox 414 x 102
        static func small(_ p: inout Path, _ pt: (CGFloat, CGFloat) -> CGPoint) {
            p.move(to: pt(0, 0))
            p.addLine(to: pt(12, 0))
            p.addLine(to: pt(12, 100))
            p.addLine(to: pt(0, 100))
            p.closeSubpath()
            p.move(to: pt(0, 88.5))
            p.addLine(to: pt(54, 88.5))
            p.addLine(to: pt(54, 100))
            p.addLine(to: pt(0, 100))
            p.closeSubpath()
            p.move(to: pt(65, 0))
            p.addLine(to: pt(65, 64.2))
            p.addCurve(to: pt(102, 101.2), control1: pt(65, 84.635), control2: pt(81.565, 101.2))
            p.addCurve(to: pt(139, 64.2), control1: pt(122.435, 101.2), control2: pt(139, 84.635))
            p.addLine(to: pt(139, 0))
            p.addLine(to: pt(127, 0))
            p.addLine(to: pt(127, 64.2))
            p.addCurve(to: pt(102, 89.2), control1: pt(127, 78.007), control2: pt(115.807, 89.2))
            p.addCurve(to: pt(77, 64.2), control1: pt(88.193, 89.2), control2: pt(77, 78.007))
            p.addLine(to: pt(77, 0))
            p.closeSubpath()
            p.move(to: pt(158, 0))
            p.addLine(to: pt(173.82, 0))
            p.addLine(to: pt(201, 66.64))
            p.addLine(to: pt(228.18, 0))
            p.addLine(to: pt(244, 0))
            p.addLine(to: pt(244, 100))
            p.addLine(to: pt(232, 100))
            p.addLine(to: pt(232, 24))
            p.addLine(to: pt(201, 100))
            p.addLine(to: pt(170, 24))
            p.addLine(to: pt(170, 100))
            p.addLine(to: pt(158, 100))
            p.closeSubpath()
            p.move(to: pt(263, 0))
            p.addLine(to: pt(275, 0))
            p.addLine(to: pt(275, 100))
            p.addLine(to: pt(263, 100))
            p.closeSubpath()
            p.move(to: pt(263, 0))
            p.addLine(to: pt(321, 0))
            p.addLine(to: pt(321, 11.5))
            p.addLine(to: pt(263, 11.5))
            p.closeSubpath()
            p.move(to: pt(263, 42.75))
            p.addLine(to: pt(314, 42.75))
            p.addLine(to: pt(314, 54.25))
            p.addLine(to: pt(263, 54.25))
            p.closeSubpath()
            p.move(to: pt(263, 88.5))
            p.addLine(to: pt(321, 88.5))
            p.addLine(to: pt(321, 100))
            p.addLine(to: pt(263, 100))
            p.closeSubpath()
            p.move(to: pt(338, 0))
            p.addLine(to: pt(350, 0))
            p.addLine(to: pt(350, 100))
            p.addLine(to: pt(338, 100))
            p.closeSubpath()
            p.move(to: pt(402, 0))
            p.addLine(to: pt(414, 0))
            p.addLine(to: pt(414, 100))
            p.addLine(to: pt(402, 100))
            p.closeSubpath()
            p.move(to: pt(338, 0))
            p.addLine(to: pt(353.43, 0))
            p.addLine(to: pt(414, 100))
            p.addLine(to: pt(398.57, 100))
            p.closeSubpath()
        }
    }
}

/// "LUMEN", sized by its rendered height (cap height ≈ 0.98 × height).
struct LumenWordmark: View {
    var height: CGFloat
    var color: Color = Theme.textPrimary

    var body: some View {
        let cut: LumenWordmarkShape.Cut = height < 16 ? .small : .regular
        LumenWordmarkShape(cut: cut)
            .fill(color)
            .frame(width: height * LumenWordmarkShape.aspect(cut), height: height)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "Lumen"))
    }
}

/// Mark and wordmark side by side, read as one "Lumen".
struct LumenLockup: View {
    var markSize: CGFloat
    var wordmarkHeight: CGFloat
    var gap: CGFloat
    var color: Color = Theme.textPrimary

    var body: some View {
        HStack(spacing: gap) {
            LumenMark(size: markSize)
            LumenWordmark(height: wordmarkHeight, color: color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Lumen"))
    }

    /// Sidebar: mark 20, wordmark 11 pt high, gap 8.
    static let sidebar = LumenLockup(markSize: 20, wordmarkHeight: 11.2, gap: 8)
    /// New Tab page and launch screen: mark 36, wordmark 22, gap 14.
    static let large = LumenLockup(markSize: 36, wordmarkHeight: 22, gap: 14)
}
