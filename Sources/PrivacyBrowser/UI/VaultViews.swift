import AppKit
import SwiftUI

/// The lock screen's backdrop: the window's black and, with the light on (Settings → Appearance),
/// the two eclipses. One for the setup, unlock and "open" states, so the eclipses close in while
/// the password is checked and part when the vault opens without starting over (RootView).
struct LockBackdrop<Content: View>: View {
    var phase: EclipseLight.Phase = .idle
    @ViewBuilder let content: () -> Content
    @ObservedObject private var appearance = AppearancePreferences.shared

    var body: some View {
        ZStack {
            // To the window's edges, under the title bar too: the window's own background is not
            // to show there (CI run 557, the snapshots' edge check).
            Theme.backdrop.ignoresSafeArea()
            if appearance.entryLight {
                EclipseLight(place: .lock, phase: phase).ignoresSafeArea()
            }
            content()
        }
    }
}

/// The lock screen (the design's "Lock and first launch"): the Lumen mark, a large title and the
/// form in a 400 pt column, centred; a footer line at the foot. It rises in once when the window
/// opens.
struct LockScreen<Content: View>: View {
    let title: String
    let subtitle: String
    /// The line at the foot: which vault this is, or where it is made.
    var footer: String?
    @ViewBuilder let content: () -> Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    var body: some View {
        // Centred in the window; scrolls when the window is shorter than the screen's content. The
        // scrolling starts under the title bar's band: one that reaches under the title bar gets
        // macOS 26's edge effect there (ProfilesScreen.inspectorTop).
        GeometryReader { geometry in
            ScrollView {
                screen.frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
        }
        .padding(.top, ProfilesScreen.inspectorTop)
        .onAppear {
            guard !appeared else { return }
            if stillFrame {
                appeared = true
                return
            }
            withAnimation(Motion.isReduced(reduceMotion) ? nil : Motion.entry(duration: 0.9).delay(0.2)) {
                appeared = true
            }
        }
    }

    private var screen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 0) {
                LumenMark(size: 64)
                Text(title)
                    .lumenDisplayTitle()
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                Text(subtitle)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                content()
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || Motion.isReduced(reduceMotion) ? 0 : 10)
            Spacer(minLength: 40)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The lock screen's field (the design's `fld`): 48 pt, radius 12, a 16 % edge; focused — the
/// edge at 50 % and a 4 pt ring; `error` — red, and it shakes once (not under Reduce Motion).
/// An eye shows the password; "Caps Lock" says itself while the key is down.
struct LockPasswordField: View {
    let label: String
    @Binding var password: String
    var error = false
    /// Changes when a wrong password was tried: the field shakes once.
    var attempts = 0
    var onSubmit: () -> Void = {}
    /// The cursor starts here. One field per screen: each took it as it appeared, and the last one
    /// won — the first launch began in "Repeat the master password" (CI run 554's snapshot).
    var takesFocus = true
    @State private var revealed = false
    @FocusState private var focused: Bool
    @StateObject private var capsLock = CapsLockState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                Group {
                    if revealed {
                        TextField(label, text: $password, prompt: Text(verbatim: ""))
                    } else {
                        SecureField(label, text: $password, prompt: Text(verbatim: ""))
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit(onSubmit)
                if capsLock.isOn {
                    Text(L("unlock.capsLock"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 6)
                }
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LumenIconButtonStyle(size: 34))
                .accessibilityLabel(revealed ? L("unlock.password.hide") : L("unlock.password.show"))
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(error ? Theme.danger : (focused ? Theme.edgeStrong : Theme.strongBorder), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(error ? Theme.dangerTint : Color.white.opacity(focused ? 0.06 : 0), lineWidth: 4)
                .padding(-4))
            .modifier(ShakeEffect(shakes: CGFloat(Motion.isReduced(reduceMotion) ? 0 : attempts)))
            .animation(Theme.hoverAnimation, value: focused)
            .animation(.linear(duration: 0.42), value: attempts)
        }
        .onAppear { if takesFocus { focused = true } }
    }
}

/// One shake: the field moves −1, 3, −6, 6 … pt and back (the design's 420 ms).
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = shakes - shakes.rounded(.down)
        guard phase > 0 else { return ProjectionTransform(.identity) }
        let amplitude = 6 * sin(phase * .pi)
        return ProjectionTransform(CGAffineTransform(translationX: amplitude * sin(phase * .pi * 8), y: 0))
    }
}

