import XCTest
@testable import BrowserCore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class VMProfileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-vm-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testANetworkCardsAddressIsItsOwnLocallyAdministeredAndUnicast() {
        var generator = SeededGenerator(state: 3)
        let addresses = (0..<200).map { _ in VMProfile.randomMACAddress(using: &generator) }
        XCTAssertEqual(Set(addresses).count, 200)
        for address in addresses {
            let bytes = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            XCTAssertEqual(bytes.count, 6, address)
            XCTAssertEqual(bytes[0] & 0x02, 0x02, "locally administered: \(address)")
            XCTAssertEqual(bytes[0] & 0x01, 0, "unicast: \(address)")
        }
    }

    func testAProfileIsCheckedBeforeItIsKept() throws {
        let proxy = ProxySettings(kind: .socks5, host: "de.example", port: 1080, username: "u", password: "p")
        XCTAssertNoThrow(try VMProfile(name: "Shop", proxy: proxy, timeZoneIdentifier: "Europe/Berlin", language: "de-DE",
                                       startURL: "https://example.com/").validate())
        XCTAssertThrowsError(try VMProfile(name: "  ").validate())
        XCTAssertThrowsError(try VMProfile(name: "A", timeZoneIdentifier: "Mars/Olympus").validate())
        XCTAssertThrowsError(try VMProfile(name: "A", language: "not a tag").validate())
        XCTAssertThrowsError(try VMProfile(name: "A", startURL: "file:///etc/passwd").validate())
        XCTAssertThrowsError(try VMProfile(name: "A", memoryGB: 1).validate())
        XCTAssertThrowsError(try VMProfile(name: "A", proxy: ProxySettings(kind: .httpConnect, host: "p.example", port: 443, tlsToProxy: true)).validate(),
                             "TLS to the proxy is not carried by the machine's network yet")
        XCTAssertEqual(try VMProfile.validatedName("  Shop DE \nsecond line"), "Shop DE")
    }

    func testTheTimeZoneAndLanguageFollowWhereTheProxyComesOut() {
        let proxy = ProxySettings(kind: .socks5, host: "fr.example", port: 1080)
        let check = ProxyCheckResult(checkedAt: Date(), exitIP: "203.0.113.7", countryCode: "fr", timeZoneIdentifier: "Europe/Paris")
        let followed = VMProfile(name: "A", proxy: proxy).followingProxy(check: check)
        XCTAssertEqual(followed.timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(followed.language, "fr-FR")
        XCTAssertEqual(followed.countryCode, "FR")

        // The person's own choice stays; so does a profile whose proxy did not answer, or has none.
        let own = VMProfile(name: "A", proxy: proxy, timeZoneIdentifier: "Asia/Tokyo", language: "ja-JP", localeFollowsProxy: false)
        XCTAssertEqual(own.followingProxy(check: check), own)
        let dead = ProxyCheckResult(checkedAt: Date(), failure: .noAnswer, countryCode: "FR", timeZoneIdentifier: "Europe/Paris")
        XCTAssertNil(VMProfile(name: "A", proxy: proxy).followingProxy(check: dead).timeZoneIdentifier)
        XCTAssertNil(VMProfile(name: "A").followingProxy(check: check).timeZoneIdentifier)
    }

    /// A machine without a proxy takes the time zone and language of the place this Mac's own
    /// connection comes out at only when the person chose that for it: finding the place is a
    /// request from this Mac to a service.
    func testWithoutAProxyTheConnectionIsFollowedOnlyWhereThePersonChoseIt() throws {
        let exit = ProxyCheckResult(checkedAt: Date(), exitIP: "203.0.113.9", countryCode: "de", timeZoneIdentifier: "Europe/Berlin")
        // Not chosen: nothing is asked, and nothing taken.
        let plain = VMProfile(name: "A")
        XCTAssertFalse(plain.localeFollowsConnection)
        XCTAssertFalse(plain.asksWhereTheConnectionComesOut)
        XCTAssertEqual(plain.followingConnection(exit: exit), plain)
        // Chosen.
        let chosen = VMProfile(name: "A", localeFollowsConnection: true)
        XCTAssertTrue(chosen.asksWhereTheConnectionComesOut)
        let followed = chosen.followingConnection(exit: exit)
        XCTAssertEqual(followed.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(followed.language, "de-DE")
        XCTAssertEqual(followed.countryCode, "DE")
        let settings = VMGuestSettings(profile: followed).text
        XCTAssertTrue(settings.contains("LUMEN_TIMEZONE=Europe/Berlin\n"))
        XCTAssertTrue(settings.contains("LUMEN_LOCALE=de_DE\n"))
        // No answer: the machine keeps what it had.
        let before = VMProfile(name: "A", timeZoneIdentifier: "Europe/Paris", language: "fr-FR", localeFollowsConnection: true)
        XCTAssertEqual(before.followingConnection(exit: ProxyCheckResult.dead(.noAnswer)), before)
        XCTAssertEqual(before.followingConnection(exit: nil), before)
        // With a proxy the proxy is followed, not the Mac; set by hand, nothing is.
        let proxied = VMProfile(name: "A", proxy: ProxySettings(kind: .socks5, host: "fr.example", port: 1080), localeFollowsConnection: true)
        XCTAssertFalse(proxied.asksWhereTheConnectionComesOut)
        XCTAssertEqual(proxied.followingConnection(exit: exit), proxied)
        let own = VMProfile(name: "A", timeZoneIdentifier: "Asia/Tokyo", language: "ja-JP", localeFollowsProxy: false, localeFollowsConnection: true)
        XCTAssertFalse(own.asksWhereTheConnectionComesOut)
        XCTAssertEqual(own.followingConnection(exit: exit), own)
        // Kept through a save, and absent in a list from before the choice.
        XCTAssertTrue(try JSONCoding.decoder.decode(VMProfile.self, from: JSONCoding.encoder.encode(chosen)).localeFollowsConnection)
        let old = #"{"id":"6F1C2E8A-0B0D-4C36-9C2A-7E7C0A1B2C3D","name":"Old","displayID":"macbook-air-13","memoryGB":4,"macAddress":"02:11:22:33:44:55"}"#
        XCTAssertFalse(try JSONCoding.decoder.decode(VMProfile.self, from: Data(old.utf8)).localeFollowsConnection)
        // A region of the person's own goes with a language set by hand only.
        XCTAssertTrue(VMGuestSettings(profile: VMProfile(name: "A", language: "en-US", regionCode: "DE", localeFollowsConnection: true)).text.contains("LUMEN_LOCALE=en_US\n"))
        XCTAssertTrue(VMGuestSettings(profile: VMProfile(name: "A", language: "en-US", localeFollowsProxy: false, regionCode: "DE")).text.contains("LUMEN_LOCALE=en_DE\n"))
    }

    func testTheProfilesAreStoredEncryptedAtTheVaultsRootAndNotSynced() async throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let vault = repository.vault
        XCTAssertEqual(try VMProfiles.load(from: vault), VMProfiles())
        var profiles = VMProfiles()
        // Whole seconds: the file keeps times to the second.
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        let proxy = ProxySettings(kind: .socks5, host: "de.example", port: 1080, username: "user", password: "secret-password")
        let first = VMProfile(name: "Shop DE", createdAt: made, proxy: proxy, macAddress: "02:00:00:00:00:01")
        try profiles.save(first)
        // The same card's address on a second machine is replaced.
        try profiles.save(VMProfile(name: "Shop FR", createdAt: made, macAddress: "02:00:00:00:00:01"))
        XCTAssertNotEqual(profiles.profiles[1].macAddress, "02:00:00:00:00:01")
        XCTAssertThrowsError(try profiles.save(VMProfile(name: "")))
        try profiles.save(to: vault)
        XCTAssertEqual(try VMProfiles.load(from: vault), profiles)
        let onDisk = try Data(contentsOf: vault.root.appendingPathComponent("vms.bin"))
        XCTAssertNil(onDisk.range(of: Data("secret-password".utf8)))
        XCTAssertNil(onDisk.range(of: Data("Shop DE".utf8)))

        var renamed = first
        renamed.name = "Shop Berlin"
        try profiles.save(renamed)
        XCTAssertEqual(profiles.profiles.map(\.name), ["Shop Berlin", "Shop FR"], "saved again by its id: replaced, not added")
        profiles.markLaunched(first.id, at: made.addingTimeInterval(60))
        XCTAssertEqual(profiles.profile(first.id)?.lastLaunchedAt, made.addingTimeInterval(60))
        XCTAssertEqual(profiles.remove(first.id)?.id, first.id)
        XCTAssertNil(profiles.remove(first.id))

        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let report = try await SyncEngine(repository: repository, transport: transport).sync()
        XCTAssertFalse(report.pushed.contains { $0.contains("vms") }, "the machines are this Mac's")

        // A later version's profile does not cost the list; a later format is refused whole.
        let later = #"{"format": 1, "profiles": [{"id": 7}, {"id": "\#(UUID().uuidString)", "name": "Kept"}]}"#
        XCTAssertEqual(try JSONCoding.decoder.decode(VMProfiles.self, from: Data(later.utf8)).profiles.map(\.name), ["Kept"])
    }
}

