import AppKit
import BrowserCore
import SwiftUI

// The licensing client's screens (the design's "Аккаунт" boards: sign-in, this Mac's connection, Settings
// › Account, the license's states). Texts of the server's states word for word from its
// docs/CONTRACT.md §17 (`contract.…`); buttons, titles and hints are the app's own (`license.…`).
// No registration and no payment here: "Create account", plans and renewal open the website.

// MARK: - Sign-in and this Mac's connection

/// Sign in — with an email and a password, or with a key — then connect this Mac (§5.2, §6.1). On
/// the first launch it comes before the master password (the owner's order, §10.1); later, over the
/// Profiles window or Settings.
struct SignInFlow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var license: LicenseModel
    /// The Mac is connected, and the person went on.
    var onFinished: () -> Void
    /// Nil on the first launch: there is nothing to go back to.
    var onCancel: (() -> Void)?
    /// In a backdrop of its own (a sheet); false inside the first launch's, which is already there.
    var standalone = true

    enum Method: Hashable { case email, key }
    /// `code`: the password was right, and the server sent a code to the account's address first (§5.2).
    enum Step: Equatable { case credentials, code, activation, connected }

    @State private var step: Step
    @State private var method: Method
    @State private var email = ""
    @State private var password = ""
    @State private var keyText: String
    /// The label this Mac is connected with, as the person types it: empty to begin with — no name
    /// of the Mac's is put in for them (the server's CONTRACT §1; the owner, 3 November).
    @State private var label = ""
    @State private var problem: String?
    @State private var keyHelp = false
    /// "Don't remember the key" (§10.1): off — the vault keeps the key, as the contract's default.
    @State private var dontRememberKey = false
    @State private var limit: AccountServerError?
    @State private var outcome: LicenseModel.ActivationOutcome?
    /// The sign-in the server holds for its letter's code (§5.2): in memory, for this screen only.
    @State private var loginCode: LoginCode?
    @State private var codeText = ""
    /// `login.code_resent`, after a resend.
    @State private var codeNote: String?
    /// The server asked for the robot check (`403 robot_check`, §5.5); the sheet with the site's page.
    @State private var needsRobotCheck = false
    @State private var showingRobotCheck = false
    /// The check's token, for the next sign-in alone.
    @State private var robotToken: String?
    /// "Try again in …" (`rate_limited`, `server_busy`, `robot_check_unavailable`): the button waits
    /// until then (§17.2).
    @State private var waitUntil: Date?

    /// `method`, `keyText`, `step`: where it starts — the snapshots' only; the app starts at the
    /// email's sign-in.
    init(license: LicenseModel, onFinished: @escaping () -> Void, onCancel: (() -> Void)? = nil, standalone: Bool = true,
         method: Method = .email, keyText: String = "", step: Step = .credentials, loginCode: LoginCode? = nil) {
        self.license = license
        self.onFinished = onFinished
        self.onCancel = onCancel
        self.standalone = standalone
        _method = State(initialValue: method)
        _keyText = State(initialValue: keyText)
        _step = State(initialValue: step)
        _loginCode = State(initialValue: loginCode)
    }

    var body: some View {
        Group {
            if standalone {
                LockBackdrop { screen }
            } else {
                screen
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onCancel, step != .connected {
                Button(L("license.signIn.later")) {
                    license.cancelSignIn()
                    onCancel()
                }
                .buttonStyle(.lumenGhost)
                .padding(.top, ProfilesScreen.inspectorTop)
                .padding(.trailing, 20)
            } else if onCancel == nil, !standalone, step == .credentials {
                // The first launch's first screen: the interface's language, on it (the owner).
                // Not past this step: a restart would lose the sign-in under way.
                FirstLaunchLanguagePicker()
                    .padding(.top, ProfilesScreen.inspectorTop)
                    .padding(.trailing, 20)
            }
        }
        .sheet(isPresented: $keyHelp) { KeyRecoveryNote(license: license) { keyHelp = false } }
    }

    @ViewBuilder
    private var screen: some View {
        switch step {
        case .credentials:
            LockScreen(title: L("license.signIn.title"), subtitle: L("license.signIn.subtitle")) { credentials }
        case .code:
            LockScreen(title: L("license.code.title"), subtitle: L("license.code.subtitle")) { codeStep }
        case .activation:
            LockScreen(title: L("license.activate.title"),
                       subtitle: L(method == .key ? "license.activate.subtitle.key" : "license.activate.subtitle.email")) { activation }
        case .connected:
            LockScreen(title: L("license.activate.done.title"), subtitle: L("license.activate.done.codeHint")) { connected }
        }
    }

    // MARK: Credentials

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            LumenSegmented(selection: $method, options: [(value: Method.email, title: L("license.signIn.method.email")),
                                                         (value: Method.key, title: L("license.signIn.method.key"))], large: true)
                .accessibilityLabel(L("license.signIn.method"))
                .onChange(of: method) { _, _ in problem = nil }
            if method == .email {
                AccountTextField(label: L("license.signIn.email"), text: $email, onSubmit: signIn, takesFocus: true)
                VStack(alignment: .trailing, spacing: 6) {
                    LockPasswordField(label: L("license.signIn.password"), password: $password,
                                      error: problem != nil, onSubmit: signIn, takesFocus: false)
                    LockLink(title: L("license.signIn.forgot")) { openSite("/reset-password") }
                }
            } else {
                // The hint belongs to its field: under it, before the link (it came after the link,
                // as a block of its own).
                VStack(alignment: .leading, spacing: 6) {
                    AccountTextField(label: L("license.key.field"), text: $keyText, monospaced: true,
                                     prompt: "LMK-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", error: problem != nil, onSubmit: signIn, takesFocus: true) // l10n: not text
                    Text(L("license.key.hint"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        LockLink(title: L("license.key.forgot")) { keyHelp = true }
                    }
                }
                // §10.1: the key is kept in the vault unless the person says otherwise — what keeping
                // it means is said beside the choice (`key.remember`).
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $dontRememberKey) {
                        Text(L("license.key.rememberOff"))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .toggleStyle(.lumenCheckbox)
                    Text(L("contract.key.remember"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Under the checkbox's label, not its box: the box's 16 pt and the 8 between.
                        .padding(.leading, 24)
                }
            }
            if let problem { problemLine(problem) }
            if needsRobotCheck, method == .email, robotCheckURL != nil {
                Button(L("license.robot.action")) { showingRobotCheck = true }
                    .buttonStyle(.lumenSecondary)
            }
            LockActionButton(title: L("license.signIn.action"), working: license.isWorking,
                             workingTitle: L("license.signIn.working"), enabled: canSignIn, action: signIn)
            HStack {
                LockLink(title: L("license.signIn.create")) { openSite("/signup") }
                Spacer(minLength: 0)
            }
            LockNote(symbol: "lock", text: L("license.signIn.masterNote"))
        }
        .padding(.top, 28)
        .sheet(isPresented: $showingRobotCheck) {
            if let url = robotCheckURL {
                RobotCheckSheet(url: url, onToken: { token in
                    showingRobotCheck = false
                    needsRobotCheck = false
                    robotToken = token
                    problem = nil
                    signIn()
                }, onCancel: { showingRobotCheck = false })
            }
        }
    }

    /// The site's robot check page for a sign-in (§5.5).
    private var robotCheckURL: URL? {
        license.configuration.flatMap { RobotCheck.pageURL(site: $0.siteURL, action: "login") }
    }

    private var canSignIn: Bool {
        if let waitUntil, waitUntil > Date() { return false }
        switch method {
        case .email: return !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .key: return AccountKeyInput.classify(keyText) != .empty
        }
    }

    /// The button waits as long as the server said (§17.2): its "try again in …" answers.
    private func waitIfAsked(_ failure: AccountFailure) {
        guard case .server(let error) = failure, ["rate_limited", "server_busy", "robot_check_unavailable"].contains(error.code) else { return }
        let seconds = TimeInterval(max(1, error.retryAfter ?? 60))
        let until = Date().addingTimeInterval(seconds)
        waitUntil = until
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if waitUntil == until { waitUntil = nil }
        }
    }

    private func signIn() {
        guard canSignIn, !license.isWorking else { return }
        problem = nil
        switch method {
        case .email:
            // A robot check's token is good for this one request (§5.5).
            let token = robotToken
            robotToken = nil
            Task {
                switch await license.signIn(email: email, password: password, robotToken: token) {
                case .signedIn:
                    password = ""
                    step = .activation
                case .code(let code):
                    password = ""
                    loginCode = code
                    codeText = ""
                    codeNote = nil
                    step = .code
                case .failed(let failure):
                    problem = LicenseText.error(failure)
                    waitIfAsked(failure)
                    if case .server(let error) = failure, error.code == "robot_check" {
                        needsRobotCheck = true
                        // The check opens at once; the button above brings it back if it is closed.
                        showingRobotCheck = robotCheckURL != nil
                    }
                }
            }
        case .key:
            // Read here, before anything is sent: a typo is said without a request (the owner's rule).
            switch AccountKeyInput.classify(keyText) {
            case .key(let key):
                license.useKey(key, remember: !dontRememberKey)
                keyText = ""
                step = .activation
            case .purchaseCode: problem = L("license.key.purchaseCode")
            case .invoiceNumber: problem = L("license.key.invoice")
            case .cyrillic: problem = L("license.key.cyrillic")
            case .typo, .empty: problem = L("contract.key.typo")
            }
        }
    }

    // MARK: The letter's code (§5.2)

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("contract.login.check_email"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            AccountTextField(label: L("license.code.field"), text: $codeText, monospaced: true,
                             prompt: "000000", error: problem != nil, onSubmit: confirmCode, takesFocus: true) // l10n: not text
            if let loginCode {
                // The times move on by themselves: when the letter went, when the code may go again.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LicenseText.loginCodeTerms(loginCode, now: context.date))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = LicenseText.loginResendNote(loginCode, now: context.date) {
                            Text(note)
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if loginCode.canResend {
                            Button(L("license.code.resend"), action: resendCode)
                                .buttonStyle(.lumenGhost)
                                .padding(.leading, -11)
                                .disabled(license.isWorking || (loginCode.resendAvailableAt.map { $0 > context.date } ?? true))
                        }
                    }
                }
            }
            if let codeNote {
                Label(codeNote, systemImage: "envelope")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem { problemLine(problem) }
            LockActionButton(title: L("license.code.action"), working: license.isWorking, workingTitle: L("license.code.working"),
                             enabled: canConfirmCode, action: confirmCode)
            HStack {
                LockLink(title: L("license.code.back")) { backToPassword(nil) }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 28)
    }

    private var canConfirmCode: Bool {
        if let waitUntil, waitUntil > Date() { return false }
        return !codeText.filter { !$0.isWhitespace }.isEmpty
    }

    /// `POST /v1/auth/login/confirm`: the session, then this Mac's activation, as after a password.
    private func confirmCode() {
        guard canConfirmCode, !license.isWorking else { return }
        problem = nil
        codeNote = nil
        Task {
            if let failure = await license.confirmLogin(email: email, code: codeText, challenge: loginCode?.challenge) {
                problem = LicenseText.error(failure)
                waitIfAsked(failure)
                if case .server(let error) = failure, error.code == "invalid_code", var spent = loginCode {
                    spent.codeAttempts = spent.codeAttempts.map { max(0, $0 - 1) }
                    loginCode = spent
                    // The code's tries spent, or its time over: this attempt is over — a new one
                    // starts with the password (§5.2).
                    if spent.codeAttempts == 0 || (spent.codeExpiresAt.map { $0 <= Date() } ?? false) {
                        backToPassword(L("contract.error.invalid_code"))
                    }
                }
            } else {
                loginCode = nil
                codeText = ""
                step = .activation
            }
        }
    }

    /// `POST /v1/auth/login/resend`: the same code again (`login.code_resent`); spent — the
    /// attempt's own words; over — back to the password (`error.login_expired`).
    private func resendCode() {
        guard let code = loginCode, !license.isWorking else { return }
        problem = nil
        codeNote = nil
        Task {
            switch await license.resendLoginCode(code) {
            case .success(let again):
                loginCode = again
                codeNote = L("contract.login.code_resent")
            case .failure(.server(let error)) where error.code == "login_expired":
                backToPassword(L("contract.error.login_expired"))
            case .failure(.server(let error)) where error.code == "resend_limit":
                // Every resend of this attempt spent: said by the code's own note from now on.
                var spent = code
                spent.resendsLeft = 0
                spent.resendAvailableAt = nil
                loginCode = spent
            case .failure(.server(let error)) where error.code == "rate_limited":
                // Not yet: the note counts down to when it can.
                var later = code
                later.resendAvailableAt = Date().addingTimeInterval(TimeInterval(max(1, error.retryAfter ?? 60)))
                loginCode = later
            case .failure(let failure):
                problem = LicenseText.error(failure)
            }
        }
    }

    /// Back to the password: the attempt ended, or the person went back. Nothing of it stays.
    private func backToPassword(_ reason: String?) {
        license.cancelSignIn()
        loginCode = nil
        codeText = ""
        codeNote = nil
        problem = reason
        step = .credentials
    }

    // MARK: Activation

    private var activation: some View {
        VStack(alignment: .leading, spacing: 18) {
            AccountTextField(label: L("license.activate.label"), text: $label, prompt: L("license.activate.labelPrompt"), onSubmit: activate)
            Text(L("license.activate.labelHint"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ServerLearnsBlock()
            if let limit { DeviceLimitList(license: license, error: limit, siteURL: license.configuration?.site("/pricing")) { activate() } }
            if let problem { problemLine(problem) }
            LockActionButton(title: L("license.activate.action"), working: license.isWorking,
                             workingTitle: L("license.activate.working"), action: activate)
            HStack {
                LockLink(title: L("license.activate.back")) {
                    license.cancelSignIn()
                    limit = nil
                    problem = nil
                    step = .credentials
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 28)
    }

    private func activate() {
        guard !license.isWorking else { return }
        problem = nil
        Task {
            switch await license.activate(label: label, vault: model.unlockedVaultForAccount) {
            case .success(let result):
                outcome = result
                limit = nil
                step = .connected
            case .failure(.server(let error)) where error.code == "device_limit_reached":
                limit = error
                problem = LicenseText.error(.server(error))
            case .failure(let failure):
                problem = LicenseText.error(failure, withKey: method == .key)
            }
        }
    }

    // MARK: Connected

    private var connected: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("license.activate.done.code")).lumenCaps()
                Text(license.record.code ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            if let outcome {
                ForEach(Array(connectedTexts(outcome).enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if outcome.entitlement.status == .exportOnly, outcome.entitlement.isOwner {
                    Button(L("license.activate.plans")) { openSite("/pricing") }
                        .buttonStyle(.lumenSecondary)
                    Button(L("license.activate.paid")) { Task { await license.refresh() } }
                        .buttonStyle(.lumenGhost)
                }
            }
            LockActionButton(title: L("license.activate.next")) { onFinished() }
        }
        .padding(.top, 28)
    }

    /// trial.started and account.trial; activation.trial_used and export.no_license; activation.saved.
    private func connectedTexts(_ outcome: LicenseModel.ActivationOutcome) -> [String] {
        let p = outcome.entitlement
        var texts: [String] = []
        if p.status == .exportOnly, p.exportReason == "no_license" {
            texts = [L("contract.activation.trial_used"), L("contract.export.no_license")]
        } else if outcome.trial, let end = p.periodEndsAt {
            texts = [String(format: L("contract.trial.started"), LicenseText.date(end)), L("contract.account.trial")]
        }
        texts.append(String(format: L("contract.activation.saved"), LicenseText.duration(p.offlineWork)))
        if let skew = outcome.clockSkew { texts.append(String(format: L("contract.clock.skew"), LicenseText.duration(skew))) }
        return texts
    }

    private func problemLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.lumenBody)
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openSite(_ path: String) {
        guard let url = license.configuration?.site(path) else { return }
        SystemOpen.openWebsite(url)
    }
}

/// A text field in the lock screen's style (`LockPasswordField` without the eye).
struct AccountTextField: View {
    let label: String
    @Binding var text: String
    var monospaced = false
    var prompt: String = ""
    var error = false
    var onSubmit: () -> Void = {}
    /// The cursor starts here: one field per screen, as `LockPasswordField.takesFocus`.
    var takesFocus = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            TextField(label, text: $text, prompt: Text(verbatim: prompt))
                .textFieldStyle(.plain)
                .font(monospaced ? .system(size: 15, design: .monospaced) : .system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(onSubmit)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(error ? Theme.danger : (focused ? Theme.edgeStrong : Theme.strongBorder), lineWidth: 1))
                // The lock field's focus and error ring (`LockPasswordField`): the two fields of one
                // sign-in screen showed focus differently.
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(error ? Theme.dangerTint : Color.white.opacity(focused ? 0.06 : 0), lineWidth: 4)
                    .padding(-4))
                .animation(Theme.hoverAnimation, value: focused)
        }
        .onAppear { if takesFocus { focused = true } }
    }
}