/// Whether Caps Lock is down, kept current while the lock screen shows.
@MainActor
private final class CapsLockState: ObservableObject {
    @Published private(set) var isOn = NSEvent.modifierFlags.contains(.capsLock)
    nonisolated(unsafe) private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isOn = event.modifierFlags.contains(.capsLock)
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// The lock screen's action (the design's `cta`): 50 pt, radius 14, a contour on near-black, 15 /
/// medium; light gathers under it on hover. `working`: a spinner and its label, not pressable.
struct LockActionButton: View {
    let title: String
    var working = false
    var workingTitle = ""
    var enabled = true
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if working {
                    ProgressView().controlSize(.small)
                }
                Text(working ? workingTitle : title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovered ? Color(hex: 0x15161A) : Color(hex: 0x0F1013)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? Theme.edgeStrong : Theme.edge, lineWidth: 1))
            .shadow(color: Theme.rim.opacity(hovered ? 0.18 : 0), radius: 20, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(LockPressStyle(reduced: Motion.isReduced(reduceMotion)))
        .disabled(working || !enabled)
        .opacity(working || enabled ? 1 : 0.5)
        .onHover { hovered = enabled && !working && $0 }
        .animation(Motion.hover(hovered), value: hovered)
    }
}

/// A press: 98.5 % for 80 ms.
private struct LockPressStyle: ButtonStyle {
    let reduced: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A quiet link under the action ("I don't remember the password"): `t2`, white and underlined
/// under the pointer.
struct LockLink: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .underline(hovered)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A note with its symbol (the key under the unlock form, the warning under the setup form).
struct LockNote: View {
    let symbol: String
    var tint: Color = Theme.textSecondary
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How strong a new master password looks: four steps, from its length and the kinds of
/// characters in it. A rough guide shown as the person types; the rule that decides is the
/// length (10 at least).
enum PasswordStrength {
    static func score(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        let kinds = [password.contains { $0.isLowercase }, password.contains { $0.isUppercase },
                     password.contains { $0.isNumber }, password.contains { !$0.isLetter && !$0.isNumber }]
            .filter { $0 }.count
        var score = password.count >= 10 ? 1 : 0
        if password.count >= 14 { score += 1 }
        if password.count >= 20 { score += 1 }
        if kinds >= 3 { score += 1 }
        return min(max(score, 1), 4)
    }

    static func word(_ score: Int) -> String {
        switch score {
        case 4: return L("setup.strength.4")
        case 3: return L("setup.strength.3")
        case 2: return L("setup.strength.2")
        default: return L("setup.strength.1")
        }
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""
    /// "It's written down": one click at the moment of the product's costliest mistake (the owner,
    /// 1 November) — a pause, and a choice made knowingly. Unticked again when the password changes:
    /// what was written down is then another password.
    @State private var writtenDown = false

    private var longEnough: Bool { password.count >= 10 }
    private var matches: Bool { !confirmation.isEmpty && password == confirmation }

    var body: some View {
        LockScreen(title: L("setup.title"), subtitle: L("setup.subtitle"), footer: L("setup.footer")) {
            VStack(alignment: .leading, spacing: 0) {
                MasterPasswordFacts()
                    .padding(.top, 24)
                if let moved = model.movedAsideVaultPath {
                    // After "forgot password": the previous vault was moved, not deleted.
                    LockNote(symbol: "archivebox", text: String(format: L("setup.movedAside"), moved))
                        .textSelection(.enabled)
                        .padding(.top, 20)
                }
                LockPasswordField(label: L("setup.field.password"), password: $password, error: model.masterPasswordRefusal != nil)
                    .padding(.top, 26)
                if let refusal = model.masterPasswordRefusal {
                    // §10.1: under the field — the account's password, or the license's key.
                    MasterPasswordRefusalLine(text: refusal)
                        .padding(.top, 10)
                }
                StrengthMeter(score: PasswordStrength.score(password))
                    .padding(.top, 10)
                LockPasswordField(label: L("setup.field.repeat"), password: $confirmation, onSubmit: create,
                                  takesFocus: false)
                    .padding(.top, 20)
                VStack(alignment: .leading, spacing: 6) {
                    PasswordRequirement(text: L("setup.req.length"), met: longEnough, shown: !password.isEmpty)
                    PasswordRequirement(text: L("setup.req.match"), met: matches, shown: !confirmation.isEmpty)
                }
                .padding(.top, 14)
                Toggle(isOn: $writtenDown) {
                    Text(L("setup.writtenDown"))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.lumenCheckbox)
                .padding(.top, 22)
                LockActionButton(title: L("setup.action.create"), working: model.isWorking,
                                 workingTitle: L("setup.working"), enabled: longEnough && matches && writtenDown,
                                 action: create)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 22)
            }
        }
        .onChange(of: password) { _, _ in
            writtenDown = false
            model.masterPasswordRefusal = nil
        }
        .overlay(alignment: .topTrailing) {
            // The interface's language, when this is the run's first screen (the owner: on the
            // first screen, before the vault exists). Not after "forgot password": a restart would
            // lose the line that says where the previous vault was moved.
            if model.setupIsFirstScreen && model.movedAsideVaultPath == nil {
                FirstLaunchLanguagePicker()
                    .padding(.top, ProfilesScreen.inspectorTop)
                    .padding(.trailing, 20)
            }
        }
    }

