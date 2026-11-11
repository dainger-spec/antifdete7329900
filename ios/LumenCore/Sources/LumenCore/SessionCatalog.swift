import Foundation

/// The list of sessions and what a person does with it: create, rename, describe, tag, search,
/// delete. Every change is written at once.
public final class SessionCatalog {
    public private(set) var sessions: [Session]
    private let store: LumenStore

    public init(store: LumenStore) {
        self.store = store
        sessions = store.loadSessions()
    }

    @discardableResult
    public func create(name: String, notes: String = "", tags: [String] = []) -> Session {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = Session(name: trimmed.isEmpty ? nextDefaultName() : trimmed, notes: notes,
                              tags: Self.normalizedTags(tags))
        sessions.append(session)
        save()
        return session
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Faults.isActive(.renameIgnored) else { return }
        update(id) { $0.name = trimmed }
    }

    public func setNotes(_ id: UUID, _ notes: String) {
        guard !Faults.isActive(.notesNotSaved) else { return }
        update(id) { $0.notes = notes }
    }

    public func setTags(_ id: UUID, _ tags: [String]) {
        update(id) { $0.tags = Self.normalizedTags(tags) }
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

    /// Removes the session from the list and its files; the caller removes its WebKit store.
    public func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        store.removeSessionFiles(id)
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

    /// "work, Ads ,work" → ["work", "Ads"]: trimmed, no empty ones, no repeats (ignoring case).
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags.flatMap({ $0.split(separator: ",") }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
            if seen.insert(tag.lowercased()).inserted { out.append(tag) }
        }
        return out
    }

    private func nextDefaultName() -> String {
        var n = sessions.count + 1
        while sessions.contains(where: { $0.name == L("Сессия %@", "\(n)") }) { n += 1 }
        return L("Сессия %@", "\(n)")
    }

    /// The Mac's profiles as the sync read them (step 3 of ios/SYNC_PLAN.md): each one a session here,
    /// found again by its id in the vault — made the first time, its name, description and tags the
    /// Mac's after that. A profile with a proxy gets it (`proxyID` gives the entry for it) and is bound
    /// to proxies at once; one whose proxy the iPhone cannot use comes with none, and bound: locked
    /// until a proxy is chosen (decision 6). The iPhone's own sessions are not touched; a profile the
    /// Mac no longer has stays here. Returns the sessions made.
    @discardableResult
    public func applySynced(_ profiles: [SyncedProfile], proxyID: (SyncedProfile.Proxy) -> UUID) -> [Session] {
        var made: [Session] = []
        for profile in profiles {
            var session: Session
            if let found = sessions.first(where: { $0.syncedProfileID == profile.id }) {
                session = found
            } else {
                session = Session(name: profile.name)
                session.syncedProfileID = profile.id
                made.append(session)
                sessions.append(session)
            }
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            session.name = trimmed.isEmpty ? session.name : trimmed
            session.notes = profile.notes
            session.tags = Self.normalizedTags(profile.tags)
            if let proxy = profile.proxy, !Faults.isActive(.syncedProxyNotBound) {
                session.proxyID = proxyID(proxy)
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

    private func update(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        save()
    }

    private func save() { store.saveSessions(sessions) }
}
