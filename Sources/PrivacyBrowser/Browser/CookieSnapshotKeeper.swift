import BrowserCore
import Foundation
import os
import WebKit

/// Cookie recovery where a profile runs — in its own process, or the app's in the sandboxed build
/// (docs/COOKIE_RECOVERY.md). `CookieRecovery` (BrowserCore) decides; this reads the store through
/// `WKHTTPCookieStore` and the disk, and does what it is told:
///
///   * at a launch, after the website data is unsealed and before the store exists, it looks at the
///     cookie file on disk (`storeState`); once the store exists, before synced cookies or anything
///     else are applied, it puts back what the store lost (`recover`);
///   * while the profile runs, it looks at the store every `checkInterval` seconds and copies it when
///     it is to be copied (`snapshot`), and at once after Lumen's own changes;
///   * at a clean stop, before the seal, it copies the store a last time and removes the running
///     mark (`close`) — only once that copy is written.
///
/// Nothing of a cookie is ever logged: counts, causes and times only.
@MainActor
final class CookieSnapshotKeeper {
    /// What a launch put back, for the profile's journal and the notice in its window.
    struct Report: Codable, Equatable {
        var restored: Int
        /// Cookies of the snapshot WebKit did not keep.
        var refused: Int
        var snapshotTakenAt: Date
        var cause: CookieRecovery.Cause
        /// Shown in the profile's window (`CookieRecoveryNotice`) by the time it was told.
        var noticeShown = false
    }

    /// How often a running profile's store is looked at; the self-test shortens it.
    static var checkInterval: TimeInterval = CookieRecovery.checkInterval

    private let repository: ProfileRepository
    private let log = Logger(subsystem: "PrivacyBrowser", category: "CookieRecovery")
    private var watches: [UUID: Task<Void, Never>] = [:]
    /// The copy of each profile's store under way (`snapshot`): the next waits for it.
    private var copies: [UUID: Task<Bool, Never>] = [:]
    /// The newest snapshot of each running profile, as written or read (nil inside: none yet), so
    /// that a look every half-minute does not decrypt the file.
    private var latest: [UUID: CookieSnapshot?] = [:]
    /// What a launch put back that no window has shown yet, and whether the manager was told.
    private var untold: [UUID: (report: Report, told: Bool)] = [:]

    init(repository: ProfileRepository) {
        self.repository = repository
    }

    // MARK: Launch

    /// What the disk says of the profile's website data once its archive is unsealed (`restored`),
    /// before its store exists — before CFNetwork reads its cookie file, and rewrites it. Only WebKit's
    /// own cookie file that does not hold together is damage (`BinaryCookiesFile`): one of a format not
    /// known here says nothing.
    static func storeState(for id: UUID, restored: WebDataStoreVault.Restored) -> (state: CookieRecovery.StoreState, note: String) {
        guard restored != .nothing else { return (.missing, "no website data") }
        var notes: [String] = []
        var damaged = false
        for file in cookieFiles(of: id) {
            guard let data = try? Data(contentsOf: file) else {
                notes.append("unreadable")
                damaged = true
                continue
            }
            switch BinaryCookiesFile.check(data) {
            case .wellFormed(let records): notes.append("well-formed, \(records) records")
            case .damaged(let reason):
                notes.append("damaged: \(reason)")
                damaged = true
            case .unrecognized: notes.append("of a format not known here")
            }
        }
        if notes.isEmpty { notes.append("no cookie file") }
        return (damaged ? .damaged : .present, notes.joined(separator: "; "))
    }

