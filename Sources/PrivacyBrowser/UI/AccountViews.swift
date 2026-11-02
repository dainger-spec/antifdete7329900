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
    enum Step: Equatable { case credentials, activation, connected }

    @State private var step: Step
    @State private var method: Method
    @State private var email = ""
    @State private var password = ""
    @State private var keyText: String
    @State private var label = ""
    @State private var problem: String?
    @State private var keyHelp = false
    @State private var limit: AccountServerError?
    @State private var outcome: LicenseModel.ActivationOutcome?

    /// `method`, `keyText`, `step`: where it starts — the snapshots' only; the app starts at the
    /// email's sign-in.
    init(license: LicenseModel, onFinished: @escaping () -> Void, onCancel: (() -> Void)? = nil, standalone: Bool = true,
         method: Method = .email, keyText: String = "", step: Step = .credentials) {
        self.license = license
        self.onFinished = onFinished
        self.onCancel = onCancel
        self.standalone = standalone
        _method = State(initialValue: method)
        _keyText = State(initialValue: keyText)
        _step = State(initialValue: step)
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
        .sheet(isPresented: $keyHelp) { KeyRecoveryNote(siteURL: license.configuration?.site("/")) { keyHelp = false } }
    }

    @ViewBuilder
    private var screen: some View {
        switch step {
        case .credentials:
            LockScreen(title: L("license.signIn.title"), subtitle: L("license.signIn.subtitle")) { credentials }
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
                AccountTextField(label: L("license.signIn.email"), text: $email, onSubmit: signIn)
                VStack(alignment: .trailing, spacing: 6) {
                    LockPasswordField(label: L("license.signIn.password"), password: $password,
                                      error: problem != nil, onSubmit: signIn, takesFocus: false)
                    LockLink(title: L("license.signIn.forgot")) { openSite("/reset-password") }
                }
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    AccountTextField(label: L("license.key.field"), text: $keyText, monospaced: true,
                                     prompt: "LMK-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", error: problem != nil, onSubmit: signIn) // l10n: not text
                    LockLink(title: L("license.key.forgot")) { keyHelp = true }
                }
                Text(L("license.key.hint"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem { problemLine(problem) }
            LockActionButton(title: L("license.signIn.action"), working: license.isWorking,
                             workingTitle: L("license.signIn.working"), enabled: canSignIn, action: signIn)
            HStack {
                LockLink(title: L("license.signIn.create")) { openSite("/signup") }
                Spacer(minLength: 0)
            }
            LockNote(symbol: "lock", text: L("license.signIn.masterNote"))
        }
        .padding(.top, 28)
    }

    private var canSignIn: Bool {
        switch method {
        case .email: return !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .key: return AccountKeyInput.classify(keyText) != .empty
        }
    }

    private func signIn() {
        guard canSignIn, !license.isWorking else { return }
        problem = nil
        switch method {
        case .email:
            Task {
                if let failure = await license.signIn(email: email, password: password) {
                    problem = LicenseText.error(failure)
                } else {
                    password = ""
                    step = .activation
                }
            }
        case .key:
            // Read here, before anything is sent: a typo is said without a request (the owner's rule).
            switch AccountKeyInput.classify(keyText) {
            case .key(let key):
                license.useKey(key)
                keyText = ""
                step = .activation
            case .purchaseCode: problem = L("license.key.purchaseCode")
            case .invoiceNumber: problem = L("license.key.invoice")
            case .cyrillic: problem = L("license.key.cyrillic")
            case .typo, .empty: problem = L("license.key.typo")
            }
        }
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
                problem = LicenseText.error(failure)
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
                .animation(Theme.hoverAnimation, value: focused)
        }
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

/// "Lost your key?": why no letter can bring it back, and what can (the owner: the screen says
/// honestly why there is no such path for a key).
private struct KeyRecoveryNote: View {
    let siteURL: URL?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("license.key.noReset.title"))
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
            Text(L("license.key.noReset.text"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let siteURL {
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
        .background(Theme.raised)
        .environment(\.colorScheme, .dark)
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
        switch banner {
        case .periodEnding(_, _, let final): return final
        case .grace, .appOutdated, .clockSkew, .trialStarted: return false
        default: return true
        }
    }

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
            if owner { Button(L("license.banner.renew")) { open("/pricing") }.buttonStyle(.lumenSecondary) }
        case .noLicense:
            Button(L("license.banner.choosePlan")) { open("/pricing") }.buttonStyle(.lumenSecondary)
        case let .grace(outdated, _, _):
            if outdated {
                Button(L("license.banner.update"), action: update).buttonStyle(.lumenSecondary)
            } else {
                Button(L("license.banner.checkNow")) { Task { await license.refresh() } }.buttonStyle(.lumenSecondary)
            }
        case .appOutdated:
            Button(L("license.banner.update"), action: update).buttonStyle(.lumenSecondary)
        case .clockSkew:
            Button(L("license.banner.systemSettings"), action: openSystemSettings).buttonStyle(.lumenSecondary)
        case let .periodEnding(owner, _, _):
            if owner { Button(L("license.banner.renew")) { open("/pricing") }.buttonStyle(.lumenSecondary) }
        case .trialStarted:
            HStack(spacing: 8) {
                Button(L("license.banner.plans")) { open("/pricing") }.buttonStyle(.lumenSecondary)
                Button(L("license.banner.hide")) { license.closeTrialNotice() }.buttonStyle(.lumenGhost)
            }
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
    @State private var confirmingUnlink: AccountDevice?
    @State private var signingIn = false
    /// The system's answer about Lumen's notifications, read when the page shows (key accounts).
    @State private var reminderStatus: ExpiryNotifications.Status?

    var body: some View {
        SettingsPage(title: L("settings.section.account"), subtitle: L("license.account.subtitle")) {
            if !license.isConfigured {
                note(L("license.account.notConfigured"))
            } else if let state = license.state, state.mode != .notSignedIn {
                plan(state)
                offline(state)
                if license.record.signedInWith == .key { reminders }
                thisMac
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
                .frame(width: 560, height: 720)
        }
        .alert(L("license.account.signOut.confirm"), isPresented: $confirmingSignOut) {
            Button(L("license.account.cancel"), role: .cancel) {}
            Button(L("license.account.signOut.button"), role: .destructive) {
                Task { await license.signOut(vault: model.unlockedVaultForAccount) }
            }
        } message: {
            Text(L("contract.signout.consequences"))
        }
        .alert(confirmingUnlink.map { String(format: L("license.account.unlink.confirm"), $0.code) } ?? "",
               isPresented: Binding(get: { confirmingUnlink != nil }, set: { if !$0 { confirmingUnlink = nil } })) {
            Button(L("license.account.cancel"), role: .cancel) { confirmingUnlink = nil }
            Button(L("license.activate.unlink"), role: .destructive) {
                guard let device = confirmingUnlink else { return }
                confirmingUnlink = nil
                Task {
                    if case .failure(let failure) = await license.unlink(device) { devicesProblem = LicenseText.error(failure) }
                    await loadDevices()
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
                    Text(L("license.account.keyAccount"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            } control: {
                VStack(alignment: .trailing, spacing: 8) {
                    if p.isOwner {
                        Button(L(p.plan == "trial" || p.status == .exportOnly ? "license.account.choosePlan" : "license.account.renew")) {
                            open("/pricing")
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
        SettingRow(L("license.account.signOut"), detail: L("contract.signout.consequences"), effect: nil) {
            Button(L("license.account.signOut.action")) { confirmingSignOut = true }
                .buttonStyle(.lumenDestructive)
                .disabled(license.isWorking)
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        SettingsCaption(L("license.account.caption.devices"))
        if license.record.signedInWith == .key, license.key == nil {
            note(L("license.account.lockedForKey"))
        } else if license.deviceCredential == nil {
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
            devicesProblem = nil
        case .failure(let failure):
            devicesProblem = LicenseText.error(failure)
        }
    }

    private func open(_ path: String) {
        guard let url = license.configuration?.site(path) else { return }
        SystemOpen.openWebsite(url)
    }
}
