import LumenCore
import SwiftUI
import WebKit

/// Signing in to a Lumen account: login and password (the owner and the lead, 9 November). The
/// account is made, and a forgotten password reset, on the site. After several failed attempts the
/// server asks for more: a code from the account's email, or the site's robot check — shown here, in
/// the app's own window, never by sending the person away.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var code = ""
    /// The code step: the server's handle of this sign-in attempt.
    @State private var challenge: String?
    @State private var message: String?
    @State private var busy = false
    @State private var robotCheck = false
    /// When the code may be sent again (a minute after the last one).
    @State private var resendAt = Date.distantPast

    var body: some View {
        NavigationStack {
            Form {
                if challenge == nil { passwordStep } else { codeStep }
            }
            .navigationTitle(challenge == nil ? L("Вход") : L("Код из письма"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { close() }.accessibilityIdentifier("cancelSignIn") }
                if busy { ToolbarItem(placement: .confirmationAction) { ProgressView().accessibilityIdentifier("signInBusy") } }
            }
            .sheet(isPresented: $robotCheck) {
                RobotCheckSheet(url: Self.robotCheckURL) { token in
                    robotCheck = false
                    guard let token else { return }
                    // Once the check's window has closed: this form may close next (signed in), and a
                    // window is not closed while the one above it is still closing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { submit(robotToken: token) }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// The account's address and password (p11-login); a failure in one red line under the fields.
    @ViewBuilder private var passwordStep: some View {
        Section {
            TextField(L("Почта"), text: $email)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.username)
                .accessibilityIdentifier("signInEmail")
            HStack {
                Group {
                    if showPassword {
                        TextField(L("Пароль"), text: $password).accessibilityIdentifier("signInPasswordShown")
                    } else {
                        SecureField(L("Пароль"), text: $password).accessibilityIdentifier("signInPassword")
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye" : "eye.slash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPassword ? L("Скрыть пароль") : L("Показать пароль"))
            }
        } header: {
            Text(L("Аккаунт Lumen"))
        } footer: {
            if let message { failure(message) }
        }
        Section {
            Button(L("Войти")) { submit(robotToken: nil) }
                .fontWeight(.semibold)
                .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                .accessibilityIdentifier("submitSignIn")
            Button(L("Забыли пароль?")) { openURL(AccountClient.site.appendingPathComponent("reset-password")) }
                .accessibilityIdentifier("forgotPassword")
        } footer: {
            Text(L("Пароль восстанавливается на сайте %@.", AccountClient.site.host() ?? "lumenbrowser.io"))
        }
    }

    /// The code from the letter (p11-code): sent again after a minute, the password step one touch away.
    @ViewBuilder private var codeStep: some View {
        Section {
            TextField(L("Код из письма"), text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode).monospacedDigit()
                .accessibilityIdentifier("signInCode")
        } header: {
            Text(AccountText.checkEmail).textCase(nil)
        } footer: {
            if let message { failure(message) }
        }
        Section {
            Button(L("Подтвердить")) { confirm() }
                .fontWeight(.semibold)
                .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("submitCode")
        }
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(resendAt.timeIntervalSince(context.date).rounded(.up)))
                Button { resend() } label: {
                    HStack(spacing: 4) {
                        Text(L("Отправить код ещё раз"))
                        if left > 0 { Text(String(format: "%d:%02d", left / 60, left % 60)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .disabled(busy || left > 0)
                .accessibilityIdentifier("resendCode")
            }
            Button(L("Ввести пароль заново")) {
                challenge = nil
                code = ""
                message = nil
            }
        }
    }

    /// One red line, the reason — under the field it is about.
    private func failure(_ text: String) -> some View {
        Text(text).foregroundStyle(Color(.systemRed)).accessibilityIdentifier("signInMessage")
    }

    /// `<site>/robot-check?action=login` (CONTRACT.md §5.5).
    static var robotCheckURL: URL {
        var parts = URLComponents(url: AccountClient.site.appendingPathComponent("robot-check"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "action", value: "login")]
        return parts?.url ?? AccountClient.site
    }

    private func submit(robotToken: String?) {
        busy = true
        message = nil
        Task {
            let outcome = await model.signIn(email: email, password: password, robotToken: robotToken)
            busy = false
            finish(outcome)
        }
    }

    private func confirm() {
        busy = true
        message = nil
        Task {
            let outcome = await model.confirmSignIn(email: email, code: code, challenge: challenge)
            busy = false
            finish(outcome)
        }
    }

    private func resend() {
        guard let challenge else { return }
        busy = true
        resendAt = Date().addingTimeInterval(60)
        Task {
            message = await model.resendCode(challenge: challenge)
            busy = false
        }
    }

    private func finish(_ outcome: AppModel.SignInOutcome) {
        switch outcome {
        case .signedIn:
            close()
        case let .needsCode(challenge):
            self.challenge = challenge
            resendAt = Date().addingTimeInterval(60)
        case .needsRobotCheck:
            message = AccountText.robotCheck
            robotCheck = true
        case let .failed(text):
            message = text
        }
    }

    /// Closes with the fields emptied first: iOS takes a form that leaves the screen with a login and
    /// a password in it for one to keep in the person's Passwords, and offers so over the app (the
    /// proxy form, CI runs 12 and 13). Lumen's password is kept nowhere on the iPhone.
    private func close() {
        email = ""
        password = ""
        code = ""
        DispatchQueue.main.async { dismiss() }
    }
}

/// The site's robot check in a window of the app (§5.5): its own web view with a data store that
/// keeps nothing — no cookie of any profile, nothing left behind — and one way out for the page:
/// `window.webkit.messageHandlers.lumenRobotCheck.postMessage(token)`.
struct RobotCheckSheet: View {
    let url: URL
    /// The page's token; nil when the person closed the window.
    let done: (String?) -> Void

    var body: some View {
        NavigationStack {
            RobotCheckPage(url: url, done: done)
                .navigationTitle(L("Проверка «не робот»"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { done(nil) }.accessibilityIdentifier("cancelRobotCheck") }
                }
        }
    }
}

private struct RobotCheckPage: UIViewRepresentable {
    let url: URL
    let done: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "lumenRobotCheck")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.accessibilityIdentifier = "robotCheckPage"
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "lumenRobotCheck")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let done: (String?) -> Void
        private var answered = false

        init(done: @escaping (String?) -> Void) { self.done = done }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !answered, let token = message.body as? String, !token.isEmpty else { return }
            answered = true
            done(token)
        }
    }
}