final class VMRequirementsTests: XCTestCase {
    func testTheScreensAreRealMacsAndAnUnknownOneIsTheStandard() {
        XCTAssertEqual(VMDisplay.standard.pointsWide, 1470)
        XCTAssertEqual(VMDisplay.standard.pixelsWide, 2940)
        XCTAssertEqual(VMDisplay.preset("macbook-pro-14").pointsHigh, 982)
        XCTAssertEqual(VMDisplay.preset("a-later-versions-screen"), VMDisplay.standard)
        XCTAssertEqual(Set(VMDisplay.presets.map(\.id)).count, VMDisplay.presets.count)
        XCTAssertEqual(VMDisplay.preset("external-1080p").pixelsWide, 1920, "an ordinary screen is not doubled")
    }

    func testWhatStandsInTheWayIsSaidBeforeAnythingIsFetched() {
        let gib = VMRequirements.gibibyte
        let download = 17 * gib
        let needed = VMRequirements.setupBytes(downloadBytes: download)
        XCTAssertGreaterThan(needed, download + VMRequirements.installedBaseBytes)
        XCTAssertEqual(VMRequirements.problems(appleSilicon: true, helperAvailable: true, freeDisk: needed, downloadBytes: download,
                                               hostMemory: 16 * gib), [])
        let all = VMRequirements.problems(appleSilicon: false, helperAvailable: false, freeDisk: 10 * gib, downloadBytes: download,
                                          hostMemory: 8 * gib, machineMemoryGB: 6)
        XCTAssertEqual(all, [.notAppleSilicon, .unavailableInThisBuild, .notEnoughDisk(needed: needed, free: 10 * gib),
                             .littleMemory(machine: 6 * gib, host: 8 * gib)])
        XCTAssertEqual(all.map(VMRequirements.stops), [true, true, true, false], "little memory is a warning")
        XCTAssertEqual(VMRequirements.cores(hostCores: 10), 8)
        XCTAssertEqual(VMRequirements.cores(hostCores: 4), 4)
        XCTAssertTrue(VMRequirements.memoryChoices.contains(VMRequirements.standardMemoryGB))
        // A new machine gets what the Mac can spare: with 4 GB macOS in it stutters.
        let gigabyte = VMRequirements.gibibyte
        XCTAssertEqual(VMRequirements.recommendedMemoryGB(hostMemory: 8 * gigabyte), 4)
        XCTAssertEqual(VMRequirements.recommendedMemoryGB(hostMemory: 16 * gigabyte), 6)
        XCTAssertEqual(VMRequirements.recommendedMemoryGB(hostMemory: 18 * gigabyte), 6)
        XCTAssertEqual(VMRequirements.recommendedMemoryGB(hostMemory: 24 * gigabyte), 8)
        XCTAssertEqual(VMRequirements.recommendedMemoryGB(hostMemory: 64 * gigabyte), 8)
        for host in [Int64(0), 8, 12, 16, 24, 32, 128] {
            XCTAssertTrue(VMRequirements.memoryChoices.contains(VMRequirements.recommendedMemoryGB(hostMemory: host * gigabyte)))
        }
    }
}

