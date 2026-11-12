import BrowserCore
import Foundation

/// A profile of the Mac's vault, as the iPhone takes it (the sync's step 3, ios/SYNC_PLAN.md): what
/// a session on the iPhone has of it — name, description, tags, proxy. The Mac's fingerprint
/// settings are not taken (decision 5 waits for the owner); neither are its passwords nor bookmarks
/// (decision 7).
public struct SyncedProfile: Equatable, Sendable {
    public struct Proxy: Equatable, Sendable {
        public var kind: ProxyKind
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
    }

    public var id: UUID
    public var name: String
    public var notes: String
    public var tags: [String]
    public var proxy: Proxy?
    /// The Mac's profile has a proxy the iPhone cannot use (TLS to the proxy): it comes without one,
    /// and stays bound to a proxy — locked until one is chosen (decision 6).
    public var proxyUnusable: Bool
}

/// A change made on the iPhone to a session made from the vault, to go to the vault.
public struct SyncedEdit: Equatable, Sendable {
    public var profileID: UUID
    public var name: String
    public var notes: String
    public var tags: [String]

    public init(profileID: UUID, name: String, notes: String, tags: [String]) {
        self.profileID = profileID
        self.name = name
        self.notes = notes
        self.tags = tags
    }
}

/// One read of the vault: the iPhone's copy of it set up (or opened) with the kept key, one run of
/// the Mac's own engine through the iPhone's transport, and the profiles as they now are. The iPhone
/// changes nothing in the vault in this step, so the run writes nothing to the server.
public enum SyncRead {
    public struct Outcome: Sendable {
        public var profiles: [SyncedProfile]
        /// The server's generation to keep for the next run (`SyncGeneration`).
        public var generation: String?
        /// Objects the server refused for their size or the plan's space (deferred).
        public var deferredForSpace: [String]
        /// Cookies set in and deleted from the sessions' stores by this run (step 4).
        public var cookiesSet = 0
        public var cookiesDeleted = 0
        /// The tokens of the synced profiles, for the renewal of the document of rights (CONTRACT.md
        /// §6.2: a profile on the Mac and on the iPhone takes one place of the license).
        public var profileTokens: [String] = []
    }

    /// Why a run did not go through, in the app's terms (the app does not see the Mac's core).
    public enum Failure: Error, Equatable {
        /// No trial or paid plan: the sync is the plan's (a state, decision 8).
        case notInPlan
        /// The kept key no longer opens the vault: the master password changed on the Mac.
        case keyNoLongerOpens
        /// The server's data changed under the run (§16.2): nothing more written; the next run starts afresh.
        case generationChanged
        /// The vault is a newer version's.
        case newerApp
        case other(String)
    }

    /// `pull`, its failures said in the app's terms.
    public static func run(root: URL, key: Data, transport: LumenSyncTransport, keptGeneration: String?,
                           edits: [SyncedEdit] = [], cookies: SyncCookieStores? = nil) async -> Result<Outcome, Failure> {
        do {
            return .success(try await pull(root: root, key: key, transport: transport, keptGeneration: keptGeneration,
                                           edits: edits, cookies: cookies))
        } catch CoreError.syncServer(403, "sync_not_in_plan") {
            return .failure(.notInPlan)
        } catch CoreError.wrongPassword {
            return .failure(.keyNoLongerOpens)
        } catch CoreError.syncServer(409, "generation_changed") {
            return .failure(.generationChanged)
        } catch CoreError.newerFormat, CoreError.unsupportedFormat {
            return .failure(.newerApp)
        } catch {
            return .failure(.other("\(error)"))
        }
    }

    /// `cookies`: the stores of the sessions already made from the vault's profiles — after the run,
    /// each gets its profile's cookies by the Mac's rules (step 4). A profile made a session by this
    /// run gets them at the next one.
    /// `edits`: what was changed here in the sessions made from the vault (their name, description,
    /// tags) — written into the iPhone's copy before the run, as an edit made now, and so sent by
    /// the run (step 5). The Mac's newer-wins rule decides between an edit here and one there.
    public static func pull(root: URL, key: Data, transport: LumenSyncTransport, keptGeneration: String?,
                            edits: [SyncedEdit] = [], cookies: SyncCookieStores? = nil) async throws -> Outcome {
        let vault: UnlockedVault
        if MasterVault.exists(in: root) {
            vault = try MasterVault.open(in: root, deviceUnlockKey: key)
        } else {
            guard let blob = try await transport.fetch(objectID: SyncEngine.vaultHeaderObjectID) else { throw CoreError.vaultNotFound }
            let header = try VaultHeader.decodeChecked(blob)
            guard header.vaultID == transport.vaultID else { throw CoreError.corruptData("another vault's header") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            vault = try MasterVault.setUp(in: root, header: header, deviceUnlockKey: key)
        }
        // The run's list first: the server's generation, and the engine's records forgotten when it
        // is another one (§16.2) — before the engine reads them.
        _ = try await transport.listObjects()
        let generation = SyncGeneration.reconcile(root: root, listed: transport.generation, kept: keptGeneration)
        let repository = try ProfileRepository(vault: vault)
        if !Faults.isActive(.syncEditNotSent) {
            for edit in edits where repository.list().contains(where: { $0.id == edit.profileID }) {
                let name = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, (try? repository.summary(for: edit.profileID).name) != name {
                    try repository.rename(edit.profileID, to: name)
                }
                var configuration = try repository.loadConfiguration(edit.profileID)
                if configuration.notes != edit.notes || configuration.tags != edit.tags {
                    configuration.notes = edit.notes
                    configuration.tags = edit.tags
                    configuration.settingsModifiedAt = Date()
                    try repository.saveConfiguration(configuration, for: edit.profileID)
                }
            }
        }
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        let profiles = repository.list().compactMap { summary -> SyncedProfile? in
            guard let configuration = try? repository.loadConfiguration(summary.id) else { return nil }
            return profile(summary, configuration)
        }
        var outcome = Outcome(profiles: profiles, generation: generation, deferredForSpace: transport.deferredForSpace)
        outcome.profileTokens = SyncProfileToken.tokens(in: repository)
        if let cookies {
            let applied = await SyncCookieRun.run(repository: repository, stores: cookies)
            outcome.cookiesSet = applied.set
            outcome.cookiesDeleted = applied.deleted
        }
        return outcome
    }

    static func profile(_ summary: ProfileSummary, _ configuration: ProfileConfiguration) -> SyncedProfile {
        var proxy: SyncedProfile.Proxy?
        var unusable = false
        if let settings = configuration.proxy {
            if settings.kind == .httpConnect && settings.tlsToProxy {
                unusable = true
            } else {
                proxy = .init(kind: settings.kind == .socks5 ? .socks5 : .http, host: settings.host, port: settings.port,
                              username: settings.username ?? "", password: settings.password ?? "")
            }
        }
        return SyncedProfile(id: summary.id, name: summary.name, notes: configuration.notes, tags: configuration.tags,
                             proxy: proxy, proxyUnusable: unusable)
    }
}
