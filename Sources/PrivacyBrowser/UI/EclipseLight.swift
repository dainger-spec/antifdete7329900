import SwiftUI

/// The design's one light effect ("Light and motion"): an eclipse — a dark circle with light breaking
/// out at its edge — in two corners of a window. Five circles of one size, each moved a little
/// toward the window's centre or away from it, and blurred: a halo, a glow, the rim, the penumbra,
/// and the shadow that hides all but a crescent. No shaders. Sizes and offsets are the design's,
/// scaled by the window's height (the lock's, in a window narrower than its board, by the width),
/// so the eclipses keep to the corners at any size. Decoration
/// only: hidden from VoiceOver, never in the way of a click.
///
/// At entry the circles come in from beyond the edges in 1.8 s, and the light at their edges
/// follows after 0.45 s; then everything is still. Under Reduce Motion (or with the animations off
/// in Settings → Appearance) they only fade in, in 0.6 s. They come in once per launch of the app
/// for each place; after that a window shows them where they rest.
struct EclipseLight: View {
    /// Where it is: each window has its own eclipses.
    enum Place: Hashable {
        /// The lock screen and the first launch: at full brightness.
        case lock
        /// The profiles window: they come in with it, then rest dimmed.
        case profiles
        /// Behind the profile editor: still.
        case editor
        /// The miniature in Settings → Appearance.
        case thumbnail
    }

    /// The lock screen while the password is checked (`busy`: the circles close in by 20 pt and
    /// the halo brightens) and once the vault opens (`open`: they part and dim to 55 %, as they
    /// stay in the corners of the profiles window).
    enum Phase: Hashable { case idle, busy, open }

    var place: Place
    var phase: Phase = .idle
    /// The whole effect's brightness: 1 on the lock screen, 0.55 in the profiles window, 0.45
    /// behind the editor.
    var brightness: Double = 1

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame
    @State private var inTopTrailing = false
    @State private var inBottomLeading = false
    @State private var lit = false

    /// The places whose eclipses have come in since the app started (read and written on the main
    /// thread only, from `onAppear`).
    nonisolated(unsafe) private static var entered: Set<Place> = []

    private var reduced: Bool { Motion.isReduced(systemReduceMotion) }

