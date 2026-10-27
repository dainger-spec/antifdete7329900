import SwiftUI

/// The app's launch screen, around the setup and unlock forms: the Lumen mark, a title and the
/// form centred on the window's backdrop, the wordmark at the foot. It rises in once when the
/// window opens; while the vault opens (or is created) the form gives way to a progress line, and
/// the Profiles window then fades in (RootView).
struct LockScreen<Content: View>: View {
    let title: String
    let subtitle: String
    let isWorking: Bool
    let workingLabel: String
    @ViewBuilder let content: () -> Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(spacing: 0) {
                LumenMark(size: 64)
                    .padding(.bottom, 24)
                Text(title)
                    .font(.lumenTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                Text(subtitle)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 28)
                ZStack(alignment: .top) {
                    content()
                        .opacity(isWorking ? 0 : 1)
                        .allowsHitTesting(!isWorking)
                        .accessibilityHidden(isWorking)
                    if isWorking {
                        VStack(spacing: 12) {
                            LumenActivityLine(width: 180)
                            Text(workingLabel)
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.top, 14)
                        .transition(.opacity)
                    }
                }
                .animation(Theme.appearAnimation, value: isWorking)
            }
            .frame(width: 360)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            Spacer(minLength: 32)
            LumenWordmark(height: 10, color: Theme.textDisabled)
                .padding(.bottom, 28)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backdrop)
        .onAppear {
            guard !appeared else { return }
            withAnimation(reduceMotion ? nil : Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42).delay(0.06)) {
                appeared = true
            }
        }
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""

    private var problem: String? {
        if password.count < 10 { return L("setup.rule.length") }
        if password != confirmation { return L("setup.rule.match") }
        return nil
    }

    var body: some View {
        LockScreen(title: L("setup.title"), subtitle: L("setup.subtitle"), isWorking: model.isWorking,
                   workingLabel: L("setup.working")) {
            VStack(spacing: 12) {
                if let moved = model.movedAsideVaultPath {
                    // After "forgot password": the previous vault was moved, not deleted.
                    Text(String(format: L("setup.movedAside"), moved))
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.bottom, 4)
                }
                SecureField(L("setup.field.password"), text: $password, prompt: Text(verbatim: ""))
                    .lumenField(L("setup.field.password"), isEmpty: password.isEmpty, height: 36)
                SecureField(L("setup.field.repeat"), text: $confirmation, prompt: Text(verbatim: ""))
                    .lumenField(L("setup.field.repeat"), isEmpty: confirmation.isEmpty, height: 36)
                if let problem, !password.isEmpty {
                    Label(problem, systemImage: "info.circle")
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(L("setup.action.create")) {
                    Task { await model.createVault(password: password) }
                }
                .buttonStyle(LumenButtonStyle(kind: .primary, fullWidth: true, height: 36))
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || model.isWorking)
                .padding(.top, 4)
            }
            .frame(width: 300)
        }
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmingReset = false

    var body: some View {
        LockScreen(title: L("unlock.title"), subtitle: L("unlock.subtitle"), isWorking: model.isWorking,
                   workingLabel: L("unlock.working")) {
            VStack(spacing: 12) {
                SecureField(L("setup.field.password"), text: $password, prompt: Text(verbatim: ""))
                    .lumenField(L("setup.field.password"), isEmpty: password.isEmpty, height: 36)
                    .onSubmit(unlock)
                Button(L("unlock.action.unlock"), action: unlock)
                    .buttonStyle(LumenButtonStyle(kind: .primary, fullWidth: true, height: 36))
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.isWorking)
                if model.unlockFailed {
                    VStack(spacing: 10) {
                        // Which vault was tried: another build (sandboxed or not, other bundle id)
                        // opens a different folder with a vault of its own.
                        Text(String(format: L("unlock.vault.info"), model.vaultCreatedDescription, model.vaultPathDescription))
                            .font(.lumenCaption)
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if model.vaultLooksLikeTestVault {
                            Label(L("unlock.vault.test"), systemImage: "exclamationmark.triangle")
                                .font(.lumenCaption)
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(L("unlock.reset.action")) { confirmingReset = true }
                            .buttonStyle(.lumenGhost)
                            .disabled(model.isWorking)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(width: 300)
        }
        .confirmationDialog(L("unlock.reset.title"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L("unlock.reset.confirm"), role: .destructive) { model.startOver() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("unlock.reset.message"))
        }
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

struct ChangePasswordView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("changepw.title"))
            Form {
                SecureField(L("changepw.current"), text: $current)
                SecureField(L("changepw.new"), text: $new)
                SecureField(L("changepw.repeat"), text: $confirmation)
                Text(L("changepw.note")).font(.caption).foregroundStyle(.secondary)
            }
            .lumenForm()
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("changepw.action.change")) {
                    Task {
                        await model.changePassword(current: current, new: new)
                        if model.errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(current.isEmpty || new.count < 10 || new != confirmation)
            }
        }
        .frame(width: 420)
        .background(Theme.raised)
    }
}
