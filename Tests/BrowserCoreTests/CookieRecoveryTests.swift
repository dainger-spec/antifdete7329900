import XCTest
@testable import BrowserCore

/// Cookie recovery's decisions (docs/COOKIE_RECOVERY.md): when a running profile's cookies are
/// copied, when a launch puts them back and which, what a deliberate clear, a sign-out and an
/// import do to that, and what a restore tells the synced cookies.
final class CookieRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var later: Date { now.addingTimeInterval(30 * 86_400) }

    private func cookie(_ name: String, _ value: String = "v", domain: String? = nil, expires: Date? = nil,
                        session: Bool = false) -> ImportedCookie {
        ImportedCookie(name: name, value: value, domain: domain ?? "\(name).test", hostOnly: true,
                       expires: session ? nil : (expires ?? later))
    }

    private func cookies(_ names: [String]) -> [ImportedCookie] { names.map { cookie($0) } }
    private func names(_ cookies: [ImportedCookie]) -> [String] { cookies.map(\.name).sorted() }
    private let ten = (0..<10).map { "c\($0)" }

    private func snapshot(_ cookies: [ImportedCookie], at time: Date? = nil, trigger: CookieSnapshot.Trigger = .periodic) -> CookieSnapshot {
        CookieSnapshot(takenAt: time ?? now.addingTimeInterval(-60), trigger: trigger, cookies: cookies)
    }

    private func restored(_ decision: CookieRecovery.Decision) -> (names: [String], cause: CookieRecovery.Cause)? {
        guard case let .restore(cookies, _, cause) = decision else { return nil }
        return (names(cookies), cause)
    }

    // MARK: What a snapshot holds

    func testASnapshotHoldsThePersistentCookiesThatHadNotExpiredOnePerNameDomainAndPath() {
        let taken = snapshot([cookie("b"), cookie("a"), cookie("session", session: true),
                              cookie("old", expires: now.addingTimeInterval(-120)),
                              cookie("a", "newer")])
        XCTAssertEqual(taken.cookies.map(\.name), ["a", "b"], "sorted by domain, path and name; no session or expired cookie")
        XCTAssertEqual(taken.cookies.first?.value, "newer", "the last of the same cookie")
        XCTAssertEqual(snapshot([cookie("a")]).liveCookies(at: later.addingTimeInterval(1)), [], "expired by then: nothing to put back")
    }

    // MARK: When a snapshot is taken

    func testTheFirstSnapshotIsTakenOnlyWhenThereIsSomethingToKeep() {
        for trigger in [CookieSnapshot.Trigger.periodic, .close, .change] {
            XCTAssertFalse(CookieRecovery.shouldSnapshot(store: [], latest: nil, trigger: trigger, now: now))
            XCTAssertTrue(CookieRecovery.shouldSnapshot(store: [cookie("a")], latest: nil, trigger: trigger, now: now))
        }
    }

    func testAnUnchangedStoreIsNotCopiedAgainWhateverAsks() {
        let latest = snapshot(cookies(["a", "b"]), at: now.addingTimeInterval(-3_600))
        // The same cookies in another order, an expiry a few milliseconds off (the store keeps
        // milliseconds), a session cookie more: no change.
        var b = cookie("b")
        b.expires = later.addingTimeInterval(0.4)
        let store = [b, cookie("a"), cookie("visit", session: true)]
        for trigger in [CookieSnapshot.Trigger.periodic, .close, .change] {
            XCTAssertFalse(CookieRecovery.shouldSnapshot(store: store, latest: latest, trigger: trigger, now: now), "\(trigger)")
        }
    }

    func testACookieThatExpiredIsNoChange() {
        let soon = now.addingTimeInterval(10)
        let latest = snapshot([cookie("a"), cookie("short", expires: soon)], at: now.addingTimeInterval(-3_600))
        // The store dropped the expired one by itself.
        XCTAssertFalse(CookieRecovery.shouldSnapshot(store: [cookie("a")], latest: latest, trigger: .periodic, now: soon.addingTimeInterval(1)))
    }

    func testAChangedStoreIsCopiedEveryFewMinutesWhileItRuns() {
        let store = cookies(["a", "b", "c"])
        let young = snapshot(cookies(["a", "b"]), at: now.addingTimeInterval(-(CookieRecovery.snapshotInterval - 1)))
        let old = snapshot(cookies(["a", "b"]), at: now.addingTimeInterval(-CookieRecovery.snapshotInterval))
        XCTAssertFalse(CookieRecovery.shouldSnapshot(store: store, latest: young, trigger: .periodic, now: now))
        XCTAssertTrue(CookieRecovery.shouldSnapshot(store: store, latest: old, trigger: .periodic, now: now))
        // A clock set back since: the newest snapshot is "from the future" — taken anew.
        let ahead = snapshot(cookies(["a", "b"]), at: now.addingTimeInterval(600))
        XCTAssertTrue(CookieRecovery.shouldSnapshot(store: store, latest: ahead, trigger: .periodic, now: now))
    }

    func testACleanStopAndLumensOwnChangesAreCopiedAtOnce() {
        let young = snapshot(cookies(["a", "b"]), at: now.addingTimeInterval(-5))
        for trigger in [CookieSnapshot.Trigger.close, .change] {
            XCTAssertTrue(CookieRecovery.shouldSnapshot(store: cookies(["a"]), latest: young, trigger: trigger, now: now), "\(trigger)")
        }
    }

    func testAMassRemovalWhileTheProfileRunsIsCopiedAtOnceSoThatACrashRightAfterDoesNotUndoIt() {
        let latest = snapshot(cookies(ten), at: now.addingTimeInterval(-5))
        // The person cleared the site's data, or signed out of the site that set most of them.
        let cleared = cookies(["c0", "c1", "c2", "c3"])
        XCTAssertTrue(CookieRecovery.isMassRemoval(store: cleared, latest: latest, now: now))
        XCTAssertTrue(CookieRecovery.shouldSnapshot(store: cleared, latest: latest, trigger: .periodic, now: now))
        XCTAssertTrue(CookieRecovery.shouldSnapshot(store: [], latest: latest, trigger: .periodic, now: now), "everything cleared")
        // A sign-out of one site (two of ten gone) waits for the next periodic copy.
        let signedOut = cookies(Array(ten.dropFirst(2)))
        XCTAssertFalse(CookieRecovery.isMassRemoval(store: signedOut, latest: latest, now: now))
        XCTAssertFalse(CookieRecovery.shouldSnapshot(store: signedOut, latest: latest, trigger: .periodic, now: now))
    }

    // MARK: When a launch puts cookies back

    func testWithoutASnapshotOrAValidCookieInItNothingIsPutBack() {
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .missing, end: .unclean, latest: nil, now: now), .keep(.noSnapshot))
        let expired = snapshot([cookie("a", expires: now.addingTimeInterval(-1))], at: now.addingTimeInterval(-7_200))
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .missing, end: .unclean, latest: expired, now: now), .keep(.nothingToRestore))
        // A snapshot of a deliberately emptied store: nothing to put back either.
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .present, end: .unclean, latest: snapshot([]), now: now),
                       .keep(.nothingToRestore))
    }

    func testAStoreThatHasEveryCookieKeepsItsOwnValues() {
        let latest = snapshot(cookies(["a", "b"]))
        // Changed since the snapshot (a session renewed): the store's value is the newer, and stays.
        let store = [cookie("a", "renewed"), cookie("b"), cookie("new")]
        for state in [CookieRecovery.StoreState.missing, .damaged, .present] {
            for end in [CookieRecovery.RunEnd.clean, .unclean] {
                XCTAssertEqual(CookieRecovery.decide(store: store, state: state, end: end, latest: latest, now: now), .keep(.nothingMissing))
            }
        }
    }

    func testMissingWebsiteDataOrADamagedCookieFileBringsBackEveryCookieTheStoreLacks() {
        let latest = snapshot(cookies(ten))
        let missing = CookieRecovery.decide(store: [], state: .missing, end: .clean, latest: latest, now: now)
        XCTAssertEqual(restored(missing)?.names, ten.sorted())
        XCTAssertEqual(restored(missing)?.cause, .websiteDataMissing)
        // A damaged file that still gave the store most of its cookies: the one it lost comes back,
        // after an unclean end as well.
        let damaged = CookieRecovery.decide(store: cookies(Array(ten.dropFirst())), state: .damaged, end: .unclean, latest: latest, now: now)
        XCTAssertEqual(restored(damaged)?.names, ["c0"])
        XCTAssertEqual(restored(damaged)?.cause, .cookieFileDamaged)
    }

    func testAfterACleanEndACookieTheSealedStoreLacksWasLost() {
        // The snapshot was taken as the store was sealed; nothing changes a sealed store.
        let latest = snapshot(cookies(ten), at: now.addingTimeInterval(-86_400), trigger: .close)
        let decision = CookieRecovery.decide(store: cookies(Array(ten.dropFirst())), state: .present, end: .clean, latest: latest, now: now)
        XCTAssertEqual(restored(decision)?.names, ["c0"])
        XCTAssertEqual(restored(decision)?.cause, .cleanEnd)
    }

    func testAfterAnUncleanEndASignOutIsNotALoss() {
        // Two of ten gone since the last snapshot: a site signed the person out (or they deleted
        // them) before the crash — theirs, kept gone.
        let latest = snapshot(cookies(ten))
        let store = cookies(Array(ten.dropFirst(2)))
        XCTAssertEqual(CookieRecovery.decide(store: store, state: .present, end: .unclean, latest: latest, now: now),
                       .keep(.fewMissingAfterUncleanEnd))
        // Exactly half kept is not "far fewer".
        XCTAssertEqual(CookieRecovery.decide(store: cookies(Array(ten.prefix(5))), state: .present, end: .unclean, latest: latest, now: now),
                       .keep(.fewMissingAfterUncleanEnd))
    }

    func testAfterAnUncleanEndFarFewerCookiesIsALoss() {
        let latest = snapshot(cookies(ten))
        let decision = CookieRecovery.decide(store: cookies(["c0", "c1", "c2", "c3"]), state: .present, end: .unclean, latest: latest, now: now)
        XCTAssertEqual(restored(decision)?.names, ["c4", "c5", "c6", "c7", "c8", "c9"], "only those it lacks")
        XCTAssertEqual(restored(decision)?.cause, .uncleanEnd)
        let empty = CookieRecovery.decide(store: [], state: .present, end: .unclean, latest: snapshot([cookie("only")]), now: now)
        XCTAssertEqual(restored(empty)?.names, ["only"])
    }

    func testNeitherAnExpiredNorASessionCookieIsEverPutBack() {
        let soon = now.addingTimeInterval(60)
        let latest = snapshot([cookie("lasting"), cookie("brief", expires: soon), cookie("session", session: true)])
        let decision = CookieRecovery.decide(store: [], state: .missing, end: .unclean, latest: latest, now: soon.addingTimeInterval(1))
        XCTAssertEqual(restored(decision)?.names, ["lasting"])
        XCTAssertEqual(CookieRecovery.manualRestore(from: latest, now: soon.addingTimeInterval(1)).map(\.name), ["lasting"])
    }

    func testOnlyTheNewestSnapshotDecides() {
        // The person cleared the store while it ran (copied at once), then the profile crashed: the
        // snapshots before the clear are not used for it — they are for a restore by hand.
        var kept = CookieSnapshots()
        kept.add(snapshot(cookies(ten), at: now.addingTimeInterval(-600)))
        kept.add(snapshot([], at: now.addingTimeInterval(-30)))
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .present, end: .unclean, latest: kept.latest, now: now), .keep(.nothingToRestore))
        XCTAssertEqual(kept.newestFirst.last?.cookies.count, 10)
    }

    func testADomainCookieAndAHostOnlyOneOfTheSameNameAreTwoCookies() {
        var domainCookie = cookie("sid", domain: "site.test")
        domainCookie.hostOnly = false
        let hostOnly = cookie("sid", domain: "site.test")
        let decision = CookieRecovery.decide(store: [hostOnly], state: .present, end: .clean, latest: snapshot([domainCookie, hostOnly]), now: now)
        XCTAssertEqual(restored(decision)?.names, ["sid"])
        if case let .restore(cookies, _, _) = decision { XCTAssertEqual(cookies.first?.hostOnly, false, "the domain cookie, the one it lacks") }
    }

    // MARK: The clear and import cases, end to end through the policy

    /// A run as the app drives the policy: each look at the store, and what is kept.
    private func run(from latest: CookieSnapshots, looks: [(TimeInterval, [ImportedCookie], CookieSnapshot.Trigger)]) -> CookieSnapshots {
        var kept = latest
        for (offset, store, trigger) in looks {
            let time = now.addingTimeInterval(offset)
            if CookieRecovery.shouldSnapshot(store: store, latest: kept.latest, trigger: trigger, now: time) {
                kept.add(CookieSnapshot(takenAt: time, trigger: trigger, cookies: store))
            }
        }
        return kept
    }

    func testCookiesClearedInTheStoreAreNotPutBackAfterACrash() {
        let start = run(from: CookieSnapshots(), looks: [(-3_600, cookies(Array(ten.dropLast())), .close)])
        // Launched, a cookie set, copied at the first look; then the person clears the store (Web
        // Inspector, a site's "delete my data"): the next look, 30 seconds later — well within the
        // periodic interval — copies it at once; the process is then killed.
        let after = run(from: start, looks: [(0, cookies(ten), .periodic), (30, [], .periodic)])
        XCTAssertEqual(after.snapshots.map(\.cookies.count), [9, 10, 0])
        XCTAssertEqual(after.latest?.takenAt, now.addingTimeInterval(30))
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .present, end: .unclean, latest: after.latest, now: now.addingTimeInterval(60)),
                       .keep(.nothingToRestore))
    }

    func testCookiesDeletedThroughLumenAreNotPutBackAfterACrash() {
        let start = run(from: CookieSnapshots(), looks: [(-3_600, cookies(ten), .close)])
        // WebDriver's deleteCookies: Lumen's own change, copied at once.
        let after = run(from: start, looks: [(5, [], .change)])
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .present, end: .unclean, latest: after.latest, now: now.addingTimeInterval(6)),
                       .keep(.nothingToRestore))
        // Even with the cookie file damaged at the next launch: nothing was there to lose.
        XCTAssertEqual(CookieRecovery.decide(store: [], state: .damaged, end: .unclean, latest: after.latest, now: now.addingTimeInterval(6)),
                       .keep(.nothingToRestore))
    }

    func testAnImportThatReplacedCookiesIsWhatARestorePutsBack() {
        let start = run(from: CookieSnapshots(), looks: [(-3_600, [cookie("sid", "old"), cookie("x")], .close)])
        // An import into the running profile replaces sid's value: copied at once.
        let imported = [cookie("sid", "imported"), cookie("x")]
        let after = run(from: start, looks: [(5, imported, .change)])
        XCTAssertEqual(after.latest?.cookies.first { $0.name == "sid" }?.value, "imported")
        // The store lost its cookie file before the next launch: the imported value comes back, not the old one.
        guard case let .restore(back, _, _) = CookieRecovery.decide(store: [], state: .missing, end: .clean, latest: after.latest,
                                                                   now: now.addingTimeInterval(60)) else { return XCTFail("nothing put back") }
        XCTAssertEqual(back.first { $0.name == "sid" }?.value, "imported")
    }

    func testASignOutBeforeACrashStaysSignedOut() {
        let start = run(from: CookieSnapshots(), looks: [(-3_600, cookies(Array(ten.dropLast())), .close)])
        // Two cookies of one site gone 10 s after a periodic copy; the crash comes before the next.
        let store = cookies(Array(ten.dropFirst(2)))
        let after = run(from: start, looks: [(0, cookies(ten), .periodic), (10, store, .periodic)])
        XCTAssertEqual(after.latest?.takenAt, now)
        XCTAssertEqual(after.latest?.cookies.count, 10, "not copied yet: a sign-out waits for the periodic copy")
        XCTAssertEqual(CookieRecovery.decide(store: store, state: .present, end: .unclean, latest: after.latest, now: now.addingTimeInterval(20)),
                       .keep(.fewMissingAfterUncleanEnd))
    }

    // MARK: Rotation

    func testTheLastThreeSnapshotsAreKeptInTheOrderTheyWereTaken() {
        var kept = CookieSnapshots()
        let taken = (0..<5).map { snapshot([cookie("n\($0)")], at: now.addingTimeInterval(Double($0))) }
        for item in taken { kept.add(item) }
        XCTAssertEqual(kept.snapshots, Array(taken.suffix(3)))
        XCTAssertEqual(kept.latest, taken.last)
        XCTAssertEqual(kept.newestFirst.map(\.id), taken.suffix(3).reversed().map(\.id))
        // Taken after a clock was set back: still the newest.
        let back = snapshot([cookie("back")], at: now.addingTimeInterval(-86_400))
        kept.add(back)
        XCTAssertEqual(kept.latest, back)
        XCTAssertEqual(CookieSnapshots(snapshots: taken).snapshots.count, CookieSnapshots.kept)
    }

    func testATriggerOfALaterVersionIsReadAsAPeriodicOne() throws {
        let json = #"{"id":"6C6E3B2A-0E64-4F0B-9E8C-5D0B8A1D2C3E","takenAt":"2030-01-01T00:00:00Z","trigger":"somethingNew","cookies":[]}"#
        let read = try JSONCoding.decoder.decode(CookieSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(read.trigger, .periodic)
    }

    // MARK: The synced cookies after a restore

    private let baselineTime = Date(timeIntervalSince1970: 1_899_990_000)

    private func entry(_ cookie: ImportedCookie, at time: Date) -> CookieJarDocument.Entry {
        CookieJarDocument.Entry(cookie: cookie, updatedAt: time)
    }

    func testARestoredStoreRecordsNoDeletionAndItsChangesAsOfTheBaseline() {
        let baseline = CookieBaseline(cookies: cookies(["a", "b", "lost"]), savedAt: baselineTime)
        let loaded = CookieJarDocument(cookies: baseline.cookies.map { entry($0, at: baselineTime) })
        // The store lost "lost" (not in the snapshot either) and had "b" renewed and "new" set by the
        // crashed run, which the snapshot put back.
        let store = [cookie("a"), cookie("b", "renewed"), cookie("new")]
        let jar = loaded.atLaunch(store: store, baseline: baseline, came: .recovered)
        XCTAssertEqual(jar.deleted, [], "what the damaged store lacks is no deletion")
        XCTAssertEqual(names(jar.liveCookies(at: now)), ["a", "b", "lost", "new"])
        XCTAssertEqual(jar.cookies.first { $0.cookie.name == "b" }?.cookie.value, "renewed")
        XCTAssertEqual(Set(jar.cookies.filter { ["b", "new"].contains($0.cookie.name) }.map(\.updatedAt)), [baselineTime],
                       "changes of the run before, as of the baseline: anything newer from another device wins")
        // Applied, the document puts back what neither the store nor its snapshot had.
        XCTAssertEqual(jar.changes(over: store, at: now).set.map(\.name), ["lost"])
        // Before the restore mode existed, the same store as it was left would have recorded "lost" as deleted.
        XCTAssertEqual(loaded.atLaunch(store: store, baseline: baseline, came: .asLeft).deleted.map(\.key.name), ["lost"])
    }

    func testARestoreNeverPushesAStaleCookieOverAnotherDevicesNewerChange() {
        let baseline = CookieBaseline(cookies: cookies(["sid", "gone"]), savedAt: baselineTime)
        let newer = baselineTime.addingTimeInterval(3_600)
        // Merged by sync while the profile was stopped: another Mac renewed sid and signed out of "gone".
        let loaded = CookieJarDocument(cookies: [entry(cookie("sid", "from-other-mac"), at: newer)],
                                       deleted: [CookieJarDocument.Tombstone(key: CookieKey(cookie("gone")), deletedAt: newer)])
        // This Mac's snapshot put back its older sid and "gone".
        let store = [cookie("sid", "from-snapshot"), cookie("gone", "from-snapshot")]
        let jar = loaded.atLaunch(store: store, baseline: baseline, came: .recovered)
        XCTAssertEqual(jar.cookies.map(\.cookie.value), ["from-other-mac"])
        XCTAssertEqual(jar.deleted.map(\.key.name), ["gone"])
        // Applied before the first page: the newer sid replaces the restored one, "gone" goes again.
        let changes = jar.changes(over: store, at: now)
        XCTAssertEqual(changes.set.map(\.value), ["from-other-mac"])
        XCTAssertEqual(changes.delete.map(\.name), ["gone"])
        // And merged on the other Mac, nothing of the snapshot wins there.
        XCTAssertEqual(CookieJarDocument.merge(loaded, jar, now: now), loaded.pruned(at: now))
    }

    func testARestoredCookieTheSyncedCookiesDoNotKnowFillsThemInOnce() {
        let baseline = CookieBaseline(cookies: [], savedAt: baselineTime)
        let restoredCookie = cookie("fresh")
        let jar = CookieJarDocument().atLaunch(store: [restoredCookie], baseline: baseline, came: .recovered)
        XCTAssertEqual(jar.cookies, [entry(restoredCookie, at: baselineTime)])
        // Recorded again as nothing new: no duplicate, no loop.
        let again = jar.atLaunch(store: [restoredCookie], baseline: CookieBaseline(cookies: [restoredCookie], savedAt: now), came: .recovered)
        XCTAssertEqual(again, jar)
        XCTAssertEqual(CookieJarDocument.merge(jar, again, now: now).cookies.count, 1)
    }

    // MARK: The profile's setting

    func testTheSettingIsOnByDefaultWrittenOnlyWhenOffAndNeverForAnEphemeralProfile() throws {
        let standard = ProfileConfiguration()
        XCTAssertTrue(standard.cookieRecovery)
        XCTAssertTrue(standard.keepsCookieSnapshots)
        XCTAssertFalse(String(decoding: try JSONCoding.encoder.encode(standard), as: UTF8.self).contains("cookieRecovery"),
                       "a profile that keeps snapshots is written as before")
        var off = standard
        off.cookieRecovery = false
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(off))
        XCTAssertFalse(decoded.cookieRecovery)
        XCTAssertFalse(decoded.keepsCookieSnapshots)
        XCTAssertFalse(ProfileConfiguration(ephemeral: true).keepsCookieSnapshots)
        XCTAssertFalse(standard.hasSameSettings(as: off), "a change of it is an edit of the settings")
    }
}

