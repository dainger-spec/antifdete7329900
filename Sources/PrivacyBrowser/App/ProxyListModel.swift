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
            log.error("The proxy list could not be read: \(String(describing: error), privacy: .public)")
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

    func rename(_ id: UUID, to label: String) {
        var updated = list
        updated.rename(id, to: label)
        save(updated)
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
                self.list.record(result, for: id)
                self.checking.remove(id)
                self.checkedCount += 1
            }
            self?.finishCheck(run)
        }
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
            log.error("The proxy list could not be saved: \(String(describing: error), privacy: .public)")
            onError(String(format: L("proxies.error.save"), error.localizedDescription))
            return false
        }
    }
}