/// `activation.server_learns`: the four lines, before the button (§6.1, §17.3).
private struct ServerLearnsBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("license.activate.serverLearns")).lumenCaps()
            ForEach(1...4, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                    Text(L("contract.activation.server_learns.\(line)"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// All places of the license taken (§10.6): its Macs, and an unlink right here — after the
/// confirmation, the connection is tried again.
private struct DeviceLimitList: View {
    @ObservedObject var license: LicenseModel
    let error: AccountServerError
    let siteURL: URL?
    let retry: () -> Void
    @State private var confirming: AccountDevice?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(error.devices ?? []) { device in
                HStack(spacing: 12) {
                    DeviceLine(device: device, isThisMac: false)
                    Spacer(minLength: 8)
                    Button(L("license.activate.unlink")) { confirming = device }
                        .buttonStyle(.lumenSecondary)
                        .disabled(error.unlinkAvailableAt != nil || license.isWorking)
                }
            }
            if let available = error.unlinkAvailableAt {
                Text(String(format: L("contract.error.unlink_cooldown"), LicenseText.date(available)))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.lumenSecondary).foregroundStyle(Theme.danger)
            }
            if let siteURL {
                Button(L("license.activate.plans")) { SystemOpen.openWebsite(siteURL) }
                    .buttonStyle(.lumenGhost)
            }
        }
        .alert(confirming.map { String(format: L("license.account.unlink.confirm"), $0.code) } ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(L("license.account.cancel"), role: .cancel) { confirming = nil }
            Button(L("license.activate.unlink"), role: .destructive) {
                guard let device = confirming else { return }
                confirming = nil
                Task {
                    switch await license.unlinkDuringActivation(device) {
                    case .success: retry()
                    case .failure(let failure): problem = LicenseText.error(failure)
                    }
                }
            }
        } message: {
            Text(String(format: L("contract.unlink.consequences"),
                        LicenseText.duration(TimeInterval(error.offlineWorkSeconds ?? 0)),
                        LicenseText.duration(TimeInterval(error.unlinkCooldownSeconds ?? 0))))
        }
    }
}