    /// The profile's cookie files in WebKit's directories (`*.binarycookies`).
    static func cookieFiles(of id: UUID) -> [URL] {
        var found: [URL] = []
        for directory in WebDataStoreVault.discoverDirectories(for: id) {
            guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walk where url.pathExtension.lowercased() == "binarycookies" {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(url) }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// At a launch, once the store exists and before anything is applied to it: whether it lost the
    /// profile's cookies (`CookieRecovery.decide`), and those put back. Nil when it lost none —
    /// otherwise the report, even when WebKit kept none of them: the store is then not the
    /// person's to record for sync (`CookieJarDocument.LaunchStore.recovered`).
    func recover(_ id: UUID, store: WKHTTPCookieStore, state: CookieRecovery.StoreState, note: String) async -> Report? {
        let end = repository.lastCookieRunEnd(for: id)
        let snapshots: CookieSnapshots
        do {
            snapshots = try repository.cookieSnapshots(for: id)
        } catch {
            // Moved aside, not deleted, at the next copy (`addCookieSnapshot`).
            log.error("The cookie snapshots of \(id.uuidString, privacy: .public) could not be read: \(error.logKind, privacy: .public)")
            latest[id] = .some(nil)
            return nil
        }
        latest[id] = .some(snapshots.latest)
        let current = await CookieStoreSync.persistentCookies(in: store)
        let now = Date()
        switch CookieRecovery.decide(store: current, state: state, end: end, latest: snapshots.latest, now: now) {
        case .keep(let why):
            log.info("Cookies of \(id.uuidString, privacy: .public) kept as the store has them: \(why.rawValue, privacy: .public); the store \(state.rawValue, privacy: .public) (\(note, privacy: .public)), the last run \(end.rawValue, privacy: .public), \(current.count) in the store")
            return nil
        case let .restore(cookies, snapshot, cause):
            let result = await CookieStoreImport.apply(cookies, to: store)
            let age = Int(now.timeIntervalSince(snapshot.takenAt))
            log.notice("Cookies of \(id.uuidString, privacy: .public) put back from the snapshot of \(age) s before: \(result.stored) of \(cookies.count), \(result.refused.count) refused; \(cause.rawValue, privacy: .public), the store \(state.rawValue, privacy: .public) (\(note, privacy: .public)), the last run \(end.rawValue, privacy: .public), \(current.count) in the store")
            let report = Report(restored: result.stored, refused: result.refused.count, snapshotTakenAt: snapshot.takenAt, cause: cause)
            if result.stored > 0 { untold[id] = (report: report, told: false) }
            return report
        }
    }

    /// The end of a launch's cookies, before the first page: copies the store when the launch
    /// changed it (cookies put back, synced cookies applied, imported cookies put in) — they are the
    /// profile's state now — marks the run as begun, and looks at the store from now on.
    func begin(_ id: UUID, store: WKHTTPCookieStore, changedAtLaunch: Bool,
               storeNow: @escaping @MainActor () -> WKHTTPCookieStore?) async {
        if changedAtLaunch { await snapshot(id, store: store, trigger: .change) }
        do {
            try repository.markCookieRunStarted(for: id)
        } catch {
            // Without the mark the next launch would take a crash for a clean end: its snapshot for
            // the store as it was sealed. Said; the run goes on.
            log.error("The running mark of \(id.uuidString, privacy: .public) could not be written: \(error.logKind, privacy: .public)")
        }
        watch(id, storeNow: storeNow)
    }

    // MARK: While it runs

    private func watch(_ id: UUID, storeNow: @escaping @MainActor () -> WKHTTPCookieStore?) {
        watches[id]?.cancel()
        let interval = Self.checkInterval
        watches[id] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // Held for one look only: a store held past its stop would keep WebKit from letting it go.
                guard !Task.isCancelled, let self, let store = storeNow() else { return }
                await self.snapshot(id, store: store, trigger: .periodic)
            }
        }
    }

    func stopWatching(_ id: UUID) {
        watches.removeValue(forKey: id)?.cancel()
    }

