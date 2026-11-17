import AppKit
import SwiftUI

// MARK: - Timing

/// The launch screen's times, in seconds from its start.
struct WelcomeTiming {
    /// The horizon fades and rises in.
    static let arcIn = 0.7
    /// The mark, "Lumen" and the line under it.
    static let titleDelay = 0.2
    static let titleIn = 0.8
    /// The first launch's button.
    static let buttonDelay = 0.7
    static let buttonIn = 0.5
    /// A later launch: how long the screen stays once it has come in, before it opens by itself.
    static let hold = 0.6
    /// The opening: the screen eases up 30 pt and fades while the window's content scales in.
    static let opening = 0.5
    /// Reduce Motion: nothing moves; the screen stays this long, and opens with a short cross-fade.
    static let reducedHold = 1.4
    static let reducedOpening = 0.25

    let reduced: Bool

    /// Everything has come in.
    var settledAt: Double { reduced ? 0 : max(Self.arcIn, Self.titleDelay + Self.titleIn, Self.buttonDelay + Self.buttonIn) }
    /// A later launch opens by itself.
    var openAt: Double { reduced ? Self.reducedHold : settledAt + Self.hold }
    /// How long the opening takes.
    var opening: Double { reduced ? Self.reducedOpening : Self.opening }
}

/// Where the screen's parts stand in a window of `size`: the horizon as the lock screen's
/// launch picture has it (`LumenHorizon`), and the title above its light, never on it.
struct WelcomeLayout {
    let size: CGSize
    let horizon: LumenHorizon.Geometry
    /// From the window's top to where the title's block ends: a gap above the arc's light.
    let titleBottom: CGFloat
    /// "Lumen"'s size, and the mark's.
    let wordSize: CGFloat
    let markSize: CGFloat
    /// The first launch's button: on the disc, under the light.
    let buttonY: CGFloat

    init(size: CGSize) {
        self.size = size
        horizon = LumenHorizon.Geometry(width: size.width, height: size.height)
        wordSize = max(34, min(60, size.height * 0.075))
        markSize = wordSize * 0.9
        // The light's haze reaches some way above the rim's top: the block stands clear of it.
        titleBottom = horizon.top - max(36, size.height * 0.06)
        buttonY = horizon.top + max(84, (size.height - horizon.top) * 0.42)
    }
}

// MARK: - The screen

/// The launch screen (the owner, 17 November, replacing the handwritten «welcome» in glass): the
/// dark backdrop and the eclipse's horizon — the lock screen's — with the Lumen mark, "Lumen" and
/// one short line fading in above the arc's light, and at the first launch one button, «Начать» /
/// "Get started". About a second and a half; under Reduce Motion (or with the animations off)
/// nothing moves: the screen is there whole, and opens with a short cross-fade.
///
/// Shown at the first start only, or at every start with Settings → Appearance's setting
/// (`WelcomeSplashPolicy`, `WelcomeLaunch`). At the first launch the button opens it (setup comes
/// next); at a later one it opens by itself after a moment. Any click or key opens it at once. The
/// opening is the screen's own — it eases up 30 pt and fades — while RootView brings the window's
/// content in over it (`opening`), then lets it go (`finished`).
/// On a start with a vault the screen is `overScreens`: the lock screen is under it from the start,
/// its password's field holding the keyboard; the screen takes no focus, its backdrop fades with
/// the rest, and a key opens it and still goes on to the field — the password typed at once is
/// the whole password.
struct WelcomeSplash: View {
    /// The first launch: the button leads on; otherwise the screen goes on by itself.
    let firstLaunch: Bool
    /// The opening begins: the window's content comes in over the screen. Called once.
    let opening: () -> Void
    /// The opening is over: the screen can go. Called once.
    let finished: () -> Void
    /// The snapshots: the screen at this time (seconds from its start), still.
    var still: Double?
    /// Over the window's screens (a start with a vault: the lock screen): not focusable, the
    /// backdrop fading with the opening, keys watched and passed on (`watchKeys`).
    var overScreens = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame
    @Environment(\.displayScale) private var displayScale
    /// When the screen started: nil until it appears.
    @State private var start: Date?
    @State private var settled = false
    /// When the opening began, seconds from the start.
    @State private var openedAt: Double?
    @State private var cache = WelcomeSplashCache()
    @FocusState private var focused: Bool
    /// `overScreens`: the app's key events, looked at on their way (`NSEvent`'s local monitor).
    @State private var keyMonitor: Any?

    private var reduced: Bool { Motion.isReduced(systemReduceMotion) }
    private var timing: WelcomeTiming { WelcomeTiming(reduced: reduced) }
    /// A still frame: the snapshots' time, or (any other still picture) the settled screen.
    private var stillTime: Double? { still ?? (stillFrame ? timing.settledAt + 0.5 : nil) }
    /// Nothing moves: a still, before the start, or settled and waiting.
    private var paused: Bool { stillTime != nil || start == nil || (settled && openedAt == nil) }

