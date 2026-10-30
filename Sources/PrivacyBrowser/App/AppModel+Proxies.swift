import BrowserCore
import Foundation

/// The proxy list's part of the app model, and what the Profiles list does to several profiles at
/// once. Kept apart from `AppModel` itself: everything here goes through what it already offers
/// (the repository, the manager, launch, stop, delete).
extension AppModel {
    // MARK: Proxies

    /// Gives profiles proxies of the list — one each, as `ProxyList.rotation(of:over:)` planned —
    /// as the editor would (`ProfileRepository.assign`): saved encrypted, synced like an edit, used
    /// from each profile's next launch (a running one keeps its proxy until it stops). Says which
    /// profiles could not be changed.
    @discardableResult
    func assignProxies(_ assignments: [ProxyAssignment]) -> ProxyAssignmentOutcome? {
        guard let repository else { return nil }
        let outcome = repository.assign(assignments)
        for id in assignments.map(\.profileID) {
            guard let reason = outcome.failed[id] else { continue }
            let name = profiles.first { $0.id == id }?.name ?? id.uuidString
            showError(String(format: L("proxies.assign.failed"), name, reason))
        }
        refresh()
        return outcome
    }

    /// The profiles that used the list's entry as it was (`previous`) take it as it is now — an
    /// edit in the Proxies sheet, or a check that found its type (`ProfileRepository.follow`).
    /// Says which profiles could not be changed (they keep their proxy as it was).
    func followProxyEntry(_ entry: ProxyListEntry, previous: ProxySettings) {
        guard let repository else { return }
        let outcome = repository.follow(entry, previous: previous)
        for (id, reason) in outcome.failed {
            let name = profiles.first { $0.id == id }?.name ?? id.uuidString
            showError(String(format: L("proxies.follow.failed"), name, reason))
        }
        if !outcome.changed.isEmpty { refresh() }
    }

    /// How many profiles use each proxy of the list, by `ProxyList.identity(of:)`.
    var proxyUseCounts: [String: Int] {
        details.values.reduce(into: [:]) { counts, details in
            if let identity = details.proxyIdentity { counts[identity, default: 0] += 1 }
        }
    }

    // MARK: A profile whose proxy does not work

    /// A profile that was started has a proxy that does not work: the Profiles window comes to the
    /// front and says so (one problem per profile: the latest).
    /// `notStarted`: the settings keep such a profile stopped (Settings → Proxies), and it was.
    func reportProxyProblem(of id: UUID, proxy: ProxySettings, diagnosis: ProxyDiagnosis, notStarted: Bool = false) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        proxyProblems.removeAll { $0.profileID == id }
        proxyProblems.append(ProxyProblem(profileID: id, profileName: profile.name, proxy: proxy, diagnosis: diagnosis,
                                          notStarted: notStarted))
        activateProfilesWindow()
    }

    func dismissProxyProblem(_ problem: ProxyProblem) {
        proxyProblems.removeAll { $0.id == problem.id }
    }

    /// Check, from a problem: the profile's proxy checked as the Proxies sheet checks one
    /// (`ProxyListModel.checkProfileProxy`). Nil while locked.
    func checkProxy(of problem: ProxyProblem) async -> ProxyCheckResult? {
        await proxyList?.checkProfileProxy(problem.proxy)
    }

    /// The problem's proxy in the list (added when it is not there), for the Proxies sheet to show.
    func proxyEntryID(of problem: ProxyProblem) -> UUID? {
        proxyList?.entryID(for: problem.proxy)
    }

    // MARK: Several profiles at once

    /// Launches each of `ids` that is stopped, one after the other (each opens its window), as
    /// Launch on each row would.
    func launchProfiles(_ ids: [UUID]) async {
        for id in ids where !isRunning(id) && !isBusy(id) {
            guard phase == .unlocked else { return }
            await launch(id)
        }
    }

    /// Stops and seals each of `ids` that runs, all at once (as Lock does).
    func stopProfiles(_ ids: [UUID]) async {
        guard let manager else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in ids where manager.isRunning(id) {
                group.addTask { @MainActor in
                    do {
                        try await manager.stop(id)
                    } catch {
                        self.showError((error as? CoreError)?.description ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Deletes each of `ids` with all its data, stopping a running one first.
    func deleteProfiles(_ ids: [UUID]) async {
        for id in ids {
            guard phase == .unlocked else { return }
            await deleteProfile(id)
        }
    }
}

/// A profile that was started with a proxy that does not work, and how it does not
/// (`ProfileManager.onProxyProblem`).
struct ProxyProblem: Identifiable, Equatable {
    var id: UUID { profileID }
    let profileID: UUID
    let profileName: String
    let proxy: ProxySettings
    let diagnosis: ProxyDiagnosis
    /// The profile was not started (Settings → Proxies → do not start it); otherwise it runs and
    /// loads nothing.
    var notStarted = false
}