    /// Copies the store when it is to be copied (`CookieRecovery.shouldSnapshot`) and the profile's
    /// setting, as it is now, keeps snapshots; with the setting turned off meanwhile, removes them.
    /// False when a copy that was due could not be written.
    @discardableResult
    func snapshot(_ id: UUID, store: WKHTTPCookieStore, trigger: CookieSnapshot.Trigger) async -> Bool {
        // One at a time per profile: a look and an import's copy that overlapped would both find the
        // store changed and copy it twice, the second pushing out an older snapshot for nothing.
        let previous = copies[id]
        let copy = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.copy(id, store: store, trigger: trigger)
        }
        copies[id] = copy
        let written = await copy.value
        if copies[id] == copy { copies[id] = nil }
        return written
    }

    private func copy(_ id: UUID, store: WKHTTPCookieStore, trigger: CookieSnapshot.Trigger) async -> Bool {
        let current = await CookieStoreSync.persistentCookies(in: store)
        let now = Date()
        let newest = newestSnapshot(of: id)
        guard CookieRecovery.shouldSnapshot(store: current, latest: newest, trigger: trigger, now: now) else { return true }
        // Turned off, or the profile made ephemeral, while it ran: nothing more is kept.
        if let configuration = try? repository.loadConfiguration(id), !configuration.keepsCookieSnapshots {
            forget(id)
            return true
        }
        do {
            let kept = try repository.addCookieSnapshot(CookieSnapshot(takenAt: now, trigger: trigger, cookies: current), for: id)
            latest[id] = .some(kept.latest)
            log.info("Cookies of \(id.uuidString, privacy: .public) copied (\(trigger.rawValue, privacy: .public)): \(kept.latest?.cookies.count ?? 0) cookies, \(kept.snapshots.count) snapshots kept")
            return true
        } catch {
            log.error("Cookies of \(id.uuidString, privacy: .public) could not be copied (\(trigger.rawValue, privacy: .public)): \(error.logKind, privacy: .public)")
            return false
        }
    }

    private func newestSnapshot(of id: UUID) -> CookieSnapshot? {
        if let known = latest[id] { return known }
        let read = (try? repository.cookieSnapshots(for: id))?.latest
        latest[id] = .some(read)
        return read
    }

    // MARK: Stop

    /// A clean stop, before the website data is sealed (the store's cookies already on disk): the
    /// last copy, then the running mark goes. Kept when that copy was due and not written — or the
    /// store was not there to copy: the next launch then takes the end for unclean, and puts back
    /// only what a far-fewer store lost, rather than every cookie a stale snapshot has.
    func close(_ id: UUID, store: WKHTTPCookieStore?) async {
        stopWatching(id)
        defer { latest[id] = nil }
        if let configuration = try? repository.loadConfiguration(id), !configuration.keepsCookieSnapshots {
            forget(id)
            return
        }
        guard let store, await snapshot(id, store: store, trigger: .close) else {
            log.notice("The running mark of \(id.uuidString, privacy: .public) is kept: its last copy was not made")
            return
        }
        do {
            try repository.markCookieRunEnded(for: id)
        } catch {
            log.error("The running mark of \(id.uuidString, privacy: .public) could not be removed: \(error.logKind, privacy: .public)")
        }
        untold[id] = nil
    }

    /// The profile keeps no snapshots (the setting off, an ephemeral profile): none are, nor its mark.
    func forget(_ id: UUID) {
        stopWatching(id)
        latest[id] = nil
        untold[id] = nil
        do {
            try repository.removeCookieSnapshots(for: id)
        } catch {
            log.error("The cookie snapshots of \(id.uuidString, privacy: .public) could not be removed: \(error.logKind, privacy: .public)")
        }
    }

    // MARK: Telling

    /// What a launch put back and no window has shown yet: taken to be shown (`noticeShown`) or
    /// only told. `firstTime` is true once per report, for the journal.
    func takeUntold(_ id: UUID, shown: Bool) -> (report: Report, firstTime: Bool)? {
        guard let pending = untold[id] else { return nil }
        var report = pending.report
        report.noticeShown = shown
        if shown {
            untold[id] = nil
        } else {
            untold[id] = (report: pending.report, told: true)
        }
        return (report, !pending.told)
    }

    /// What a launch put back and no window has shown yet.
    func untoldReport(_ id: UUID) -> Report? { untold[id]?.report }
}