final class VMGuestSettingsTests: XCTestCase {
    func testTheGuestIsGivenOnlyWhatItMayBeGiven() {
        let settings = VMGuestSettings(timeZone: "Europe/Berlin", language: "de-DE", hostName: "MacBook Air; rm -rf /", startURL: nil)
        XCTAssertEqual(settings.hostName, "MacBookAirrm-rf")
        let lines = settings.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.dropFirst()), ["LUMEN_TIMEZONE=Europe/Berlin", "LUMEN_LANGUAGE=de-DE", "LUMEN_LOCALE=de_DE", "LUMEN_HOSTNAME=MacBookAirrm-rf",
                                                  "LUMEN_OPEN_SAFARI=1", "LUMEN_WALLPAPER=0"])
        XCTAssertTrue(lines[0].hasPrefix("LUMEN_REVISION="))

        // Nothing a shell reads as more than text gets through.
        for bad in ["Europe/Berlin; reboot", "../../etc/passwd", "Europe//Berlin", "/Europe/Berlin", "$(id)", "Europe/Nowhere"] {
            XCTAssertNil(VMGuestSettings(timeZone: bad, language: nil, hostName: "Mac", startURL: nil).timeZone, bad)
        }
        for bad in ["javascript:alert(1)", "https://", "ftp://a.example/", "a.example/path", ""] {
            XCTAssertNil(VMGuestSettings.startURL(bad), bad)
        }
        // An address with such characters is either refused or written with them percent-encoded
        // (the system's URL parser differs between versions): never passed on as they are.
        let dangerous = CharacterSet(charactersIn: " \t\r\n\"'`$;|<>(){}!*\u{5C}")
        for odd in ["https://a.example/$(id)", "https://a.example/`id`", "https://a.example/;reboot", "https://a.example/a b?q=\"x\"",
                    "https://a.example/\nLUMEN_HOSTNAME=x", "https://a.example/\u{5C}x"] {
            if let written = VMGuestSettings.startURL(odd) {
                XCTAssertTrue(written.unicodeScalars.allSatisfy { !dangerous.contains($0) }, "\(odd) → \(written)")
                XCTAssertFalse(written.contains("\n"))
            }
        }
        XCTAssertEqual(VMGuestSettings.startURL(" https://example.com/path?q=a%20b&x=1#top "), "https://example.com/path?q=a%20b&x=1#top")
        XCTAssertNil(VMGuestSettings(timeZone: nil, language: "de_DE; id", hostName: "Mac", startURL: nil).language)
        XCTAssertEqual(VMGuestSettings.hostName("---"), "Mac")
    }

    func testTheRevisionChangesWithTheSettingsAndOnlyThen() {
        let a = VMGuestSettings(timeZone: "Europe/Berlin", language: "de-DE", hostName: "Mac", startURL: nil)
        let same = VMGuestSettings(timeZone: "Europe/Berlin", language: "de-DE", hostName: "Mac", startURL: nil)
        let other = VMGuestSettings(timeZone: "Europe/Paris", language: "de-DE", hostName: "Mac", startURL: nil)
        XCTAssertEqual(a.revision, same.revision)
        XCTAssertNotEqual(a.revision, other.revision)
        XCTAssertEqual(VMGuestSettings.locale(for: "zh-Hant-TW"), "zh_TW")
        XCTAssertEqual(VMGuestSettings.locale(for: "en"), "en")
        XCTAssertEqual(VMGuestSettings(profile: VMProfile(name: "A", displayID: "imac-24")).hostName, "iMac")
    }

    func testWhatTheGuestWroteBackIsReadAsTextOnly() {
        let status = VMGuestStatus(text: """
            LUMEN_TOOLS_VERSION=1
            LUMEN_MACOS_VERSION=26.1
            LUMEN_MACOS_BUILD=25B78
            LUMEN_SAFARI_VERSION=26.1
            LUMEN_APPLIED_REVISION=abc123
            LUMEN_SETUP_DONE=1
            SOMETHING_ELSE=ignored
            LUMEN_BAD=\u{1B}[31mred
            """)
        XCTAssertEqual(status.toolsVersion, 1)
        XCTAssertEqual(status.systemVersion, "26.1")
        XCTAssertEqual(status.systemBuild, "25B78")
        XCTAssertEqual(status.safariVersion, "26.1")
        XCTAssertEqual(status.appliedRevision, "abc123")
        XCTAssertTrue(status.setupDone)
        XCTAssertFalse(VMGuestStatus(text: "garbage\n=\n").setupDone)
        // Lumen's desktop picture: what came of it, and the system's words for a failure.
        XCTAssertNil(status.wallpaperState)
        XCTAssertFalse(status.wallpaperFailed)
        let failed = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=4\nLUMEN_WALLPAPER_STATE=failed\nLUMEN_WALLPAPER_NOTE=execution error: (-2700)\nLUMEN_SETUP_DONE=1\n")
        XCTAssertTrue(failed.wallpaperFailed)
        XCTAssertEqual(failed.wallpaperNote, "execution error: (-2700)")
        XCTAssertFalse(VMGuestStatus(text: "LUMEN_WALLPAPER_STATE=set\n").wallpaperFailed)
    }
}

final class VMLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-vmlib-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheSetupsStateIsReadFromWhatIsOnDisk() throws {
        let library = VMLibrary(vaultDirectory: root)
        XCTAssertEqual(library.root.lastPathComponent, "VirtualMachines")
        XCTAssertEqual(library.setupState(), .none)

        let image = VMRestoreImage(url: URL(string: "https://updates.example/UniversalMac.ipsw")!, version: "26.1", build: "25B78")
        try library.saveDownloadState(VMDownloadState(image: image, expectedLength: 1000, validator: "\"etag\""))
        try Data(repeating: 1, count: 400).write(to: library.partialRestoreImageURL)
        XCTAssertEqual(library.setupState(), .downloading(have: 400, of: 1000))

        try FileManager.default.moveItem(at: library.partialRestoreImageURL, to: library.restoreImageURL)
        XCTAssertEqual(library.setupState(), .downloaded)

