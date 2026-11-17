import AppKit
import BrowserCore
import SwiftUI

/// The setup screen's other way (`SetupView`, "I already have a vault"): a vault kept by the Lumen
/// account, in a sync folder or on a server of one's own is brought to this Mac (`RestoreModel`,
/// `VaultRestore`). The lock screen's own look and parts — the mark, the title, the 400 pt column, its
/// fields, button, links and notes — one step a screen: where it is, which one, its master password,
/// it comes, it is here.
struct RestoreFlow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var restore: RestoreModel
    /// Back to creating a vault.
    var onBack: () -> Void
    @State private var password = ""
    @State private var address = ""
    @State private var token = ""
    @State private var vaultID = ""
    /// The unfinished restore whose Discard is being confirmed.
    @State private var discarding: VaultRestore.Unfinished? = nil

    init(restore: RestoreModel, onBack: @escaping () -> Void) {
        _restore = ObservedObject(wrappedValue: restore)
        self.onBack = onBack
    }

    var body: some View {
        screen
            .onAppear { restore.begin(app: model) }
            .onChange(of: password) { _, typed in
                if !typed.isEmpty { restore.problem = nil }
            }
            .confirmationDialog(L("restore.discard.title"),
                                isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                                titleVisibility: .visible) {
                Button(L("restore.discard.confirm"), role: .destructive) {
                    // The person's own Discard: only what this Mac downloaded goes (docs/DESTRUCTIVE_PATHS.md).
                    if let unfinished = discarding { restore.discardUnfinished(unfinished.vaultID, app: model) }
                    discarding = nil
                }
                Button(L("common.cancel"), role: .cancel) { discarding = nil }
            } message: {
                Text(L("restore.discard.message"))
            }
    }

    @ViewBuilder
    private var screen: some View {
        switch restore.step {
        case .source:
            LockScreen(title: L("restore.source.title"), subtitle: L("restore.source.subtitle"), footer: L("restore.source.footer")) { sourceStep }
        case .account:
            LockScreen(title: L("restore.account.title"), subtitle: L("restore.account.subtitle")) { accountStep }
        case .server:
            LockScreen(title: L("restore.server.title"), subtitle: L("restore.server.subtitle")) { serverStep }
        case .password:
            LockScreen(title: L("restore.password.title"), subtitle: RestoreText.kept(restore.candidate, at: restore.place)) { passwordStep }
        case .bringing:
            LockScreen(title: L(restore.interrupted == nil ? "restore.bringing.title" : "restore.interrupted.title"),
                       subtitle: bringingSubtitle) { bringingStep }
        case .done:
            LockScreen(title: L("restore.done.title"), subtitle: doneSubtitle) { doneStep }
        }
    }

    // MARK: Where it is

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                if restore.offersAccount(model) {
                    RestoreSourceRow(symbol: "person.crop.circle", title: L("restore.source.account"),
                                     detail: L(model.license.record.isSignedIn ? "restore.source.account.detail" : "restore.source.account.signedOut")) {
                        Task { await restore.chooseAccount(app: model) }
                    }
                }
                RestoreSourceRow(symbol: "folder", title: L("restore.source.folder"), detail: L("restore.source.folder.detail"),
                                 action: chooseFolder)
                RestoreSourceRow(symbol: "server.rack", title: L("restore.source.server"), detail: L("restore.source.server.detail")) {
                    restore.showServerForm()
                }
            }
            .disabled(restore.isWorking)
            .padding(.top, 30)
            if let problem = restore.problem {
                MasterPasswordRefusalLine(text: problem)
                    .textSelection(.enabled)
                    .padding(.top, 14)
            }
            ForEach(restore.unfinished) { item in
                VStack(alignment: .leading, spacing: 4) {
                    LockNote(symbol: "arrow.down.circle",
                             text: String(format: L("restore.unfinished"), RestoreText.day(item.createdAt), RestoreText.bytes(item.bytes)))
                    LockLink(title: L("restore.unfinished.discard")) { discarding = item }
                        .padding(.leading, 17)
                }
                .padding(.top, 20)
            }
            centred(LockLink(title: L("restore.source.back"), action: onBack))
                .disabled(restore.isWorking)
                .padding(.top, 22)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("restore.folder.message")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await restore.chooseFolder(folder, app: model) }
    }

    // MARK: The account's vaults

    @ViewBuilder
    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch restore.account {
            case .asking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("restore.account.asking"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 36)
            case .vaults(let candidates):
                VStack(spacing: 10) {
                    ForEach(candidates) { candidate in
                        RestoreVaultRow(candidate: candidate, selected: restore.selected == candidate.vaultID) {
                            restore.selected = candidate.vaultID
                        }
                    }
                }
                .padding(.top, 30)
                LockActionButton(title: L("restore.account.continue"), enabled: restore.selected != nil) {
                    restore.continueWithSelected(app: model)
                }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 24)
            case .state(let state):
                LockNote(symbol: Self.symbol(of: state), tint: Self.tint(of: state), text: RestoreText.text(state))
                    .textSelection(.enabled)
                    .padding(.top, 30)
                accountAction(state)
                    .padding(.top, 24)
            }
            centred(LockLink(title: L("restore.back")) { restore.backToSource(app: model) })
                .disabled(restore.isWorking)
                .padding(.top, 14)
        }
    }

    /// What the person can do about the account's answer: pay, sign in, or ask again.
    @ViewBuilder
    private func accountAction(_ state: AccountVaults.State) -> some View {
        switch state {
        case .notInPlan:
            if let plans = model.license.configuration?.site("/pricing") {
                LockActionButton(title: L("restore.account.plans")) { SystemOpen.openWebsite(plans) }
            }
        case .signedOut:
            // The first launch's sign-in again; the setup screen comes back after it.
            LockActionButton(title: L("restore.account.signIn")) { model.accountStepDone = false }
        case .accountDisabled:
            EmptyView()
        case .vaults, .noVaults, .onHold, .rateLimited, .unreachable, .refused:
            LockActionButton(title: L("restore.account.again"), working: restore.isWorking, workingTitle: L("restore.account.asking")) {
                Task { await restore.chooseAccount(app: model) }
            }
        }
    }

    private static func symbol(of state: AccountVaults.State) -> String {
        switch state {
        case .notInPlan: return "creditcard"
        case .onHold: return "clock"
        case .accountDisabled: return "nosign"
        case .signedOut: return "person.crop.circle.badge.xmark"
        case .unreachable, .rateLimited: return "wifi.slash"
        case .vaults, .noVaults, .refused: return "tray"
        }
    }

    private static func tint(of state: AccountVaults.State) -> Color {
        switch state {
        case .notInPlan, .onHold, .accountDisabled, .signedOut, .unreachable, .rateLimited, .refused: return Theme.warning
        case .vaults, .noVaults: return Theme.textSecondary
        }
    }

    // MARK: A server of one's own

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountTextField(label: L("restore.server.address"), text: $address, prompt: "https://sync.example.com") // l10n: not text
                .padding(.top, 30)
            LockPasswordField(label: L("restore.server.token"), password: $token, takesFocus: false)
                .padding(.top, 18)
            AccountTextField(label: L("restore.server.vaultID"), text: $vaultID, monospaced: true, onSubmit: findOnServer)
                .padding(.top, 18)
            Text(L("restore.server.vaultID.note"))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let problem = restore.problem {
                MasterPasswordRefusalLine(text: problem)
                    .textSelection(.enabled)
                    .padding(.top, 14)
            }
            VStack(spacing: 14) {
                LockActionButton(title: L("restore.server.find"), working: restore.isWorking, workingTitle: L("restore.server.finding"),
                                 enabled: !address.isEmpty && !vaultID.isEmpty, action: findOnServer)
                    .keyboardShortcut(.defaultAction)
                LockLink(title: L("restore.back")) { restore.backToSource(app: model) }
                    .disabled(restore.isWorking)
            }
            .padding(.top, 24)
        }
    }

    private func findOnServer() {
        guard !address.isEmpty, !vaultID.isEmpty, !restore.isWorking else { return }
        Task { await restore.chooseServer(address: address, token: token, vaultID: vaultID, app: model) }
    }

    // MARK: The master password

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            LockPasswordField(label: L("setup.field.password"), password: $password,
                              error: restore.problem != nil && password.isEmpty, attempts: restore.wrongPasswords, onSubmit: bring)
                .padding(.top, 30)
            if let problem = restore.problem {
                MasterPasswordRefusalLine(text: problem)
                    .textSelection(.enabled)
                    .padding(.top, 10)
            } else {
                Text(L(restore.candidate?.passwordChanged == true ? "restore.password.help.changed" : "restore.password.help"))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            VStack(spacing: 14) {
                LockActionButton(title: L("restore.password.action"), working: restore.isWorking, workingTitle: L("restore.password.working"),
                                 enabled: !password.isEmpty, action: bring)
                    .keyboardShortcut(.defaultAction)
                LockLink(title: L("restore.back")) { restore.backToSource(app: model) }
                    .disabled(restore.isWorking)
            }
            .padding(.top, 24)
            // What joining means while another Mac still works with this vault: said before it is brought.
            LockNote(symbol: "laptopcomputer.and.iphone", text: L("restore.join.note"))
                .padding(.top, 26)
        }
    }

    private func bring() {
        let entered = password
        // Return reaches both the field's submit and the default button (as on the unlock screen).
        guard !entered.isEmpty, !restore.isWorking else { return }
        password = ""
        Task { await restore.bring(password: entered, app: model) }
    }

    // MARK: It comes

    private var bringingSubtitle: String {
        if restore.moving { return L("restore.bringing.moving") }
        guard let profiles = restore.profileNames else { return L("restore.bringing.listing") }
        return profiles.isEmpty ? L("restore.bringing.empty") : String(format: L("restore.bringing.profiles"), RestoreText.names(profiles))
    }

    @ViewBuilder
    private var bringingStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let interrupted = restore.interrupted {
                MasterPasswordRefusalLine(text: interrupted)
                    .textSelection(.enabled)
                    .padding(.top, 30)
                Text(L("restore.interrupted.kept"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                VStack(spacing: 14) {
                    LockActionButton(title: L("restore.interrupted.again")) {
                        Task { await restore.goOn(app: model) }
                    }
                    .keyboardShortcut(.defaultAction)
                    LockLink(title: L("restore.interrupted.back")) { restore.backToSource(app: model) }
                }
                .padding(.top, 24)
            } else {
                RestoreBar(fraction: restore.moving ? 1 : restore.progress?.fraction)
                    .padding(.top, 34)
                HStack {
                    Text(progressLine)
                    Spacer()
                    if let fraction = restore.progress?.fraction {
                        Text(verbatim: "\(Int((fraction * 100).rounded(.down))) %")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
                if restore.continued {
                    Text(L("restore.bringing.continued"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                LockNote(symbol: "shippingbox", text: L("restore.bringing.note"))
                    .padding(.top, 26)
                centred(LockLink(title: L("restore.bringing.stop")) { restore.stop() })
                    .disabled(restore.moving)
                    .padding(.top, 20)
            }
        }
    }

    private var progressLine: String {
        guard let progress = restore.progress, progress.listed > 0 else { return L("restore.bringing.asking") }
        return String(format: L("restore.bringing.progress"), min(progress.listed, progress.fetched + progress.alreadyHere), progress.listed,
                      RestoreText.bytes(progress.bytes))
    }

    // MARK: It is here

    private var doneSubtitle: String {
        guard let summary = restore.summary, summary.profiles > 0 else { return L("restore.done.subtitle.none") }
        return String(format: L("restore.done.subtitle.count"), summary.profiles)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = restore.summary {
                LockNote(symbol: "arrow.triangle.2.circlepath",
                         text: String(format: L("restore.done.sync"), RestoreText.syncsWith(summary.place), L("profiles.menu.more"),
                                      L("profiles.menu.syncNow")))
                    .padding(.top, 30)
                if !summary.withoutSettings.isEmpty {
                    LockNote(symbol: "exclamationmark.triangle", tint: Theme.warning,
                             text: String(format: L("restore.done.withoutSettings"), summary.withoutSettings.joined(separator: ", "),
                                          CameraSubstitution.maxMediaBytes / (1024 * 1024)))
                        .textSelection(.enabled)
                        .padding(.top, 16)
                }
                LockNote(symbol: "tray", text: L("restore.done.notSynced"))
                    .padding(.top, 16)
            }
            LockActionButton(title: L("restore.done.open")) { restore.open(app: model) }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 26)
        }
    }

    private func centred<Content: View>(_ content: Content) -> some View {
        HStack {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
    }
}

/// A place a vault can be brought from, on the lock screen: the field's shape, a symbol, a title and
/// a line of what it is; pressed like the lock screen's action.
private struct RestoreSourceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered ? Color(hex: 0x15161A) : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovered ? Theme.edgeStrong : Theme.strongBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovered = isEnabled && $0 }
        .animation(Theme.hoverAnimation, value: hovered)
        .accessibilityElement(children: .combine)
    }
}

