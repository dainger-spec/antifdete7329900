import AppKit
import SwiftUI

// MARK: - Settings → Appearance

/// How the app's own windows look and move (Settings → Appearance): the light at entry, the
/// profile list's density, the interface's animations. Kept in this Mac's defaults, outside the
/// vault: the lock screen needs them before the vault opens, and none of it is secret.
@MainActor
final class AppearancePreferences: ObservableObject {
    static let shared = AppearancePreferences()

    enum Density: String, CaseIterable {
        /// Rows 52 pt.
        case comfortable
        /// Rows 40 pt: more profiles on the screen.
        case compact

        var rowHeight: CGFloat { self == .compact ? 40 : 52 }
    }

    /// The eclipses at the corners of the lock screen and the profiles window, and still, dimmed,
    /// behind the profile editor and Scenarios.
    @Published var entryLight: Bool { didSet { defaults.set(entryLight, forKey: Keys.entryLight) } }
    @Published var density: Density { didSet { defaults.set(density.rawValue, forKey: Keys.density) } }
    /// Short transitions (up to 250 ms); off — only colour and opacity change, as under Reduce Motion.
    @Published var animations: Bool { didSet { defaults.set(animations, forKey: Keys.animations) } }

    private let defaults: UserDefaults

    enum Keys {
        static let entryLight = "appearance.entryLight"
        static let density = "appearance.density"
        static let animations = "appearance.animations"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entryLight = defaults.object(forKey: Keys.entryLight) as? Bool ?? true
        density = defaults.string(forKey: Keys.density).flatMap(Density.init(rawValue:)) ?? .comfortable
        animations = defaults.object(forKey: Keys.animations) as? Bool ?? true
    }

    /// The animations setting as stored, from any thread.
    nonisolated static var animationsEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.animations) as? Bool ?? true
    }
}

// MARK: - Motion

/// Lumen's motion (the design's "Light and motion"). Hover: at once on, 120–150 ms off. A press:
/// 98 % for 80 ms. A switch: 180 ms. A selection: 180 ms. A panel in: 260 ms, 24 pt from its edge
/// (`AnyTransition.lumenSlide`, `lumenRise`, `lumenDrop`), never its whole width. The "Running" dot
/// lights up once, in 700 ms. The profile list's groups re-sort in 220 ms, and only once the
/// pointer has left the list. With Reduce Motion in macOS, or the animations turned off in
/// Settings → Appearance, only colour and opacity change.
enum Motion {
    /// The design's ease-out for things entering: cubic-bezier(.16, 1, .3, 1).
    static func entry(duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
    /// Under the pointer at once; away in 150 ms.
    static func hover(_ hovered: Bool) -> Animation? { hovered ? nil : .easeOut(duration: 0.15) }
    static let press = Animation.easeOut(duration: 0.08)
    static let toggle = Animation.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.18)
    static let ignite = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)
    static let reflow = Animation.easeInOut(duration: 0.22)
    /// A selection moving between rows or sidebar items: 180 ms on the entry curve.
    static let select = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
    /// A panel in (an inspector, the selection bar): 260 ms on the entry curve.
    static let panelIn = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.26)

    /// Movement is off: Reduce Motion in macOS (`systemReduceMotion`), or the animations turned
    /// off in Settings → Appearance.
    static func isReduced(_ systemReduceMotion: Bool) -> Bool {
        systemReduceMotion || !AppearancePreferences.animationsEnabled
    }
}

/// The design's entrances, each a short way from its place rather than from beyond an edge.
/// `reduced` (`Motion.isReduced`): a fade alone.
extension AnyTransition {
    /// A banner or notice above a list: settles 6 pt down into place while fading in; leaves by fading.
    static func lumenDrop(_ reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }

    /// A floating bar from below: 10 pt and 98 %; leaves 6 pt down.
    static func lumenRise(_ reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10))
                                             .combined(with: .scale(scale: 0.98, anchor: .bottom)),
                                         removal: .opacity.combined(with: .offset(y: 6)))
    }

    /// A side panel: 24 pt from the trailing edge, not its whole width; leaves 16 pt.
    static func lumenSlide(_ reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                         removal: .opacity.combined(with: .offset(x: 16)))
    }
}

private struct StillFrameKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LazyProfileListKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draw the state a window settles in, with no entry animation: the self-test's snapshots.
    var lumenStillFrame: Bool {
        get { self[StillFrameKey.self] }
        set { self[StillFrameKey.self] = newValue }
    }

    /// The profile list in its former shape, a lazy stack of whole groups: the control of the UI
    /// snapshots' check that the list shows its rows after a profile came back
    /// (`UISnapshots.listAfterReturn`). The app never sets it.
    var lazyProfileListControl: Bool {
        get { self[LazyProfileListKey.self] }
        set { self[LazyProfileListKey.self] = newValue }
    }
}

// MARK: - Switch and checkbox

/// The design's switch: a 36 × 20 track — off: dark, with a button's 32 % contour (3 : 1; 50 % with
/// Increase Contrast) and a 14 pt grey knob; on: white, with a 16 pt dark knob and its small
/// shadow — the knob sliding in 180 ms. To VoiceOver and the keyboard it is the standard switch,
/// with its label even when `showsLabel` is false (a settings row whose title stands beside it).
struct LumenSwitchStyle: ToggleStyle {
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        LumenSwitch(configuration: configuration, showsLabel: showsLabel)
    }
}