        // Installed: every file of the base, and what is known of it.
        try FileManager.default.createDirectory(at: library.baseDirectory, withIntermediateDirectories: true)
        let installed = VMBaseInfo(stage: .installed, version: "26.1", build: "25B78", installedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try library.saveBaseInfo(installed)
        XCTAssertEqual(library.setupState(), .downloaded, "the base's files are not all there yet")
        for url in [library.base.disk, library.base.auxiliaryStorage, library.base.hardwareModel, library.base.machineIdentifier] {
            try Data([1]).write(to: url)
        }
        XCTAssertEqual(library.setupState(), .needsGuestSetup(installed))
        var ready = installed
        ready.stage = .ready
        ready.toolsVersion = VMGuestTools.version
        try library.saveBaseInfo(ready)
        XCTAssertEqual(library.setupState(), .ready(ready))

        let id = UUID()
        XCTAssertEqual(library.machine(for: id).disk.path, library.machinesDirectory.appendingPathComponent(id.uuidString).appendingPathComponent("disk.img").path)
        XCTAssertFalse(library.machine(for: id).isComplete)
        XCTAssertEqual(library.machine(for: id).settings.lastPathComponent, VMGuestSettings.fileName)
        XCTAssertGreaterThanOrEqual(VMLibrary.allocatedSize(of: library.baseDirectory), 4)
    }
}

final class VMDownloadTests: XCTestCase {
    private let image = VMRestoreImage(url: URL(string: "https://updates.example/UniversalMac.ipsw")!, version: "26.1", build: "25B78")

    func testADownloadGoesOnWhereItStoppedOnlyWhenTheFileIsKnownToBeTheSame() {
        XCTAssertEqual(VMDownload.request(state: nil, image: image, have: 0), .whole)
        let state = VMDownloadState(image: image, expectedLength: 1000, validator: "\"abc\"")
        XCTAssertEqual(VMDownload.request(state: state, image: image, have: 0), .whole)
        XCTAssertEqual(VMDownload.request(state: state, image: image, have: 400), .rest(from: 400, ifRange: "\"abc\""))
        XCTAssertEqual(VMDownload.request(state: state, image: image, have: 1000), .nothing)
        XCTAssertEqual(VMDownload.request(state: state, image: image, have: 1200), .whole, "longer than the file: not this file")
        var newer = image
        newer.build = "25C10"
        XCTAssertEqual(VMDownload.request(state: state, image: newer, have: 400), .whole, "another macOS since")
        XCTAssertEqual(VMDownload.request(state: VMDownloadState(image: image, expectedLength: 1000), image: image, have: 400), .whole,
                       "nothing tells a changed file: from the start")
        XCTAssertEqual(VMDownload.headers(for: .rest(from: 400, ifRange: "\"abc\"")), ["Range": "bytes=400-", "If-Range": "\"abc\""])
        XCTAssertEqual(VMDownload.headers(for: .whole), [:])
        XCTAssertTrue(image.isFetchable)
        XCTAssertFalse(VMRestoreImage(url: URL(string: "http://updates.example/x.ipsw")!, version: "1", build: "1").isFetchable)
    }

    func testAnAnswerIsAppendedRestartedOrRefused() {
        let rest = VMDownload.Request.rest(from: 400, ifRange: "\"abc\"")
        XCTAssertEqual(VMDownload.answer(to: rest, status: 206, contentRange: "bytes 400-999/1000", contentLength: 600), .append(total: 1000))
        XCTAssertEqual(VMDownload.answer(to: rest, status: 206, contentRange: "bytes 400-999/*", contentLength: 600), .append(total: nil))
        XCTAssertEqual(VMDownload.answer(to: rest, status: 206, contentRange: "bytes 0-999/1000", contentLength: 1000), .refused(status: 206),
                       "not the part that was asked for")
        XCTAssertEqual(VMDownload.answer(to: rest, status: 200, contentRange: nil, contentLength: 1000), .restart(total: 1000),
                       "the file changed (If-Range): the whole of it comes")
        XCTAssertEqual(VMDownload.answer(to: .whole, status: 200, contentRange: nil, contentLength: 1000), .restart(total: 1000))
        XCTAssertEqual(VMDownload.answer(to: .whole, status: 403, contentRange: nil, contentLength: nil), .refused(status: 403))
        XCTAssertEqual(VMDownload.validator(etag: "\"abc\"", lastModified: "Tue, 01 Jan 2030 00:00:00 GMT"), "\"abc\"")
        XCTAssertEqual(VMDownload.validator(etag: "W/\"weak\"", lastModified: "Tue, 01 Jan 2030 00:00:00 GMT"), "Tue, 01 Jan 2030 00:00:00 GMT")
        XCTAssertNil(VMDownload.validator(etag: nil, lastModified: nil))
    }
}

