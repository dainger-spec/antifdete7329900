import Foundation

/// The list of sessions and what a person does with it: create, rename, describe, tag, search,
/// delete. Every change is written at once.
public final class SessionCatalog {
    public private(set) var sessions: [Session]
    /// The Mac's profiles whose sessions were deleted on this iPhone: the sync makes none of them a
    /// session again. Deleting a session made from the vault stops that profile's sync to this
    /// iPhone — the profile on the Mac is not touched — until the person brings them back
    /// (`syncAgainHere`).
    public private(set) var notSyncedHere: Set<UUID>
    private let store: LumenStore

    public init(store: LumenStore) {
        self.store = store
        let catalogue = store.loadCatalogue()
        sessions = catalogue.sessions
        notSyncedHere = catalogue.notSyncedHere
    }

    /// Name, description and tags are held to the Mac's limits (`SessionLimits`), for every session.
    @discardableResult
    public func create(name: String, notes: String = "", tags: [String] = []) -> Session {
        let trimmed = SessionLimits.name(name)
        let session = Session(name: trimmed.isEmpty ? nextDefaultName() : trimmed, notes: SessionLimits.notes(notes),
                              tags: Self.normalizedTags(tags))
        sessions.append(session)
        save()
        return session
    }

    public func rename(_ id: UUID, to name: String, at date: Date = Date()) {
        let trimmed = SessionLimits.name(name)
        guard !trimmed.isEmpty, !Faults.isActive(.renameIgnored) else { return }
        edit(id, at: date) { $0.name = trimmed }
    }

    public func setNotes(_ id: UUID, _ notes: String, at date: Date = Date()) {
        guard !Faults.isActive(.notesNotSaved) else { return }
        edit(id, at: date) { $0.notes = SessionLimits.notes(notes) }
    }

    public func setTags(_ id: UUID, _ tags: [String], at date: Date = Date()) {
        edit(id, at: date) { $0.tags = Self.normalizedTags(tags) }
    }

    /// A proxy given to a session binds it to proxies for good; taking it away leaves it bound (locked)
    /// unless the person asked for that on purpose (`unbind`).
    public func setProxy(_ id: UUID, proxyID: UUID?, unbind: Bool = false) {
        update(id) {
            $0.proxyID = proxyID
            if proxyID != nil { $0.boundToProxy = true } else if unbind { $0.boundToProxy = false }
        }
    }

    public func setSettings(_ id: UUID, _ settings: SessionSettings) {
        guard !Faults.isActive(.settingsNotSaved) else { return }
        update(id) { $0.settings = settings }
    }

    public func markOpened(_ id: UUID, at date: Date = Date()) {
        update(id) { $0.lastOpenedAt = date }
    }

    /// Removes the session from the list and its files; the caller removes its WebKit store. A
    /// session made from the Mac's vault is not made again by the next sync (`notSyncedHere`).
    public func delete(_ id: UUID) {
        if let profileID = session(id)?.syncedProfileID { notSyncedHere.insert(profileID) }
        sessions.removeAll { $0.id == id }
        store.removeSessionFiles(id)
        save()
    }

    /// The Mac's profiles deleted here come back as sessions at the next sync (new ones: their
    /// cookies come from the vault, as a profile's first time here).
    public func syncAgainHere() {
        guard !notSyncedHere.isEmpty else { return }
        notSyncedHere = []
        save()
    }

    /// A proxy removed from the list leaves its sessions without one (never with a dangling id).
    public func forgetProxy(_ proxyID: UUID) {
        for index in sessions.indices where sessions[index].proxyID == proxyID { sessions[index].proxyID = nil }
        save()
    }

