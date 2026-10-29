import Foundation

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
    /// saved — or left alone when it already has that proxy. One profile that fails does not stop
    /// the others.
    @discardableResult
    public func assign(_ assignments: [ProxyAssignment], at time: Date = Date()) -> ProxyAssignmentOutcome {
        var outcome = ProxyAssignmentOutcome()
        for assignment in assignments {
            let id = assignment.profileID
            do {
                let stored = try loadConfiguration(id)
                let assigned = stored.assigning(assignment.entry.proxy, check: assignment.entry.lastCheck, at: time)
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
}