    private func create() {
        guard longEnough, matches, writtenDown, !model.isWorking else { return }
        Task { await model.createVault(password: password) }
    }
}

/// Why a new master password is not accepted (§10.1), under its field: the account's password, or the
/// license's key — the contract's words, in the danger's colour.
struct MasterPasswordRefusalLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

/// A new master password's requirement under its fields: a ring until it is typed, then a check when
/// met or a cross in red when not — never a check that could be read as met before anything is typed.
private struct PasswordRequirement: View {
    let text: String
    let met: Bool
    let shown: Bool

    var body: some View {
        let failed = shown && !met
        HStack(spacing: 7) {
            Image(systemName: failed ? "xmark" : (met ? "checkmark" : "circle"))
                .font(.system(size: met || failed ? 10 : 7, weight: .bold))
                .foregroundStyle(failed ? Theme.danger : (met ? Theme.textPrimary : Theme.textTertiary))
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(failed ? Theme.danger : (met ? Theme.textPrimary : Theme.textTertiary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(met ? L("setup.req.met") : L("setup.req.notMet")))
    }
}

/// What the person must know before choosing the master password, said first and large — not as a
/// footnote (the owner, 1 November). With accounts, this screen comes right after the account's own
/// password, twice typed, and many would type that one again; but the account's password comes back
/// by email and this one never does. So: it is another password, it is sent nowhere, it cannot be
/// recovered, and it is to be written down apart. "Cannot be recovered", not "keep it safe".
private struct MasterPasswordFacts: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("setup.facts.title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            fact("icloud.slash", L("setup.facts.notSent"), strong: false)
            fact("exclamationmark.triangle.fill", L("setup.facts.noRecovery"), strong: true)
            fact("square.and.pencil", L("setup.facts.writeDown"), strong: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.warningTint))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warningLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func fact(_ symbol: String, _ text: String, strong: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(strong ? Theme.warning : Theme.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15, weight: strong ? .semibold : .regular))
                .lineSpacing(2)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Four 3 pt steps filled white by strength, "Strength" and its word under them.
private struct StrengthMeter: View {
    let score: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { step in
                    Capsule()
                        .fill(step <= score ? Theme.textPrimary : Color.white.opacity(0.10))
                        .frame(height: 3)
                }
            }
            .animation(.easeOut(duration: 0.25), value: score)
            HStack {
                Text(L("setup.strength"))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if score > 0 {
                    Text(PasswordStrength.word(score))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.system(size: 12))
        }
        .accessibilityElement(children: .combine)
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmingReset = false
    @State private var attempts = 0

    var body: some View {
        LockScreen(title: L("unlock.title"), subtitle: L("unlock.subtitle"), footer: footer) {
            VStack(alignment: .leading, spacing: 0) {
                LockPasswordField(label: L("setup.field.password"), password: $password,
                                  error: model.unlockFailed && password.isEmpty, attempts: attempts, onSubmit: unlock)
                    .padding(.top, 36)
                if model.unlockFailed && password.isEmpty {
                    Label(L("unlock.wrong"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 10)
                        .transition(.opacity)
                } else {
                    Text(L("unlock.help"))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                if model.unlockFailed && model.vaultLooksLikeTestVault {
                    Label(L("unlock.vault.test"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                VStack(spacing: 14) {
                    LockActionButton(title: L("unlock.action.unlock"), working: model.isWorking,
                                     workingTitle: L("unlock.working"), enabled: !password.isEmpty, action: unlock)
                        .keyboardShortcut(.defaultAction)
                    LockLink(title: L("unlock.reset.action")) { confirmingReset = true }
                        .disabled(model.isWorking)
                }
                .padding(.top, 28)
                if model.unlockFailed {
                    // Which vault was tried: another build (sandboxed or not, other bundle id)
                    // opens a different folder with a vault of its own.
                    Text(String(format: L("unlock.vault.info"), model.vaultCreatedDescription, model.vaultPathDescription))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 18)
                } else {
                    LockNote(symbol: "key", text: L("unlock.keys"))
                        .padding(.top, 26)
                }
            }
            .animation(Theme.appearAnimation, value: model.unlockFailed)
        }
        .onChange(of: model.isWorking) { _, working in
            if !working && model.unlockFailed { attempts += 1 }
        }
        .confirmationDialog(L("unlock.reset.title"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L("unlock.reset.confirm"), role: .destructive) { model.startOver() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("unlock.reset.message"))
        }
    }

    private var footer: String {
        // Without its day (a vault that does not say when it was made): the folder alone.
        model.vaultCreatedDay.map { String(format: L("unlock.footer"), $0, model.vaultPathDescription) } ?? model.vaultPathDescription
    }

    private func unlock() {
        let entered = password
        // Return reaches both `.onSubmit` and the default button: the second call finds the
        // field already cleared and must not submit "" (that is a "wrong password").
        guard !entered.isEmpty, !model.isWorking else { return }
        password = ""
        Task { await model.unlock(password: entered) }
    }
}

/// The vault is open: said for a moment while the eclipses part, before the Profiles window
/// comes in (RootView).
struct VaultOpenView: View {
    var body: some View {
        LockScreen(title: L("open.title"), subtitle: L("open.subtitle")) {
            EmptyView()
        }
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    /// A change is on its way: a second click does not start another.
    @State private var changing = false

    private var longEnough: Bool { new.count >= 10 }
    private var matches: Bool { !confirmation.isEmpty && new == confirmation }
    private var canChange: Bool { !current.isEmpty && longEnough && matches && !changing }

    // The lock screen's fields (the design's), with Caps Lock said and the eye to show what was
    // typed; the new password's strength and requirements as at the first launch. Return presses
    // "Change" (the default button) — the fields themselves submit nothing, so that one press is
    // never two changes.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("changepw.title"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LockPasswordField(label: L("changepw.current"), password: $current)
                    LockPasswordField(label: L("changepw.new"), password: $new, error: model.masterPasswordRefusal != nil, takesFocus: false)
                        .padding(.top, 18)
                    if let refusal = model.masterPasswordRefusal {
                        MasterPasswordRefusalLine(text: refusal)
                            .padding(.top, 10)
                    }
                    StrengthMeter(score: PasswordStrength.score(new))
                        .padding(.top, 10)
                    LockPasswordField(label: L("changepw.repeat"), password: $confirmation, takesFocus: false)
                        .padding(.top, 18)
                    VStack(alignment: .leading, spacing: 6) {
                        PasswordRequirement(text: L("setup.req.length"), met: longEnough, shown: !new.isEmpty)
                        PasswordRequirement(text: L("setup.req.match"), met: matches, shown: !confirmation.isEmpty)
                    }
                    .padding(.top, 12)
                    Text(L("changepw.note"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("changepw.action.change"), action: change)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canChange)
            }
        }
        // Fits under the Settings window's title bar (700 pt) as well as the Profiles window's.
        .sheetFrame(width: 480, height: 660)
        .background(Theme.raised)
        .onAppear { model.masterPasswordRefusal = nil }
        .onChange(of: new) { _, _ in model.masterPasswordRefusal = nil }
    }

    private func change() {
        guard canChange else { return }
        changing = true
        Task {
            await model.changePassword(current: current, new: new)
            changing = false
            if model.errorMessage == nil, model.masterPasswordRefusal == nil { dismiss() }
        }
    }
}