final class VMHelperProtocolTests: XCTestCase {
    func testARequestAndAnEventAreOneLineEach() throws {
        let profile = VMProfile(name: "Shop DE", proxy: ProxySettings(kind: .socks5, host: "de.example", port: 1080, username: "u", password: "p"),
                                displayID: "macbook-pro-14", memoryGB: 6, macAddress: "02:11:22:33:44:55")
        let library = VMLibrary(root: URL(fileURLWithPath: "/tmp/lib"))
        let request = VMHelperRequest.run(profile: profile, library: library, hostCores: 10, texts: ["stop": "Stop"])
        XCTAssertEqual(request.network, .proxy)
        XCTAssertEqual(request.cores, 8)
        XCTAssertEqual(request.memoryBytes, 6 << 30)
        XCTAssertEqual(request.display.pixelsWide, 3024)
        XCTAssertEqual(request.machineDirectory, "/tmp/lib/machines/\(profile.id.uuidString)")
        XCTAssertEqual(request.blockedHosts, VMRequirements.blockedHosts)
        let line = try request.line()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(try VMHelperRequest.parse(line), request)
        XCTAssertEqual(VMHelperRequest.run(profile: VMProfile(name: "Direct"), library: library, hostCores: 8, texts: [:]).network, .direct)
        // The base's first-run setup: no network card at all — and never a profile's machine.
        let offline = VMHelperRequest(mode: .run, machineDirectory: "/tmp/lib/base", network: .absent)
        XCTAssertEqual(try VMHelperRequest.parse(try offline.line()).network, .absent)
        XCTAssertTrue(try offline.line().contains(#""network":"absent""#))

        let event = VMHelperEvent(kind: .traffic, bytesUp: 10, bytesDown: 2000, connections: 3)
        XCTAssertEqual(VMHelperEvent.parse(event.line()), event)
        XCTAssertNil(VMHelperEvent.parse(event.line())?.trouble)
        // A machine without a proxy whose connections are not being made says why, as a kind.
        let troubled = VMHelperEvent(kind: .traffic, bytesUp: 0, bytesDown: 0, connections: 0,
                                     trouble: VMNetworkTrouble.proxyUnreachable.rawValue, viaSystemProxy: false)
        XCTAssertEqual(VMHelperEvent.parse(troubled.line()), troubled)
        XCTAssertEqual(VMHelperEvent.parse(troubled.line())?.trouble.flatMap(VMNetworkTrouble.init(rawValue:)), .proxyUnreachable)
        XCTAssertNil(VMNetworkTrouble(rawValue: "a kind of a later helper"))
        // The connector's kinds, word for word (it is not linked here): a configuration file is one.
        XCTAssertEqual(VMNetworkTrouble.allCases.map(\.rawValue),
                       ["nameNotFound", "notPublic", "unreachable", "proxyUnreachable", "proxyRefused", "proxyConfigurationFile"])
        XCTAssertGreaterThan(VMNetworkTrouble.failuresBeforeSaying, 1, "one dead address of a page is not a machine without internet")
        XCTAssertNil(VMHelperEvent.parse("2026-11-13 12:00:00.000 LumenVM[1:2] a line of the system's own"))
        XCTAssertNil(VMHelperEvent.parse(#"{"kind":"something-new"}"#), "an event of a later helper is not this version's")
    }
}

/// What a machine may be told about itself beyond where it is: its processors, its sound, its
/// system's look, its name.
final class VMMachineSettingsTests: XCTestCase {
    /// A name to block is kept as the network takes it, and nothing but a host's name is one.
    func testANameToBlockIsAHostsName() {
        XCTAssertEqual(VMProfile.blockedHost(" Ads.Example.COM "), "ads.example.com")
        XCTAssertEqual(VMProfile.blockedHost("*.tracker.example.net"), "tracker.example.net")
        XCTAssertEqual(VMProfile.blockedHost(".example.org."), "example.org")
        XCTAssertEqual(VMProfile.blockedHost("xn--80ak6aa92e.com"), "xn--80ak6aa92e.com")
        for bad in ["", "com", "localhost", "https://example.com", "example.com/path", "a b.example.com", "-a.example.com",
                    "a-.example.com", "exa$mple.com", "1.2.3.4", "пример.рф", "a..example.com",
                    String(repeating: "a", count: 64) + ".example.com"] {
            XCTAssertNil(VMProfile.blockedHost(bad), bad)
        }
    }

    /// The machine's own names to block go to its network after the app's, and its window's
    /// full screen to the helper.
    func testAMachinesOwnBlockedNamesAndFullScreenReachTheHelper() throws {
        let library = VMLibrary(root: URL(fileURLWithPath: "/tmp/lib"))
        let plain = VMHelperRequest.run(profile: VMProfile(name: "A"), library: library, hostCores: 8, texts: [:])
        XCTAssertEqual(plain.blockedHosts, VMRequirements.blockedHosts)
        XCTAssertNil(plain.fullScreen)
        let request = VMHelperRequest.run(profile: VMProfile(name: "A", blockedHosts: ["ads.example.com", "t.example.net"], startsFullScreen: true),
                                          library: library, hostCores: 8, texts: [:])
        XCTAssertEqual(request.blockedHosts, VMRequirements.blockedHosts + ["ads.example.com", "t.example.net"])
        XCTAssertEqual(request.fullScreen, true)
        XCTAssertEqual(try VMHelperRequest.parse(try request.line()), request)
    }

    func testTheMemoryAMacIsOfferedAndAMacBooksScrollBars() {
        let gigabyte = VMRequirements.gibibyte
        XCTAssertEqual(VMRequirements.memoryChoices(hostMemory: 8 * gigabyte), [3, 4, 6, 8])
        XCTAssertEqual(VMRequirements.memoryChoices(hostMemory: 16 * gigabyte), [3, 4, 6, 8])
        XCTAssertEqual(VMRequirements.memoryChoices(hostMemory: 24 * gigabyte), [3, 4, 6, 8, 12, 16])
        XCTAssertEqual(VMRequirements.memoryChoices(hostMemory: 20 * gigabyte), [3, 4, 6, 8, 12])
        XCTAssertNoThrow(try VMProfile(name: "A", memoryGB: 16).validate())
        XCTAssertThrowsError(try VMProfile(name: "A", memoryGB: 32).validate())
        // A MacBook has a trackpad: its bars show while scrolling. A desktop Mac's are the system's.
        XCTAssertEqual(VMScrollBars.standard(for: VMDisplay.preset("macbook-air-13")), .whenScrolling)
        XCTAssertEqual(VMScrollBars.standard(for: VMDisplay.preset("macbook-pro-16-more")), .whenScrolling)
        XCTAssertNil(VMScrollBars.standard(for: VMDisplay.preset("imac-24")))
        XCTAssertNil(VMScrollBars.standard(for: VMDisplay.preset("external-4k")))
        XCTAssertEqual(VMDockSize.allCases.map(\.tileSize), [36, 52, 72])
        XCTAssertEqual(VMScrollBars.allCases.map(\.systemName), ["Automatic", "WhenScrolling", "Always"])
    }

    /// The region of the formats, the clock, the week, the Dock, the scroll bars and the pages, as
    /// the guest is given them.
    func testTheSystemsHabitsAsTheGuestIsGivenThem() {
        var profile = VMProfile(name: "A", language: "en-US", localeFollowsProxy: false, startURL: "https://a.example/",
                                regionCode: "de", hourCycle: "24", firstWeekday: 2, dockPosition: "right", dockAutohide: false,
                                dockSize: "medium", scrollBars: "always",
                                moreStartURLs: ["https://b.example/", "nonsense", "https://c.example/"])
        let lines = Set(VMGuestSettings(profile: profile).text.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("LUMEN_LANGUAGE=en-US"))
        XCTAssertTrue(lines.contains("LUMEN_LOCALE=en_DE"), "\(lines)")
        XCTAssertTrue(lines.contains("LUMEN_HOURS=24"))
        XCTAssertTrue(lines.contains("LUMEN_FIRST_WEEKDAY=2"))
        XCTAssertTrue(lines.contains("LUMEN_DOCK_POSITION=right"))
        XCTAssertTrue(lines.contains("LUMEN_DOCK_AUTOHIDE=0"))
        XCTAssertTrue(lines.contains("LUMEN_DOCK_SIZE=52"))
        XCTAssertTrue(lines.contains("LUMEN_SCROLLBARS=Always"))
        XCTAssertTrue(lines.contains("LUMEN_START_URL=https://a.example/"))
        // What is not a page's address is left out, and the rest keep their order.
        XCTAssertTrue(lines.contains("LUMEN_START_URL_2=https://b.example/"))
        XCTAssertTrue(lines.contains("LUMEN_START_URL_3=https://c.example/"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("LUMEN_START_URL_4") })

        // Where the language follows a proxy, the region is the one found with it.
        profile.localeFollowsProxy = true
        profile.proxy = ProxySettings(kind: .socks5, host: "proxy.example", port: 1080)
        XCTAssertTrue(VMGuestSettings(profile: profile).text.contains("LUMEN_LOCALE=en_US\n"))
        // Without a first page there are no pages after it.
        XCTAssertFalse(VMGuestSettings(profile: VMProfile(name: "A", moreStartURLs: ["https://b.example/"])).text.contains("LUMEN_START_URL"))
        // Nothing set: nothing said — the guest leaves each as it is.
        let plain = VMGuestSettings(profile: VMProfile(name: "A")).text
        for key in ["LUMEN_HOURS", "LUMEN_FIRST_WEEKDAY", "LUMEN_DOCK", "LUMEN_SCROLLBARS"] {
            XCTAssertFalse(plain.contains(key), key)
        }
        // And each is a new revision.
        XCTAssertNotEqual(VMGuestSettings(profile: VMProfile(name: "A", hourCycle: "12")).revision, VMGuestSettings(profile: VMProfile(name: "A")).revision)
        XCTAssertEqual(VMGuestSettings.locale(for: "zh-Hant-TW", region: "HK"), "zh_HK")
        XCTAssertEqual(VMGuestSettings.locale(for: "en", region: nil), "en")
    }

    func testAListFromBeforeTheseSettingsReadsAsAMachineWasThen() throws {
        let old = #"{"format":1,"profiles":[{"id":"6F1C2E8A-0B0D-4C36-9C2A-7E7C0A1B2C3D","name":"Old","displayID":"macbook-air-13","memoryGB":4,"macAddress":"02:11:22:33:44:55"}]}"#
        let list = try JSONCoding.decoder.decode(VMProfiles.self, from: Data(old.utf8))
        let profile = try XCTUnwrap(list.profiles.first)
        XCTAssertNil(profile.cores)
        XCTAssertTrue(profile.soundEnabled)
        XCTAssertNil(profile.appearance)
        XCTAssertNil(profile.accent)
        XCTAssertNil(profile.computerName)
        XCTAssertTrue(profile.opensSafari)
        XCTAssertNil(profile.colorIndex)
        XCTAssertTrue(profile.lumenWallpaper)
        XCTAssertNil(profile.regionCode)
        XCTAssertNil(profile.hourCycle)
        XCTAssertNil(profile.firstWeekday)
        XCTAssertNil(profile.dockPosition)
        XCTAssertNil(profile.dockAutohide)
        XCTAssertNil(profile.dockSize)
        XCTAssertNil(profile.scrollBars)
        XCTAssertEqual(profile.moreStartURLs, [])
        XCTAssertEqual(profile.blockedHosts, [])
        XCTAssertFalse(profile.startsFullScreen)
        XCTAssertNoThrow(try profile.validate())
        // And what is set is kept through a save.
        var changed = profile
        changed.cores = 4
        changed.soundEnabled = false
        changed.appearance = VMAppearance.dark.rawValue
        changed.accent = VMAccent.green.rawValue
        changed.computerName = "Anna's MacBook Air"
        changed.opensSafari = false
        changed.colorIndex = 3
        changed.lumenWallpaper = false
        changed.regionCode = "DE"
        changed.hourCycle = "24"
        changed.firstWeekday = 2
        changed.dockPosition = "left"
        changed.dockAutohide = true
        changed.dockSize = "large"
        changed.scrollBars = "whenScrolling"
        changed.startURL = "https://a.example/"
        changed.moreStartURLs = ["https://b.example/"]
        changed.blockedHosts = ["ads.example.com"]
        changed.startsFullScreen = true
        XCTAssertNoThrow(try changed.validate())
        changed.notes = "shop"
        let again = try JSONCoding.decoder.decode(VMProfile.self, from: JSONCoding.encoder.encode(changed))
        XCTAssertEqual(again, changed)
    }

    func testWhatIsNotASettingIsRefused() {
        func profile(_ change: (inout VMProfile) -> Void) -> VMProfile {
            var profile = VMProfile(name: "A")
            change(&profile)
            return profile
        }
        // The system's habits, the pages, the names to block, the card's address.
        XCTAssertThrowsError(try profile { $0.regionCode = "DEU" }.validate())
        XCTAssertThrowsError(try profile { $0.regionCode = "D1" }.validate())
        XCTAssertThrowsError(try profile { $0.hourCycle = "25" }.validate())
        XCTAssertThrowsError(try profile { $0.firstWeekday = 0 }.validate())
        XCTAssertThrowsError(try profile { $0.firstWeekday = 8 }.validate())
        XCTAssertThrowsError(try profile { $0.dockPosition = "top" }.validate())
        XCTAssertThrowsError(try profile { $0.dockSize = "huge" }.validate())
        XCTAssertThrowsError(try profile { $0.scrollBars = "never" }.validate())
        XCTAssertThrowsError(try profile { $0.moreStartURLs = ["javascript:alert(1)"] }.validate())
        XCTAssertThrowsError(try profile { $0.moreStartURLs = Array(repeating: "https://a.example/", count: 6) }.validate())
        XCTAssertThrowsError(try profile { $0.blockedHosts = ["Ads.Example.com"] }.validate(), "kept as the network takes it: lower case")
        XCTAssertThrowsError(try profile { $0.blockedHosts = ["not a host"] }.validate())
        XCTAssertThrowsError(try profile { $0.macAddress = "01:00:5e:00:00:01" }.validate(), "a group's address")
        XCTAssertThrowsError(try profile { $0.macAddress = "00:1a:2b:3c:4d:5e" }.validate(), "a maker's address, not a machine's own")
        XCTAssertThrowsError(try profile { $0.macAddress = "02:1a:2b:3c:4d" }.validate())
        XCTAssertNoThrow(try profile { $0.macAddress = "0e:1A:2b:3c:4d:5e" }.validate())
        for _ in 0..<50 { XCTAssertTrue(VMProfile.isMACAddress(VMProfile.randomMACAddress())) }
        XCTAssertNoThrow(try profile { $0.cores = 6 }.validate())
        XCTAssertThrowsError(try profile { $0.cores = 3 }.validate())
        XCTAssertThrowsError(try profile { $0.cores = 64 }.validate())
        XCTAssertThrowsError(try profile { $0.appearance = "sepia" }.validate())
        XCTAssertThrowsError(try profile { $0.accent = "ultraviolet" }.validate())
        XCTAssertThrowsError(try profile { $0.computerName = "x$(reboot)" }.validate())
        XCTAssertThrowsError(try profile { $0.computerName = "Имя" }.validate())
        XCTAssertThrowsError(try profile { $0.notes = String(repeating: "n", count: 2001) }.validate())
    }

    func testTheGuestIsToldTheSystemsLookAndTheComputersName() {
        let settings = VMGuestSettings(profile: VMProfile(name: "A", appearance: "dark", accent: "graphite",
                                                          computerName: "Anna's MacBook Air", opensSafari: false))
        let lines = Set(settings.text.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("LUMEN_APPEARANCE=dark"))
        // macOS's own number for the colour; multicolour is the absence of one.
        XCTAssertTrue(lines.contains("LUMEN_ACCENT=-1"))
        XCTAssertTrue(lines.contains("LUMEN_COMPUTER_NAME=Anna's MacBook Air"))
        // The host name goes with the computer's name.
        XCTAssertTrue(lines.contains("LUMEN_HOSTNAME=Annas-MacBook-Air"))
        XCTAssertTrue(lines.contains("LUMEN_OPEN_SAFARI=0"))
        let plain = VMGuestSettings(profile: VMProfile(name: "A", accent: "multi")).text
        XCTAssertTrue(plain.contains("LUMEN_ACCENT=multi\n"))
        XCTAssertTrue(plain.contains("LUMEN_OPEN_SAFARI=1\n"))
        // Lumen's desktop picture: a machine has it unless the person says otherwise.
        XCTAssertTrue(plain.contains("LUMEN_WALLPAPER=1\n"))
        XCTAssertTrue(VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false)).text.contains("LUMEN_WALLPAPER=0\n"))
        XCTAssertNotEqual(VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false)).revision,
                          VMGuestSettings(profile: VMProfile(name: "A")).revision)
        XCTAssertFalse(plain.contains("LUMEN_APPEARANCE"))
        XCTAssertFalse(plain.contains("LUMEN_COMPUTER_NAME"))
        // A change of any of them is a new revision: the guest applies it.
        XCTAssertNotEqual(settings.revision, VMGuestSettings(profile: VMProfile(name: "A", appearance: "light", accent: "graphite",
                                                                              computerName: "Anna's MacBook Air", opensSafari: false)).revision)
    }

