import Foundation

/// Which entry of the proxy list a profile's proxy from the Mac takes (decision 6). On the Mac each
/// profile connects with its own copy of its proxy, password included — a gateway that puts the
/// country or the sticky session in the password gives two profiles the same address and login and
/// different passwords, and each its own exit. Here the password is the entry's (the Keychain's), so
/// such profiles never share an entry, and the password of an entry another session uses is never
/// written over: that session would leave through the other profile's exit.
public enum SyncedProxyEntry: Equatable, Sendable {
    /// This entry, as it is.
    case use(UUID)
    /// This entry — the session's own, no other uses it — with the profile's new password.
    case newPassword(UUID)
    /// A new entry.
    case add

    /// `boundTo`: the entry the profile's session has now (nil: a session made by this run).
    /// `usedElsewhere`: the entries other sessions have. `password`: an entry's password.
    public static func choose(for proxy: SyncedProfile.Proxy, boundTo current: UUID?, entries: [ProxyEntry],
                              usedElsewhere: Set<UUID>, password: (UUID) -> String?) -> SyncedProxyEntry {
        func sameLogin(_ entry: ProxyEntry) -> Bool {
            entry.kind == proxy.kind && entry.host == proxy.host && entry.port == proxy.port && entry.username == proxy.username
        }
        func samePassword(_ entry: ProxyEntry) -> Bool { (password(entry.id) ?? "") == proxy.password }
        if let current, let entry = entries.first(where: { $0.id == current }), sameLogin(entry) {
            if samePassword(entry) { return .use(entry.id) }
            // The profile's password changed on the Mac: its own entry follows, a shared one does not.
            if !usedElsewhere.contains(entry.id) { return .newPassword(entry.id) }
        }
        if let entry = entries.first(where: { sameLogin($0) && samePassword($0) }) { return .use(entry.id) }
        return .add
    }
}