    public func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    /// The list's search: every word must be found in the name, the description, a tag or the
    /// proxy's name, ignoring case and diacritics.
    public func filter(_ query: String, proxyName: (UUID) -> String? = { _ in nil }) -> [Session] {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard !words.isEmpty else { return sessions }
        return sessions.filter { session in
            var fields = [session.name, session.notes]
            if !Faults.isActive(.searchIgnoresTags) { fields += session.tags }
            if let id = session.proxyID, let name = proxyName(id) { fields.append(name) }
            let haystack = fields.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// "work, Ads ,work" → ["work", "Ads"]: trimmed, no empty ones, no repeats (ignoring case), held
    /// to the Mac's limits (`SessionLimits.tags`).
    public static func normalizedTags(_ tags: [String]) -> [String] {
        SessionLimits.tags(tags)
    }

    private func nextDefaultName() -> String {
        var n = sessions.count + 1
        while sessions.contains(where: { $0.name == L("Сессия %@", "\(n)") }) { n += 1 }
        return L("Сессия %@", "\(n)")
    }

    /// The Mac's profiles as the sync read them (step 3 of ios/SYNC_PLAN.md): each one a session here,
    /// found again by its id in the vault — made the first time, its name, description and tags the
    /// Mac's after that. A profile with a proxy gets it (`proxyID` gives the entry for it, asked with
    /// the session as it is) and is bound to proxies at once; one whose proxy the iPhone cannot use
    /// comes with none, and bound: locked until a proxy is chosen (decision 6). The iPhone's own
    /// sessions are not touched; a profile the Mac no longer has stays here; one whose session was
    /// deleted here is not made again (`notSyncedHere`). `keepingEditsOf`: the profiles whose edit
    /// made here the vault refused — their sessions keep it, still to go, and the name, description
    /// and tags of the vault are not put over it. Returns the sessions made.
    @discardableResult
    public func applySynced(_ profiles: [SyncedProfile], keepingEditsOf kept: Set<UUID> = [],
                            proxyID: (SyncedProfile.Proxy, Session) -> UUID) -> [Session] {
        var made: [Session] = []
        for profile in profiles where !notSyncedHere.contains(profile.id) {
            var session: Session
            if let found = sessions.first(where: { $0.syncedProfileID == profile.id }) {
                session = found
            } else {
                session = Session(name: SessionLimits.name(profile.name))
                session.syncedProfileID = profile.id
                made.append(session)
                sessions.append(session)
            }
            if !kept.contains(profile.id) || session.syncedState == nil {
                let trimmed = SessionLimits.name(profile.name)
                session.name = trimmed.isEmpty ? session.name : trimmed
                session.notes = profile.notes
                session.tags = Self.normalizedTags(profile.tags)
                session.syncedState = SyncedState(name: session.name, notes: session.notes, tags: session.tags)
                session.syncedEditedAt = nil
            }
            if let proxy = profile.proxy, !Faults.isActive(.syncedProxyNotBound) {
                session.proxyID = proxyID(proxy, session)
                session.boundToProxy = true
            } else if profile.proxyUnusable {
                session.proxyID = nil
                session.boundToProxy = true
            }
            if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        }
        save()
        return made
    }

    /// What was changed here in the sessions made from the vault since the last run, to go to the
    /// vault (step 5): of their name, description and tags only the ones changed, with what the vault
    /// had at the last run and when the change was made — the run puts them on the vault's settings
    /// as they are then, and of a field the Mac changed too, the newer change stays.
    public func localEdits() -> [SyncedEdit] {
        sessions.compactMap { session in
            guard let profileID = session.syncedProfileID, let state = session.syncedState else { return nil }
            let now = SyncedState(name: session.name, notes: session.notes, tags: session.tags)
            guard now != state else { return nil }
            return SyncedEdit(profileID: profileID,
                              name: now.name == state.name ? nil : now.name,
                              notes: now.notes == state.notes ? nil : now.notes,
                              tags: now.tags == state.tags ? nil : now.tags,
                              editedAt: session.syncedEditedAt ?? Date(), base: state)
        }
    }

    private func update(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        save()
    }

    /// A change of a session's name, description or tags. One that changes a session made from the
    /// vault is timed: that time decides between it and the Mac's change of the same field.
    private func edit(_ id: UUID, at date: Date, _ change: (inout Session) -> Void) {
        update(id) { session in
            let before = SyncedState(name: session.name, notes: session.notes, tags: session.tags)
            change(&session)
            if session.syncedProfileID != nil, SyncedState(name: session.name, notes: session.notes, tags: session.tags) != before {
                session.syncedEditedAt = date
            }
        }
    }

    private func save() { store.saveSessions(sessions, notSyncedHere: notSyncedHere) }
}