/// "Mac B119 · Рабочий", when it was seen, how many profiles; this Mac marked.
private struct DeviceLine: View {
    let device: AccountDevice
    let isThisMac: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(String(format: L("license.account.device.title"), device.code) + (device.label.isEmpty ? "" : " · " + device.label))
                    .font(.lumenRowTitle)
                    .foregroundStyle(Theme.textPrimary)
                if isThisMac {
                    Text(L("license.account.thisMacBadge"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.raisedInset))
                }
            }
            Text(String(format: L("license.account.device.seen"),
                        device.lastSeenAt.map { LicenseText.when($0) } ?? "—",
                        LicenseText.count(device.profileCount ?? 0, "profile"))
                 + (device.accountEmail.map { " · " + $0 } ?? ""))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Lost your key?" (§11.1): an email linked to the purchase — sign in with it, and replace the key
/// on the site (`key.no_reset.email`); else no letter can bring the key back, and the screen says so
/// plainly with what can (`key.no_reset`): the site, within the time `GET /v1/plans` gives — from the
/// server only (§17.1); it not answering, `error.unreachable`.
private struct KeyRecoveryNote: View {
    @ObservedObject var license: LicenseModel
    let close: () -> Void
    @State private var retrievalSeconds: Int?
    @State private var asked = false

