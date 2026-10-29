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
                outcome.failed[id] = (error as? CoreError)?.description ?? error.localizedDescription
            }
        }
        return outcome
    }

    /// The profiles that use the list's entry as it was (`previous`: the same host, port and user
    /// name, `ProxyList.identity(of:)`) take its connection as it is now — after an edit, or a
    /// check that found its type — each keeping its own bypass list, saved as an edit of the proxy
    /// alone. Profiles with another proxy, or none, are not touched.
    @discardableResult
    public func follow(_ entry: ProxyListEntry, previous: ProxySettings, at time: Date = Date()) -> ProxyAssignmentOutcome {
        var outcome = ProxyAssignmentOutcome()
        guard let proxy = entry.usableProxy else { return outcome }
        let identity = ProxyList.identity(of: previous)
        for summary in list() {
            do {
                let stored = try loadConfiguration(summary.id)
                guard let current = stored.proxy, ProxyList.identity(of: current) == identity else { continue }
                let followed = stored.assigning(current.withConnection(of: proxy), check: entry.lastCheck, at: time)
                guard followed != stored else {
                    outcome.unchanged.append(summary.id)
                    continue
                }
                try saveConfiguration(followed, for: summary.id)
                outcome.changed.append(summary.id)
            } catch {
                outcome.failed[summary.id] = (error as? CoreError)?.description ?? error.localizedDescription
            }
        }
        return outcome
    }

    /// The proxies of every profile that has one, for the list to take in (`ProxyList.takeIn`).
    public func profileProxies() -> [ProxySettings] {
        list().compactMap { (try? loadConfiguration($0.id))?.proxy }
    }
}
