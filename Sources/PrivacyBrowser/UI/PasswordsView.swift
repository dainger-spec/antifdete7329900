import AppKit
import BrowserCore
import SwiftUI

/// A profile's saved passwords, as Safari's Passwords: locked until the master password is entered
/// again (Safari asks for Touch ID or the login password), then a searchable list of website and
/// user name; the selected login shows its password on request, can be copied, edited and
/// deleted; new ones can be added. Below the list, the websites passwords are never saved for.
/// Changes apply at once, also to the running profile (it shares this vault).
struct PasswordListView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var unlocked = false
    @State private var masterPassword = ""
    @State private var checking = false
    @State private var wrongPassword = false

    @State private var entries: [PasswordEntry] = []
    @State private var neverSaved: [String] = []
    @State private var search = ""
    @State private var selection: UUID?
    @State private var draft: Draft?
    @State private var revealed = false
    @State private var pendingDelete: PasswordEntry?
    @State private var error: String?

    /// A login being edited (or added: `id` nil).
    struct Draft: Equatable {
        var id: UUID?
        var website = ""
        var username = ""
        var password = ""
        var note = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(String(format: L("passwords.title"), profile.name))
                    .font(.lumenSheetTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if unlocked {
                    LumenSearchField(text: $search, prompt: L("passwords.search"))
                        .frame(width: 220)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Group {
                if unlocked { content } else { locked }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
            SheetFooter(leading: {
                if let error { Text(error).foregroundStyle(Theme.danger).font(.lumenSecondary).lineLimit(2) }
            }, buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
            })
        }
        .frame(width: 780, height: 560)
        .background(Theme.raised)
        .onReceive(NotificationCenter.default.publisher(for: PasswordVault.didChangeNotification)) { note in
            if unlocked, note.userInfo?["profileID"] as? UUID == profile.id { reload() }
        }
        .confirmationDialog(L("passwords.delete.title"), isPresented: Binding(get: { pendingDelete != nil },
                                                                             set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button(L("common.delete"), role: .destructive) { delete(entry) }
        } message: { entry in
            Text(String(format: L("passwords.delete.message"), entry.username.isEmpty ? L("passwords.noUsername") : entry.username,
                        entry.host))
        }
    }

    // MARK: Locked

    private var locked: some View {
        VStack(spacing: 12) {
            Spacer()
            IconBadge(symbol: "lock", tint: Theme.textSecondary, size: 44)
                .padding(.bottom, 4)
            Text(L("passwords.locked.title")).font(.lumenSheetTitle).foregroundStyle(Theme.textPrimary)
            Text(String(format: L("passwords.locked.message"), profile.name))
                .font(.lumenBody).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                SecureField(L("passwords.locked.field"), text: $masterPassword)
                    .lumenField()
                    .frame(width: 260)
                    .onSubmit(unlock)
                Button(L("passwords.locked.unlock"), action: unlock)
                    .buttonStyle(LumenButtonStyle(kind: .primary, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(masterPassword.isEmpty || checking)
                if checking { ProgressView().controlSize(.small) }
            }
            .padding(.top, 6)
            if wrongPassword { Text(L("passwords.locked.wrong")).foregroundStyle(Theme.danger).font(.lumenSecondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func unlock() {
        guard !masterPassword.isEmpty, !checking else { return }
        checking = true
        Task {
            let ok = await model.verifyMasterPassword(masterPassword)
            checking = false
            masterPassword = ""
            wrongPassword = !ok
            if ok {
                unlocked = true
                reload()
            }
        }
    }

    // MARK: Unlocked

    private var filtered: [PasswordEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.origin.lowercased().contains(query) || $0.username.lowercased().contains(query) }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                List(filtered, selection: $selection) { entry in
                    HStack {
                        IconBadge(symbol: "key.fill", size: 26)
                        VStack(alignment: .leading) {
                            Text(entry.host)
                            Text(entry.username.isEmpty ? L("passwords.noUsername") : entry.username)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .overlay {
                    if filtered.isEmpty {
                        Text(entries.isEmpty ? L("passwords.empty") : L("passwords.noMatches")).foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.raisedInset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                HStack {
                    Button {
                        selection = nil
                        revealed = true
                        draft = Draft()
                    } label: { Label(L("passwords.add"), systemImage: "plus") }
                    .buttonStyle(.lumenGhost)
                    Spacer()
                }
                if !neverSaved.isEmpty { neverSavedList }
            }
            .frame(width: 300)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(fill: Theme.raisedInset)
        }
        // Choosing another login ends an edit (a new one, too); "Add Password" clears the selection itself.
        .onChange(of: selection) { _, newValue in
            if newValue != nil, draft?.id != newValue {
                draft = nil
                revealed = false
            }
        }
    }

    private var neverSavedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("passwords.never.title")).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(neverSaved, id: \.self) { site in
                        HStack {
                            Text(WebOrigin(site)?.host ?? site).font(.caption)
                            Spacer()
                            Button(L("passwords.never.remove")) { removeNeverSaved(site) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
            .frame(maxHeight: 80)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let draft {
            editor(draft)
        } else if let id = selection, let entry = entries.first(where: { $0.id == id }) {
            details(entry)
        } else {
            Text(L("passwords.selectHint")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ entry: PasswordEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            row(L("passwords.field.website"), entry.origin, copy: entry.origin)
            row(L("passwords.field.username"), entry.username.isEmpty ? L("passwords.noUsername") : entry.username,
                copy: entry.username.isEmpty ? nil : entry.username)
            HStack(alignment: .firstTextBaseline) {
                Text(L("passwords.field.password")).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                Text(revealed ? entry.password : String(repeating: "•", count: 10))
                    .font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(L(revealed ? "passwords.hide" : "passwords.show"))
                Button { Self.copy(entry.password, concealed: true) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("passwords.copy"))
            }
            if let note = entry.note, !note.isEmpty { row(L("passwords.field.note"), note, copy: nil) }
            Divider()
            Text(String(format: L("passwords.updated"), entry.updatedAt.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
            if let used = entry.lastUsedAt {
                Text(String(format: L("passwords.lastUsed"), used.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button(L("passwords.edit")) {
                    revealed = true
                    draft = Draft(id: entry.id, website: entry.origin, username: entry.username,
                                  password: entry.password, note: entry.note ?? "")
                }
                .buttonStyle(.lumenSecondary)
                Spacer()
                Button(L("common.delete"), role: .destructive) { pendingDelete = entry }
                    .buttonStyle(.lumenDestructive)
            }
        }
    }

    private func row(_ label: String, _ value: String, copy: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3)
            Spacer()
            if let copy {
                Button { Self.copy(copy, concealed: false) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("passwords.copy"))
            }
        }
    }

    private func editor(_ initial: Draft) -> some View {
        let binding = Binding(get: { draft ?? initial }, set: { draft = $0 })
        return VStack(alignment: .leading, spacing: 10) {
            Text(initial.id == nil ? L("passwords.addTitle") : L("passwords.editTitle"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
            TextField(L("passwords.placeholder.origin"), text: binding.website).lumenField()
            TextField(L("passwords.placeholder.username"), text: binding.username).lumenField()
            HStack {
                Group {
                    if revealed {
                        TextField(L("passwords.placeholder.password"), text: binding.password)
                    } else {
                        SecureField(L("passwords.placeholder.password"), text: binding.password)
                    }
                }
                .lumenField()
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(LumenIconButtonStyle())
            }
            TextField(L("passwords.placeholder.note"), text: binding.note, axis: .vertical)
                .lineLimit(2...4)
                .lumenField(height: nil)
            Spacer()
            HStack {
                Button(L("common.cancel")) { draft = nil }
                    .buttonStyle(.lumenSecondary)
                Spacer()
                Button(L("common.save")) { save(binding.wrappedValue) }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(binding.wrappedValue.password.isEmpty || binding.wrappedValue.website.isEmpty)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        do {
            entries = try model.passwordVault(for: profile.id).allEntries()
            neverSaved = model.neverSavedSites(for: profile.id)
            if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "example.com" is taken as https://example.com.
    private static func origin(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URL(string: withScheme).flatMap(PasswordEntry.normalizedOrigin(for:))
    }

    private func save(_ draft: Draft) {
        guard let origin = Self.origin(from: draft.website) else {
            error = L("passwords.error.origin")
            return
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let vault = try model.passwordVault(for: profile.id)
            if let id = draft.id, var entry = vault.entry(id: id) {
                entry.origin = origin
                entry.username = draft.username
                entry.password = draft.password
                entry.note = note.isEmpty ? nil : note
                try vault.update(entry)
                selection = id
            } else {
                guard !vault.allEntries().contains(where: { $0.origin == origin && $0.username == draft.username }) else {
                    throw PasswordVaultError.duplicate
                }
                let entry = PasswordEntry(origin: origin, username: draft.username, password: draft.password,
                                          note: note.isEmpty ? nil : note)
                try vault.upsert(entry)
                selection = entry.id
            }
            self.draft = nil
            revealed = false
            reload()
        } catch PasswordVaultError.duplicate {
            error = L("passwords.error.duplicate")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: PasswordEntry) {
        do {
            try model.passwordVault(for: profile.id).remove(id: entry.id)
            if selection == entry.id { selection = nil }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeNeverSaved(_ site: String) {
        do {
            try model.removeNeverSavedSite(site, for: profile.id)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Copies to the clipboard; a password is marked as concealed (clipboard managers skip it).
    private static func copy(_ value: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        if concealed { pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }
}
