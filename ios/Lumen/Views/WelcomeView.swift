import LumenCore
import SwiftUI

/// The start screen, on the first launch without an account (the owner, 17 November). The mark comes up
/// from where the launch screen left it while a dark horizon rises under it. The horizon's edge is lit:
/// a fine line of light, strongest at the top of the arc, the eclipse of the mark's own split disc. The
/// halves part along the split, the light flares, and the sign-in follows on the dark side: the
/// account's address and password, the code from the email or the robot check when the server asks
/// (SignInFlow, as the account's form), the site for a forgotten password. Plain on purpose (the owner,
/// 17 November: "посерьезнее"): one light, one group of fields, one button, no ornament.
/// Signing in is not required: "Продолжить без входа" goes to the free level (App Store 5.1.1), and the
/// start screen does not come back. The account is made on the site; the app offers no purchase.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var flow = SignInFlow()
    @Namespace private var mark
    @FocusState private var field: Field?
    /// Gone from the screen: signed in, or on without an account.
    let done: () -> Void

    /// The mark still where the launch screen drew it (the screen's centre, its size).
    @State private var risen = false
    /// The light through the split, then the halves close again.
    @State private var parted = false
    @State private var shown = false
    /// The horizon risen to its place under the mark.
    @State private var horizonUp = false
    /// The light flares as the halves part.
    @State private var flare = false
    /// The light swells and ebbs, slowly, once everything is in place.
    @State private var breathe = false

    enum Field { case email, password, code }

    var body: some View {
        GeometryReader { screen in
            content(size: screen.size)
        }
        .background(Color("LaunchBackground").ignoresSafeArea())
        .task { await play() }
        .sheet(isPresented: $flow.robotCheck) {
            RobotCheckSheet(url: SignInView.robotCheckURL) { token in
                flow.robotCheck = false
                guard let token else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { flow.submit(model, robotToken: token, signedIn: done) }
            }
        }
        .animation(.smooth(duration: 0.3), value: flow.challenge)
    }

    private func content(size: CGSize) -> some View {
        ZStack {
            if !risen {
                // As on the launch screen: the mark 60 points wide at the centre of the whole screen.
                Color.clear
                    .overlay {
                        SplitMark(parted: false)
                            .matchedGeometryEffect(id: "mark", in: mark)
                            .frame(width: Self.launchBox, height: Self.launchBox)
                    }
                    .ignoresSafeArea()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(height: max(170, size.height * 0.3))
                    // The horizon's top is here; it is drawn under everything that follows.
                    Color.clear
                        .frame(height: 0)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            Horizon(diameter: max(size.width * 2.7, 900), glow: flare ? 1.6 : 1, breathe: breathe)
                                .offset(y: horizonUp ? 0 : 220)
                                .opacity(horizonUp ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                    Group {
                        if flow.challenge == nil { passwordStep } else { codeStep }
                    }
                    .padding(.top, 60)
                    Spacer(minLength: 32)
                    footer
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 480, minHeight: size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: The parts

    /// The mark over the top of the horizon's arc.
    private func hero(height: CGFloat) -> some View {
        Group {
            if risen {
                SplitMark(parted: parted)
                    .matchedGeometryEffect(id: "mark", in: mark)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.markBox, height: Self.markBox)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.title, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(L("Вход в Lumen"), L("Тот же аккаунт, что в Lumen для Mac."))
                .appear(shown, step: 0, reduceMotion: reduceMotion)
            FieldGroup {
                TextField("", text: $flow.email, prompt: prompt(L("Почта")))
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($field, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                    .accessibilityLabel(L("Почта"))
                    .accessibilityIdentifier("signInEmail")
                    .fieldRow()
                FieldSeparator()
                HStack(spacing: 12) {
                    Group {
                        if flow.showPassword {
                            TextField("", text: $flow.password, prompt: prompt(L("Пароль")))
                                .accessibilityIdentifier("signInPasswordShown")
                        } else {
                            SecureField("", text: $flow.password, prompt: prompt(L("Пароль")))
                                .accessibilityIdentifier("signInPassword")
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.password)
                    .focused($field, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if flow.canSubmit { submit() } }
                    .accessibilityLabel(L("Пароль"))
                    Button { flow.showPassword.toggle() } label: {
                        Image(systemName: flow.showPassword ? "eye" : "eye.slash")
                            .font(.body.weight(.light))
                            .foregroundStyle(.white.opacity(0.45))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(flow.showPassword ? L("Скрыть пароль") : L("Показать пароль"))
                }
                .fieldRow()
            }
            .padding(.top, 28)
            .appear(shown, step: 1, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 0) {
                if let message = flow.message { failure(message).padding(.top, 12) }
                Button(L("Забыли пароль?")) { openURL(SignInView.resetURL) }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 14)
                    .accessibilityIdentifier("forgotPassword")
                primaryButton(L("Войти"), enabled: flow.canSubmit, id: "submitSignIn", action: submit)
                    .padding(.top, 24)
            }
            .appear(shown, step: 2, reduceMotion: reduceMotion)
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    @ViewBuilder private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(L("Код из письма"), AccountText.checkEmail)
            FieldGroup {
                TextField("", text: $flow.code, prompt: prompt(L("Код из письма")))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode).monospacedDigit()
                    .focused($field, equals: .code)
                    .accessibilityLabel(L("Код из письма"))
                    .accessibilityIdentifier("signInCode")
                    .fieldRow()
            }
            .padding(.top, 28)
            if let message = flow.message { failure(message).padding(.top, 12) }
            primaryButton(L("Подтвердить"), enabled: flow.canConfirm, id: "submitCode") {
                flow.confirm(model, signedIn: done)
            }
            .padding(.top, 24)
            HStack {
                ResendCodeButton(flow: flow) { flow.resend(model) }
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 12)
                Button(L("Ввести пароль заново")) { flow.backToPassword() }
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.subheadline)
            .padding(.top, 18)
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .onAppear { field = .code }
    }

    private var footer: some View {
        Button(L("Продолжить без входа")) { done() }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
            .accessibilityIdentifier("continueWithoutAccount")
            .appear(shown, step: 3, reduceMotion: reduceMotion)
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(.white.opacity(0.32))
    }

    private func primaryButton(_ title: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(flow.busy ? 0 : 1)
                if flow.busy { ProgressView().tint(.black).accessibilityIdentifier("signInBusy") }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.white)
        .foregroundStyle(.black)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    private func failure(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color(.systemRed))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("signInMessage")
    }

    private func submit() {
        field = nil
        flow.submit(model, signedIn: done)
    }

    // MARK: The animation

    /// The mark's box on the launch screen: the mark is 60 points wide there (LaunchLogo), and fills
    /// 0.68 of its box (LumenMark's 32-unit square).
    static let launchBox: CGFloat = 88
    /// Its box over the horizon: the mark about 42 points wide.
    static let markBox: CGFloat = 62

    /// From the launch screen: the mark rises to its place as the horizon comes up under it, its halves
    /// part along the split and the light flares, they close, and the words and the form come up one
    /// after the other. Reduce Motion: everything in its place, faded in.
    private func play() async {
        if reduceMotion {
            risen = true
            withAnimation(.easeOut(duration: 0.3)) { horizonUp = true; shown = true }
            return
        }
        // The launch screen's copy fades out over this one first (LaunchRoot, 0.45 s).
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.spring(duration: 0.8, bounce: 0.12)) { risen = true }
        withAnimation(.spring(duration: 1.2, bounce: 0.04)) { horizonUp = true }
        try? await Task.sleep(for: .milliseconds(620))
        withAnimation(.easeInOut(duration: 0.45)) { parted = true; flare = true }
        withAnimation(.spring(duration: 0.7, bounce: 0.06).delay(0.1)) { shown = true }
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.spring(duration: 0.55, bounce: 0.2)) { parted = false }
        withAnimation(.easeOut(duration: 1.6)) { flare = false }
        try? await Task.sleep(for: .milliseconds(1600))
        if Self.breathes { breathe = true }
    }

    /// The light breathes for as long as the screen is there — but not in the tests, which wait for the
    /// app to be still before each step (an endless animation never is).
    private static var breathes: Bool {
        #if DEBUG
        if TestHooks.enabled { return false }
        #endif
        return true
    }
}

/// The mark in two halves: parted, they move apart across the split and a line of light shows in it.
private struct SplitMark: View {
    let parted: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Across the split (its normal), in the mark's 32-unit square: the halves move along it.
            let apart = parted ? side * 0.05 : 0
            ZStack {
                Capsule()
                    .fill(.white)
                    .frame(width: max(1, side * 0.025), height: side * 0.7)
                    .rotationEffect(.degrees(18.43))
                    .blur(radius: side * 0.04)
                    .opacity(parted ? 0.9 : 0)
                LumenMarkHalf(upper: true).fill(.white)
                    .offset(x: apart * 0.9487, y: apart * 0.3162)
                LumenMarkHalf(upper: false).fill(.white)
                    .offset(x: -apart * 0.9487, y: -apart * 0.3162)
            }
            .frame(width: side, height: side)
        }
    }
}