    var body: some View {
        let spec = EclipseSpec.of(place)
        GeometryReader { geometry in
            let byHeight = max(geometry.size.height, 1) / spec.referenceHeight
            // A window narrower than the design board's proportion (the sign-in sheet) is scaled by
            // its width: by the height alone the rim crossed its form.
            let byWidth = spec.referenceWidth.map { max(geometry.size.width, 1) / $0 } ?? byHeight
            let scale = min(byHeight, byWidth)
            ZStack {
                disc(spec.topTrailing, topTrailing: true, in: geometry.size, scale: scale, spec: spec,
                     shown: inTopTrailing)
                disc(spec.bottomLeading, topTrailing: false, in: geometry.size, scale: scale, spec: spec,
                     shown: inBottomLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .drawingGroup()
        }
        .opacity(brightness * (phase == .open ? 0.55 : 1))
        .animation(reduced ? .easeOut(duration: 0.3) : .easeOut(duration: 1), value: phase)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: enter)
    }

    private func enter() {
        let first = !Self.entered.contains(place)
        Self.entered.insert(place)
        guard first, EclipseSpec.of(place).comesIn, !stillFrame else {
            inTopTrailing = true
            inBottomLeading = true
            lit = true
            return
        }
        if reduced {
            withAnimation(.easeOut(duration: 0.6)) {
                inTopTrailing = true
                inBottomLeading = true
                lit = true
            }
            return
        }
        let spec = EclipseSpec.of(place)
        withAnimation(Motion.entry(duration: spec.entryDuration)) { inTopTrailing = true }
        withAnimation(Motion.entry(duration: spec.entryDuration).delay(spec.bottomLeading.delay)) { inBottomLeading = true }
        withAnimation(.easeOut(duration: spec.rimDuration).delay(spec.rimDelay)) { lit = true }
    }

    /// One eclipse: its five circles, placed by the corner it is in.
    private func disc(_ disc: EclipseSpec.Disc, topTrailing: Bool, in size: CGSize, scale: CGFloat,
                      spec: EclipseSpec, shown: Bool) -> some View {
        let diameter = disc.diameter * scale
        // The design places them by how far their edge reaches beyond the window's edges.
        let center = topTrailing
            ? CGPoint(x: size.width - disc.x * scale - diameter / 2, y: disc.y * scale + diameter / 2)
            : CGPoint(x: disc.x * scale + diameter / 2, y: size.height - disc.y * scale - diameter / 2)
        let moved: CGSize = {
            if reduced { return .zero }
            if !shown { return disc.from }
            switch phase {
            case .idle: return .zero
            case .busy: return disc.busy
            case .open: return disc.open
            }
        }()
        return ZStack {
            layer(Theme.rim.opacity(phase == .busy ? 0.38 : 0.22), blur: spec.blur.halo, offset: disc.halo, diameter, scale)
                .opacity(lit ? 1 : 0)
            layer(Theme.rim.opacity(0.5), blur: spec.blur.glow, offset: disc.glow, diameter, scale)
                .opacity(lit ? 1 : 0)
            layer(Theme.rim, blur: spec.blur.rim, offset: disc.rim, diameter, scale)
                .opacity(lit ? 1 : 0)
            layer(Color(hex: 0x2B2E35), blur: spec.blur.penumbra, offset: disc.penumbra, diameter, scale)
            layer(Theme.backdrop, blur: spec.blur.shadow, offset: disc.shadow, diameter, scale)
        }
        .frame(width: diameter, height: diameter)
        .position(center)
        .offset(x: moved.width * scale, y: moved.height * scale)
        .opacity(shown ? 1 : 0)
        .animation(reduced ? nil : Motion.entry(duration: 1.2), value: phase)
    }

    private func layer(_ color: Color, blur: CGFloat, offset: CGSize, _ diameter: CGFloat, _ scale: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .offset(x: offset.width * scale, y: offset.height * scale)
            .blur(radius: blur * scale)
    }
}

/// The eclipses of each place, as the design draws them (in points, for a window of
/// `referenceHeight`).
private struct EclipseSpec {
    struct Disc {
        var diameter: CGFloat
        /// How far its edge reaches past the window's nearest side edge (negative: beyond it) —
        /// the right edge for the top-right eclipse, the left for the bottom-left.
        var x: CGFloat
        /// The same for the top or bottom edge.
        var y: CGFloat
        var halo: CGSize
        var glow: CGSize
        var rim: CGSize
        var penumbra: CGSize
        var shadow: CGSize
        /// Where it comes in from.
        var from: CGSize
        var delay: Double
        var busy: CGSize = .zero
        var open: CGSize = .zero
    }

    struct Blur {
        var halo: CGFloat = 46
        var glow: CGFloat = 8
        var rim: CGFloat = 0.8
        var penumbra: CGFloat = 18
        var shadow: CGFloat = 36
    }

    var referenceHeight: CGFloat
    var topTrailing: Disc
    var bottomLeading: Disc
    var blur = Blur()
    var comesIn = true
    var entryDuration = 1.8
    var rimDelay = 0.45
    var rimDuration = 1.6
    /// The design board's width: a window narrower than the board's proportion scales by its width
    /// instead, so the arcs stay in its corners. Nil: by the height alone.
    var referenceWidth: CGFloat? = nil

