import AppKit
import BrowserCore
import SwiftUI

/// The cover's words, in the person's language: the helper has no strings of its own, and the app
/// sends them with its request (`VMHelperRequest.texts`, the keys `cover.…`). English where one
/// is missing.
public struct MachineCoverTexts: Equatable {
    /// Over the name: "Setting up the machine" (shown in capitals).
    public var caption: String
    /// Each step in words; `ready` has `safari`'s ("Almost ready…").
    public var steps: [VMSetupStage: String]
    /// After a minute: "Taking longer than usual." and the link "Show the screen".
    public var longer: String
    public var show: String
    /// After the cover went by itself: the screen is shown as it is.
    public var timedOut: String
    /// For VoiceOver: the machine's name, then the step ("%1$@: %2$@").
    public var label: String

    /// The keys of `VMHelperRequest.texts` the cover reads.
    public static func key(_ stage: VMSetupStage) -> String { "cover." + (stage == .ready ? VMSetupStage.safari : stage).rawValue }
    public static let captionKey = "cover.caption"
    public static let longerKey = "cover.longer"
    public static let showKey = "cover.show"
    public static let timedOutKey = "cover.timedOut"
    public static let labelKey = "cover.label"

    public init(_ texts: [String: String]) {
        let english: [VMSetupStage: String] = [
            .boot: "Starting macOS…", .signin: "Signing in…", .locale: "Setting the language and region…",
            .look: "Setting up the look…", .wallpaper: "Setting the wallpaper…", .safari: "Almost ready…",
        ]
        var steps: [VMSetupStage: String] = [:]
        for stage in VMSetupStage.allCases {
            steps[stage] = texts[Self.key(stage)] ?? english[stage == .ready ? .safari : stage] ?? ""
        }
        self.steps = steps
        caption = texts[Self.captionKey] ?? "Setting up the machine"
        longer = texts[Self.longerKey] ?? "Taking longer than usual."
        show = texts[Self.showKey] ?? "Show the screen"
        timedOut = texts[Self.timedOutKey] ?? "The machine did not say it was set up: its screen is shown as it is"
        label = texts[Self.labelKey] ?? "%1$@: %2$@"
    }

    public func step(_ stage: VMSetupStage) -> String { steps[stage] ?? "" }
}

/// What the cover shows now. The helper changes it as the guest's status says (on the main thread).
public final class MachineCoverModel: ObservableObject {
    @Published public var stage: VMSetupStage
    /// "Show the screen" is offered.
    @Published public var offersReveal: Bool
    /// The cover is going: its words leave, and the helper fades it into the machine's screen.
    @Published public var leaving: Bool
    public let name: String
    public let texts: MachineCoverTexts
    /// "Show the screen" was pressed.
    public var showScreen: () -> Void

    public init(name: String, texts: MachineCoverTexts, stage: VMSetupStage = .boot, offersReveal: Bool = false,
                leaving: Bool = false, showScreen: @escaping () -> Void = {}) {
        self.name = name
        self.texts = texts
        self.stage = stage
        self.offersReveal = offersReveal
        self.leaving = leaving
        self.showScreen = showScreen
    }
}

/// The cover's motion — design/prototypes/vm-cover.html has the same numbers (its `T` and `GLINT`).
public enum MachineCoverTiming {
    /// The words come in, rising 6 pt, after a moment.
    public static let enter = 0.6
    public static let enterDelay = 0.1
    /// A step's words go, rising 4 pt; the next step's come from 4 pt below, a moment after.
    public static let wordOut = 0.22
    public static let wordInDelay = 0.12
    public static let wordIn = 0.45
    /// A step's dash fills.
    public static let stepFill = 0.4
    /// The light running in the current step's dash, once.
    public static let shimmer = 1.4
    /// The glint along the horizon: its run from left to right, then the horizon's rest.
    public static let glide = 6.4
    public static let rest = 1.6
    /// The haze over the rim, once in and out.
    public static let breath = 6.0
    /// "Show the screen" comes in.
    public static let offerIn = 0.6
    /// Ready: the last dashes fill; after this the words go (`wordsOut`) and the cover fades
    /// (`reveal`, or `reducedReveal` under Reduce Motion) — the helper's.
    public static let revealDelay = 0.25
    public static let wordsOut = 0.4
    public static let reveal = 0.9
    public static let reducedReveal = 0.4

    /// The design's ease-out for things entering: cubic-bezier(.16, 1, .3, 1) (the app's `Motion.entry`).
    public static func entry(_ duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }

    /// The glint at `t` seconds: where it is (radians from the rim's top, to the right) and how
    /// bright (0…1). It rises a little past the screen's left edge, glides to the right on an
    /// ease-in-out, fades there, and after the horizon's rest comes again.
    public static func glint(at t: Double, visibleHalfAngle half: Double) -> (angle: Double, strength: Double) {
        let span = half + 0.05
        let p = t.truncatingRemainder(dividingBy: glide + rest) / glide
        guard p >= 0, p < 1 else { return (span, 0) }
        let angle = -span + 2 * span * inOut(p)
        let nearTop = max(0, 1 - pow(angle / half, 2))
        return (angle, pow(sin(Double.pi * p), 1.4) * (0.45 + 0.55 * nearTop))
    }

