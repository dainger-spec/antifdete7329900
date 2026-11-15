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

/// A change made on the iPhone to a session made from the vault, to go to the vault: only the
/// fields changed here (nil: left as the vault had it), when, and what the vault had at the last run.
public struct SyncedEdit: Equatable, Sendable {
    public var profileID: UUID
    public var name: String?
    public var notes: String?
    public var tags: [String]?
    /// When the person made it (the newest of its fields).
    public var editedAt: Date
    /// The name, description and tags the vault had at the last run: a field that is no longer that
    /// in the vault was changed on the Mac too. Nil: not known — a field the vault has otherwise
    /// counts as changed on both, and the newer change stays.
    public var base: SyncedState?

    public init(profileID: UUID, name: String? = nil, notes: String? = nil, tags: [String]? = nil, editedAt: Date = Date(),
                base: SyncedState? = nil) {
        self.profileID = profileID
        self.name = name
        self.notes = notes
        self.tags = tags
        self.editedAt = editedAt
        self.base = base
    }
}

/// An edit made here that the vault did not take, and why: it stays on the iPhone, to go when it can.
public struct SyncedEditRefusal: Equatable, Sendable {
    public enum Reason: Error, Equatable, Sendable {
        /// A name longer than the Mac's `SessionLimits.nameLength` characters.
        case nameTooLong
        /// A description longer than the Mac's `SessionLimits.notesLength` characters.
        case notesTooLong
        /// The Mac's core refused it (its words, for the log).
        case other(String)
    }

    public var profileID: UUID
    public var reason: Reason

    public init(profileID: UUID, reason: Reason) {
        self.profileID = profileID
        self.reason = reason
    }
}

/// One read of the vault: the iPhone's copy of it set up (or opened) with the kept key, one run of
/// the Mac's own engine through the iPhone's transport, and the profiles as they now are. The iPhone
/// changes nothing in the vault in this step, so the run writes nothing to the server.
public enum SyncRead {
    public struct Outcome: Sendable {
        public var profiles: [SyncedProfile]
        /// The server's generation to keep for the next run (`SyncGeneration`): the one the run ended
        /// with — the list's, or the one a write of the run was answered with (a vault the run made
        /// anew, after its data was deleted in the cabinet, has a new one). Never the one from before
        /// the run: with it the next run would forget its records and send everything again.
        public var generation: String?
        /// Objects the server refused for their size or the plan's space (deferred).
        public var deferredForSpace: [String]
        /// Of them, the ones too large for the server (`413`), and the ones the plan's space had no
        /// room for (`507`): each said to the person (CONTRACT.md §16.1).
        public var deferredTooLarge: [String] = []
        public var deferredOverQuota: [String] = []
        /// Cookies set in and deleted from the sessions' stores by this run (step 4).
        public var cookiesSet = 0
        public var cookiesDeleted = 0
        /// The tokens of the synced profiles, for the renewal of the document of rights (CONTRACT.md
        /// §6.2: a profile on the Mac and on the iPhone takes one place of the license).
        public var profileTokens: [String] = []
        /// Edits made here that the vault did not take: each stays, to go when it can — the rest of the
        /// run went on.
        public var refusedEdits: [SyncedEditRefusal] = []
    }

    /// Why a run did not go through, in the app's terms (the app does not see the Mac's core). Each
    /// refusal of the server is a state with words of its own (CONTRACT.md §16.1, `SyncText`); only
    /// no answer at all is "the server does not answer".
    public enum Failure: Error, Equatable {
        /// No paid plan running: the sync is the plan's (a state, decision 8).
        case notInPlan
        /// The kept key no longer opens the vault: the master password changed on the Mac.
        case keyNoLongerOpens
        /// The server's data changed under the run (§16.2): nothing more written; the next run starts afresh.
        case generationChanged
        /// The vault is a newer version's.
        case newerApp
        /// `401`: the server no longer knows this iPhone's token — unlinked in the cabinet, or by a
        /// change of the account's password. The app renews its document of rights, whose answer
        /// says why (§16.1; `device_revoked` signs this iPhone out), and runs once more if it may.
        case unauthorized
        /// `403 forbidden`: the vault is synced by another Lumen account.
        case anotherAccount
        /// `403 too_many_vaults`: the account has as many vaults as it may.
        case tooManyVaults
        /// `403 account_disabled`.
        case accountDisabled
        /// `403 sync_on_hold`: a device new to the account; sync opens then (nil: not said).
        case onHold(until: Date?)
        /// `429`: too many requests; in how many seconds to ask again, when the server said it.
        case rateLimited(retryAfter: Int?)
        /// The server has no vault header, and the iPhone no copy: sync is off on the Mac, or its
        /// data was deleted in the cabinet.
        case noVault
        /// The server answered with an error the contract names no state for (its status).
        case serverError(Int)
        /// No answer at all: no network, a timeout.
        case unreachable
        /// Anything else (the iPhone's copy of the vault, …): its words, for the log.
        case other(String)
    }