    static func of(_ place: EclipseLight.Place) -> EclipseSpec {
        switch place {
        case .lock:
            return EclipseSpec(
                referenceHeight: 920,
                topTrailing: Disc(diameter: 1274, x: -725, y: -699,
                                  halo: CGSize(width: -30, height: 19), glow: CGSize(width: -12, height: 8),
                                  rim: CGSize(width: -9, height: 6), penumbra: CGSize(width: -3, height: 2),
                                  shadow: CGSize(width: 46, height: -30),
                                  from: CGSize(width: 120, height: -80), delay: 0,
                                  busy: CGSize(width: -22, height: 14), open: CGSize(width: 150, height: -95)),
                bottomLeading: Disc(diameter: 930, x: -560, y: -680,
                                    halo: CGSize(width: 27, height: -22), glow: CGSize(width: 11, height: -9),
                                    rim: CGSize(width: 8, height: -7), penumbra: CGSize(width: 3, height: -2),
                                    shadow: CGSize(width: -40, height: 33),
                                    from: CGSize(width: -110, height: 90), delay: 0.12,
                                    busy: CGSize(width: 19, height: -16), open: CGSize(width: -130, height: 110)),
                rimDelay: 0.5, rimDuration: 1.7, referenceWidth: 1280)
        case .profiles:
            return EclipseSpec(
                referenceHeight: 1000,
                topTrailing: Disc(diameter: 1109, x: -709, y: -687,
                                  halo: CGSize(width: -28, height: 19), glow: CGSize(width: -11, height: 7),
                                  rim: CGSize(width: -8, height: 5.5), penumbra: CGSize(width: -2.5, height: 1.7),
                                  shadow: CGSize(width: 43, height: -29),
                                  from: CGSize(width: 110, height: -74), delay: 0),
                bottomLeading: Disc(diameter: 921, x: -523, y: -717,
                                    halo: CGSize(width: 26, height: -23), glow: CGSize(width: 10, height: -9),
                                    rim: CGSize(width: 7.5, height: -6.6), penumbra: CGSize(width: 2.3, height: -2),
                                    shadow: CGSize(width: -39, height: 34),
                                    from: CGSize(width: -96, height: 84), delay: 0.1))
        case .editor:
            return EclipseSpec(
                referenceHeight: 920,
                topTrailing: Disc(diameter: 1000, x: -640, y: -620,
                                  halo: CGSize(width: -28, height: 19), glow: CGSize(width: -11, height: 7),
                                  rim: CGSize(width: -8, height: 5.5), penumbra: CGSize(width: -2.5, height: 1.7),
                                  shadow: CGSize(width: 43, height: -29),
                                  from: .zero, delay: 0),
                bottomLeading: Disc(diameter: 860, x: -500, y: -660,
                                    halo: CGSize(width: 26, height: -23), glow: CGSize(width: 10, height: -9),
                                    rim: CGSize(width: 7.5, height: -6.6), penumbra: CGSize(width: 2.3, height: -2),
                                    shadow: CGSize(width: -39, height: 34),
                                    from: .zero, delay: 0),
                comesIn: false)
        case .thumbnail:
            return EclipseSpec(
                referenceHeight: 230,
                topTrailing: Disc(diameter: 520, x: -330, y: -336,
                                  halo: CGSize(width: -15, height: 10), glow: CGSize(width: -6, height: 4),
                                  rim: CGSize(width: -4.5, height: 3), penumbra: CGSize(width: -1.5, height: 1),
                                  shadow: CGSize(width: 23, height: -15),
                                  from: CGSize(width: 60, height: -40), delay: 0),
                bottomLeading: Disc(diameter: 420, x: -292, y: -306,
                                    halo: CGSize(width: 14, height: -12), glow: CGSize(width: 5.5, height: -5),
                                    rim: CGSize(width: 4, height: -3.5), penumbra: CGSize(width: 1.3, height: -1),
                                    shadow: CGSize(width: -21, height: 18),
                                    from: CGSize(width: -55, height: 45), delay: 0.1),
                blur: Blur(halo: 24, glow: 4, rim: 0.6, penumbra: 9, shadow: 18),
                entryDuration: 1.6, rimDelay: 0.4, rimDuration: 1.5)
        }
    }
}