    func testAComputersNameIsLatinLettersDigitsSpacesHyphensAndApostrophes() {
        XCTAssertEqual(VMGuestSettings.computerName("  Anna's MacBook Air "), "Anna's MacBook Air")
        XCTAssertEqual(VMGuestSettings.computerName("Mac-mini 2"), "Mac-mini 2")
        for refused in ["", "   ", "a\"b", "x`id`", "a;b", "Имя компьютера", "two  spaces", String(repeating: "a", count: 41), "a\nb"] {
            XCTAssertNil(VMGuestSettings.computerName(refused), refused)
        }
    }

    func testANewMachinesAccentIsOneOfMacOSsAndOftenItsDefault() {
        var generator = SeededGenerator(state: 7)
        var seen: [VMAccent: Int] = [:]
        for _ in 0..<2000 { seen[VMAccent.random(using: &generator), default: 0] += 1 }
        XCTAssertEqual(Set(seen.keys), Set(VMAccent.allCases))
        let share = Double(seen[.multicolor] ?? 0) / 2000
        XCTAssertTrue((0.3...0.5).contains(share), "multicolour for \(share) of the machines")
        XCTAssertNil(VMAccent.multicolor.number)
        XCTAssertEqual(Set(VMAccent.allCases.compactMap(\.number)), Set(-1...6))
    }