/// The dark horizon under the mark: a disc far wider than the screen, of which only the top of the arc
/// shows. Its edge is a fine line of light, brightest at the top of the arc and gone down the sides,
/// with a narrow glow along it and a low light over the top where the mark rises. `glow` above 1 is the
/// flare as the mark parts; `breathe` lets the light swell and ebb, slowly.
private struct Horizon: View {
    let diameter: CGFloat
    let glow: Double
    let breathe: Bool

    var body: some View {
        let breath = breathe ? 1.0 : 0.82
        ZStack(alignment: .top) {
            // The low light over the top of the arc.
            light(width: 340, height: 92, peak: 0.26)
                .opacity(min(glow, 1) * breath)
                .animation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true), value: breathe)
            // The flare: the same light, brighter and wider, for a moment.
            light(width: 520, height: 150, peak: 0.34)
                .opacity(max(0, glow - 1) / 0.6)
            // The glow along the edge.
            Circle()
                .stroke(.white, lineWidth: 4)
                .blur(radius: 6)
                .mask(fromTop([.init(color: .white, location: 0), .init(color: .white.opacity(0.3), location: 0.42),
                               .init(color: .clear, location: 1)], reach: 260))
                .opacity(0.55 * min(glow, 1.5))
            // The dark side.
            Circle().fill(.black)
            // The edge itself, and its hot top.
            Circle()
                .strokeBorder(.white, lineWidth: 1)
                .mask(fromTop([.init(color: .white, location: 0), .init(color: .white.opacity(0.5), location: 0.26),
                               .init(color: .white.opacity(0.12), location: 0.65), .init(color: .clear, location: 1)], reach: 340))
            Circle()
                .stroke(.white, lineWidth: 2)
                .blur(radius: 1.5)
                .mask(fromTop([.init(color: .white, location: 0), .init(color: .clear, location: 1)], reach: 60))
                .opacity(min(glow, 1))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// Brightest at the top of the arc (the top of the disc's square), gone `reach` points from it.
    private func fromTop(_ stops: [Gradient.Stop], reach: CGFloat) -> RadialGradient {
        RadialGradient(stops: stops, center: .top, startRadius: 0, endRadius: reach)
    }

    /// A soft oval of light centred on the top of the arc (its lower half falls behind the dark side).
    private func light(width: CGFloat, height: CGFloat, peak: Double) -> some View {
        Ellipse()
            .fill(EllipticalGradient(stops: [.init(color: .white.opacity(peak), location: 0),
                                             .init(color: .white.opacity(peak * 0.27), location: 0.55),
                                             .init(color: .clear, location: 1)]))
            .frame(width: width, height: height)
            .blur(radius: 10)
            .offset(y: -height / 2)
    }
}

/// The fields of one step in one quiet group, as the system's own forms have them.
private struct FieldGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .foregroundStyle(.white)
            .tint(.white)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The hairline between two fields of a group.
private struct FieldSeparator: View {
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 1 / scale)
            .padding(.leading, 16)
    }
}

private extension View {
    /// A row of a field group: its height and insets.
    func fieldRow() -> some View {
        frame(minHeight: 52).padding(.horizontal, 16)
    }

    /// Comes up into its place, one step after the one above it.
    func appear(_ shown: Bool, step: Int, reduceMotion: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.6, bounce: 0.08).delay(Double(step) * 0.07), value: shown)
    }
}