    /// The haze's opacity at `t`: 0.45 … 1, breathing; 0.725 when nothing moves.
    public static func haze(at t: Double, still: Bool) -> Double {
        0.45 + 0.55 * (still ? 0.5 : 0.5 - 0.5 * cos(2 * Double.pi * t / breath))
    }

    /// cubic-bezier(.4, 0, .2, 1), as the prototype's `inOut`.
    static func inOut(_ x: Double) -> Double {
        let x1 = 0.4, y1 = 0.0, x2 = 0.2, y2 = 1.0
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        var u = min(1, max(0, x))
        for _ in 0..<8 {
            let slope = (3 * ax * u + 2 * bx) * u + cx
            guard abs(slope) > 1e-6 else { break }
            u -= (((ax * u + bx) * u + cx) * u - x) / slope
        }
        u = min(1, max(0, u))
        return ((ay * u + by) * u + cy) * u
    }
}

/// The colours, as the app's `Theme` has them.
private enum Palette {
    static let backdrop = Color(red: 8.0 / 255, green: 9.0 / 255, blue: 11.0 / 255)
    static let primary = Color(red: 244.0 / 255, green: 244.0 / 255, blue: 245.0 / 255)
    static let secondary = Color(red: 161.0 / 255, green: 161.0 / 255, blue: 170.0 / 255)
}

/// The images of a picture's size, made once per size (the horizon is the window's).
private final class HorizonLayers {
    private var key: CGSize = .zero
    private var keyScale: CGFloat = 0
    private(set) var picture: CGImage?
    private(set) var haze: CGImage?
    private(set) var glint: CGImage?

    func update(size: CGSize, scale: CGFloat) {
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != key || scale != keyScale, rounded.width >= 1, rounded.height >= 1 else { return }
        key = rounded
        keyScale = scale
        picture = MachineHorizon.picture(size: rounded, scale: scale)
        // A soft gradient: a quarter of the pixels is all it needs.
        haze = MachineHorizon.haze(size: rounded, scale: max(0.5, scale / 2))
        glint = MachineHorizon.glint(size: rounded, scale: scale)
    }
}

/// The cover over a virtual machine's screen while its start makes it the profile's: the eclipse
/// of the machine's desktop, with a glint gliding along its horizon and the haze over it
/// breathing; the profile's name and the step in words; six thin dashes for the steps; "Show the
/// screen" after a minute. Under Reduce Motion (macOS's, or the app's own setting sent as
/// `reducesMotion`) nothing glides or breathes, and the words only cross-fade.
///
/// The light moves on the GPU: the picture and its layers are images made once per size, and a
/// frame changes only their opacity and the glint's turn.
public struct MachineCoverView: View {
    @ObservedObject private var model: MachineCoverModel
    private let reducesMotion: Bool
    /// A still frame at this many seconds into the light's motion (the app's UI snapshots); nil: it moves.
    private let still: Double?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var entered: Bool
    @State private var startedAt = Date()
    @State private var layers = HorizonLayers()

    /// The words' block: caption 14, 12, name 36, 10, step 20, 22, dashes 2 — its middle at 36 % of
    /// the height; "Show the screen" 26 under the dashes, 16 high.
    private static let blockHeight: CGFloat = 14 + 12 + 36 + 10 + 20 + 22 + 2

    public init(model: MachineCoverModel, reducesMotion: Bool = false, still: Double? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.reducesMotion = reducesMotion
        self.still = still
        _entered = State(initialValue: still != nil)
    }

    private var reduced: Bool { reducesMotion || systemReduceMotion }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = MachineHorizon.Geometry(size: size)
            ZStack(alignment: .topLeading) {
                horizon(geometry)
                    .accessibilityHidden(true)
                words(geometry)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .background(Palette.backdrop)
        .onAppear {
            guard !entered else { return }
            if reduced {
                withAnimation(Animation.easeOut(duration: MachineCoverTiming.enter)) { entered = true }
            } else {
                withAnimation(MachineCoverTiming.entry(MachineCoverTiming.enter).delay(MachineCoverTiming.enterDelay)) { entered = true }
            }
        }
    }

    // MARK: The horizon and its light