    /// A refusal of the sync server in the app's terms: its status and the code its body names (""
    /// for none), with what comes with them (CONTRACT.md §16.1). Also for the list of the account's
    /// vaults (`GET /v1/device/sync/vaults`), which refuses the same way.
    public static func failure(status: Int, code: String, availableAt: Date? = nil, retryAfter: Int? = nil) -> Failure {
        switch (status, code) {
        case (401, _): return .unauthorized
        case (403, "sync_not_in_plan"): return .notInPlan
        case (403, "forbidden"): return .anotherAccount
        case (403, "too_many_vaults"): return .tooManyVaults
        case (403, "account_disabled"): return .accountDisabled
        case (403, "sync_on_hold"): return .onHold(until: availableAt)
        case (409, "generation_changed"): return .generationChanged
        case (429, _): return .rateLimited(retryAfter: retryAfter)
        default: return .serverError(status)
        }
    }

    /// `pull`, its failures said in the app's terms.
    public static func run(root: URL, key: Data, transport: LumenSyncTransport, keptGeneration: String?,
                           edits: [SyncedEdit] = [], cookies: SyncCookieStores? = nil,
                           notHere: Set<UUID> = []) async -> Result<Outcome, Failure> {
        do {
            return .success(try await pull(root: root, key: key, transport: transport, keptGeneration: keptGeneration,
                                           edits: edits, cookies: cookies, notHere: notHere))
        } catch let refusal as SyncServerRefusal {
            return .failure(failure(status: refusal.status, code: refusal.code, availableAt: refusal.availableAt,
                                    retryAfter: refusal.retryAfter))
        } catch CoreError.syncServer(let status, _) {
            // An answer that is not the server's own words (a gateway's 502 while the server is down):
            // no answer from the server (§9.3) — but for what its status says by itself.
            return .failure(status == 401 || status == 429 ? failure(status: status, code: "") : .unreachable)
        } catch CoreError.wrongPassword {
            return .failure(.keyNoLongerOpens)
        } catch CoreError.newerFormat, CoreError.unsupportedFormat {
            return .failure(.newerApp)
        } catch CoreError.vaultNotFound {
            return .failure(.noVault)
        } catch is URLError {
            return .failure(.unreachable)
        } catch {
            return .failure(.other("\(error)"))
        }
    }

