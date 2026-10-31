import BrowserCore
import Combine
import Foundation
import os

/// The vault's proxy list while the app is unlocked (`ProxyList`, `proxies.bin`), and the checks
/// running over it. Every change is saved at once, encrypted; check results are saved when the run
/// ends or is stopped. Made at unlock and dropped at lock (`AppModel.proxyList`), with the vault
/// it holds.
@MainActor
final class ProxyListModel: ObservableObject {
    @Published private(set) var list: ProxyList
    /// The proxies the running check has not finished yet.
    @Published private(set) var checking: Set<UUID> = []
    /// How many proxies the running check covers, and how many it has finished.
    @Published private(set) var checkedCount = 0
    @Published private(set) var checkTotal = 0
    /// Why the stored list could not be read (damaged, or from a later build). It is then shown
    /// empty and never written, so nothing of it is lost by saving over it.
    let loadError: String?

    /// An entry's proxy changed — edited, or a check found its type — and the profiles that used it
    /// as it was (`previous`) are to follow (`ProfileRepository.follow`, done by `AppModel`).
    var onEntryChanged: ((ProxyListEntry, ProxySettings) -> Void)?

    private let vault: UnlockedVault
    private let onError: (String) -> Void
    private var checkTask: Task<Void, Never>?
    /// The current check run: a run that ended (stopped, or replaced) acts on nothing any more.
    private var checkRun: UUID?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProxyList")

    init(vault: UnlockedVault, onError: @escaping (String) -> Void) {
        self.vault = vault
        self.onError = onError
        do {
            list = try ProxyList.load(from: vault)
            loadError = nil
        } catch {
            list = ProxyList()
            loadError = (error as? CoreError)?.description ?? error.localizedDescription
            log.error("The proxy list could not be read: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    var entries: [ProxyListEntry] { list.entries }
    var isChecking: Bool { checkRun != nil }

    // MARK: Changes

    /// Adds what an import read; nil when it could not be saved (and then nothing was added).
    @discardableResult
    func add(_ lines: [ProxyListImport.Line]) -> ProxyList.AddResult? {
        var updated = list
        let result = updated.add(lines)
        return save(updated) ? result : nil
    }

    func remove(_ ids: Set<UUID>) {
        var updated = list
        updated.remove(ids)
        save(updated)
        checking.subtract(ids)
    }

    /// The profiles' own proxies, taken into the list the first time this vault's list is opened by
    /// a build that has the list (`ProxyList.takeIn`): nothing for the user to do, nothing of a
    /// profile changed. Returns how many entries that added.
    @discardableResult
    func takeIn(profileProxies: @autoclosure () -> [ProxySettings]) -> Int {
        guard loadError == nil, !list.profilesTakenIn else { return 0 }
        var updated = list
        let added = updated.takeIn(profileProxies: profileProxies())
        guard save(updated) else { return 0 }
        if !added.isEmpty { log.notice("Took \(added.count) proxies of profiles into the list") }
        return added.count
    }

    /// Changes an entry as the Edit sheet asks (`kindKnown` false: its type is left to a check);
    /// the profiles that used it follow. Nil when done, otherwise what to tell the user.
    func update(_ id: UUID, label: String, proxy: ProxySettings, kindKnown: Bool = true) -> String? {
        var updated = list
        let previous: ProxySettings
        do {
            previous = try updated.update(id, label: label, proxy: proxy, kindKnown: kindKnown)
        } catch let problem as ProxyList.EditProblem {
            switch problem {
            case .notFound: return L("proxies.edit.gone")
            case .invalid(let message): return message
            case .alreadyListed(let other):
                return String(format: L("proxies.edit.alreadyListed"), list.entry(other)?.displayName ?? "")
            }
        } catch {
            return error.localizedDescription
        }
        // Not saved: the alert says why (`save`); the sheet stays open with the change in it.
        guard save(updated) else { return L("proxies.edit.notSaved") }
        if let entry = list.entry(id), entry.proxy != previous { onEntryChanged?(entry, previous) }
        return nil
    }

    /// The entry for `proxy` — a profile's — in the list, added when it is not there (a proxy typed
    /// into a profile after the list took the profiles in). Nil when the list cannot be written.
    func entryID(for proxy: ProxySettings) -> UUID? {
        if let entry = list.entry(for: proxy) { return entry.id }
        var updated = list
        var listed = proxy
        listed.excludedDomains = []
        let line = ProxyListImport.Line(line: 1, proxy: listed)
        guard let id = updated.add([line]).added.first, save(updated) else { return nil }
        return id
    }

    /// The text of an export of `ids` (all: nil), passwords in plaintext (`ProxyList.exportText`).
    func exportText(_ ids: Set<UUID>?) -> String {
        ProxyList.exportText(list.entries.filter { ids?.contains($0.id) ?? true })
    }

    // MARK: Checks

    /// Checks the proxies `ids` (nil: all of them) through themselves, a few at a time
    /// (`ProxyChecker`). Does nothing while a check runs.
    func check(_ ids: Set<UUID>? = nil) {
        guard checkRun == nil else { return }
        let targets = list.entries.filter { ids?.contains($0.id) ?? true }.map { (id: $0.id, proxy: $0.proxy) }
        guard !targets.isEmpty else { return }
        let run = UUID()
        checkRun = run
        checking = Set(targets.map(\.id))
        checkedCount = 0
        checkTotal = targets.count
        checkTask = Task { [weak self] in
            await ProxyChecker.checkAll(targets) { [weak self] id, result in
                guard let self, self.checkRun == run else { return }
                // The type it found is the entry's from now on, and the profiles on it follow.
                if let previous = self.list.record(result, for: id), let entry = self.list.entry(id) {
                    self.onEntryChanged?(entry, previous)
                }
                self.checking.remove(id)
                self.checkedCount += 1
            }
            self?.finishCheck(run)
        }
    }

    /// Checks a profile's own proxy (a launch found it not working) as the list checks its
    /// entries (`ProxyChecker`). What it finds is kept by the proxy's entry — added when the list
    /// does not have it — when the profile reaches it the same way (`ProxyList.sameConnection`);
    /// a type it finds is then the entry's, and the profiles on it follow.
    func checkProfileProxy(_ proxy: ProxySettings) async -> ProxyCheckResult {
        let result = await ProxyChecker.check(proxy)
        guard let id = entryID(for: proxy), let entry = list.entry(id), entry.kindKnown,
              ProxyList.sameConnection(entry.proxy, proxy), !checking.contains(id) else { return result }
        var updated = list
        let previous = updated.record(result, for: id)
        guard save(updated) else { return result }
        if let previous, let entry = list.entry(id) { onEntryChanged?(entry, previous) }
        return result
    }

    /// Stops the running check; what it found so far is kept.
    func stopChecking() {
        guard let run = checkRun else { return }
        checkTask?.cancel()
        finishCheck(run)
    }

    private func finishCheck(_ run: UUID) {
        guard checkRun == run else { return }
        checkRun = nil
        checkTask = nil
        checking = []
        save(list)
    }

    // MARK: Saving

    @discardableResult
    private func save(_ updated: ProxyList) -> Bool {
        guard loadError == nil else {
            onError(L("proxies.error.unreadable"))
            return false
        }
        do {
            try updated.save(to: vault)
            list = updated
            return true
        } catch {
            log.error("The proxy list could not be saved: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            onError(String(format: L("proxies.error.save"), error.localizedDescription))
            return false
        }
    }
}