    private var linked: Bool { license.record.emailLinked == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("license.key.forgot"))
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
            if let text {
                Text(text)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                // The site's account to sign in to with the email, or its key page (§11.1).
                if let siteURL = license.configuration?.site(linked ? "/account" : "/key") {
                    Button(L("license.key.noReset.site")) { SystemOpen.openWebsite(siteURL) }
                        .buttonStyle(.lumenSecondary)
                }
                Spacer()
                Button(L("license.close"), action: close)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .lumenSheetSurface()
        .environment(\.colorScheme, .dark)
        .task {
            guard !linked else { return }
            retrievalSeconds = await license.keyRetrievalSeconds()
            asked = true
        }
    }

    private var text: String? {
        if linked { return L("contract.key.no_reset.email") }
        if let retrievalSeconds { return String(format: L("contract.key.no_reset"), LicenseText.duration(TimeInterval(retrievalSeconds))) }
        return asked ? L("contract.error.unreachable") : nil
    }
}

// MARK: - Banners and the sidebar's line

/// A license's banner above the profiles (§8.5), with what can be done about it.
struct LicenseBannerView: View {
    @ObservedObject var license: LicenseModel
    let banner: LicenseBanner
    var signIn: () -> Void = {}
    var openSystemSettings: () -> Void = {}
    var update: () -> Void = {}

    var body: some View {
        LumenBanner(tone: isDanger ? .danger : .warning) {
            HStack(alignment: .center, spacing: 12) {
                Text(LicenseText.banner(banner, withoutEmail: license.record.signedInWith == .key))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
        }
    }

    /// What stops work is red; what warns, amber — and the period's last day, red.
    private var isDanger: Bool {
        if case .periodEnding(_, _, let final) = banner { return final }
        return banner.stopsWork
    }

    /// Where the period is paid for: the key's page for a key's license without an email (§11.1),
    /// the plans otherwise (§17.4).
    private var renewalPath: String { license.hasNoEmail ? "/key" : "/pricing" }

    @ViewBuilder
    private var actions: some View {
        switch banner {
        case .deviceRevoked, .machineMismatch:
            Button(L("license.banner.signIn"), action: signIn).buttonStyle(.lumenSecondary)
        case .notSignedIn:
            HStack(spacing: 8) {
                Button(L("license.banner.signIn"), action: signIn).buttonStyle(.lumenSecondary)
                Button(L("license.banner.createAccount")) { open("/signup") }.buttonStyle(.lumenGhost)
            }
        case .accountDisabled:
            Button(L("license.banner.support")) { open("/") }.buttonStyle(.lumenSecondary)
        case let .periodEnded(owner, _):
            if owner { Button(L("license.banner.renew")) { open(renewalPath) }.buttonStyle(.lumenSecondary) }
        case .noLicense:
            Button(L("license.banner.choosePlan")) { open("/pricing") }.buttonStyle(.lumenSecondary)
        case let .grace(outdated, _, _), let .expired(outdated, _):
            if outdated {
                Button(L("license.banner.update"), action: update).buttonStyle(.lumenSecondary)
            } else {
                Button(L("license.banner.checkNow")) { Task { await license.refresh() } }.buttonStyle(.lumenSecondary)
            }
        case .unverified:
            Button(L("license.banner.checkNow")) { Task { await license.refresh() } }.buttonStyle(.lumenSecondary)
        case .appOutdated:
            Button(L("license.banner.update"), action: update).buttonStyle(.lumenSecondary)
        case .clockSkew:
            Button(L("license.banner.systemSettings"), action: openSystemSettings).buttonStyle(.lumenSecondary)
        case let .periodEnding(owner, endsAt, final):
            // It can be closed (§8.5 item 10): during the week it comes back for the last day.
            HStack(spacing: 8) {
                if owner { Button(L("license.banner.renew")) { open(renewalPath) }.buttonStyle(.lumenSecondary) }
                Button(L("license.banner.hide")) { license.closePeriodEnding(endsAt: endsAt, final: final) }.buttonStyle(.lumenGhost)
            }
        case .trialStarted:
            HStack(spacing: 8) {
                Button(L("license.banner.plans")) { open("/pricing") }.buttonStyle(.lumenSecondary)
                Button(L("license.banner.hide")) { license.closeTrialNotice() }.buttonStyle(.lumenGhost)
            }
        case .renewalFailing:
            Button(L("license.banner.checkNow")) { Task { await license.refresh() } }.buttonStyle(.lumenSecondary)
        }
    }

    private func open(_ path: String) {
        guard let url = license.configuration?.site(path) else { return }
        SystemOpen.openWebsite(url)
    }
}

/// What the sidebar's line says (§17.4's table), and whether it warns.
struct RightsLine: Equatable {
    let title: String
    let caption: String
    let warning: Bool
}

/// The sidebar's one quiet line about the rights, between sync and Lock; a click opens Settings ›
/// Account (§17.4's table).
struct RightsStatusButton: View {
    let title: String
    let caption: String
    let warning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: warning ? "exclamationmark.triangle" : "person.crop.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(warning ? Theme.warning : Theme.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.lumenSecondary.weight(.medium))
                        .foregroundStyle(warning ? Theme.warning : Theme.textPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8)
        .help(L("settings.section.account"))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings › Account

/// Settings › Account (the design's board): the plan and until when, how long this Mac works without
/// the server, this Mac, the license's devices, the site.
struct AccountSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var license: LicenseModel
    @State private var devices: AccountDevices?
    @State private var devicesProblem: String?
    @State private var loadingDevices = false
    @State private var confirmingSignOut = false
    /// `429 unlink_cooldown` answered the sign-out (§6.3): until when — this Mac stays connected.
    @State private var signOutCooldown: Date??
    @State private var confirmingUnlink: AccountDevice?
    @State private var signingIn = false
    /// The system's answer about Lumen's notifications, read when the page shows (key accounts).
    @State private var reminderStatus: ExpiryNotifications.Status?
    /// The key typed for one request when the vault keeps none, or is locked (`key.devices_need_key`,
    /// §11.1): sent, then the field is emptied — the key is not held after its request (§10.1).
    @State private var devicesKeyText = ""
    /// The list on the page came with a key typed for it: unlinking asks for the key again.
    @State private var devicesByTypedKey = false
    @State private var unlinkKeyText = ""
    @State private var linkingEmail = false
    @State private var replacingKey = false