    /// `cookies`: the stores of the sessions made from the vault's profiles before the run — after
    /// the run, each gets its profile's cookies by the Mac's rules (step 4). The app leaves it out and
    /// runs `applyCookies` once it has made the run's new sessions, so that those get theirs in the
    /// same run too.
    /// `edits`: what was changed here in the sessions made from the vault (their name, description,
    /// tags; step 5). The run first takes what the Mac changed, then writes into the iPhone's copy
    /// only the fields edited here, onto the settings as they now are — never the copy from the last
    /// run, which would send the Mac's older settings back with them — stamped with the edit's own
    /// time, and sends them. Of a field changed on both, the newer change stays (`apply`). An edit
    /// the vault refuses is refused for its profile alone (`Outcome.refusedEdits`).
    /// `notHere`: the profiles whose sessions were deleted on this iPhone — neither returned nor
    /// counted among this iPhone's (`profileTokens`).
    public static func pull(root: URL, key: Data, transport: LumenSyncTransport, keptGeneration: String?,
                            edits: [SyncedEdit] = [], cookies: SyncCookieStores? = nil,
                            notHere: Set<UUID> = []) async throws -> Outcome {
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
        // What the Mac changed first: the edits made here go onto it. (A vault copy set up again —
        // after a sign-out, or the vault forgotten — has its profiles only now.)
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        var refused: [SyncedEditRefusal] = []
        if !Faults.isActive(.syncEditNotSent) {
            var written = false
            for edit in edits where repository.list().contains(where: { $0.id == edit.profileID }) {
                do {
                    try apply(edit, to: repository, written: &written)
                } catch let reason as SyncedEditRefusal.Reason {
                    refused.append(SyncedEditRefusal(profileID: edit.profileID, reason: reason))
                } catch {
                    refused.append(SyncedEditRefusal(profileID: edit.profileID, reason: .other("\(error)")))
                }
            }
            // The edits go now, in this run.
            if written { _ = try await SyncEngine(repository: repository, transport: transport).sync() }
        }
        let profiles = repository.list().compactMap { summary -> SyncedProfile? in
            guard !notHere.contains(summary.id), let configuration = try? repository.loadConfiguration(summary.id) else { return nil }
            return profile(summary, configuration)
        }
        // The generation the records are now of: a write of the run may have made the vault anew
        // (CONTRACT.md §16.2, 6).
        var outcome = Outcome(profiles: profiles, generation: transport.generation ?? generation,
                              deferredForSpace: transport.deferredForSpace)
        outcome.deferredTooLarge = transport.deferredTooLarge
        outcome.deferredOverQuota = transport.deferredOverQuota
        // Only this iPhone's profiles: one deleted here takes no place of it.
        let gone = Set(notHere.compactMap { try? SyncProfileToken.token(for: $0, vault: repository.vault) })
        outcome.profileTokens = SyncProfileToken.tokens(in: repository).filter { !gone.contains($0) }
        outcome.refusedEdits = refused
        if let cookies {
            let applied = await SyncCookieRun.run(repository: repository, stores: cookies, root: root)
            outcome.cookiesSet = applied.set
            outcome.cookiesDeleted = applied.deleted
        }
        return outcome
    }

    /// Step 4 after the run (`pull` without `cookies`): each session made from the vault's profiles —
    /// the ones the run's profiles were just made into too — gets its profile's cookies by the Mac's
    /// rules, from the iPhone's copy of the vault. How many were set and deleted.
    public static func applyCookies(root: URL, key: Data, stores: SyncCookieStores) async throws -> (set: Int, deleted: Int) {
        let repository = try ProfileRepository(vault: MasterVault.open(in: root, deviceUnlockKey: key))
        return await SyncCookieRun.run(repository: repository, stores: stores, root: root)
    }

