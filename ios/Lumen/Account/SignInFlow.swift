import Foundation
import LumenCore

/// One attempt to sign in, shared by the account's form (SignInView) and the start screen
/// (WelcomeView): the address and the password, then — when the server asks for more — the code from
/// the account's email or the site's robot check (§5.2, §5.5). The views draw it; this keeps what was
/// typed, what the server said, and when the code may be sent again.
@MainActor
final class SignInFlow: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var showPassword = false
    @Published var code = ""
    /// The code step: the server's handle of this sign-in attempt (in memory only, never written).
    @Published private(set) var challenge: String?
    @Published var message: String?
    @Published private(set) var busy = false
    /// The site's robot check is asked for: its window is open.
    @Published var robotCheck = false
    /// When the code may be sent again (a minute after the last one).
    @Published private(set) var resendAt = Date.distantPast

    var canSubmit: Bool { !busy && !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }
    var canConfirm: Bool { !busy && !code.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The address and the password, with the robot check's token once it was passed.
    func submit(_ model: AppModel, robotToken: String? = nil, signedIn: @escaping () -> Void) {
        busy = true
        message = nil
        Task {
            let outcome = await model.signIn(email: email, password: password, robotToken: robotToken)
            busy = false
            finish(outcome, signedIn: signedIn)
        }
    }

    /// The code from the letter.
    func confirm(_ model: AppModel, signedIn: @escaping () -> Void) {
        busy = true
        message = nil
        Task {
            let outcome = await model.confirmSignIn(email: email, code: code, challenge: challenge)
            busy = false
            finish(outcome, signedIn: signedIn)
        }
    }

    /// The same code once more, not before a minute has passed.
    func resend(_ model: AppModel) {
        guard let challenge else { return }
        busy = true
        resendAt = Date().addingTimeInterval(60)
        Task {
            message = await model.resendCode(challenge: challenge)
            busy = false
        }
    }

    /// From the code back to the password.
    func backToPassword() {
        challenge = nil
        code = ""
        message = nil
    }

    /// The fields emptied: iOS takes a form that leaves the screen with a login and a password in it
    /// for one to keep in the person's Passwords, and offers so over the app (the proxy form, CI runs
    /// 12 and 13). Lumen's password is kept nowhere on the iPhone.
    func clear() {
        email = ""
        password = ""
        code = ""
        challenge = nil
        message = nil
    }

    private func finish(_ outcome: AppModel.SignInOutcome, signedIn: () -> Void) {
        switch outcome {
        case .signedIn:
            clear()
            signedIn()
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
}