    var body: some View {
        SettingsPage(title: L("settings.section.account"), subtitle: L("license.account.subtitle")) {
            if !license.isConfigured {
                // A section-wide note, as Downloads' and Diagnostics': a grey sentence read as the
                // subtitle's second line.
                SettingsNote(text: L("license.account.notConfigured"))
            } else if let state = license.state, state.mode != .notSignedIn {
                plan(state)
                offline(state)
                if license.hasNoEmail { reminders }
                thisMac
                if license.record.signedInWith == .key { keySection }
                devicesSection
                site
            } else {
                notSignedIn
            }
        }
        .task { await loadDevices() }
        .sheet(isPresented: $signingIn) {
            SignInFlow(license: license, onFinished: { signingIn = false; Task { await loadDevices() } },
                       onCancel: { signingIn = false })
                // Under the 700 pt Settings window, as Change Password's 660 (720 was taller).
                .sheetFrame(width: 560, height: 660)
        }
        .alert(L("license.account.signOut.confirm"), isPresented: $confirmingSignOut) {
            Button(L("license.account.cancel"), role: .cancel) {}
            Button(L("license.account.signOut.button"), role: .destructive) {
                Task {
                    if case .cooldown(let availableAt)? = await license.signOut(vault: model.unlockedVaultForAccount) {
                        signOutCooldown = .some(availableAt)
                    }
                }
            }
        } message: {
            Text(signOutConsequences)
        }
        .alert(L("license.account.signOut.notNow"),
               isPresented: Binding(get: { signOutCooldown != nil }, set: { if !$0 { signOutCooldown = nil } })) {
            Button(L("license.close"), role: .cancel) { signOutCooldown = nil }
        } message: {
            Text(String(format: L("contract.signout.cooldown"), (signOutCooldown ?? nil).map(LicenseText.date) ?? "—"))
        }
        .sheet(isPresented: $linkingEmail) {
            EmailLinkSheet(license: license) {
                linkingEmail = false
                Task { await loadDevices() }
            }
        }
        .sheet(isPresented: $replacingKey) {
            KeyReplaceSheet(license: license, label: thisMacLabel) {
                replacingKey = false
                Task { await loadDevices() }
            }
        }
        .alert(confirmingUnlink.map { String(format: L("license.account.unlink.confirm"), $0.code) } ?? "",
               isPresented: Binding(get: { confirmingUnlink != nil }, set: { if !$0 { confirmingUnlink = nil } })) {
            if devicesByTypedKey {
                // The key is not kept (§10.1): asked for again for this request, forgotten after it.
                TextField(L("license.key.field"), text: $unlinkKeyText)
            }
            Button(L("license.account.cancel"), role: .cancel) {
                confirmingUnlink = nil
                unlinkKeyText = ""
            }
            Button(L("license.activate.unlink"), role: .destructive) {
                guard let device = confirmingUnlink else { return }
                confirmingUnlink = nil
                let input = AccountKeyInput.classify(unlinkKeyText)
                unlinkKeyText = ""
                let typedKey: AccountKey?
                if !devicesByTypedKey {
                    typedKey = nil
                } else if case .key(let key) = input {
                    typedKey = key
                } else {
                    devicesProblem = L("contract.key.typo")
                    return
                }
                Task {
                    if case .failure(let failure) = await license.unlink(device, typedKey: typedKey) {
                        devicesProblem = LicenseText.error(failure, withKey: license.record.signedInWith == .key)
                    } else if !devicesByTypedKey {
                        await loadDevices()
                    } else {
                        devices?.devices.removeAll { $0.deviceID == device.deviceID }
                    }
                }
            }
        } message: {
            Text(String(format: L("contract.unlink.consequences"),
                        LicenseText.duration(TimeInterval(devices?.offlineWorkSeconds ?? 0)),
                        LicenseText.duration(TimeInterval(devices?.unlinkCooldownSeconds ?? 0))))
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func plan(_ state: LicenseState) -> some View {
        SettingsCaption(L("license.account.caption.plan"))
        if let p = state.entitlement {
            SettingCustomRow(planTitle(p, state: state)) {
                ForEach(Array(planLines(p, state: state).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if license.record.signedInWith == .key {
                    // §11.1: a license by key — with an email linked, or without any.
                    Text(license.record.emailLinked == true ? L("contract.account.key_license.email") : L("contract.account.key_license"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            } control: {
                VStack(alignment: .trailing, spacing: 8) {
                    if p.isOwner {
                        Button(L(p.plan == "trial" || p.status == .exportOnly ? "license.account.choosePlan" : "license.account.renew")) {
                            // A key's license without an email is paid for on the key's page (§11.1).
                            open(license.hasNoEmail ? "/key" : "/pricing")
                        }
                        .buttonStyle(.lumenSecondary)
                    }
                    Button(L(license.isWorking ? "license.account.refreshing" : "license.account.refresh")) {
                        Task { await license.refresh() }
                    }
                    .buttonStyle(.lumenGhost)
                    .disabled(license.isWorking)
                }
            }
            SettingRow(String(format: L("contract.account.profiles"), "\(model.profiles.count)", "\(p.profilesOnOtherDevices)"),
                       detail: String(format: L("contract.account.profiles.left"), "\(max(0, state.allowedProfilesHere - model.profiles.count))"),
                       effect: nil) { EmptyView() }
        } else {
            note(L("license.refusal.notChecked"))
        }
    }

    private func planTitle(_ p: Entitlement, state: LicenseState) -> String {
        if let reason = LicenseBanners.exportReason(p, at: state.now) {
            switch reason {
            case "no_license": return L("contract.export.no_license")
            case "account_disabled": return L("contract.error.account_disabled")
            default: return String(format: L("contract.export.period_ended"), p.periodEndsAt.map(LicenseText.date) ?? "—")
            }
        }
        let end = p.periodEndsAt.map(LicenseText.date) ?? "—"
        if p.plan == "trial" { return String(format: L("contract.account.plan.trial"), end) }
        return String(format: L("contract.account.plan"), LicenseText.plan(p.plan), end)
    }

    private func planLines(_ p: Entitlement, state: LicenseState) -> [String] {
        if LicenseBanners.exportReason(p, at: state.now) != nil { return [L("contract.account.period_ended")] }
        if p.plan == "trial" { return [L("contract.account.trial")] }
        let checked = license.record.lastSuccessAt.map { LicenseText.when($0) } ?? "—"
        if p.isOwner { return [String(format: L("contract.account.checked"), checked)] }
        return [String(format: L("contract.account.checked.member.noEmail"), checked)]
    }

    /// How long this Mac works without the server, and how much of it is left (the owner: "сколько
    /// офлайн-запаса осталось").
    @ViewBuilder
    private func offline(_ state: LicenseState) -> some View {
        SettingsCaption(L("license.account.caption.offline"))
        if let until = state.worksWithoutServerUntil {
            note(String(format: L("license.account.offline"), LicenseText.date(until),
                        LicenseText.remaining(until.timeIntervalSince(Date()))))
        } else {
            note(L("license.account.offline.none"))
        }
    }

    /// The subscription's reminders through the system's notifications, for an account signed in
    /// with a key alone: offered once by itself (ExpiryNotifications), here again (the owner, 2 November).
    @ViewBuilder
    private var reminders: some View {
        SettingsCaption(L("reminders.caption"))
        SettingRow(L("reminders.title"), detail: remindersDetail, effect: nil) {
            switch reminderStatus {
            case .allowed?:
                Text(L("reminders.on"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
            case .refused?:
                Button(L("reminders.openSettings")) { SystemOpen.openSystemSettingsForNotifications() }
                    .buttonStyle(.lumenSecondary)
            case .notAsked?:
                Button(L("reminders.turnOn")) {
                    Task {
                        await ExpiryNotifications.turnOnFromSettings(license: license)
                        reminderStatus = await ExpiryNotifications.status()
                    }
                }
                .buttonStyle(.lumenSecondary)
            case nil:
                EmptyView()
            }
        }
        .task { reminderStatus = await ExpiryNotifications.status() }
    }

    private var remindersDetail: String {
        switch reminderStatus {
        case .allowed?: return L("reminders.detail.on")
        case .refused?: return L("reminders.detail.off")
        default: return L("reminders.detail.notAsked")
        }
    }

    @ViewBuilder
    private var thisMac: some View {
        SettingsCaption(L("license.account.caption.thisMac"))
        SettingRow(L("license.account.code"), detail: L("license.account.codeHint"), effect: nil) {
            Text(license.record.code ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
        SettingRow(L("license.account.signOut"), detail: signOutConsequences, effect: nil) {
            Button(L("license.account.signOut.action")) { confirmingSignOut = true }
                .buttonStyle(.lumenDestructive)
                .disabled(license.isWorking)
        }
    }

    /// A license by key (§11.1): an email to link — a way to recover access, optional — and a new key
    /// for whoever thinks the key has leaked.
    @ViewBuilder
    private var keySection: some View {
        SettingsCaption(L("license.account.caption.key"))
        if license.record.emailLinked == true {
            SettingRow(L("license.emailLink.linked"), detail: nil, effect: nil) { EmptyView() }
        } else {
            SettingRow(L("license.emailLink.title"), detail: L("license.emailLink.detail"), effect: nil) {
                Button(L("license.emailLink.action")) { linkingEmail = true }
                    .buttonStyle(.lumenSecondary)
                    .disabled(license.isWorking)
            }
        }
        SettingRow(L("license.keyReplace.title"), detail: L("license.keyReplace.detail"), effect: nil) {
            Button(L("license.keyReplace.action")) { replacingKey = true }
                .buttonStyle(.lumenDestructive)
                .disabled(license.isWorking)
        }
    }

    /// `signout.consequences`, with the cooldown the server last said (§6.3).
    private var signOutConsequences: String {
        LicenseText.signOutConsequences(cooldownSeconds: license.record.unlinkCooldownSeconds)
    }

    /// This Mac's label as the license's list shows it — else as its activation's answer named it —
    /// sent again when a new key connects it.
    private var thisMacLabel: String {
        devices?.devices.first { $0.deviceID == license.record.deviceID }?.label ?? license.record.label ?? ""
    }

    @ViewBuilder
    private var devicesSection: some View {
        SettingsCaption(L("license.account.caption.devices"))
        if license.record.signedInWith == .key, license.deviceCredential == nil, !devicesByTypedKey {
            // §11.1: the key not kept, or the vault locked — the key is asked for, for this request.
            VStack(alignment: .leading, spacing: 10) {
                note(L("contract.key.devices_need_key"))
                HStack(alignment: .bottom, spacing: 10) {
                    AccountTextField(label: L("license.key.field"), text: $devicesKeyText, monospaced: true,
                                     prompt: "LMK-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", onSubmit: showDevicesWithTypedKey) // l10n: not text
                    Button(L("license.account.showDevices"), action: showDevicesWithTypedKey)
                        .buttonStyle(.lumenSecondary)
                        .disabled(license.isWorking || AccountKeyInput.classify(devicesKeyText) == .empty)
                        .padding(.bottom, 8)
                }
            }
            .padding(.vertical, 8)
        } else if license.deviceCredential == nil, !devicesByTypedKey {
            SettingRow(L("license.account.signIn"), detail: noSessionText, effect: nil) {
                HStack(spacing: 8) {
                    Button(L("license.account.signIn")) { signingIn = true }.buttonStyle(.lumenSecondary)
                    Button(L("license.account.devicesOnSite")) { open("/account/devices") }.buttonStyle(.lumenGhost)
                }
            }
        } else if let devices {
            ForEach(devices.devices) { device in
                let isThisMac = device.deviceID == license.record.deviceID
                HStack(spacing: 12) {
                    DeviceLine(device: device, isThisMac: isThisMac)
                    Spacer(minLength: 8)
                    if !isThisMac {
                        Button(L("license.activate.unlink")) { confirmingUnlink = device }
                            .buttonStyle(.lumenSecondary)
                            .disabled(devices.unlinkAvailableAt != nil || license.isWorking)
                    }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            }
            if let available = devices.unlinkAvailableAt {
                note(String(format: L("contract.error.unlink_cooldown"), LicenseText.date(available)))
            }
        } else if loadingDevices {
            note(L("license.account.loading"))
        }
        if let devicesProblem { note(devicesProblem) }
    }

    private var noSessionText: String {
        String(format: L("contract.account.no_session"),
               LicenseText.duration(TimeInterval(license.record.session?.idleTimeoutSeconds ?? 604_800)))
    }

    @ViewBuilder
    private var site: some View {
        SettingsCaption(L("license.account.caption.site"))
        SettingRow(L("license.account.cabinet"), detail: L("license.account.cabinetDetail"), effect: nil) {
            Button(L("license.account.cabinetOpen")) { open("/account") }.buttonStyle(.lumenSecondary)
        }
    }

    @ViewBuilder
    private var notSignedIn: some View {
        SettingsCaption(L("license.account.caption.plan"))
        SettingRow(L("license.account.notSignedIn"), detail: L("contract.mode.not_signed_in"), effect: nil) {
            HStack(spacing: 8) {
                Button(L("license.banner.signIn")) { signingIn = true }.buttonStyle(.lumenSecondary)
                Button(L("license.banner.createAccount")) { open("/signup") }.buttonStyle(.lumenGhost)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.lumenBody)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private func loadDevices() async {
        guard license.isConfigured, license.record.isSignedIn, license.deviceCredential != nil else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        switch await license.devices() {
        case .success(let list):
            devices = list
            devicesByTypedKey = false
            devicesProblem = nil
        case .failure(let failure):
            devicesProblem = LicenseText.error(failure, withKey: license.record.signedInWith == .key)
        }
    }

    /// The license's Macs with a key typed for this one request: read before anything is sent, sent,
    /// and the field emptied whatever the answer (§10.1).
    private func showDevicesWithTypedKey() {
        guard !license.isWorking else { return }
        guard case .key(let key) = AccountKeyInput.classify(devicesKeyText) else {
            devicesProblem = L("contract.key.typo")
            return
        }
        devicesKeyText = ""
        devicesProblem = nil
        Task {
            loadingDevices = true
            defer { loadingDevices = false }
            switch await license.devices(typedKey: key) {
            case .success(let list):
                devices = list
                devicesByTypedKey = true
            case .failure(let failure):
                devicesProblem = LicenseText.error(failure, withKey: true)
            }
        }
    }

    private func open(_ path: String) {
        guard let url = license.configuration?.site(path) else { return }
        SystemOpen.openWebsite(url)
    }
}

// MARK: - A purchase without registration: an email, a new key (§11.1)

/// A problem under a sheet's fields, in the danger's colour.
private struct SheetProblemLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.lumenBody)
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sentence under a field, quieter than the body.
private struct SheetHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.lumenSecondary)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Link an email address" (§11.1; the site's SITE_API §12.9): optional — a way to recover access, not
/// a new account. The key and the purchase code prove the purchase (the key alone is not enough); the
/// six digits of the letter confirm the address. The key works on, this Mac stays connected by it.
/// A key typed here when the vault keeps none is held for this sheet's two steps only; the purchase
/// code is forgotten once its request is answered.
struct EmailLinkSheet: View {
    @ObservedObject var license: LicenseModel
    let close: () -> Void

    enum Step { case form, code }

    @State private var step = Step.form
    @State private var keyText = ""
    @State private var purchaseCodeText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var sent: AccountAPI.CodeSent?
    @State private var typedKey: AccountKey?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("license.emailLink.title"))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .form: form
                    case .code: codeStep
                    }
                    if let problem { SheetProblemLine(text: problem) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            SheetFooter {
                Button(L("common.cancel"), action: close)
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if step == .code {
                    Button(L("license.emailLink.back")) {
                        step = .form
                        code = ""
                        problem = nil
                    }
                    .buttonStyle(.lumenSecondary)
                }
                Button(step == .form ? L("license.emailLink.send") : L("license.emailLink.confirm"), action: step == .form ? send : confirm)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(license.isWorking)
            }
        }
        .sheetFrame(width: 500, height: 660)
        .lumenSheetSurface()
        .onDisappear {
            typedKey = nil
            password = ""
            purchaseCodeText = ""
        }
    }

    @ViewBuilder
    private var form: some View {
        // Before the fields (§11.1).
        Text(L("contract.email_link.explain"))
            .font(.lumenBody)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if !license.keyAtHand {
            AccountTextField(label: L("license.key.field"), text: $keyText, monospaced: true,
                             prompt: "LMK-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX") // l10n: not text
        }
        VStack(alignment: .leading, spacing: 6) {
            AccountTextField(label: L("license.purchaseCode.field"), text: $purchaseCodeText, monospaced: true,
                             prompt: "LPC-XXXX-XXXX-XXXX-XXXX-XXXX") // l10n: not text
            SheetHint(text: L("license.purchaseCode.hint"))
        }
        AccountTextField(label: L("license.signIn.email"), text: $email)
        VStack(alignment: .leading, spacing: 6) {
            LockPasswordField(label: L("license.signIn.password"), password: $password, takesFocus: false)
            SheetHint(text: L("license.emailLink.passwordHint"))
        }
    }

    @ViewBuilder
    private var codeStep: some View {
        Text(String(format: L("contract.signup.check_email"), email.trimmingCharacters(in: .whitespacesAndNewlines)))
            .font(.lumenBody)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        AccountTextField(label: L("license.emailLink.code"), text: $code, monospaced: true, prompt: "000000", onSubmit: confirm) // l10n: not text
        // The numbers from the server's answer only (§17.1).
        if let seconds = sent?.codeValidSeconds, let attempts = sent?.codeAttempts {
            SheetHint(text: String(format: L("contract.signup.code_terms"), LicenseText.duration(TimeInterval(seconds)),
                                   LicenseText.count(attempts, "time")))
        }
    }

    /// The key: the one the vault keeps, or the one typed here — read before anything is sent.
    private func keyForRequest() -> (ok: Bool, typed: AccountKey?) {
        if license.keyAtHand { return (true, nil) }
        if let typedKey { return (true, typedKey) }
        guard case .key(let key) = AccountKeyInput.classify(keyText) else {
            problem = L("contract.key.typo")
            return (false, nil)
        }
        return (true, key)
    }

    private func send() {
        guard !license.isWorking else { return }
        problem = nil
        let key = keyForRequest()
        guard key.ok else { return }
        guard let purchaseCode = PurchaseCode(typed: purchaseCodeText) else {
            problem = L("contract.purchase_code.typo")
            return
        }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            problem = L("contract.error.invalid_email")
            return
        }
        guard (10...256).contains(password.count) else {
            problem = L("contract.error.invalid_password")
            return
        }
        Task {
            switch await license.linkEmail(typedKey: key.typed, purchaseCode: purchaseCode, email: address, password: password) {
            case .success(let answer):
                sent = answer
                typedKey = key.typed
                keyText = ""
                purchaseCodeText = ""
                step = .code
            case .failure(let failure):
                problem = LicenseText.error(failure, withKey: true)
            }
        }
    }

    private func confirm() {
        guard !license.isWorking else { return }
        problem = nil
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            problem = L("contract.error.invalid_code")
            return
        }
        Task {
            if let failure = await license.confirmEmail(typedKey: typedKey, email: email, code: digits) {
                problem = LicenseText.error(failure, withKey: true)
            } else {
                typedKey = nil
                password = ""
                close()
            }
        }
    }
}

/// "Replace the key" (§11.1; SITE_API §12.10): for whoever thinks the key has leaked — a step taken
/// knowingly, after `key.replace.confirm`. Proved with the key and the purchase code, or — an email
/// linked and its session here — with the account's password. Then the new key, shown once
/// (`key.replaced`); the vault keeps it instead of the old one when the key is remembered, and this
/// Mac, unlinked with every other, is connected again with it.
struct KeyReplaceSheet: View {
    @ObservedObject var license: LicenseModel
    /// This Mac's label, as the license's list showed it.
    let label: String
    let close: () -> Void

    @State private var keyText = ""
    @State private var purchaseCodeText = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var result: LicenseModel.KeyReplacement?

    /// An email linked and its session on this Mac: the account's password proves it.
    private var bySession: Bool { license.record.emailLinked == true && license.validSession != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("license.keyReplace.title"))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result {
                        done(result)
                    } else {
                        form
                    }
                    if let problem { SheetProblemLine(text: problem) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            SheetFooter {
                if result == nil {
                    Button(L("common.cancel"), action: close)
                        .buttonStyle(.lumenSecondary)
                        .keyboardShortcut(.cancelAction)
                    // The sheet's main action: a red contour at the main height, not quiet red text
                    // weaker than Cancel.
                    Button(L("license.keyReplace.button"), action: replace)
                        .buttonStyle(LumenButtonStyle(kind: .destructive, height: Theme.buttonHeight))
                        .disabled(license.isWorking || license.vaultNeededForKeyReplacement)
                } else {
                    Button(L("license.done"), action: close)
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .sheetFrame(width: 500, height: 600)
        .lumenSheetSurface()
        .task {
            // Whether an email is linked chooses the warning: asked of the license's view when the
            // key is at hand and it is not known yet.
            if !bySession, license.record.emailLinked == nil, license.keyAtHand { _ = await license.devices() }
        }
        .onDisappear {
            result = nil
            password = ""
            keyText = ""
            purchaseCodeText = ""
        }
    }

    /// With the key and the purchase code, a linked email is unlinked too (§11.1, F3): said before —
    /// also while it is not known whether one is linked (the license's view not read since this Mac
    /// was connected): the warning is not left out on a guess.
    private var confirmation: String {
        L(!bySession && license.record.emailLinked != false ? "contract.key.replace.confirm.email" : "contract.key.replace.confirm")
    }

    @ViewBuilder
    private var form: some View {
        Text(confirmation)
            .font(.lumenBody)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        // Why the action is off, said before the fields as a state: it was a hint under them,
        // far above the dimmed button.
        if license.vaultNeededForKeyReplacement {
            LockNote(symbol: "lock", tint: Theme.warning, text: L("license.keyReplace.vaultLocked"))
        }
        if bySession {
            LockPasswordField(label: L("license.keyReplace.password"), password: $password, takesFocus: false)
        } else {
            if !license.keyAtHand {
                AccountTextField(label: L("license.key.field"), text: $keyText, monospaced: true,
                                 prompt: "LMK-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX") // l10n: not text
            }
            VStack(alignment: .leading, spacing: 6) {
                AccountTextField(label: L("license.purchaseCode.field"), text: $purchaseCodeText, monospaced: true,
                                 prompt: "LPC-XXXX-XXXX-XXXX-XXXX-XXXX") // l10n: not text
                SheetHint(text: L("license.purchaseCode.hint"))
            }
        }
    }

    @ViewBuilder
    private func done(_ replacement: LicenseModel.KeyReplacement) -> some View {
        Text(L("contract.key.replaced"))
            .font(.lumenBody)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        NewKeyView(key: replacement.key)
        if replacement.kept { SheetHint(text: L("license.keyReplace.kept")) }
        if let failure = replacement.reconnection {
            SheetProblemLine(text: LicenseText.error(failure, withKey: true))
            SheetHint(text: L("license.keyReplace.notReconnected"))
        } else {
            SheetHint(text: L("license.keyReplace.reconnected"))
        }
    }

    private func replace() {
        guard !license.isWorking, !license.vaultNeededForKeyReplacement else { return }
        problem = nil
        let proof: AccountAPI.KeyReplacementProof
        if bySession, let session = license.validSession {
            guard !password.isEmpty else {
                // No email is typed here: the password's own words (§17.2).
                problem = L("contract.error.invalid_credentials.password")
                return
            }
            proof = .account(session: session, password: password)
        } else {
            let key: AccountKey
            if license.keyAtHand, let kept = license.key {
                key = kept
            } else if case .key(let typed) = AccountKeyInput.classify(keyText) {
                key = typed
            } else {
                problem = L("contract.key.typo")
                return
            }
            guard let code = PurchaseCode(typed: purchaseCodeText) else {
                problem = L("contract.purchase_code.typo")
                return
            }
            proof = .purchase(key, code)
        }
        let withKey = !bySession
        let passwordOnly = bySession
        Task {
            switch await license.replaceKey(proof, label: label) {
            case .success(let replacement):
                result = replacement
                keyText = ""
                purchaseCodeText = ""
                password = ""
            case .failure(let failure):
                problem = LicenseText.error(failure, withKey: withKey, passwordOnly: passwordOnly)
            }
        }
    }
}
