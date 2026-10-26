import SwiftUI

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
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                IconBadge(symbol: "lock.shield.fill", size: 56)
                Text(L("setup.title")).font(.title.bold())
                Text(L("setup.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                SecureField(L("setup.field.password"), text: $password)
                SecureField(L("setup.field.repeat"), text: $confirmation)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)

            if let problem, !password.isEmpty {
                Label(problem, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await model.createVault(password: password) }
            } label: {
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Text(L("setup.action.create"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(problem != nil || model.isWorking)
        }
        .frame(width: 420)
        .card(padding: 28)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 18) {
            IconBadge(symbol: "lock.fill", size: 56)
            Text(L("unlock.title")).font(.title.bold())
            Text(L("unlock.subtitle")).font(.callout).foregroundStyle(.secondary)
            SecureField(L("setup.field.password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(width: 300)
                .onSubmit(unlock)
            Button {
                unlock()
            } label: {
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Text(L("unlock.action.unlock"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(width: 300)
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty || model.isWorking)
            if model.unlockFailed {
                // Which vault was tried: another build (sandboxed or not, other bundle id) opens
                // a different folder with a vault of its own.
                Text(String(format: L("unlock.vault.info"), model.vaultCreatedDescription, model.vaultPathDescription))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(width: 300)
            }
        }
        .frame(width: 380)
        .card(padding: 28)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
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
            Text(L("changepw.title")).font(.title3.bold()).padding([.top, .horizontal], 20)
            Form {
                SecureField(L("changepw.current"), text: $current)
                SecureField(L("changepw.new"), text: $new)
                SecureField(L("changepw.repeat"), text: $confirmation)
                Text(L("changepw.note")).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .frame(width: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("changepw.action.change")) {
                    Task {
                        await model.changePassword(current: current, new: new)
                        if model.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(current.isEmpty || new.count < 10 || new != confirmation)
            }
        }
    }
}