/// One of the account's vaults, told by what is known of it before its password: when it was made
/// (its header), when it last changed (the server), the start of its ID — and why it cannot be
/// brought, when it cannot.
private struct RestoreVaultRow: View {
    let candidate: RestoreModel.Candidate
    let selected: Bool
    let action: () -> Void

    private var shortID: String { String(candidate.vaultID.uuidString.prefix(8)) }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.createdAt.map { String(format: L("restore.vault.created"), RestoreText.day($0)) }
                         ?? String(format: L("restore.vault.id"), shortID))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(candidate.changedAt.map { String(format: L("restore.vault.changed"), RestoreText.moment($0)) }
                         ?? L("restore.vault.changed.unknown"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    if let problem = candidate.problem {
                        Text(problem)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.warning)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if candidate.createdAt != nil {
                        Text(String(format: L("restore.vault.id"), shortID))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.edgeStrong : Theme.strongBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(candidate.problem != nil)
        .opacity(candidate.problem == nil ? 1 : 0.7)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// How far the vault is: a 3 pt line across the column, as the strength meter's steps are drawn.
private struct RestoreBar: View {
    /// 0…1; nil before the place has listed the vault.
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                if let fraction {
                    Capsule().fill(Theme.textPrimary)
                        .frame(width: max(3, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityLabel(L("restore.bringing.title"))
        .accessibilityValue(Text(verbatim: fraction.map { "\(Int(($0 * 100).rounded(.down))) %" } ?? ""))
    }
}