    func testAMachineMayHaveFewerProcessorsAndNoSound() throws {
        let library = VMLibrary(root: URL(fileURLWithPath: "/tmp/lib"))
        let quiet = VMProfile(name: "Quiet", cores: 4, soundEnabled: false)
        let request = VMHelperRequest.run(profile: quiet, library: library, hostCores: 10, texts: [:])
        XCTAssertEqual(request.cores, 4)
        XCTAssertFalse(request.sound)
        XCTAssertEqual(try VMHelperRequest.parse(try request.line()), request)
        // As a Mac has them — and never more than this Mac has.
        XCTAssertEqual(VMHelperRequest.run(profile: VMProfile(name: "Mac"), library: library, hostCores: 10, texts: [:]).cores, 8)
        XCTAssertEqual(VMHelperRequest.run(profile: VMProfile(name: "Mac", cores: 6), library: library, hostCores: 4, texts: [:]).cores, 4)
        XCTAssertTrue(VMHelperRequest.run(profile: VMProfile(name: "Mac"), library: library, hostCores: 8, texts: [:]).sound)
    }

    func testEveryScreenIsOneAMacHas() {
        XCTAssertEqual(Set(VMDisplay.presets.map(\.id)).count, VMDisplay.presets.count)
        for display in VMDisplay.presets {
            XCTAssertTrue((1280...2600).contains(display.pointsWide), display.id)
            XCTAssertTrue([1, 2].contains(display.scale), display.id)
            // What the helper gives the framework: within what a Mac's screens are.
            XCTAssertLessThanOrEqual(display.pixelsWide, 4480, display.id)
        }
        XCTAssertEqual(VMDisplay.preset("no such screen"), VMDisplay.standard)
    }
}

