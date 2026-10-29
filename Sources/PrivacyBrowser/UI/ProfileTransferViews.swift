import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A profile export (`ProfileTransfer`): one file, encrypted with a password of its own.
    static let privacyBrowserProfile = UTType(filenameExtension: ProfileTransfer.fileExtension, conformingTo: .data) ?? .data
}

/// What a profile export's error means to the person who typed the password.
private func transferErrorText(_ error: Error) -> String {
    switch error as? CoreError {
    case .authenticationFailed?: return L("transfer.error.password")
    case .unsupportedFormat?: return L("transfer.error.notExport")
    case let core?: return core.description
    case nil: return error.localizedDescription
    }
}

/// Writes one profile — settings and proxy, passwords, history, bookmarks, cookies and website
/// data, Safari's own state of it — into a `.pbprofile` file encrypted with a password of its own,
/// for another Mac, a backup or a colleague. A running profile is stopped first: only then is its
/// website data sealed, and only sealed is it whole.
struct ProfileExportView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var saved: URL?
    @State private var error: String?

    static let minimumPasswordLength = 8

    private var isRunning: Bool { model.isRunning(profile.id) }
    private var canExport: Bool {
        !working && saved == nil && password.count >= Self.minimumPasswordLength && password == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("transfer.export.title"), profile.name), subtitle: L("transfer.export.explanation"))
            Form {
                if isRunning && saved == nil {
                    Label(L("transfer.export.running"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.textSecondary)
                }
                SecureField(L("transfer.password"), text: $password)
                    .disabled(working || saved != nil)
                SecureField(L("transfer.password.repeat"), text: $confirmation)
                    .disabled(working || saved != nil)
                Text(L("transfer.password.note")).font(.caption).foregroundStyle(.secondary)
                if let saved {
                    Label(String(format: L("transfer.export.done"), saved.lastPathComponent), systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.textPrimary)
                }
                if let error {
                    Text(error).foregroundStyle(Theme.danger).font(.lumenSecondary)
                }
            }
            .lumenForm()
            SheetFooter(leading: {
                if working { ProgressView().controlSize(.small) }
            }, buttons: {
                Button(L(saved == nil ? "common.cancel" : "common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if saved == nil {
                    Button(L(isRunning ? "transfer.export.actionStop" : "transfer.export.action"), action: export)
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canExport)
                }
            })
        }
        .frame(width: 480)
        .background(Theme.raised)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).\(ProfileTransfer.fileExtension)"
        panel.allowedContentTypes = [.privacyBrowserProfile]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        error = nil
        Task {
            do {
                _ = try await model.exportProfile(profile.id, to: url, password: password)
                saved = url
            } catch {
                self.error = transferErrorText(error)
            }
            working = false
        }
    }
}

/// Brings a `.pbprofile` file in as a new profile: the file is opened with its password and
/// described first — its name, what it holds, its proxy — and imported only when asked, as a
/// profile of its own beside the ones already here.
struct ProfileImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var file: URL?
    @State private var password = ""
    @State private var manifest: ProfileTransfer.Manifest?
    @State private var name = ""
    @State private var working = false
    @State private var imported: ProfileSummary?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("transfer.import.title"), subtitle: L("transfer.import.explanation"))
            Form {
                HStack(spacing: 10) {
                    Button { choosingFile = true } label: { Label(L("transfer.import.choose"), systemImage: "doc") }
                        .buttonStyle(.lumenSecondary)
                        .disabled(working || imported != nil)
                    if let file {
                        Text(file.lastPathComponent)
                            .font(.lumenBody).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if file != nil, manifest == nil {
                    SecureField(L("transfer.password"), text: $password)
                        .onSubmit(open)
                        .disabled(working)
                }
                if let manifest {
                    TextField(L("transfer.import.name"), text: $name)
                        .disabled(working || imported != nil)
                    summary(manifest)
                }
                if let imported {
                    Label(String(format: L("transfer.import.done"), imported.name), systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.textPrimary)
                }
                if let error {
                    Text(error).foregroundStyle(Theme.danger).font(.lumenSecondary)
                }
            }
            .lumenForm()
            SheetFooter(leading: {
                if working { ProgressView().controlSize(.small) }
            }, buttons: {
                Button(L(imported == nil ? "common.cancel" : "common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if imported == nil {
                    if manifest == nil {
                        Button(L("transfer.import.open"), action: open)
                            .buttonStyle(.lumenPrimary)
                            .keyboardShortcut(.defaultAction)
                            .disabled(working || file == nil || password.isEmpty)
                    } else {
                        Button(L("transfer.import.action"), action: importProfile)
                            .buttonStyle(.lumenPrimary)
                            .keyboardShortcut(.defaultAction)
                            .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            })
        }
        .frame(width: 480)
        .background(Theme.raised)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.privacyBrowserProfile, .data]) { result in
            switch result {
            case let .success(url):
                file = url
                manifest = nil
                error = nil
            case let .failure(failure):
                error = failure.localizedDescription
            }
        }
    }

    private func summary(_ manifest: ProfileTransfer.Manifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: L("transfer.import.contents"), manifest.passwordCount, manifest.historyCount, manifest.bookmarkCount))
            Text(L(manifest.hasWebsiteData ? "transfer.import.websiteData" : "transfer.import.noWebsiteData"))
            Text(manifest.configuration.proxy.map { String(format: L("transfer.import.proxy"), "\($0.host):\($0.port)") }
                 ?? L("transfer.import.direct"))
            Text(String(format: L("transfer.import.exportedAt"),
                        manifest.exportedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        .font(.lumenSecondary)
        .foregroundStyle(Theme.textSecondary)
    }

    private func open() {
        guard let file, !password.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            do {
                let found = try await model.readProfileExport(file, password: password)
                manifest = found
                name = found.name
            } catch {
                self.error = transferErrorText(error)
            }
            working = false
        }
    }

    private func importProfile() {
        guard let file, manifest != nil, !working else { return }
        working = true
        error = nil
        Task {
            do {
                imported = try await model.importProfile(from: file, password: password,
                                                         name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.error = transferErrorText(error)
            }
            working = false
        }
    }
}
