import LumenCore
import SwiftUI

/// The start screen, on the first launch without an account (the owner, 17 November): the mark comes
/// up from where the launch screen left it, its halves part along the split and let the light through,
/// and the sign-in follows — the account's address and password, the code from the email or the robot
/// check when the server asks (SignInFlow, as the account's form), the site for a forgotten password.
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

    enum Field { case email, password, code }

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
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
                VStack(spacing: 0) {
                    Spacer(minLength: 72)
                    header
                    Spacer(minLength: 40)
                    if flow.challenge == nil { passwordStep } else { codeStep }
                    Spacer(minLength: 24)
                    footer
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
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

    // MARK: The parts

    private var header: some View {
        VStack(spacing: 14) {
            Group {
                if risen {
                    SplitMark(parted: parted)
                        .matchedGeometryEffect(id: "mark", in: mark)
                } else {
                    Color.clear
                }
            }
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)
            Text(verbatim: "Lumen")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .appear(shown, step: 0, reduceMotion: reduceMotion)
            Text(flow.challenge == nil ? L("Войдите, чтобы продолжить") : L("Код из письма"))
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
                .appear(shown, step: 1, reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder private var passwordStep: some View {
        VStack(spacing: 12) {
            WelcomeField(symbol: "envelope", focused: field == .email) {
                TextField(L("Почта"), text: $flow.email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($field, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                    .accessibilityIdentifier("signInEmail")
            }
            WelcomeField(symbol: "lock", focused: field == .password) {
                Group {
                    if flow.showPassword {
                        TextField(L("Пароль"), text: $flow.password).accessibilityIdentifier("signInPasswordShown")
                    } else {
                        SecureField(L("Пароль"), text: $flow.password).accessibilityIdentifier("signInPassword")
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.password)
                .focused($field, equals: .password)
                .submitLabel(.go)
                .onSubmit { if flow.canSubmit { submit() } }
                Button { flow.showPassword.toggle() } label: {
                    Image(systemName: flow.showPassword ? "eye" : "eye.slash").foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(flow.showPassword ? L("Скрыть пароль") : L("Показать пароль"))
            }
            HStack {
                if let message = flow.message { failure(message) }
                Spacer(minLength: 12)
                Button(L("Забыли пароль?")) { openURL(SignInView.resetURL) }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("forgotPassword")
            }
            .padding(.top, 2)
            primaryButton(L("Войти"), enabled: flow.canSubmit, id: "submitSignIn", action: submit)
                .padding(.top, 18)
        }
        .appear(shown, step: 2, reduceMotion: reduceMotion)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    @ViewBuilder private var codeStep: some View {
        VStack(spacing: 12) {
            Text(AccountText.checkEmail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            WelcomeField(symbol: "number", focused: field == .code) {
                TextField(L("Код из письма"), text: $flow.code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode).monospacedDigit()
                    .focused($field, equals: .code)
                    .accessibilityIdentifier("signInCode")
            }
            if let message = flow.message { failure(message).frame(maxWidth: .infinity, alignment: .leading) }
            primaryButton(L("Подтвердить"), enabled: flow.canConfirm, id: "submitCode") {
                flow.confirm(model, signedIn: done)
            }
            .padding(.top, 18)
            ResendCodeButton(flow: flow) { flow.resend(model) }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 8)
            Button(L("Ввести пароль заново")) { flow.backToPassword() }
                .foregroundStyle(.white.opacity(0.6))
        }
        .font(.body)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .onAppear { field = .code }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            Button(L("Продолжить без входа")) { done() }
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityIdentifier("continueWithoutAccount")
            Text(L("Аккаунт Lumen — тот же, что в Lumen для Mac."))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 24)
        .appear(shown, step: 3, reduceMotion: reduceMotion)
    }

    private func primaryButton(_ title: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(flow.busy ? 0 : 1)
                if flow.busy { ProgressView().tint(.black).accessibilityIdentifier("signInBusy") }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 34)
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

    /// From the launch screen: the mark rises to its place, its halves part along the split and the
    /// light shows through, they close, and the words and the form come up one after the other.
    /// Reduce Motion: the mark in its place at once, the rest fades in.
    private func play() async {
        if reduceMotion {
            risen = true
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
            return
        }
        // The launch screen's copy fades out over this one first (LaunchRoot, 0.45 s).
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.spring(duration: 0.7, bounce: 0.18)) { risen = true }
        try? await Task.sleep(for: .milliseconds(420))
        withAnimation(.easeInOut(duration: 0.45)) { parted = true }
        withAnimation(.spring(duration: 0.6, bounce: 0.1).delay(0.1)) { shown = true }
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { parted = false }
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

/// A field of the start screen: its symbol, then the field, on a quiet rounded ground.
private struct WelcomeField<Content: View>: View {
    let symbol: String
    let focused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22)
                .accessibilityHidden(true)
            content
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(focused ? 0.35 : 0.1), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

private extension View {
    /// Comes up into its place, one step after the one above it.
    func appear(_ shown: Bool, step: Int, reduceMotion: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.55, bounce: 0.12).delay(Double(step) * 0.07), value: shown)
    }
}