private struct LumenSwitch: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let on = configuration.isOn
        HStack(spacing: 10) {
            if showsLabel {
                configuration.label
            }
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    // Off, the track is told by its contour: a grey fill on the window's black was
                    // about 1.4 : 1, seen mostly by its knob.
                    Capsule().fill(on ? Theme.textPrimary : Color(hex: 0x15161A))
                        .overlay(Capsule().strokeBorder(on ? Color.clear : (contrast == .increased ? Theme.edgeStrong : Theme.edge),
                                                        lineWidth: 1))
                    Circle().fill(on ? Theme.backdrop : Theme.textSecondary)
                        .frame(width: on ? 16 : 14, height: on ? 16 : 14)
                        .shadow(color: Color.black.opacity(on ? 0.35 : 0), radius: 1, y: 0.5)
                        .padding(on ? 2 : 3)
                }
                .frame(width: 36, height: 20)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .animation(Motion.isReduced(reduceMotion) ? nil : Motion.toggle, value: configuration.isOn)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The design's checkbox: 16 pt, radius 5, a 1.5 pt contour at a button's 32 % (`edge`, 3 : 1);
/// checked — white, with a dark mark.
/// To VoiceOver and the keyboard it is the standard checkbox.
struct LumenCheckboxStyle: ToggleStyle {
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        LumenCheckbox(configuration: configuration, showsLabel: showsLabel)
    }
}

private struct LumenCheckbox: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isOn ? Theme.textPrimary : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(configuration.isOn ? Theme.textPrimary : Theme.edge, lineWidth: 1.5))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.backdrop)
                        }
                    }
                    .frame(width: 16, height: 16)
                if showsLabel {
                    configuration.label
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == LumenSwitchStyle {
    static var lumenSwitch: LumenSwitchStyle { LumenSwitchStyle() }
}

extension ToggleStyle where Self == LumenCheckboxStyle {
    static var lumenCheckbox: LumenCheckboxStyle { LumenCheckboxStyle() }
}

// MARK: - Choices

/// The design's segments: options in a recessed group (`field` black, a 10 % edge, radius 9); the
/// chosen one a raised pill (`faceLit`, `pillEdge`; flat `raisedInset` and `strongBorder` with
/// Increase Contrast) that slides to the new choice in 180 ms — under Reduce Motion it simply
/// appears there. 26 pt / 12.5 (`large`: 28 pt / 13, the editor's).
struct LumenSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var large = false
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(large ? Font.lumenLabel : Font.lumenControl)
                        .lineLimit(1)
                        .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, large ? 14 : 12)
                        .frame(height: large ? 28 : 26)
                        .background {
                            // One pill, moved between the options by its id rather than a fill that
                            // jumps from one to the next.
                            if chosen {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(contrast == .increased ? AnyShapeStyle(Theme.raisedInset) : AnyShapeStyle(Theme.faceLit))
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(contrast == .increased ? AnyShapeStyle(Theme.strongBorder) : AnyShapeStyle(Theme.pillEdge),
                                                      lineWidth: 1))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .animation(Motion.isReduced(reduceMotion) ? nil : Motion.toggle, value: selection)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .fixedSize()
    }
}

/// One choice among a few (the design's `radio`): a 16 pt ring at a button's 32 % (`edge`); chosen —
/// white, with a 6 pt dot.
struct LumenRadio: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Circle()
                    .strokeBorder(isOn ? Theme.textPrimary : Theme.edge, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .overlay {
                        if isOn {
                            Circle().fill(Theme.textPrimary).frame(width: 6, height: 6)
                        }
                    }
                Text(title)
                    .font(.lumenBody)
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The app's errors (`AppModel.showError`) said in the window they were raised from. Only the
/// Profiles window said them: one raised from Settings or the scenario editor — a wrong password
/// in Change Password, a sync server not saved, a scenario not written — came up behind, or in a
/// window that was closed. Said here while this window is the key one; the Profiles window says
/// it as before.
private struct ModelErrors: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.alert(L("common.error"),
                      isPresented: Binding(get: { model.errorMessage != nil && activeState == .key },
                                           set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension View {
    /// The app's errors as an alert of this window while it is the key one (`ModelErrors`).
    func saysModelErrors() -> some View { modifier(ModelErrors()) }
}

/// A key or a shortcut (the design's `kbd`): `small` — 18 pt, in the search field (⌘K), a hairline
/// only; else 24 pt, in the list of shortcuts, raised as a key is: a lit face (`faceLit`) and a quiet
/// lit edge (`pillEdge`; flat `strongBorder` with Increase Contrast).
struct KeyCap: View {
    let keys: String
    var small = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 5 : 7, style: .continuous)
        Text(verbatim: keys)
            .font(.system(size: small ? 11 : 12, weight: .medium))
            .foregroundStyle(small ? Theme.textTertiary : Theme.textPrimary)
            .padding(.horizontal, small ? 5 : 8)
            .frame(minWidth: small ? 20 : 24, minHeight: small ? 18 : 24)
            .background {
                if !small { shape.fill(Theme.faceLit) }
            }
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            .fixedSize()
    }

    private var edge: AnyShapeStyle {
        if small { return AnyShapeStyle(Theme.hairline) }
        return contrast == .increased ? AnyShapeStyle(Theme.strongBorder) : AnyShapeStyle(Theme.pillEdge)
    }
}

extension View {
    /// A side panel over the light (sidebar, inspector): 80 % of `bg2`, so the light behind it is
    /// all but gone.
    func lumenFrost() -> some View {
        background(Theme.sidebar.opacity(0.8))
    }
}