/// The snapshots on disk: sealed in the profile's folder under its own key, written whole, rotated,
/// moved aside rather than lost when they do not open, and the running mark.
final class CookieSnapshotFileTests: XCTestCase {
    private var base: URL!
    private var repository: ProfileRepository!
    private var id: UUID!
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-cookie-snapshots-\(UUID().uuidString)")
        repository = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("vault"), password: "pw", iterations: 1_000))
        id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func snapshot(_ value: String, _ offset: TimeInterval = 0) -> CookieSnapshot {
        CookieSnapshot(takenAt: now.addingTimeInterval(offset), trigger: .periodic,
                       cookies: [ImportedCookie(name: "sid", value: value, domain: "site.test", hostOnly: true,
                                                expires: now.addingTimeInterval(86_400))])
    }

    func testSnapshotsAreSealedInTheProfilesFolderAndNeverInPlaintext() throws {
        try repository.addCookieSnapshot(snapshot("secret-session-value"), for: id)
        let url = repository.cookieSnapshotsURL(for: id)
        XCTAssertEqual(url.deletingLastPathComponent(), repository.directory(for: id))
        let bytes = try Data(contentsOf: url)
        for plain in ["secret-session-value", "site.test", "sid"] {
            XCTAssertNil(bytes.range(of: Data(plain.utf8)), "\(plain) readable on disk")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try repository.cookieSnapshots(for: id).latest?.cookies.first?.value, "secret-session-value")
        // No temporary file left beside it: written whole, then renamed.
        let names = try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: id).path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") }, "\(names)")
    }

    func testAnotherProfileCannotOpenThem() throws {
        try repository.addCookieSnapshot(snapshot("a"), for: id)
        let other = try repository.create(name: "Q", configuration: ProfileConfiguration()).id
        // Its process holds its own key only (a grant): this profile's file is not its to open.
        let granted = try ProfileRepository(vault: MasterVault.open(in: repository.root, grant: repository.grant(for: other)))
        XCTAssertThrowsError(try granted.cookieSnapshots(for: id))
        // Copied into its folder, the bytes do not open with its key either (key and AAD are the profile's).
        try FileManager.default.copyItem(at: repository.cookieSnapshotsURL(for: id), to: repository.cookieSnapshotsURL(for: other))
        XCTAssertThrowsError(try granted.cookieSnapshots(for: other))
        // Its own process opens its own.
        let mine = try ProfileRepository(vault: MasterVault.open(in: repository.root, grant: repository.grant(for: id)))
        XCTAssertEqual(try mine.cookieSnapshots(for: id).latest?.cookies.first?.value, "a")
    }

    func testEachSnapshotIsAddedAndTheOldestGoesBeyondThree() throws {
        for (index, value) in ["1", "2", "3", "4"].enumerated() {
            try repository.addCookieSnapshot(snapshot(value, Double(index)), for: id)
        }
        let kept = try repository.cookieSnapshots(for: id)
        XCTAssertEqual(kept.snapshots.map { $0.cookies.first?.value }, ["2", "3", "4"])
    }

    func testSnapshotsThatDoNotOpenAreMovedAsideAndBegunAnew() throws {
        try repository.addCookieSnapshot(snapshot("1"), for: id)
        let url = repository.cookieSnapshotsURL(for: id)
        try Data("damaged".utf8).write(to: url)
        XCTAssertThrowsError(try repository.cookieSnapshots(for: id))
        try repository.addCookieSnapshot(snapshot("2"), for: id)
        XCTAssertEqual(try repository.cookieSnapshots(for: id).snapshots.map { $0.cookies.first?.value }, ["2"])
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unreadable")), Data("damaged".utf8), "never deleted")
    }

    func testANewerVersionsSnapshotsAreNeitherReadNorWrittenOver() throws {
        let file = try repository.cookieSnapshotsFile(for: id)
        let newer = try AEAD.seal(Data(#"{"format":2,"snapshots":[]}"#.utf8), key: file.key, aad: file.aad)
        try newer.write(to: repository.cookieSnapshotsURL(for: id))
        XCTAssertThrowsError(try repository.cookieSnapshots(for: id))
        XCTAssertThrowsError(try repository.addCookieSnapshot(snapshot("x"), for: id))
        XCTAssertThrowsError(try repository.removeCookieSnapshots(for: id))
        XCTAssertEqual(try Data(contentsOf: repository.cookieSnapshotsURL(for: id)), newer)
    }

    func testTheRunningMarkTellsHowTheLastRunEnded() throws {
        XCTAssertEqual(repository.lastCookieRunEnd(for: id), .clean, "never ran")
        try repository.markCookieRunStarted(for: id)
        XCTAssertEqual(repository.lastCookieRunEnd(for: id), .unclean, "a crash leaves the mark")
        try repository.markCookieRunEnded(for: id)
        XCTAssertEqual(repository.lastCookieRunEnd(for: id), .clean)
        try repository.markCookieRunEnded(for: id) // twice: nothing to do
    }

    func testTurnedOffNoSnapshotAndNoMarkIsKept() throws {
        try repository.addCookieSnapshot(snapshot("1"), for: id)
        try repository.markCookieRunStarted(for: id)
        try repository.removeCookieSnapshots(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.cookieSnapshotsURL(for: id).path))
        XCTAssertEqual(repository.lastCookieRunEnd(for: id), .clean)
        XCTAssertEqual(try repository.cookieSnapshots(for: id), CookieSnapshots())
        try repository.removeCookieSnapshots(for: id) // none: nothing to do
    }

    func testARestorePointCarriesTheSnapshotsAndTheMarkWithTheWebsiteData() throws {
        try Data("site data 1".utf8).write(to: repository.webDataArchiveURL(for: id))
        try repository.addCookieSnapshot(snapshot("at point"), for: id)
        try repository.markCookieRunStarted(for: id) // the run before the point crashed
        let point = try repository.createRestorePoint(for: id, name: "P", at: now)
        XCTAssertTrue(point.files.contains("cookie-snapshots.bin") && point.files.contains("cookies-running"), "\(point.files)")

        // Later: launched and stopped cleanly, other cookies.
        try repository.markCookieRunEnded(for: id)
        try repository.addCookieSnapshot(snapshot("after point", 60), for: id)
        try repository.restore(point.id, for: id, at: now.addingTimeInterval(120))
        XCTAssertEqual(try repository.cookieSnapshots(for: id).latest?.cookies.first?.value, "at point",
                       "the point's own snapshots: its cookies are not taken for a loss, the later ones not put back")
        XCTAssertEqual(repository.lastCookieRunEnd(for: id), .unclean, "as the point's state was")

        // A point made before snapshots existed: the restore leaves none, and no mark.
        let folder = repository.restorePointDirectory(point.id, for: id)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("cookie-snapshots.bin"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("cookies-running"))
        var described = try XCTUnwrap(repository.restorePoints(for: id).first { $0.id == point.id })
        described.files.removeAll { $0 == "cookie-snapshots.bin" || $0 == "cookies-running" }
        try repository.restorePointFile(point.id, for: id).save(described)
        try repository.restore(point.id, for: id, at: now.addingTimeInterval(180))
        XCTAssertEqual(try repository.cookieSnapshots(for: id), CookieSnapshots())
        XCTAssertEqual(repository.lastCookieRunEnd(for: id), .clean)
    }
}

