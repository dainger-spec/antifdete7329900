import BrowserCore
import SwiftUI

/// Rename a profile. The name is only a label: the profile's data and identity stay the same.
struct RenameProfileView: View {
    let profileID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("rename.title")).font(.title3.bold())
            TextField(L("editor.name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = model.summary(profileID)?.name ?? "" }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.rename(profileID, to: trimmed)
        dismiss()
    }
}

/// Export a profile to one password-protected file: settings, cookies and site data, history,
/// bookmarks and saved passwords. The file is encrypted with its own password, independent of
/// the master password, so it can be restored on another Mac.
struct ExportProfileView: View {
    let profileID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""

    private var problemKey: String? {
        if password.count < 8 { return "backup.password.length" }
        if password != confirmation { return "setup.rule.match" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(symbol: "square.and.arrow.up", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("backup.export.title")).font(.title3.bold())
                    Text(model.summary(profileID)?.name ?? "").foregroundStyle(.secondary)
                }
            }
            Text(L("backup.export.explain"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isRunning(profileID) {
                Label(L("backup.export.willStop"), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SecureField(L("backup.password"), text: $password)
            SecureField(L("backup.password.repeat"), text: $confirmation)
            if let problemKey, !password.isEmpty {
                Text(L(problemKey)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("backup.export.action"), action: export)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problemKey != nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 440)
    }

    private func export() {
        let name = model.summary(profileID)?.name ?? "profile"
        let password = password
        let id = profileID
        dismiss()
        Task { @MainActor in
            guard let url = await FilePanels.save(titleKey: "backup.export.title", messageKey: "backup.export.panel",
                                                  suggestedName: FilePanels.fileName(name, ext: ProfileBackup.fileExtension),
                                                  type: FilePanels.backupType) else { return }
            await model.exportProfile(id, to: url, password: password)
        }
    }
}

/// Import a profile file (asks for the file's password).
struct ImportProfileView: View {
    let file: URL
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(symbol: "square.and.arrow.down", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("backup.import.title")).font(.title3.bold())
                    Text(file.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(L("backup.import.explain"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(L("backup.password"), text: $password)
                .onSubmit(importFile)
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("backup.import.action"), action: importFile)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 440)
    }

    private func importFile() {
        guard !password.isEmpty else { return }
        let password = password
        let file = file
        dismiss()
        Task { @MainActor in await model.importProfile(from: file, password: password) }
    }
}
