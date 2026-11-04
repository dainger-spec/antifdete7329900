import BrowserCore
import Foundation
import XCTest
@testable import UpdateInstaller

/// The installer on real bundles (macOS): apps made here, signed ad hoc with `codesign`, zipped with
/// `ditto`, their zips signed with Ed25519 — and the installer run on them as the helper runs it,
/// with LaunchServices and the process list stood in for.
final class InstallerTests: XCTestCase {
    var root: URL!
    var staging: URL!
    var installed: URL!
    var key: (privateKey: Data, publicKey: Data)!
    let identifier = "dev.local.PrivacyBrowserUpdateTest"
    let start = Date(timeIntervalSince1970: 1_900_000_000)

    /// What the stand-ins saw.
    var launched: [URL] = []
    var launchFails = false
    var processLists: [[BundleProcess]] = []
    var clock: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-installer-\(UUID().uuidString)")
        staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        key = UpdateSigner.newKey()
        clock = start
        installed = try makeApp(at: root.appendingPathComponent("Applications/PrivacyBrowser.app"), version: "0.1.0", build: "1")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Making apps

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(process.terminationStatus)) }
    }

    /// An app bundle: an executable (a copy of /usr/bin/true), an Info.plist with the update keys,
    /// signed ad hoc — unless `signed` is false.
    @discardableResult
    private func makeApp(at url: URL, version: String, build: String, identifier: String? = nil, signed: Bool = true,
                         keys: [String: String]? = nil) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("PrivacyBrowser"))
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier ?? self.identifier,
            "CFBundleExecutable": "PrivacyBrowser",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "PBUpdatePublicKeys": keys ?? [UpdateKeys.keyID(of: key.publicKey): key.publicKey.base64EncodedString()],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        if signed { try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path]) }
        return url
    }

    /// A release: the app zipped as `ditto -c -k --keepParent` makes it, its item signed with
    /// `privateKey` (the test key), and the request for it in the staging folder.
    @discardableResult
    private func stage(version: String = "0.2.0", build: String = "2", appBuild: String? = nil, identifier: String? = nil,
                       signed: Bool = true, privateKey: Data? = nil, appPath: String? = nil,
                       requestedAt: Date? = nil) throws -> AppcastItem {
        let made = root.appendingPathComponent("made-\(UUID().uuidString)/PrivacyBrowser.app")
        try makeApp(at: made, version: version, build: appBuild ?? build, identifier: identifier, signed: signed)
        let archive = staging.appendingPathComponent("PrivacyBrowser-\(build).zip")
        try? FileManager.default.removeItem(at: archive)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", made.path, archive.path])
        let item = try UpdateSigner.item(archive: archive, version: version, build: build, minimumSystemVersion: "14.0",
                                         url: URL(string: "https://updates.example/\(archive.lastPathComponent)")!, notes: "",
                                         publishedAt: start, privateKey: privateKey ?? key.privateKey)
        try UpdateRequest(appPath: appPath ?? installed.path, archive: archive.lastPathComponent, item: item,
                          requestedAt: requestedAt ?? start).write(to: staging)
        return item
    }

    private func installer(patience: TimeInterval = 600) -> Installer {
        Installer(app: installed, staging: staging, environment: Installer.Environment(
            processes: { [unowned self] _ in self.processLists.isEmpty ? [] : self.processLists.removeFirst() },
            launch: { [unowned self] url in
                self.launched.append(url)
                if self.launchFails { throw NSError(domain: "LaunchServices", code: -10810) }
            },
            sleep: { [unowned self] seconds in self.clock = self.clock.addingTimeInterval(seconds) },
            now: { [unowned self] in self.clock },
            system: BuildVersion("14.6")!,
            patience: patience))
    }

    private func build(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"]) as? String
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path).filter { $0 != "PrivacyBrowser.app" }
    }

    // MARK: Installing

    func testAVerifiedReleaseReplacesTheAppAndStartsIt() async throws {
        try stage()
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .installed, outcome.detail)
        XCTAssertEqual(build(of: installed), "2")
        XCTAssertNoThrow(try CodeSignature.check(installed, identifier: identifier, teamID: nil))
        XCTAssertEqual(launched, [installed.standardizedFileURL])
        XCTAssertEqual(try leftovers(), [], "the previous app and the work folder are gone")
        XCTAssertEqual(UpdateOutcome.read(from: staging)?.result, .installed, "left for the app's next launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(UpdateStaging.requestName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("PrivacyBrowser-2.zip").path))
    }

    func testANewAppThatCannotStartIsSwappedBack() async throws {
        try stage()
        launchFails = true
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .rolledBack, outcome.detail)
        XCTAssertEqual(build(of: installed), "1", "the previous app is back")
        XCTAssertNoThrow(try CodeSignature.check(installed, identifier: identifier, teamID: nil))
        XCTAssertEqual(launched.count, 2, "the new app, then the previous one")
        XCTAssertEqual(try leftovers(), [])
    }

    // MARK: Waiting, never killing

    func testItWaitsForTheAppToGoAndKillsNothing() async throws {
        try stage()
        let app = BundleProcess(pid: 4242, startedAt: start.addingTimeInterval(-3600))
        processLists = [[app], [app], [app]]
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .installed, outcome.detail)
        XCTAssertEqual(clock.timeIntervalSince(start), 1.5, accuracy: 0.01, "three polls of half a second")
    }

    func testItGivesUpOnAnAppThatDoesNotQuit() async throws {
        try stage()
        let app = BundleProcess(pid: 4242, startedAt: start.addingTimeInterval(-3600))
        processLists = Array(repeating: [app], count: 100)
        let outcome = await installer(patience: 10).run()
        XCTAssertEqual(outcome.result, .gaveUp, outcome.detail)
        XCTAssertEqual(build(of: installed), "1")
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("PrivacyBrowser-2.zip").path),
                      "kept for the next quit")
    }

    /// Started again after the quit that asked: that quit is over; the next one asks again.
    func testAnAppStartedAgainEndsTheRequest() async throws {
        try stage()
        processLists = [[BundleProcess(pid: 4343, startedAt: start.addingTimeInterval(30))]]
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .gaveUp, outcome.detail)
        XCTAssertEqual(build(of: installed), "1")
    }

    // MARK: Refusals: nothing replaced

    private func assertRefused(_ expected: String, line: UInt = #line) async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: installed.appendingPathComponent("Contents").path).sorted()
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .refused, line: line)
        XCTAssertTrue(outcome.detail.contains(expected), "\(outcome.detail)", line: line)
        XCTAssertEqual(build(of: installed), "1", line: line)
        XCTAssertNoThrow(try CodeSignature.check(installed, identifier: identifier, teamID: nil), line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.appendingPathComponent("Contents").path).sorted(),
                       before, line: line)
        XCTAssertTrue(launched.isEmpty, line: line)
        XCTAssertEqual(try leftovers(), [], line: line)
    }

    func testAnArchiveSignedWithAnotherKeyIsRefused() async throws {
        try stage(privateKey: UpdateSigner.newKey().privateKey)
        try await assertRefused("signed with a key this app does not carry")
    }

    func testAForgedArchiveSignatureIsRefused() async throws {
        let item = try stage()
        var forged = item
        forged.edSignature = Data(repeating: 7, count: 64)
        try UpdateRequest(appPath: installed.path, archive: "PrivacyBrowser-2.zip", item: forged, requestedAt: start).write(to: staging)
        try await assertRefused("the signature of the archive does not check")
    }

    func testAnUnsignedAppIsRefused() async throws {
        try stage(signed: false)
        try await assertRefused("the signature does not hold")
    }

    func testAnotherAppIsRefused() async throws {
        try stage(identifier: "org.example.Other")
        try await assertRefused("not \(identifier)")
    }

    func testAnAppWhoseVersionIsNotTheReleasesIsRefused() async throws {
        try stage(build: "2", appBuild: "3")
        try await assertRefused("the release says 0.2.0 (2)")
    }

    func testAnOlderOrTheSameBuildIsRefused() async throws {
        try stage(version: "0.1.0", build: "1")
        try await assertRefused("not newer than the running build 1")
        try stage(version: "0.0.9", build: "0.9")
        try await assertRefused("not newer")
    }

    func testARequestForAnotherAppOrFromAnotherQuitIsRefused() async throws {
        try stage(appPath: root.appendingPathComponent("Elsewhere/PrivacyBrowser.app").path)
        try await assertRefused("the request is for")
        try stage(requestedAt: start.addingTimeInterval(-3600))
        try await assertRefused("not from this quit")
    }

    /// The keys come from the installed app's signed Info.plist: changed, the signature no longer
    /// holds, and nothing is trusted from it.
    func testAnInstalledAppWhoseKeysWereChangedTrustsNothing() async throws {
        try stage()
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let other = UpdateSigner.newKey().publicKey
        info["PBUpdatePublicKeys"] = [UpdateKeys.keyID(of: other): other.base64EncodedString()]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .refused)
        XCTAssertTrue(outcome.detail.contains("the signature does not hold"), outcome.detail)
        XCTAssertTrue(launched.isEmpty)
    }

    func testAnAppWithoutKeysInstallsNothing() async throws {
        try FileManager.default.removeItem(at: installed)
        installed = try makeApp(at: installed, version: "0.1.0", build: "1", keys: [:])
        try stage()
        let outcome = await installer().run()
        XCTAssertEqual(outcome.result, .refused)
        XCTAssertTrue(outcome.detail.contains("carries no update keys"), outcome.detail)
    }

    // MARK: Processes

    /// The real process list: this test's own process runs from no bundle of its making; a copy of
    /// `sleep` started from inside one is found, with its start time.
    func testTheProcessesRunningFromABundle() throws {
        XCTAssertEqual(BundleProcess.running(inside: installed), [])
        let tool = installed.appendingPathComponent("Contents/MacOS/sleeper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: tool)
        let process = Process()
        process.executableURL = tool
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let running = BundleProcess.running(inside: installed)
        XCTAssertEqual(running.map(\.pid), [process.processIdentifier])
        XCTAssertLessThan(abs(running.first?.startedAt.timeIntervalSinceNow ?? 99), 5)
    }
}