    /// One edit made here, written into the iPhone's copy as the vault now has the profile: each field
    /// edited here that the vault does not have already — unless the Mac changed that field too since
    /// the last run (it is no longer `edit.base`'s) at a time not older than the edit (the Mac's
    /// settings time stands for its rename too: the profile list keeps no time of a rename). The
    /// settings are stamped with the edit's time, or theirs if newer: a stamp never goes back, or an
    /// older change on a third device would win over the Mac's. A field over the Mac's limits refuses
    /// the whole edit before anything is written (`SyncedEditRefusal.Reason`).
    static func apply(_ edit: SyncedEdit, to repository: ProfileRepository, written: inout Bool) throws {
        let id = edit.profileID
        let name = edit.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let name, name.count > SessionLimits.nameLength { throw SyncedEditRefusal.Reason.nameTooLong }
        if let notes = edit.notes, notes.count > SessionLimits.notesLength { throw SyncedEditRefusal.Reason.notesTooLong }
        let tags = edit.tags.map { ProfileTags.normalized($0) }

        var configuration = try repository.loadConfiguration(id)
        let theirs = configuration.settingsModifiedAt
        func taken<T: Equatable>(_ mine: T?, now: T, base: T?) -> T? {
            guard let mine, mine != now else { return nil }
            // Changed on the Mac as well since the last run (or not known to be otherwise): the newer stays.
            if base.map({ $0 != now }) ?? true, let theirs, theirs >= edit.editedAt { return nil }
            return mine
        }
        let currentName = try repository.summary(for: id).name
        let newName = taken(name, now: currentName, base: edit.base?.name)
        let newNotes = taken(edit.notes, now: configuration.notes, base: edit.base?.notes)
        let newTags = taken(tags, now: configuration.tags, base: edit.base?.tags)

        if let newName {
            try repository.rename(id, to: newName)
            written = true
        }
        if newNotes != nil || newTags != nil {
            if let newNotes { configuration.notes = newNotes }
            if let newTags { configuration.tags = newTags }
            configuration.settingsModifiedAt = max(theirs ?? edit.editedAt, edit.editedAt)
            try repository.saveConfiguration(configuration, for: id)
            written = true
        }
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

/// What the person is told of the sync (CONTRACT.md §16.1): each refusal of the server in words of its
/// own, saying that nothing on this iPhone changed by it — "the server does not answer" only when it
/// did not. `dateText`: the app's way of writing a date.
public enum SyncText {
    /// A run, or the list of the account's vaults, that did not go through.
    public static func failure(_ failure: SyncRead.Failure, dateText: (Date) -> String) -> String {
        switch failure {
        case .notInPlan: return L("Синхронизация с Mac — в платных тарифах. Профили на этом iPhone остаются как есть.")
        case .keyNoLongerOpens: return L("Мастер-пароль изменился на Mac. Введите новый.")
        case .generationChanged: return L("Данные синхронизации на сервере изменились. Синхронизируйте ещё раз.")
        case .newerApp: return AccountText.outdated
        case .unauthorized:
            return L("Сервер Lumen не принял вход этого iPhone для синхронизации. Выйдите из аккаунта и войдите снова; сессии на этом iPhone остались как были.")
        case .anotherAccount:
            return L("Это хранилище Mac синхронизируется другим аккаунтом Lumen: войдите в аккаунт, с которым синхронизируется Mac. Ничего не отправлено и не изменено.")
        case .tooManyVaults:
            return L("У аккаунта уже наибольшее число хранилищ синхронизации. Лишние можно удалить в кабинете на сайте; сессии на этом iPhone остались как были.")
        case .accountDisabled: return L("Аккаунт заблокирован, напишите в поддержку.")
        case let .onHold(until): return onHold(until, dateText: dateText)
        case let .rateLimited(retryAfter):
            guard let retryAfter else { return L("Слишком много запросов синхронизации к серверу Lumen: попробуйте позже.") }
            return L("Слишком много запросов синхронизации к серверу Lumen: попробуйте через %@.", AccountText.duration(retryAfter))
        case .noVault:
            return L("Хранилища Mac на сервере нет: синхронизация на Mac выключена или её данные удалены в кабинете. Сессии на этом iPhone остались как были.")
        case let .serverError(status):
            return L("Сервер Lumen ответил ошибкой (%@) и синхронизацию не провёл. Попробуйте позже; сессии на этом iPhone остались как были.", "\(status)")
        case .unreachable: return AccountText.unreachable
        case .other: return L("Синхронизация не прошла. Сессии на этом iPhone остались как были.")
        }
    }

    /// `403 sync_on_hold`: when sync opens on this device, and why it waits (the contract's words).
    public static func onHold(_ date: Date?, dateText: (Date) -> String) -> String {
        guard let date else { return L("Синхронизация на этом устройстве откроется позже: на почту аккаунта ушло письмо о новом устройстве.") }
        return L("Синхронизация на этом устройстве откроется %@: на почту аккаунта ушло письмо о новом устройстве.", dateText(date))
    }

    /// Objects of a run that went through, deferred for their size or the plan's space: they wait,
    /// and the rest was synced.
    public static let overQuota = L("Место для синхронизации по тарифу закончилось: изменения, которым нужно больше места, не синхронизируются. Сколько занято, видно в кабинете на сайте.")
    public static let tooLarge = L("Слишком большой объект для синхронизации: он ждёт, остальное синхронизировано.")
}
