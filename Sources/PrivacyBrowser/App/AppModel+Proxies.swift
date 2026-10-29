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