    private func horizon(_ geometry: MachineHorizon.Geometry) -> some View {
        layers.update(size: geometry.size, scale: displayScale)
        let frame = MachineHorizon.glintFrame(geometry)
        // The glint turns about the disc's centre: that point, in the glint's own frame.
        let anchor = UnitPoint(x: (geometry.centre.x - frame.minX) / max(1, frame.width),
                               y: (geometry.centre.y - frame.minY) / max(1, frame.height))
        let moving = !(reduced || still != nil)
        return ZStack(alignment: .topLeading) {
            if let picture = layers.picture {
                Image(decorative: picture, scale: displayScale)
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
                let t = still ?? timeline.date.timeIntervalSince(startedAt)
                let glint = MachineCoverTiming.glint(at: t, visibleHalfAngle: Double(geometry.visibleHalfAngle))
                ZStack(alignment: .topLeading) {
                    if let haze = layers.haze {
                        Image(decorative: haze, scale: max(0.5, displayScale / 2))
                            .resizable()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .opacity(MachineCoverTiming.haze(at: t, still: reduced))
                    }
                    if let sprite = layers.glint, !reduced, glint.strength > 0 {
                        Image(decorative: sprite, scale: displayScale)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .rotationEffect(.radians(glint.angle), anchor: anchor)
                            .opacity(glint.strength)
                            .blendMode(.plusLighter)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .clipped()
    }

    // MARK: The words

    private func words(_ geometry: MachineHorizon.Geometry) -> some View {
        let top = (geometry.size.height * 0.36 - Self.blockHeight / 2).rounded()
        let shown = model.texts.step(model.stage)
        let visible = entered && !model.leaving
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(model.texts.caption)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.54)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.primary.opacity(0.46))
                    .frame(height: 14)
                    .padding(.bottom, 12)
                Text(model.name)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.36)
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 36)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 10)
                ZStack {
                    Text(shown)
                        .font(.system(size: 14))
                        .tracking(0.07)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .id(shown)
                        .transition(stepTransition)
                }
                .frame(height: 20)
                .animation(MachineCoverTiming.entry(MachineCoverTiming.wordIn), value: shown)
                .padding(.bottom, 22)
                StepDashes(done: model.stage.stepsDone, reduced: reduced, still: still, startedAt: startedAt)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: model.texts.label, model.name, shown))
            .accessibilityAddTraits(.updatesFrequently)
            longer
                .padding(.top, 26)
        }
        .frame(width: geometry.size.width)
        .opacity(visible ? 1 : 0)
        .offset(y: reduced ? 0 : (entered ? (model.leaving ? -6 : 0) : 6))
        .animation(reduced ? Animation.easeOut(duration: MachineCoverTiming.wordsOut) : MachineCoverTiming.entry(MachineCoverTiming.wordsOut),
                   value: model.leaving)
        .offset(y: top)
    }

    /// "Taking longer than usual. Show the screen" — there from the start, seen after a minute.
    private var longer: some View {
        HStack(spacing: 0) {
            Text(model.texts.longer)
                .foregroundStyle(Palette.primary.opacity(0.46))
            Text(verbatim: "  ")
            Button(action: { model.showScreen() }) {
                Text(model.texts.show)
                    .underline(true, color: Palette.primary.opacity(0.32))
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.primary.opacity(0.88))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .font(.system(size: 12))
        .frame(height: 16)
        .opacity(model.offersReveal ? 1 : 0)
        .allowsHitTesting(model.offersReveal)
        .accessibilityHidden(!model.offersReveal)
        .animation(.easeOut(duration: MachineCoverTiming.offerIn), value: model.offersReveal)
    }

    private var stepTransition: AnyTransition {
        let out = MachineCoverTiming.entry(MachineCoverTiming.wordOut)
        let inward = MachineCoverTiming.entry(MachineCoverTiming.wordIn).delay(MachineCoverTiming.wordInDelay)
        if reduced {
            return .asymmetric(insertion: AnyTransition.opacity.animation(inward), removal: AnyTransition.opacity.animation(out))
        }
        return .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(y: 4)).animation(inward),
                           removal: AnyTransition.opacity.combined(with: .offset(y: -4)).animation(out))
    }
}

/// The six thin dashes of the steps: those behind filled, a light running in the current one.
private struct StepDashes: View {
    let done: Int
    let reduced: Bool
    let still: Double?
    let startedAt: Date

    private static let width: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced || still != nil)) { timeline in
            let t = still ?? timeline.date.timeIntervalSince(startedAt)
            HStack(spacing: 6) {
                ForEach(0..<VMSetupStage.steps.count, id: \.self) { index in
                    dash(index, t: t)
                }
            }
        }
        .frame(height: 2)
        .animation(MachineCoverTiming.entry(MachineCoverTiming.stepFill), value: done)
    }

    private func dash(_ index: Int, t: Double) -> some View {
        let width = Self.width
        let p = t.truncatingRemainder(dividingBy: MachineCoverTiming.shimmer) / MachineCoverTiming.shimmer
        let eased = CGFloat(p * p * (3 - 2 * p))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10))
            Capsule().fill(Palette.primary.opacity(0.85))
                .frame(width: index < done ? width : 0)
            if index == done {
                if reduced {
                    Capsule().fill(Palette.primary.opacity(0.55))
                        .frame(width: width * 0.5)
                        .offset(x: width * 0.25)
                } else {
                    Capsule().fill(Palette.primary.opacity(0.7))
                        .frame(width: width * 0.42)
                        .offset(x: (-0.42 + 1.42 * eased) * width)
                }
            }
        }
        .frame(width: width, height: 2, alignment: .leading)
        .clipShape(Capsule())
    }
}

/// A word over the machine's screen once the cover has gone by itself: the screen is shown as it
/// is. Takes no click: the helper's host lets every event through.
public struct MachineCoverNote: View {
    private let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(red: 18.0 / 255, green: 19.0 / 255, blue: 23.0 / 255).opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .padding(.top, 14)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .combine)
    }
}
