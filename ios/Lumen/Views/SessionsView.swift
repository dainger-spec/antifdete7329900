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
                        Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Theme.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("accountMessage")
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
                if model.sessions.isEmpty {
                    EmptySessions { openNew() }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(shown) { session in
                    // A card is a button, not a row with a chevron (the design): it opens the session.
                    Button { model.path.append(session.id) } label: {
                        SessionCard(session: session, proxy: model.proxy(session.proxyID), lock: model.lock(session),
                                    lockedForProxy: model.lockedForProxy(session))
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .glassPane(radius: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session-\(session.name)")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .contextMenu {
                        Button(L("Изменить"), systemImage: "pencil") { editor = .edit(session.id) }
                        Button(L("Удалить"), systemImage: "trash", role: .destructive) { model.deleteSession(session.id) }
                    }
                    .swipeActions {
                        Button(L("Удалить"), systemImage: "trash", role: .destructive) { model.deleteSession(session.id) }
                        Button(L("Изменить"), systemImage: "pencil") { editor = .edit(session.id) }.tint(.gray)
                    }
                }
            }
            .listStyle(.plain)
            .eclipseScreen()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Имя, описание, метка, прокси"))
            .navigationTitle(L("Сессии"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openNew() } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("newSession")
                        .accessibilityLabel(L("Новая сессия"))
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { ProxiesView() } label: { Label(L("Прокси"), systemImage: "network").labelStyle(.titleAndIcon) }
                        .accessibilityIdentifier("proxiesButton")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { editor = .plans(because: nil) } label: { Label(L("Аккаунт"), systemImage: "person.crop.circle") }
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

extension SessionsView {
    /// A new session — or, one more profile than the plan allows, the account's screen saying why.
    func openNew() {
        editor = model.mayCreateSession ? .new
            : .plans(because: L("На этом iPhone можно держать не больше %@ профилей.", "\(model.access.maxProfiles ?? model.sessions.count)"))
    }
}

/// No session yet: what a session is, and the way to the first one.
struct EmptySessions: View {
    var create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Color.clear.frame(width: 88, height: 66).glassPane(radius: 18).offset(y: -23)
                Color.clear.frame(width: 110, height: 76).glassPane(radius: 20).offset(y: -4)
                Image(systemName: "plus").font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.text)
                    .frame(width: 132, height: 82).glassPane(radius: 22).offset(y: 15)
            }
            .frame(width: 132, height: 112)
            .accessibilityHidden(true)
            Text(L("Сессий пока нет")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 10)
            Text(L("У каждой сессии свои куки, хранилище, вкладки, история и прокси."))
                .font(.system(size: 16)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button(action: create) {
                Label(L("Новая сессия"), systemImage: "plus").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text).padding(.horizontal, 22).frame(height: 48)
            }
            .buttonStyle(.plain)
            .glassPane(radius: 24)
            .padding(.top, 14)
            .accessibilityIdentifier("newSessionEmpty")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 70)
    }
}

/// A session at a glance: name, proxy, where it exits, when it was last opened, tags, description.
struct SessionCard: View {
    let session: Session
    let proxy: ProxyEntry?
    var lock = SessionLock.open
    var lockedForProxy = true

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            InitialBadge(name: session.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if !exitText.isEmpty { Chip(text: exitText) }
                }
                Text(proxy.map { L("Прокси: %@", "\($0.displayName)") } ?? (session.boundToProxy ? L("Прокси удалён") : L("Без прокси")))
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                if case let .locked(reason) = lock {
                    // A profile that lived behind a proxy says the short thing; any other lock, its reason.
                    Label(lockedForProxy ? L("Заперт: без прокси не откроется") : L("Заперт: %@", "\(reason)"), systemImage: "lock.fill")
                        .font(.system(size: 14)).foregroundStyle(Theme.warn)
                }
                Text(openedText).font(.system(size: 14)).foregroundStyle(Theme.tertiary)
                if !session.notes.isEmpty {
                    Text(session.notes).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                if !session.tags.isEmpty {
                    Text(session.tags.map { "#\($0)" }.joined(separator: " ")).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var exitText: String {
        guard let proxy else { return "" }
        guard let check = proxy.check else { return L("не проверен") }
        guard check.alive, let country = check.country else { return L("недоступен") }
        return "\(CountryLocale.flag(country)) \(country)"
    }

    private var openedText: String {
        guard let date = session.lastOpenedAt else { return L("Ещё не открывали") }
        return L("Открывали ") + date.formatted(.relative(presentation: .named))
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
                Section(L("Сессия")) {
                    TextField(L("Имя"), text: $name).accessibilityIdentifier("sessionName")
                    TextField(L("Описание"), text: $notes).accessibilityIdentifier("sessionNotes")
                    TextField(L("Метки через запятую"), text: $tags).accessibilityIdentifier("sessionTags")
                        .textInputAutocapitalization(.never)
                }
                .glassRow()
                if sessionID != nil {
                    Section {
                        Button(L("Удалить сессию"), role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("deleteSession")
                    } footer: {
                        Text(L("Удаляются куки, хранилище, кэш, вкладки и история этой сессии."))
                    }
                    .glassRow()
                }
            }
            .eclipseSheet()
            .navigationTitle(sessionID == nil ? L("Новая сессия") : L("Сессия"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить")) {
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
            .confirmationDialog(L("Удалить сессию со всеми её данными?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("Удалить"), role: .destructive) {
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
