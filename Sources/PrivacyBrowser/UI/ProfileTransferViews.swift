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
    // Every other error in the interface's language too (`errorText`), never the core's English.
    default: return errorText(error)
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
            // The design's fields on the sheet's own surface: in the system's grouped Form the
            // password fields drew no box at all.
            VStack(alignment: .leading, spacing: 14) {
                if isRunning && saved == nil {
                    SheetWarning(text: L("transfer.export.running"))
                }
                EditorField(L("transfer.password")) {
                    SecureField(L("transfer.password"), text: $password, prompt: Text(verbatim: ""))
                        .lumenField(takesFocus: true)
                        .disabled(working || saved != nil)
                }
                EditorField(L("transfer.password.repeat")) {
                    SecureField(L("transfer.password.repeat"), text: $confirmation, prompt: Text(verbatim: ""))
                        .lumenField()
                        .disabled(working || saved != nil)
                }
                Text(L("transfer.password.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let saved {
                    Label(String(format: L("transfer.export.done"), saved.lastPathComponent), systemImage: "checkmark.circle")
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.running)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 18)
            // Without a height of its own the sheet would hug its content; the Form filled it.
            Spacer(minLength: 0)
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
        .sheetFrame(width: 480)
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
            VStack(alignment: .leading, spacing: 14) {
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
                    EditorField(L("transfer.password")) {
                        SecureField(L("transfer.password"), text: $password, prompt: Text(verbatim: ""))
                            .lumenField(takesFocus: true)
                            .onSubmit(open)
                            .disabled(working)
                    }
                }
                if let manifest {
                    EditorField(L("transfer.import.name")) {
                        TextField(L("transfer.import.name"), text: $name, prompt: Text(verbatim: ""))
                            .lumenField()
                            .disabled(working || imported != nil)
                    }
                    summary(manifest)
                }
                if let imported {
                    Label(String(format: L("transfer.import.done"), imported.name), systemImage: "checkmark.circle")
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.running)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 18)
            Spacer(minLength: 0)
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
        .sheetFrame(width: 480)
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
                        manifest.exportedAt.shown(date: .abbreviated, time: .shortened)))
            // What the import leaves out of the file's settings (APP-08 of the security audit):
            // said before the person imports, so that nothing of the file goes around the proxy
            // unseen.
            let leftOut = ProfileTransfer.LeftOut(of: manifest.configuration)
            if !leftOut.isEmpty {
                SheetWarning(text: String(format: L("transfer.import.leftOut"), leftOutList(leftOut)))
                    .padding(.top, 4)
            }
            Text(L("transfer.import.trust"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .font(.lumenSecondary)
        .foregroundStyle(Theme.textSecondary)
    }

    /// The settings left out, in a sentence: the bypassed sites by name (the first few), then the rest.
    private func leftOutList(_ leftOut: ProfileTransfer.LeftOut) -> String {
        var items: [String] = []
        if !leftOut.directDomains.isEmpty {
            let shown = leftOut.directDomains.prefix(4).joined(separator: ", ")
            let more = leftOut.directDomains.count > 4 ? String(format: L("transfer.import.leftOut.more"), leftOut.directDomains.count - 4) : ""
            items.append(String(format: L("transfer.import.leftOut.direct"), shown + more))
        }
        if leftOut.safeBrowsing { items.append(L("transfer.import.leftOut.safeBrowsing")) }
        if leftOut.localRequests { items.append(L("transfer.import.leftOut.localRequests")) }
        return items.joined(separator: "; ")
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

/// Writes a profile's cookies to a file another browser, a cookie extension or an automation tool
/// reads (`CookieExport`). The file is not encrypted — a session cookie in it is the session —
/// which the sheet says before anything is written. A stopped profile is started without a window
/// to be read, and stopped again.
struct CookieExportView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: CookieExport.Format = .netscape
    @State private var working = false
    @State private var saved: (url: URL, count: Int)?
    @State private var error: String?

    private func label(_ format: CookieExport.Format) -> String {
        switch format {
        case .netscape: return L("cookieExport.format.netscape")
        case .extensionJSON: return L("cookieExport.format.extension")
        case .playwright: return L("cookieExport.format.playwright")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("cookieExport.title"), profile.name), subtitle: L("cookieExport.explanation"))
            VStack(alignment: .leading, spacing: 14) {
                // The formats' names are too long for a segmented control: one radio row each.
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("cookieExport.format")).lumenCaps().padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                    ForEach(CookieExport.Format.allCases, id: \.self) { choice in
                        LumenRadio(title: label(choice), isOn: format == choice) { format = choice }
                    }
                }
                .disabled(working || saved != nil)
                SheetWarning(text: L("cookieExport.warning"))
                if !model.isRunning(profile.id) && saved == nil {
                    Text(L("cookieExport.stopped"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saved {
                    Label(String(format: L("cookieExport.done"), saved.count, saved.url.lastPathComponent), systemImage: "checkmark.circle")
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.running)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 18)
            Spacer(minLength: 0)
            SheetFooter(leading: {
                if working { ProgressView().controlSize(.small) }
            }, buttons: {
                Button(L(saved == nil ? "common.cancel" : "common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if saved == nil {
                    Button(L("cookieExport.action"), action: export)
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            })
        }
        .sheetFrame(width: 480)
        .background(Theme.raised)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name) cookies.\(format.fileExtension)"
        panel.allowedContentTypes = [format == .netscape ? .plainText : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        error = nil
        let format = format
        Task {
            do {
                let cookies = try await model.exportCookies(of: profile.id)
                try CookieExport.data(cookies, format: format).write(to: url, options: .atomic)
                saved = (url, CookieExport.count(cookies, format: format))
            } catch {
                self.error = String(format: L("cookieExport.failed"), error.localizedDescription)
            }
            working = false
        }
    }
}
