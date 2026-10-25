import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""

    private var problem: String? {
        if password.count < 10 { return "Use at least 10 characters." }
        if password != confirmation { return "Passwords do not match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create master password").font(.title2.bold())
            Text("""
            The master password encrypts the profile list, every profile's settings, saved passwords, \
            and archived website data. It cannot be recovered: if you forget it, the data is lost.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            SecureField("Master password", text: $password)
            SecureField("Repeat master password", text: $confirmation)
            HStack {
                if let problem, !password.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Create Vault") {
                    Task { await model.createVault(password: password) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || model.isWorking)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(32)
        .frame(maxWidth: 460)
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Vault locked").font(.title2.bold())
            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(unlock)
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.isWorking)
            }
        }
        .padding(32)
    }

    private func unlock() {
        let entered = password
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
        Form {
            SecureField("Current password", text: $current)
            SecureField("New password", text: $new)
            SecureField("Repeat new password", text: $confirmation)
            Text("Only the wrapped vault key is re-encrypted; profile data is unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Change") {
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
