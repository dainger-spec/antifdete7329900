import Foundation
import XCTest
@testable import VMControllerCore

final class TartVMBundleTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tartvm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Shaped like Tart's own config.json (sorted keys, pretty printed).
    static let sampleConfig = """
    {
      "arch" : "arm64",
      "cpuCount" : 4,
      "cpuCountMin" : 4,
      "diskFormat" : "raw",
      "display" : { "height" : 768, "width" : 1024 },
      "ecid" : "YWJjZGVmZ2g=",
      "hardwareModel" : "aGFyZHdhcmU=",
      "macAddress" : "7a:65:e4:3f:00:01",
      "memorySize" : 8589934592,
      "memorySizeMin" : 4294967296,
      "os" : "darwin",
      "version" : 1
    }
    """

    private func makeVM(_ name: String, config: String = sampleConfig, files: [String] = ["disk.img", "nvram.bin"]) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        for file in files {
            try Data().write(to: directory.appendingPathComponent(file))
        }
        return directory
    }

    func testLoadsStandaloneMacVM() throws {
        _ = try makeVM("pb-work-1")
        let bundle = try TartVMBundle.load(name: "pb-work-1", vmsDirectory: root)
        XCTAssertEqual(bundle.config.cpuCount, 4)
        XCTAssertEqual(bundle.config.memorySize, 8_589_934_592)
        XCTAssertEqual(bundle.config.macAddress, "7a:65:e4:3f:00:01")
        XCTAssertEqual(bundle.config.display, .init(width: 1024, height: 768, unit: nil))
        XCTAssertEqual(bundle.config.ecidData, Data("abcdefgh".utf8))
        XCTAssertEqual(bundle.config.hardwareModelData, Data("hardware".utf8))
        XCTAssertEqual(bundle.diskURL.lastPathComponent, "disk.img")
    }

    func testRejectsWhatTheAppCannotRun() throws {
        _ = try makeVM("no-disk", files: ["nvram.bin"])
        XCTAssertThrowsError(try TartVMBundle.load(name: "no-disk", vmsDirectory: root)) {
            XCTAssertEqual($0 as? TartVMBundle.LoadError, .missing("disk.img"))
        }
        _ = try makeVM("stacked", files: ["nvram.bin", "manifest.json", "overlay.asif"])
        XCTAssertThrowsError(try TartVMBundle.load(name: "stacked", vmsDirectory: root)) {
            XCTAssertEqual($0 as? TartVMBundle.LoadError, .unsupported("stacked disk"))
        }
        let linux = Self.sampleConfig.replacingOccurrences(of: "\"darwin\"", with: "\"linux\"")
        _ = try makeVM("linux", config: linux)
        XCTAssertThrowsError(try TartVMBundle.load(name: "linux", vmsDirectory: root))
        XCTAssertThrowsError(try TartVMBundle.load(name: "absent", vmsDirectory: root)) {
            XCTAssertEqual($0 as? TartVMBundle.LoadError, .missing("config.json"))
        }
    }

    /// The lock is the one `tart` checks: another process must see it.
    func testRunLockIsVisibleToOtherProcesses() async throws {
        let vm = try makeVM("locked")
        let config = vm.appendingPathComponent("config.json")
        let lock = try VMRunLock(url: config)
        XCTAssertTrue(try lock.tryLock())
        XCTAssertNil(lock.holder(), "own lock is not another holder")
        let probe = """
        import fcntl, sys
        f = open(sys.argv[1], "r+")
        try:
            fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("free")
        except OSError:
            print("locked")
        """
        let held = try await GroupProcess.run("/usr/bin/env", ["python3", "-c", probe, config.path],
                                              environment: ProcessInfo.processInfo.environment, timeout: 20)
        XCTAssertEqual(held.lines.last, "locked")
        lock.unlock()
        let freed = try await GroupProcess.run("/usr/bin/env", ["python3", "-c", probe, config.path],
                                               environment: ProcessInfo.processInfo.environment, timeout: 20)
        XCTAssertEqual(freed.lines.last, "free")
    }

    func testRunLockFailsWhileTartHoldsIt() async throws {
        let vm = try makeVM("busy")
        let config = vm.appendingPathComponent("config.json")
        let holder = """
        import fcntl, sys, time
        f = open(sys.argv[1], "r+")
        fcntl.lockf(f, fcntl.LOCK_EX)
        print("held", flush=True)
        time.sleep(30)
        """
        let ready = expectation(description: "holder has the lock")
        let process = GroupProcess(executable: "/usr/bin/env", arguments: ["python3", "-c", holder, config.path],
                                   environment: ProcessInfo.processInfo.environment) { line in
            if line == "held" { ready.fulfill() }
        }
        try process.start()
        defer { process.signalGroup(SIGKILL) }
        await fulfillment(of: [ready], timeout: 20)
        let lock = try VMRunLock(url: config)
        XCTAssertFalse(try lock.tryLock(), "a VM tart already runs can't be started again")
        XCTAssertEqual(lock.holder(), process.processIdentifier)
    }

    func testSoftnetArgumentsFollowThePolicy() {
        XCTAssertEqual(SoftnetCommand.arguments(macAddress: "aa:bb:cc:dd:ee:ff", policy: .proxyOnly(allowCIDR: "10.0.0.9/32")),
                       ["--vm-fd", "0", "--vm-mac-address", "aa:bb:cc:dd:ee:ff",
                        "--block", "0.0.0.0/0", "--allow", "10.0.0.9/32,in @host"])
        XCTAssertEqual(SoftnetCommand.arguments(macAddress: "m", policy: .isolated),
                       ["--vm-fd", "0", "--vm-mac-address", "m", "--block", "0.0.0.0/0", "--allow", "in @host"])
        XCTAssertNil(SoftnetCommand.arguments(macAddress: "m", policy: .openNAT), "direct mode uses NAT")
    }

    func testSoftnetReadiness() async throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let environment = ["PATH": bin.path]
        var readiness = await SoftnetReadiness.check(searchPath: bin.path, environment: environment)
        XCTAssertEqual(readiness, .missing)

        try stub("softnet", "echo '  * in TARGET: flows initiated from TARGET to the VM'")
        try stub("sudo", "exit 1")
        readiness = await SoftnetReadiness.check(searchPath: bin.path, environment: environment)
        guard case .needsRoot = readiness else { return XCTFail("\(readiness)") }
        XCTAssertNotNil(readiness.problem)

        try stub("sudo", "[ \"$1\" = -n ] && shift; exec \"$@\"")
        readiness = await SoftnetReadiness.check(searchPath: bin.path, environment: environment)
        guard case .ready = readiness else { return XCTFail("\(readiness)") }
        XCTAssertNil(readiness.problem)

        try stub("softnet", "echo '--allow <CIDRs>'")
        readiness = await SoftnetReadiness.check(searchPath: bin.path, environment: environment)
        guard case .tooOld = readiness else { return XCTFail("\(readiness)") }
    }
}

