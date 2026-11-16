import Foundation

extension ProxySettings {
    /// This proxy with `other`'s connection — type, host, port, login, TLS — and its own bypass
    /// list, which is the profile's choice, not the proxy's.
    public func withConnection(of other: ProxySettings) -> ProxySettings {
        var proxy = other
        proxy.excludedDomains = excludedDomains
        return proxy
    }
}

extension ProfileConfiguration {
    /// This configuration with `proxy` as its proxy, saved as the editor saves a change of the
    /// proxy alone (`savingEdit(over:)`): what the browser keeps for itself stays as stored, and
    /// `settingsModifiedAt` moves only when the proxy is really another one (giving a profile the
    /// proxy it already has is no edit, and does not make sync carry it).
    ///
    /// The one exception to "kept as stored": the location remembered for the previous proxy. It
    /// is about another proxy — a launch would ignore it (`rememberedProxyLocation` matches the
    /// endpoint) — so it is not kept at all, and nothing about the old proxy, its exit IP among it,
    /// stays with the profile. In its place goes what `check` found through the new proxy, as a
    /// launch's lookup through it would have remembered it (`ProxyCheckResult.location(for:)`), so
    /// the Profiles list can show where the profile now exits; its exit IP only while the profile
    /// asks to be warned when it changes, as `keepingStoredState(of:)` keeps it.
    public func assigning(_ proxy: ProxySettings, check: ProxyCheckResult? = nil, at time: Date = Date()) -> ProfileConfiguration {
        var edited = self
        edited.proxy = proxy
        var saved = edited.savingEdit(over: self, at: time)
        if self.proxy.map(ProxyLocation.endpoint(of:)) != ProxyLocation.endpoint(of: proxy) {
            saved.lastProxyLocation = check?.location(for: proxy)
            if !saved.warnOnProxyIPChange { saved.lastProxyLocation?.exitIP = nil }
        }
        return saved
    }

    /// This configuration as the profile editor saves it over `stored` (`savingEdit(over:)`), with
    /// the proxy's location as `assigning` has it: when the proxy is another one than `stored`'s,
    /// the location remembered for the old proxy goes, and in its place goes the one this edit
    /// carries if it is the new proxy's — what the editor's check found through it ("From the
    /// list", or Check under "New") — or none; its exit IP only while the profile asks to be warned
    /// when it changes. The same proxy: what is stored stays (a launch's lookup may be newer than
    /// the editor's copy). Without this, the old proxy's location was kept and the check's thrown
    /// away, and the first launch through the new proxy had no location to fall back on.
    public func savingEditorEdit(over stored: ProfileConfiguration?, at time: Date = Date()) -> ProfileConfiguration {
        var saved = savingEdit(over: stored, at: time)
        guard let stored, ProxyLocation.exitEndpoint(of: stored.proxy) != ProxyLocation.exitEndpoint(of: proxy) else { return saved }
        saved.lastProxyLocation = rememberedProxyLocation
        if proxy != nil, !saved.warnOnProxyIPChange { saved.lastProxyLocation?.exitIP = nil }
        return saved
    }
}

/// What giving proxies to profiles did.
public struct ProxyAssignmentOutcome: Equatable, Sendable {
    /// Profiles that now have another proxy (saved; a running one uses it from its next launch).
    public var changed: [UUID] = []
    /// Profiles that already had that proxy: nothing was written.
    public var unchanged: [UUID] = []
    /// Profiles that could not be changed, with why (their configuration did not decrypt, …).
    public var failed: [UUID: String] = [:]

    public init(changed: [UUID] = [], unchanged: [UUID] = [], failed: [UUID: String] = [:]) {
        self.changed = changed
        self.unchanged = unchanged
        self.failed = failed
    }
}

extension ProfileRepository {
    /// Gives each profile its proxy from the list (`ProxyList.rotation(of:over:)` for several in
    /// turn): read, changed as the editor would change it (`ProfileConfiguration.assigning`), and
    /// saved — or left alone when it already has that proxy. The profile keeps its own bypass list.
    /// An entry whose type no check has found yet is given to nobody (the profile would connect
    /// with a guess). One profile that fails does not stop the others.
    @discardableResult
    public func assign(_ assignments: [ProxyAssignment], at time: Date = Date()) -> ProxyAssignmentOutcome {
        var outcome = ProxyAssignmentOutcome()
        for assignment in assignments {
            let id = assignment.profileID
            guard let proxy = assignment.entry.usableProxy else {
                outcome.failed[id] = "the proxy's type is not known yet: check it first"
                continue
            }
            do {
                let stored = try loadConfiguration(id)
                let given = stored.proxy.map { $0.withConnection(of: proxy) } ?? proxy
                let assigned = stored.assigning(given, check: assignment.entry.lastCheck, at: time)
                guard assigned != stored else {
                    outcome.unchanged.append(id)
                    continue
                }
                try saveConfiguration(assigned, for: id)
                outcome.changed.append(id)
            } catch {
                outcome.failed[id] = error.localizedDescription
            }
        }
        return outcome
    }

    /// The profiles that use the list's entry as it was (`previous`) take its connection as it is
    /// now — after an edit, or a check that found its type — each keeping its own bypass list,
    /// saved as an edit of the proxy alone. "As it was": the same proxy (host, port, user name)
    /// reached the same way (type, TLS, password: `ProxyList.sameConnection`). A profile whose own
    /// copy went another way — a password changed in its editor, not in the list — keeps it: the
    /// list never overwrites what a profile was given since. Profiles with another proxy, or none,
    /// are not touched.
    ///
    /// `among`: the profiles to look at, of those listed — the ones the caller knows may use that
    /// proxy; nil: every profile. A check that finds a proxy's type follows it, and with several
    /// hundred proxies checked every profile's settings were read for each, on the main thread.
    @discardableResult
    public func follow(_ entry: ProxyListEntry, previous: ProxySettings, among candidates: [UUID]? = nil,
                       at time: Date = Date()) -> ProxyAssignmentOutcome {
        var outcome = ProxyAssignmentOutcome()
        guard let proxy = entry.usableProxy else { return outcome }
        let listed = list().map(\.id)
        let ids = candidates.map { wanted in listed.filter(Set(wanted).contains) } ?? listed
        for id in ids {
            do {
                let stored = try loadConfiguration(id)
                guard let current = stored.proxy, ProxyList.sameConnection(current, previous) else { continue }
                let followed = stored.assigning(current.withConnection(of: proxy), check: entry.lastCheck, at: time)
                guard followed != stored else {
                    outcome.unchanged.append(id)
                    continue
                }
                try saveConfiguration(followed, for: id)
                outcome.changed.append(id)
            } catch {
                outcome.failed[id] = error.localizedDescription
            }
        }
        return outcome
    }

    /// The proxies of every profile that has one, for the list to take in (`ProxyList.takeIn`).
    public func profileProxies() -> [ProxySettings] {
        list().compactMap { (try? loadConfiguration($0.id))?.proxy }
    }
}