    var body: some View {
        GeometryReader { geometry in
            let layout = WelcomeLayout(size: geometry.size)
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
                scene(at: time(at: context.date), layout: layout)
            }
        }
        // Over the screens the backdrop is the scene's, and fades with it.
        .background(overScreens ? Color.clear : Theme.backdrop)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { go() }
        // Over the screens, once it opens, a click is the screen's under it.
        .allowsHitTesting(!overScreens || openedAt == nil)
        // Any key goes on; the screen holds the keyboard's focus without a ring — but over the
        // screens the keyboard stays with what has it there (`watchKeys`).
        .focusable(!overScreens)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { _ in
            go()
            return .handled
        }
        .onAppear {
            if overScreens { watchKeys() } else { focused = true }
        }
        .onDisappear { stopWatchingKeys() }
        .task { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L("welcome.skip")) { go() }
    }

    /// Over the screens: a key opens the launch screen and goes on, unchanged, to what has the
    /// keyboard — the lock screen's password field, so the first key typed is the password's.
    private func watchKeys() {
        guard keyMonitor == nil, stillTime == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { go() }
            return event
        }
    }

    private func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func time(at date: Date) -> Double {
        if let stillTime { return stillTime }
        guard let start else { return 0 }
        return date.timeIntervalSince(start)
    }

    /// The screen's own course: it stills once everything has come in, and on a later launch
    /// opens by itself.
    private func run() async {
        guard stillTime == nil else { return }
        if start == nil { start = Date() }
        let wait = firstLaunch ? timing.settledAt : timing.openAt
        try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
        guard !Task.isCancelled, openedAt == nil else { return }
        if firstLaunch {
            settled = true
        } else {
            go()
        }
    }

    /// The opening, once: the screen eases up and fades by itself (the timeline) while RootView
    /// brings the window's content in; when it is over the screen goes.
    private func go() {
        guard openedAt == nil, stillTime == nil else { return }
        let now = Date()
        if start == nil { start = now }
        openedAt = now.timeIntervalSince(start ?? now)
        settled = false
        opening()
        let length = timing.opening
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(length * 1_000_000_000))
            finished()
        }
    }

    // MARK: One frame

    @ViewBuilder
    private func scene(at time: Double, layout: WelcomeLayout) -> some View {
        let open = openedAt.map { progress(time, $0, timing.opening) } ?? 0
        let leave = easeInOut(open)
        let lift: CGFloat = reduced ? 0 : -30 * CGFloat(leave)
        let alpha = 1 - leave
        let arcIn = reduced ? 1 : easeOut(progress(time, 0, WelcomeTiming.arcIn))
        let titleIn = reduced ? 1 : easeOut(progress(time, WelcomeTiming.titleDelay, WelcomeTiming.titleIn))
        let buttonIn = !firstLaunch ? 0 : reduced ? 1 : easeOut(progress(time, WelcomeTiming.buttonDelay, WelcomeTiming.buttonIn))

        ZStack(alignment: .topLeading) {
            if overScreens {
                // The lock screen is under it: the backdrop fades with the rest as it opens.
                Theme.backdrop
                    .frame(width: layout.size.width, height: layout.size.height)
                    .opacity(alpha)
            }
            if let horizon = cache.horizon(size: layout.size, scale: displayScale) {
                Image(decorative: horizon, scale: displayScale)
                    .resizable()
                    .frame(width: layout.size.width, height: layout.size.height)
                    .opacity(arcIn * alpha)
                    .offset(y: CGFloat(1 - arcIn) * 10 + lift)
                    .accessibilityHidden(true)
            }
            title(layout)
                .opacity(titleIn * alpha)
                .offset(y: CGFloat(1 - titleIn) * 8 + lift)
            if firstLaunch {
                // Lumen's main button, a size up: the screen's one action.
                Button { go() } label: {
                    Text(L("welcome.start")).frame(minWidth: 132)
                }
                    .buttonStyle(LumenButtonStyle(kind: .primary, height: 40))
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
                    .position(x: layout.size.width / 2, y: layout.buttonY)
                    .offset(y: lift)
                    .opacity(buttonIn * alpha)
                    .allowsHitTesting(buttonIn > 0.5 && openedAt == nil)
                    .accessibilityHidden(buttonIn == 0)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    /// The mark, "Lumen" and the line under it, standing on the arc's light — above it, never on it.
    private func title(_ layout: WelcomeLayout) -> some View {
        VStack(spacing: 0) {
            LumenGlyph(size: layout.markSize)
                .shadow(color: Theme.rim.opacity(0.3), radius: 18)
                .accessibilityHidden(true)
            Text(verbatim: "Lumen") // l10n: not text — the product's name
                .font(.system(size: layout.wordSize, weight: .semibold))
                .tracking(-0.02 * layout.wordSize)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, layout.wordSize * 0.32)
                .accessibilityAddTraits(.isHeader)
            Text(L("welcome.tagline"))
                .font(.system(size: max(15, layout.wordSize * 0.3)))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, layout.wordSize * 0.16)
        }
        .fixedSize()
        .frame(width: layout.size.width, height: max(0, layout.titleBottom), alignment: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("welcome.hint"))
    }

    private func progress(_ time: Double, _ from: Double, _ length: Double) -> Double {
        max(0, min(1, (time - from) / length))
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

/// What the launch screen makes once and keeps: the horizon's picture for the window's size.
final class WelcomeSplashCache {
    private var horizonKey: (CGSize, CGFloat)?
    private var horizonPicture: CGImage?

    func horizon(size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        if let key = horizonKey, key.0 == size, key.1 == scale { return horizonPicture }
        horizonKey = (size, scale)
        horizonPicture = LumenHorizon.image(size: size, scale: scale)
        return horizonPicture
    }
}