final class ProfileNetworkTests: XCTestCase {
    private func decode(_ json: String) throws -> Profile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Profile.self, from: Data(json.utf8))
    }

    private let legacyFields = """
    "id":"abc12345","name":"Work","baseImage":"b","clipboardShared":false,"cookieCount":0,
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"
    """

    func testLegacyProfilesWithoutProxyGetInternet() throws {
        let profile = try decode("{\(legacyFields)}")
        XCTAssertEqual(profile.network, .direct, "they used to be isolated by surprise")
        XCTAssertEqual(profile.networkPolicy, .openNAT)
        XCTAssertNil(profile.guestProxy)
        XCTAssertNil(profile.uniqueIdentity)
    }

    func testLegacyProfilesWithProxyStayFailClosed() throws {
        let profile = try decode("{\(legacyFields),\"proxy\":\"socks5://10.0.0.9:1080\"}")
        XCTAssertEqual(profile.network, .proxy)
        XCTAssertEqual(profile.networkPolicy, .proxyOnly(allowCIDR: "10.0.0.9/32"))
        XCTAssertEqual(profile.guestProxy, "socks5://10.0.0.9:1080")
    }

    func testModes() {
        var profile = Profile(name: "p", proxy: "http://proxy.example:8080", network: .proxy)
        XCTAssertEqual(profile.networkPolicy, .isolated, "a hostname proxy can't be allowlisted: no internet, not direct")
        XCTAssertNil(profile.guestProxy)
        profile.network = .offline
        XCTAssertEqual(profile.networkPolicy, .isolated)
        profile.network = .direct
        XCTAssertEqual(profile.networkPolicy, .openNAT)
        XCTAssertNil(profile.guestProxy, "direct mode ignores a leftover proxy")
        profile = Profile(name: "p", network: .proxy)
        XCTAssertEqual(profile.networkPolicy, .isolated, "proxy mode without a proxy fails closed")
    }

    func testNewFieldsRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // whole seconds: ISO 8601 drops fractions
        let profile = Profile(name: "p", createdAt: date, updatedAt: date, network: .offline,
                              timeZone: "Europe/Berlin", language: "de-DE", uniqueIdentity: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Profile.self, from: encoder.encode(profile))
        XCTAssertEqual(back, profile)
        XCTAssertEqual(back.network, .offline)
        XCTAssertEqual(back.timeZone, "Europe/Berlin")
    }

    func testUniqueIdentityPlan() {
        let profile = Profile(id: "i", name: "n")
        XCTAssertEqual(ProfilePlan.uniqueIdentity(profile), ["set", "pb-n-i", "--random-serial", "--random-mac"])
    }
}
