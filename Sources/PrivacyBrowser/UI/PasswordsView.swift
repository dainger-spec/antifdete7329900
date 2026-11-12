import AppKit
import BrowserCore
import SwiftUI

/// A profile's saved passwords, as Safari's Passwords: locked until the master password is entered
/// again (Safari asks for Touch ID or the login password), then a searchable list of website and
/// user name; the selected login shows its password on request, can be copied, edited and
/// deleted; new ones can be added. A login can hold what makes its one-time codes (two-step
/// sign-in): the code that stands now is shown with the time it has left, and one click copies it.
/// Below the list, the websites passwords are never saved for.
/// Changes apply at once, also to the running profile (it shares this vault).
struct PasswordListView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

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
        /// What makes the login's one-time codes, and what is typed for it and not added yet.
        var totp: OneTimeCode?
        var codeInput = ""
        /// Why Save did not take what is typed for the code: said at its field until it changes.
        var codeProblem: String?
    }

    /// The moment the one-time code is shown for, for a picture that must not change (the snapshots).
    var codeDate: Date?
    /// Opens unlocked on these logins, the first chosen (the snapshots) — `sampleEditing`: the first
    /// without a one-time code, being edited.
    var sample: [PasswordEntry]?
    var sampleEditing = false

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
                    // While a login is being typed, Esc is its Cancel: it closed the whole sheet,
                    // and the master password was asked again to come back.
                    .keyboardShortcut(draft == nil ? KeyboardShortcut.cancelAction : nil)
            })
        }
        .sheetFrame(width: 780, height: 620)
        .background(Theme.raised)
        .onAppear {
            guard let sample, !unlocked else { return }
            entries = sample
            selection = sample.first?.id
            unlocked = true
            // The editor's picture is of a code being added: the sample login that has none
            // (one that has a code, opened without it, would be a code about to be removed).
            if sampleEditing, let entry = sample.first(where: { $0.totp == nil }) ?? sample.first {
                selection = entry.id
                revealed = true
                draft = Draft(id: entry.id, website: entry.origin, username: entry.username, password: entry.password,
                              note: entry.note ?? "", totp: entry.totp, codeInput: "")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PasswordVault.didChangeNotification)) { note in
            if unlocked, note.userInfo?["profileID"] as? UUID == profile.id { reload() }
        }
        .confirmationDialog(L("passwords.delete.title"), isPresented: Binding(get: { pendingDelete != nil },
                                                                             set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button(L("common.delete"), role: .destructive) { delete(entry) }
        } message: { entry in
            // A login's one-time code is deleted with it, and without that code the site lets
            // nobody in: the question says so.
            Text(String(format: entry.totp == nil ? L("passwords.delete.message") : L("passwords.delete.messageWithCode"),
                        entry.username.isEmpty ? L("passwords.noUsername") : entry.username, entry.host))
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
                SecureField(L("passwords.locked.field"), text: $masterPassword, prompt: Text(verbatim: ""))
                    .lumenField(L("passwords.locked.field"), isEmpty: masterPassword.isEmpty)
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
                            if entry.isConflictVersion {
                                Label(String(format: L("passwords.conflict.badgeNumbered"), conflictNumber(of: entry)),
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(Theme.warning)
                            }
                        }
                        if entry.totp != nil {
                            Spacer(minLength: 4)
                            // The login has a one-time code.
                            Image(systemName: "lock.rotation")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .help(L("passwords.code.title"))
                                .accessibilityLabel(L("passwords.code.title"))
                        }
                    }
                    // The design's selected row: the system's, under the app's white tint, was white
                    // behind white words.
                    .listRowBackground(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selection == entry.id ? Theme.rowSelected : Color.clear))
                    .background(SystemListHighlightOff().accessibilityHidden(true))
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
            // The login scrolls, the buttons stay, as in the editor: a code's card under a long
            // note, or a kept version's explanation, is more than the sheet is tall on a small screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entry.isConflictVersion {
                        Label(L("passwords.conflict.explanation"), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    row(L("passwords.field.website"), entry.origin, copy: entry.origin)
                    row(L("passwords.field.username"), entry.username.isEmpty ? L("passwords.noUsername") : entry.username,
                        copy: entry.username.isEmpty ? nil : entry.username)
                    // A login that is a one-time code alone has no password to show.
                    if !entry.password.isEmpty {
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
                    }
                    if let generator = entry.totp {
                        OneTimeCodeCard(generator: generator, at: codeDate)
                            .padding(.vertical, 2)
                    } else if !entry.isConflictVersion {
                        // Seen on the login itself, not only behind Edit: opens the editor, where the code is added.
                        Button { edit(entry) } label: { Label(L("passwords.code.addToLogin"), systemImage: "lock.rotation") }
                            .buttonStyle(.lumenGhost)
                    }
                    if let note = entry.note, !note.isEmpty { row(L("passwords.field.note"), note, copy: nil) }
                    Divider()
                    // Which Mac made this version, and when by that Mac's clock: beside a version kept after a
                    // conflict, what the person tells the two apart by.
                    Text(entry.device.map { String(format: L("passwords.updatedOn"), $0, entry.updatedAt.shown(date: .abbreviated, time: .shortened)) }
                         ?? String(format: L("passwords.updated"), entry.updatedAt.shown(date: .abbreviated, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                    if let used = entry.lastUsedAt {
                        Text(String(format: L("passwords.lastUsed"), used.shown(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if entry.isConflictVersion {
                    // A version kept after a conflict is chosen, or deleted; it is not edited.
                    Button(L("passwords.conflict.keep")) { keepConflictVersion(entry) }
                        .buttonStyle(.lumenSecondary)
                } else {
                    Button(L("passwords.edit")) { edit(entry) }
                        .buttonStyle(.lumenSecondary)
                }
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

    /// Opens the login in the editor, its password shown.
    private func edit(_ entry: PasswordEntry) {
        revealed = true
        draft = Draft(id: entry.id, website: entry.origin, username: entry.username,
                      password: entry.password, note: entry.note ?? "", totp: entry.totp)
    }

    private func editor(_ initial: Draft) -> some View {
        let binding = Binding(get: { draft ?? initial }, set: { draft = $0 })
        // The code the login is saved with: the code's part says what Save would change.
        let saved: OneTimeCode? = initial.id.flatMap { id in entries.first(where: { $0.id == id })?.totp }
        return VStack(alignment: .leading, spacing: 10) {
            Text(initial.id == nil ? L("passwords.addTitle") : L("passwords.editTitle"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
            // The fields scroll, the buttons stay: with the one-time code's part open, a login
            // has more to it than the sheet is tall on a small screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
            TextField(L("passwords.placeholder.origin"), text: binding.website, prompt: Text(verbatim: ""))
                .lumenField(L("passwords.placeholder.origin"), isEmpty: binding.wrappedValue.website.isEmpty)
            TextField(L("passwords.placeholder.username"), text: binding.username, prompt: Text(verbatim: ""))
                .lumenField(L("passwords.placeholder.username"), isEmpty: binding.wrappedValue.username.isEmpty)
            HStack {
                Group {
                    if revealed {
                        TextField(L("passwords.placeholder.password"), text: binding.password, prompt: Text(verbatim: ""))
                    } else {
                        SecureField(L("passwords.placeholder.password"), text: binding.password, prompt: Text(verbatim: ""))
                    }
                }
                .lumenField(L("passwords.placeholder.password"), isEmpty: binding.wrappedValue.password.isEmpty)
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(LumenIconButtonStyle())
            }
            TextField(L("passwords.placeholder.note"), text: binding.note, prompt: Text(verbatim: ""), axis: .vertical)
                .lineLimit(2...4)
                .lumenField(L("passwords.placeholder.note"), isEmpty: binding.wrappedValue.note.isEmpty, height: nil)
            OneTimeCodeSetup(generator: binding.totp, input: binding.codeInput, saved: saved,
                             saveProblem: binding.wrappedValue.codeProblem,
                             onHelp: {
                                 model.helpTopic = .codes
                                 openWindow(id: "help")
                             })
                }
                .padding(1) // the fields' focus rings, which a scroll view clips at its edge
            }
            HStack {
                Button(L("common.cancel")) { draft = nil }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("common.save")) { save(binding.wrappedValue) }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(binding.wrappedValue.website.isEmpty
                              || (binding.wrappedValue.password.isEmpty && binding.wrappedValue.totp == nil
                                  && binding.wrappedValue.codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        // What Save refused is said until the secret is typed again or a code is added another way.
        .onChange(of: draft?.codeInput) { _, _ in draft?.codeProblem = nil }
        .onChange(of: draft?.totp) { _, _ in draft?.codeProblem = nil }
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
        // What an earlier attempt was refused for does not stand under this one.
        error = nil
        guard let origin = Self.origin(from: draft.website) else {
            error = L("passwords.error.origin")
            return
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // A secret typed and not added with its button is added by Save; one that is not a
        // secret stops the save and says why at its field, rather than be dropped.
        var generator = draft.totp
        if generator == nil, !draft.codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch OneTimeCodeInput.read(draft.codeInput) {
            case let .generator(found): generator = found
            case let .problem(message):
                self.draft?.codeProblem = message
                return
            }
        }
        do {
            let vault = try model.passwordVault(for: profile.id)
            if let id = draft.id, var entry = vault.entry(id: id) {
                entry.origin = origin
                entry.username = draft.username
                entry.password = draft.password
                entry.note = note.isEmpty ? nil : note
                entry.totp = generator
                try vault.update(entry)
                selection = id
            } else {
                guard !vault.allEntries().contains(where: { !$0.isConflictVersion && $0.origin == origin && $0.username == draft.username }) else {
                    throw PasswordVaultError.duplicate
                }
                let entry = PasswordEntry(origin: origin, username: draft.username, password: draft.password,
                                          note: note.isEmpty ? nil : note, totp: generator)
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

    /// "Other version 2": the versions kept beside one login, numbered by when they were made (by the
    /// clocks of the Macs that made them: an order to tell them apart by, nothing more).
    private func conflictNumber(of entry: PasswordEntry) -> Int {
        let kept = entries.filter { $0.isConflictVersion && $0.conflictOf == entry.conflictOf }
            .sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }
        return (kept.firstIndex { $0.id == entry.id } ?? 0) + 1
    }

    /// The version kept after a conflict becomes the login's password (the other version goes).
    private func keepConflictVersion(_ entry: PasswordEntry) {
        do {
            try model.passwordVault(for: profile.id).keepConflictVersion(entry.id)
            selection = entry.conflictOf ?? entry.id
            reload()
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