/// WebKit's cookie file, checked for holding together without reading a cookie out of it.
final class BinaryCookiesFileTests: XCTestCase {
    private func be32(_ value: Int) -> [UInt8] { (0..<4).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }

    /// A cookie record: its size, the fixed fields (zeros here) and its strings.
    private func record(_ name: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 56)
        for text in ["site.test", name, "/", "value"] {
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(0)
        }
        bytes.replaceSubrange(0..<4, with: le32(bytes.count))
        return bytes
    }

    private func page(_ names: [String]) -> [UInt8] {
        let records: [[UInt8]] = names.map { record($0) }
        var offset = 8 + 4 * records.count + 4
        var bytes: [UInt8] = [0x00, 0x00, 0x01, 0x00]
        bytes.append(contentsOf: le32(records.count))
        for item in records {
            bytes.append(contentsOf: le32(offset))
            offset += item.count
        }
        bytes.append(contentsOf: [0, 0, 0, 0])
        for item in records { bytes.append(contentsOf: item) }
        return bytes
    }

    private func file(_ pages: [[String]]) -> [UInt8] {
        let built: [[UInt8]] = pages.map { page($0) }
        var bytes: [UInt8] = Array("cook".utf8)
        bytes.append(contentsOf: be32(built.count))
        for item in built { bytes.append(contentsOf: be32(item.count)) }
        for item in built { bytes.append(contentsOf: item) }
        // The checksum and the footer CFNetwork writes after the pages.
        bytes.append(contentsOf: [0, 0, 0x1A, 0x2B, 0x07, 0x17, 0x20, 0x05, 0x00, 0x00, 0x00, 0x4B])
        return bytes
    }

    func testAWellFormedFileIsCountedWithoutReadingItsCookies() {
        XCTAssertEqual(BinaryCookiesFile.check(Data(file([["a", "b"], ["c"]]))), .wellFormed(cookies: 3))
        XCTAssertEqual(BinaryCookiesFile.check(Data(file([]))), .wellFormed(cookies: 0), "an empty store")
        XCTAssertEqual(BinaryCookiesFile.check(Data(file([[]]))), .wellFormed(cookies: 0))
    }

    func testAFileCutShortIsDamagedWhereverItEnds() {
        let whole = file([["a", "b"], ["c"]])
        let pagesEnd = whole.count - 12 // checksum and footer
        for length in [0, 2, 6, 10, 20, pagesEnd - 1] {
            guard case .damaged = BinaryCookiesFile.check(Data(whole.prefix(length))) else {
                return XCTFail("cut at \(length) of \(whole.count): \(BinaryCookiesFile.check(Data(whole.prefix(length))))")
            }
        }
    }

    func testRecordsOrPagesRunningPastTheirEndsAreDamage() {
        var bytes = file([["a"]])
        // The first record's size made larger than its page.
        let recordStart = 8 + 4 + 8 + 4 + 4
        bytes.replaceSubrange(recordStart..<recordStart + 4, with: le32(10_000))
        guard case .damaged = BinaryCookiesFile.check(Data(bytes)) else { return XCTFail("\(BinaryCookiesFile.check(Data(bytes)))") }
        var offsets = file([["a"]])
        offsets.replaceSubrange(8 + 4 + 8..<8 + 4 + 12, with: le32(4)) // a record inside the page's own header
        guard case .damaged = BinaryCookiesFile.check(Data(offsets)) else { return XCTFail("\(BinaryCookiesFile.check(Data(offsets)))") }
        var pageCount = file([["a"]])
        pageCount.replaceSubrange(4..<8, with: be32(0x7FFF_FFFF))
        guard case .damaged = BinaryCookiesFile.check(Data(pageCount)) else { return XCTFail("\(BinaryCookiesFile.check(Data(pageCount)))") }
    }

    func testAnotherFormatSaysNothingEitherWay() {
        XCTAssertEqual(BinaryCookiesFile.check(Data("SQLite format 3\u{0}".utf8)), .unrecognized)
        var otherPage = file([["a"]])
        otherPage.replaceSubrange(12..<16, with: [0x00, 0x00, 0x02, 0x00])
        XCTAssertEqual(BinaryCookiesFile.check(Data(otherPage)), .unrecognized)
    }
}
