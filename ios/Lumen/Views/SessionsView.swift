import LumenCore
import SwiftUI
import UIKit

/// The list of sessions («Приборная панель», k-list): a large title, search under it, the account's
/// notice above the list, the sessions as rows — the one opened last on top.
struct SessionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var editor: EditorTarget?
    /// The session whose deletion is being confirmed (from its context menu).
    @State private var deleting: Session?
    @Namespace private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// At the accessibility sizes the search's long hint does not fit its field (the audit, run 108).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// The sessions shown: the search's, the one used last first (a new one counts from its making).
    private var shown: [Session] {
        model.filteredSessions(query).sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                if let message = model.accountMessage, !searching {
                    Section {
                        Button { editor = .plans(because: nil) } label: {
                            NoticeRow(text: message, dismiss: dismissible(message) ? { model.dismissEndingNotice() } : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("accountMessage")
                    }
                }
                if !shown.isEmpty {
                    Section {
                        ForEach(shown) { session in
                            row(session)
                        }
                    } header: {
                        if TitleProbe.off != "noheader" { Text(searching ? Count.sessions(shown.count) : L("Недавние")) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The list starts at its top: the large title and the search under it (run 108: with rows
            // the title came collapsed into the bar).
            .defaultScrollAnchor(.top)
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView {
                        Label(L("Сессий пока нет"), systemImage: "square.on.square")
                    } description: {
                        Text(L("У каждой сессии свои куки, хранилище сайтов, вкладки, история и прокси."))
                    } actions: {
                        Button(L("Новая сессия")) { openNew() }
                            .buttonStyle(.borderedProminent).tint(Theme.accentFill).controlSize(.large)
                            .accessibilityIdentifier("newSessionEmpty")
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView {
                        Label(L("Ничего не найдено"), systemImage: "magnifyingglass")
                    } description: {
                        Text(L("Нет сессий с «%@». Проверьте написание или ищите по прокси.", query))
                    }
                }
            }
            .unlessProbe("nosearch") {
                $0.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: dynamicTypeSize.isAccessibilitySize ? L("Поиск") : L("Имя, описание, метка, прокси"))
            }
            .navigationTitle(L("Сессии"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    NavigationLink { ProxiesView() } label: { Image(systemName: "network") }
                        .accessibilityIdentifier("proxiesButton")
                        .accessibilityLabel(L("Прокси"))
                    Button { editor = .plans(because: nil) } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityIdentifier("plansButton")
                        .accessibilityLabel(L("Аккаунт"))
                }
                ToolbarItem(placement: .topBarTrailing) { DebugProbeLink() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openNew() } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("newSession")
                        .accessibilityLabel(L("Новая сессия"))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                SessionScreen(sessionID: id)
                    .modifier(ZoomFrom(id: id, namespace: zoom, enabled: !reduceMotion))
            }
            .sheet(item: $editor) { target in
                switch target {
                case .new: SessionEditor(sessionID: nil)
                case let .edit(id): SessionEditor(sessionID: id)
                case let .plans(because): PlansView(because: because)
                }
            }
            .confirmationDialog(L("Удалить сессию со всеми её данными?"), isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { session in
                Button(L("Удалить сессию"), role: .destructive) { model.deleteSession(session.id) }
                    .accessibilityIdentifier("confirmDelete")
                Button(L("Отмена"), role: .cancel) {}
            } message: { session in
                Text(L("Куки, хранилище сайтов, вкладки и история «%@» будут удалены. Это нельзя отменить.", session.name))
            }
        }
    }

    private func row(_ session: Session) -> some View {
        Button { model.path.append(session.id) } label: {
            SessionRow(session: session, proxy: model.proxy(session.proxyID), lock: model.lock(session),
                       lockedForProxy: model.lockedForProxy(session),
                       checking: session.proxyID.map { model.checking.contains($0) } ?? false)
        }
        .buttonStyle(.plain)
        .unlessProbe("nozoom") { $0.matchedTransitionSource(id: session.id, in: zoom) }
        .accessibilityIdentifier("session-\(session.name)")
        .unlessProbe("nomenu") { $0.contextMenu {
            Button(L("Изменить"), systemImage: "pencil") { editor = .edit(session.id) }
            Button(L("Скопировать имя"), systemImage: "doc.on.doc") { UIPasteboard.general.string = session.name }
            Divider()
            Button(L("Удалить"), systemImage: "trash", role: .destructive) { deleting = session }
        }
        .swipeActions {
            Button(L("Удалить"), systemImage: "trash", role: .destructive) { deleting = session }
            Button(L("Изменить"), systemImage: "pencil") { editor = .edit(session.id) }.tint(Color(.systemGray))
        } }
    }

    /// The notice of the period's end may be closed (§8.5); the others stay while they are true.
    private func dismissible(_ message: String) -> Bool {
        model.endingNotice != nil && message == model.endingNotice?.text
    }
}

/// Opening a session: its row grows into the browser (iOS 18's zoom), and shrinks back on the way out.
/// With "Reduce Motion" the system's plain transition.
struct ZoomFrom: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
    }
}

extension SessionsView {
    /// A new session — or, one more profile than the plan allows, the account's screen saying why.
    func openNew() {
        editor = model.mayCreateSession ? .new
            : .plans(because: L("На этом iPhone можно держать не больше %@ профилей.", "\(model.access.maxProfiles ?? model.sessions.count)"))
    }
}

/// Create or change a session's name, description and tags; delete it (k-keyboard).
struct SessionEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID?
    @State private var name = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Имя"), text: $name).accessibilityIdentifier("sessionName")
                        .focused($nameFocused)
                    TextField(L("Описание"), text: $notes).accessibilityIdentifier("sessionNotes")
                    TextField(L("Метки через запятую"), text: $tags).accessibilityIdentifier("sessionTags")
                        .textInputAutocapitalization(.never)
                } header: {
                    Text(L("Сессия"))
                } footer: {
                    Text(L("У сессии свои куки, хранилище сайтов, вкладки и история."))
                }
                if sessionID != nil {
                    Section {
                        Button(L("Удалить сессию"), role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("deleteSession")
                    } footer: {
                        Text(L("Удаляются куки, хранилище, кэш, вкладки и история этой сессии."))
                    }
                }
            }
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("saveSession")
                }
            }
            .confirmationDialog(L("Удалить сессию со всеми её данными?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("Удалить сессию"), role: .destructive) {
                    if let sessionID { model.deleteSession(sessionID) }
                    dismiss()
                }
                .accessibilityIdentifier("confirmDelete")
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Куки, хранилище сайтов, вкладки и история «%@» будут удалены. Это нельзя отменить.", name))
            }
            .onAppear {
                guard let id = sessionID, let session = model.session(id) else {
                    nameFocused = true
                    return
                }
                name = session.name
                notes = session.notes
                tags = session.tags.joined(separator: ", ")
            }
        }
        .presentationDetents([.large])
    }
}