/// The tools the base system's macOS gets (Resources/VMGuest) and the app agree on the two files
/// they pass each other: a key one side writes and the other does not read would be a setting that
/// silently does nothing in every machine.
final class VMGuestToolsTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/VMGuest", isDirectory: true)

    private func script(_ name: String) throws -> String {
        try String(contentsOf: Self.folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheBootScriptReadsEveryKeyTheAppWrites() throws {
        let boot = try script("lumen-guest.sh")
        let profile = VMProfile(name: "A", timeZoneIdentifier: "Europe/Berlin", language: "de-DE", startURL: "https://example.com/",
                                appearance: "dark", accent: "purple", computerName: "Anna's MacBook Air", opensSafari: false,
                                hourCycle: "24", firstWeekday: 2, dockPosition: "left", dockAutohide: true, dockSize: "small",
                                scrollBars: "whenScrolling",
                                moreStartURLs: (2...6).map { "https://example.com/\($0)" })
        let keys = VMGuestSettings(profile: profile).text.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) }
        XCTAssertEqual(Set(keys), ["LUMEN_REVISION", "LUMEN_TIMEZONE", "LUMEN_LANGUAGE", "LUMEN_LOCALE", "LUMEN_HOSTNAME", "LUMEN_START_URL",
                                   "LUMEN_COMPUTER_NAME", "LUMEN_APPEARANCE", "LUMEN_ACCENT", "LUMEN_OPEN_SAFARI", "LUMEN_WALLPAPER",
                                   "LUMEN_HOURS", "LUMEN_FIRST_WEEKDAY", "LUMEN_DOCK_POSITION", "LUMEN_DOCK_AUTOHIDE", "LUMEN_DOCK_SIZE",
                                   "LUMEN_SCROLLBARS", "LUMEN_START_URL_2", "LUMEN_START_URL_3", "LUMEN_START_URL_4", "LUMEN_START_URL_5",
                                   "LUMEN_START_URL_6"])
        XCTAssertEqual(VMProfile.moreStartURLsLimit, 5, "the boot script reads the pages by name: LUMEN_START_URL_2 … _6")
        for key in keys {
            XCTAssertTrue(boot.contains("value \(key) "), "the boot script does not read \(key)")
        }
        XCTAssertTrue(boot.contains(VMGuestSettings.fileName))
    }

    /// A base whose boot script takes a newer copy of itself needs nothing done to it for a later
    /// version's settings; one from before that (tools 1) has to have its tools installed again.
    func testOnlyABaseFromBeforeTheScriptUpdatedItselfIsToldToInstallAgain() {
        XCTAssertTrue(VMGuestTools.mustBeInstalledAgain(1))
        XCTAssertFalse(VMGuestTools.mustBeInstalledAgain(2))
        XCTAssertFalse(VMGuestTools.mustBeInstalledAgain(VMGuestTools.version))
        XCTAssertFalse(VMGuestTools.mustBeInstalledAgain(nil), "a base that does not say is not nagged")
        XCTAssertGreaterThanOrEqual(VMGuestTools.version, VMGuestTools.updatesItselfFrom)
        XCTAssertEqual(VMGuestSettings.wallpaperFileName, "lumen-wallpaper.png")
    }

    func testTheScriptsWriteTheStatusTheAppReads() throws {
        for name in ["lumen-guest.sh", "install.sh"] {
            let text = try script(name)
            for key in ["LUMEN_TOOLS_VERSION", "LUMEN_MACOS_VERSION", "LUMEN_MACOS_BUILD", "LUMEN_SAFARI_VERSION", "LUMEN_SETUP_DONE"] {
                XCTAssertTrue(text.contains("'\(key)="), "\(name) does not write \(key)")
            }
            XCTAssertTrue(text.contains("TOOLS_VERSION=\(VMGuestTools.version)\n"), "\(name) is not the tools' version the app expects")
            if name == "lumen-guest.sh" {
                // What came of Lumen's desktop picture, and what the system said when nothing did.
                for key in ["LUMEN_WALLPAPER_STATE", "LUMEN_WALLPAPER_NOTE"] {
                    XCTAssertTrue(text.contains("'\(key)="), "\(name) does not write \(key)")
                }
            }
            XCTAssertTrue(text.contains(VMGuestSettings.statusFileName))
        }
        XCTAssertTrue(try script("lumen-guest.sh").contains("'LUMEN_APPLIED_REVISION="))
        // What the scripts write reads back as the app's status.
        let status = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=1\nLUMEN_MACOS_VERSION=26.1\nLUMEN_MACOS_BUILD=25B78\nLUMEN_SAFARI_VERSION=26.1\nLUMEN_APPLIED_REVISION=9f\nLUMEN_SETUP_DONE=1\n")
        XCTAssertEqual(status.toolsVersion, 1)
        XCTAssertEqual(status.systemVersion, "26.1")
        XCTAssertEqual(status.safariVersion, "26.1")
        XCTAssertEqual(status.appliedRevision, "9f")
        XCTAssertTrue(status.setupDone)
    }

    /// The settings file is the app's word to a root process in the guest: it is read as text,
    /// value by value, and never run.
    func testTheBootScriptNeverRunsWhatItReads() throws {
        let boot = try script("lumen-guest.sh")
        for line in boot.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let code = String(line)
            XCTAssertFalse(code.contains("eval "), code)
            XCTAssertFalse(code.contains("source "), code)
            XCTAssertFalse(code.contains(". \"$settings\""), code)
            XCTAssertFalse(code.contains("sh \"$share"), code)
        }
        // And the shutdown request's name is the one the helper writes (Sources/LumenVM/MachineRunner.swift).
        XCTAssertTrue(boot.contains("lumen-shutdown"))
        let runner = try String(contentsOf: Self.folder.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenVM/MachineRunner.swift"), encoding: .utf8)
        XCTAssertTrue(runner.contains("\"lumen-shutdown\""))
    }

    func testTheScriptsParse() throws {
        for name in ["lumen-guest.sh", "install.sh", "Install Lumen Tools.command"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", Self.folder.appendingPathComponent(name).path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(name) does not parse")
        }
        // The daemon's property list names the script where the installer puts it.
        let plist = try script("io.lumenbrowser.guest.plist")
        XCTAssertTrue(plist.contains("/usr/local/lumen/lumen-guest.sh"))
        XCTAssertTrue(try script("install.sh").contains("DEST=/usr/local/lumen\n"))
    }
}
