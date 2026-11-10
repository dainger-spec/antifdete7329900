import LumenCore
import SwiftUI

/// The list of sessions: a card each, search over names, descriptions, tags and proxies.
struct SessionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var editor: EditorTarget?

    enum EditorTarget: Identifiable {
        case new
        case edit(UUID)
        /// The plan; `because`: what the plan did not allow.
        case plans(because: String?)
        var id: String {
            switch self {
            case .new: return "new"
            case let .edit(id): return id.uuidString
            case .plans: return "plans"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                let shown = model.filteredSessions(query)
                // What the account says that the person must read (the iPhone unlinked, no answer of
                // the server, the paid period over): one line, the plan behind it.
                if let message = model.accountMessage {
                    Button { editor = .plans(because: nil) } label: {
                        Label(message, systemImage: "exclamationmark.triangle").font(.subheadline)
                    }
                    .accessibilityIdentifier("accountMessage")
                }
                if model.sessions.isEmpty {
                    ContentUnavailableView("Сессий пока нет", systemImage: "rectangle.stack.badge.plus",
                                           description: Text("У каждой сессии свои куки, хранилище, вкладки, история и прокси."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(shown) { session in
                    NavigationLink(value: session.id) {
                        SessionCard(session: session, proxy: model.proxy(session.proxyID), lock: model.lock(session),
                                    lockedForProxy: model.lockedForProxy(session))
                    }
                    .accessibilityIdentifier("session-\(session.name)")
                    .contextMenu {
                        Button("Изменить", systemImage: "pencil") { editor = .edit(session.id) }
                        Button("Удалить", systemImage: "trash", role: .destructive) { model.deleteSession(session.id) }
                    }
                    .swipeActions {
                        Button("Удалить", systemImage: "trash", role: .destructive) { model.deleteSession(session.id) }
                        Button("Изменить", systemImage: "pencil") { editor = .edit(session.id) }.tint(.blue)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Имя, описание, метка, прокси")
            .navigationTitle("Сессии")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // One more profile than the plan allows: the plans, saying why.
                        let target: EditorTarget = model.mayCreateSession ? .new
                            : .plans(because: "На этом iPhone можно держать не больше \(model.access.maxProfiles ?? model.sessions.count) профилей.")
                        editor = target
                    } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("newSession")
                        .accessibilityLabel("Новая сессия")
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { ProxiesView() } label: { Label("Прокси", systemImage: "network") }
                        .accessibilityIdentifier("proxiesButton")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { editor = .plans(because: nil) } label: { Label("Аккаунт", systemImage: "person.crop.circle") }
                        .accessibilityIdentifier("plansButton")
                }
                ToolbarItem(placement: .topBarTrailing) { DebugProbeLink() }
            }
            .navigationDestination(for: UUID.self) { id in
                SessionScreen(sessionID: id)
            }
            .sheet(item: $editor) { target in
                switch target {
                case .new: SessionEditor(sessionID: nil)
                case let .edit(id): SessionEditor(sessionID: id)
                case let .plans(because): PlansView(because: because)
                }
            }
        }
    }
}

/// A session at a glance: name, proxy, where it exits, when it was last opened, tags, description.
struct SessionCard: View {
    let session: Session
    let proxy: ProxyEntry?
    var lock = SessionLock.open
    var lockedForProxy = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.name).font(.headline)
                Spacer()
                Text(exitText).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(proxy.map { "Прокси: \($0.displayName)" } ?? (session.boundToProxy ? "Прокси удалён" : "Без прокси"))
                .font(.subheadline).foregroundStyle(.secondary)
            if case let .locked(reason) = lock {
                // A profile that lived behind a proxy says the short thing; any other lock, its reason.
                Label(lockedForProxy ? "Заперт: без прокси не откроется" : "Заперт: \(reason)", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(openedText).font(.caption).foregroundStyle(.secondary)
            if !session.notes.isEmpty {
                Text(session.notes).font(.caption).lineLimit(1)
            }
            if !session.tags.isEmpty {
                Text(session.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    private var exitText: String {
        guard let proxy else { return "" }
        guard let check = proxy.check else { return "не проверен" }
        guard check.alive, let country = check.country else { return "недоступен" }
        return "\(CountryLocale.flag(country)) \(country)"
    }

    private var openedText: String {
        guard let date = session.lastOpenedAt else { return "Ещё не открывали" }
        return "Открывали " + date.formatted(.relative(presentation: .named))
    }
}

/// Create or change a session's name, description and tags; delete it.
struct SessionEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID?
    @State private var name = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Сессия") {
                    TextField("Имя", text: $name).accessibilityIdentifier("sessionName")
                    TextField("Описание", text: $notes).accessibilityIdentifier("sessionNotes")
                    TextField("Метки через запятую", text: $tags).accessibilityIdentifier("sessionTags")
                        .textInputAutocapitalization(.never)
                }
                if sessionID != nil {
                    Section {
                        Button("Удалить сессию", role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("deleteSession")
                    } footer: {
                        Text("Удаляются куки, хранилище, кэш, вкладки и история этой сессии.")
                    }
                }
            }
            .navigationTitle(sessionID == nil ? "Новая сессия" : "Сессия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if let sessionID {
                            model.updateSession(sessionID, name: name, notes: notes, tags: tags)
                        } else {
                            model.createSession(name: name, notes: notes, tags: tags)
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("saveSession")
                }
            }
            .confirmationDialog("Удалить сессию со всеми её данными?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let sessionID { model.deleteSession(sessionID) }
                    dismiss()
                }
                .accessibilityIdentifier("confirmDelete")
            }
            .onAppear {
                guard let id = sessionID, let session = model.session(id) else { return }
                name = session.name
                notes = session.notes
                tags = session.tags.joined(separator: ", ")
            }
        }
    }
}
