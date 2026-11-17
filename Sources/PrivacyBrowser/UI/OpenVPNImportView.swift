import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Proxies › Add › OpenVPN (docs/OPENVPN.md) — also a `.ovpn` dropped on Add's sheet or on this
/// one, or opened with Lumen in the Finder: a `.ovpn` file becomes an entry of the list, which
/// profiles are given as any proxy. The file is read once, here: files it names are
/// taken from beside it; what Lumen leaves out is said; a configuration Lumen cannot run is
/// refused whole, with why. Its user name and password are the entry's, kept as every proxy's.
/// Opened on an OpenVPN entry, the same sheet changes its name, credentials or file.
struct OpenVPNImportView: View {
    @ObservedObject var proxies: ProxyListModel
    let entry: ProxyListEntry?
    /// A file to read as the sheet opens (dropped on Add's sheet, opened in the Finder).
    var file: URL?
    var onAdded: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false

    @State private var label: String
    @State private var username: String
    @State private var password: String
    @State private var configuration: OpenVPNConfiguration?
    @State private var fileName: String?
    @State private var problem: String?
    @State private var error: String?

    init(proxies: ProxyListModel, entry: ProxyListEntry? = nil, file: URL? = nil, onAdded: @escaping (UUID) -> Void = { _ in }) {
        _proxies = ObservedObject(wrappedValue: proxies)
        self.entry = entry
        self.file = file
        self.onAdded = onAdded
        _label = State(initialValue: entry?.label ?? "")
        _username = State(initialValue: entry?.proxy.username ?? "")
        _password = State(initialValue: entry?.proxy.password ?? "")
        _configuration = State(initialValue: try? entry?.proxy.openVPN?.parsed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L(entry == nil ? "openvpn.import.title" : "openvpn.edit.title"),
                        subtitle: L("openvpn.import.explanation"))
            VStack(alignment: .leading, spacing: 14) {
                EditorField(L("openvpn.import.file")) {
                    HStack(spacing: 10) {
                        Text(fileName ?? configuration.map(serverLine) ?? L("openvpn.import.file.none"))
                            .font(.lumenBody)
                            .foregroundStyle(configuration == nil ? Theme.textTertiary : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button(L("openvpn.import.choose"), action: choose)
                            .buttonStyle(LumenButtonStyle(kind: .ghost, height: Theme.buttonHeight))
                    }
                }
                if let configuration {
                    Text(serverLine(configuration))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                    if !configuration.notices.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(configuration.notices.enumerated()), id: \.offset) { _, notice in
                                Text(OpenVPNTexts.notice(notice))
                                    .font(.lumenSecondary)
                                    .foregroundStyle(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let problem {
                    Label(problem, systemImage: "xmark.octagon.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                EditorField(L("proxies.edit.name")) {
                    TextField(L("proxies.edit.name"), text: $label, prompt: Text(verbatim: ""))
                        .lumenField(L("openvpn.import.name.placeholder"), isEmpty: label.isEmpty)
                }
                if configuration?.needsCredentials ?? false {
                    EditorField(L("openvpn.import.username")) {
                        TextField(L("openvpn.import.username"), text: $username, prompt: Text(verbatim: ""))
                            .lumenField(L("openvpn.import.username"), isEmpty: username.isEmpty)
                            .autocorrectionDisabled()
                    }
                    EditorField(L("openvpn.import.password")) {
                        SecureField(L("openvpn.import.password"), text: $password, prompt: Text(verbatim: ""))
                            .lumenField(L("openvpn.import.password"), isEmpty: password.isEmpty)
                    }
                }
                if !OpenVPNTunnels.shared.isAvailable {
                    Text(L("openvpn.failure.notInThisBuild"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(LumenButtonStyle(kind: .ghost, height: Theme.buttonHeight))
                    .keyboardShortcut(.cancelAction)
                Button(L(entry == nil ? "proxies.add.action" : "common.save"), action: save)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(configuration == nil || proxies.loadError != nil)
            }
        }
        .sheetFrame(width: 560)
        .background(Theme.raised)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            OpenVPNFile.receive(providers) { load($0) }
        }
        .onAppear {
            if let file, fileName == nil { load(file) }
        }
    }

    /// "vpn.example.net:1194 (UDP), and 2 more servers".
    private func serverLine(_ configuration: OpenVPNConfiguration) -> String {
        let first = configuration.firstRemote
        let address = "\(first.host):\(first.port) (\(first.transport.rawValue.uppercased()))"
        let more = configuration.remotes.count - 1
        return more > 0 ? String(format: L("openvpn.import.servers.more"), address, more) : address
    }

    private func choose() {
        if let url = OpenVPNFile.choose() { load(url) }
    }

    /// Reads the file, and the files it names from beside it.
    private func load(_ url: URL) {
        problem = nil
        error = nil
        // A file dropped or opened from the Finder: readable through its own grant (the sandboxed build).
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= OpenVPNConfiguration.maximumSize,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            configuration = nil
            problem = OpenVPNTexts.problem(.notText)
            return
        }
        let folder = url.deletingLastPathComponent()
        let inlined = OpenVPNConfiguration.inlining(text) { name in
            // Only a file in the same folder (or below it), named relatively: never a path elsewhere.
            guard !name.hasPrefix("/"), !name.contains(".."), !name.contains("~") else { return nil }
            let file = folder.appendingPathComponent(name)
            guard let contents = try? Data(contentsOf: file), contents.count <= OpenVPNConfiguration.maximumSize else { return nil }
            return String(data: contents, encoding: .utf8)
        }
        do {
            let parsed = try OpenVPNConfiguration.parse(inlined)
            configuration = parsed
            fileName = url.lastPathComponent
            if label.isEmpty { label = url.deletingPathExtension().lastPathComponent }
            if let inline = parsed.inlineUsername { username = inline }
            if let inline = parsed.inlinePassword { password = inline }
        } catch let refused as OpenVPNConfigProblem {
            configuration = nil
            fileName = url.lastPathComponent
            problem = OpenVPNTexts.problem(refused)
        } catch {
            configuration = nil
            problem = error.localizedDescription
        }
    }

    private func save() {
        guard let configuration else { return }
        error = nil
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.needsCredentials, user.isEmpty || password.isEmpty {
            error = L("openvpn.failure.credentialsNeeded")
            return
        }
        let proxy = ProxySettings.openVPN(configuration, username: configuration.needsCredentials ? user : nil,
                                          password: configuration.needsCredentials ? password : nil)
        do {
            try proxy.validate()
        } catch {
            self.error = error.localizedDescription
            return
        }
        if let entry {
            if let problem = proxies.update(entry.id, label: label, proxy: proxy) {
                error = problem
                return
            }
            dismiss()
            return
        }
        switch proxies.addOne(label: label, proxy: proxy, kindKnown: true, check: nil) {
        case .added(let id):
            onAdded(id)
            dismiss()
        case .failed(let message):
            error = message
        }
    }
}
