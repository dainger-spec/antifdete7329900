import AppKit
import BrowserCore
import SwiftUI

/// Saved passwords of one profile (stored encrypted with the profile key).
struct PasswordListView: View {
    let profileID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PasswordEntry] = []
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L("passwords.title"), model.summary(profileID)?.name ?? "")).font(.title3.bold())
            List {
                ForEach(entries) { entry in
                    HStack {
                        IconBadge(symbol: "key.fill", size: 28)
                        VStack(alignment: .leading) {
                            Text(entry.origin)
                            Text(entry.username.isEmpty ? L("passwords.noUsername") : entry.username)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .frame(minHeight: 200)
            HStack {
                TextField(L("passwords.placeholder.origin"), text: $origin)
                TextField(L("passwords.placeholder.username"), text: $username)
                SecureField(L("passwords.placeholder.password"), text: $password)
                Button(L("passwords.add"), action: add).disabled(password.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            entries = try model.passwordVault(for: profileID).allEntries()
        } catch {
            self.error = ErrorPresenter.alert(for: error)?.message
        }
    }

    private func add() {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespaces)),
              let normalized = PasswordEntry.normalizedOrigin(for: url) else {
            error = L("passwords.error.origin")
            return
        }
        do {
            try model.passwordVault(for: profileID).upsert(PasswordEntry(origin: normalized, username: username, password: password))
            origin = ""; username = ""; password = ""; error = nil
            reload()
        } catch {
            self.error = ErrorPresenter.alert(for: error)?.message
        }
    }

    private func remove(_ entry: PasswordEntry) {
        do {
            try model.passwordVault(for: profileID).remove(id: entry.id)
            reload()
        } catch {
            self.error = ErrorPresenter.alert(for: error)?.message
        }
    }
}
