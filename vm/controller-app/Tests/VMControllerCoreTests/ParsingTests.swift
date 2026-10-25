import Foundation
import XCTest
@testable import VMControllerCore

final class LineSplitterTests: XCTestCase {
    func testSplitsOnNewlineAndCarriageReturn() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed(Array("one\ntwo\r\nthree\r4".utf8)), ["one", "two", "three"])
        XCTAssertEqual(splitter.finish(), ["4"])
    }

    func testStripsAnsiEvenAcrossChunks() {
        // tart redraws its progress line: cursor up + erase line, then "57%".
        var splitter = LineSplitter()
        let stream = Array("pulling disk...\n\u{1B}[1A\u{1B}[K57%\n".utf8)
        let cut = 18 // inside the second escape sequence
        let lines = splitter.feed(stream[..<cut]) + splitter.feed(stream[cut...])
        XCTAssertEqual(lines, ["pulling disk...", "57%"])
    }

    func testStripsOscTitleSequence() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed(Array("\u{1B}]0;title\u{07}hello\n".utf8)), ["hello"])
    }

    func testDropsBlankLinesAndKeepsUTF8() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed(Array("\n\n   \nпривет\n".utf8)), ["привет"])
    }

    func testCapsVeryLongLines() {
        var splitter = LineSplitter()
        let lines = splitter.feed([UInt8](repeating: 0x61, count: LineSplitter.maxLineBytes + 10))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(splitter.finish(), [String(repeating: "a", count: 10)])
    }
}

final class TartOutputTests: XCTestCase {
    let list = """
    Source Name                                          Disk Size State
    oci    ghcr.io/cirruslabs/macos-sonoma-base:latest   50   24   stopped
    local  safari-profile-2                              50   24   stopped
    local  safari-profile                                50   24   running
    """

    func testListMatchesNameColumnExactly() {
        XCTAssertTrue(TartOutput.vmListContains(list, name: "safari-profile"))
        XCTAssertTrue(TartOutput.vmListContains(list, name: "safari-profile-2"))
        XCTAssertFalse(TartOutput.vmListContains(list, name: "safari"))
        XCTAssertFalse(TartOutput.vmListContains(list, name: "Name"), "the header row is not a VM")
        XCTAssertTrue(TartOutput.vmListContains(list + "\nlocal  Name  50 24 stopped", name: "Name"))
        XCTAssertFalse(TartOutput.vmListContains("Source Name Disk Size State\n", name: "safari-profile"))
    }

    func testPercent() {
        XCTAssertEqual(TartOutput.percent(in: "42%"), 0.42)
        XCTAssertEqual(TartOutput.percent(in: "100%"), 1.0)
        XCTAssertEqual(TartOutput.percent(in: "12.5 %"), 0.125)
        XCTAssertEqual(TartOutput.percent(in: "3% … 7%"), 0.07, "the last value wins")
        XCTAssertEqual(TartOutput.percent(in: "pulling disk (64%)"), 0.64)
        XCTAssertNil(TartOutput.percent(in: "pulling disk (24.3 GB compressed)..."))
        XCTAssertNil(TartOutput.percent(in: "1000%"))
        XCTAssertNil(TartOutput.percent(in: "v1.42%"))
    }

    func testLabel() {
        XCTAssertNil(TartOutput.label(in: "57%"))
        XCTAssertEqual(TartOutput.label(in: "pulling manifest..."), "pulling manifest...")
    }

    func testRunningVMNames() {
        let out = """
        Source Name            Disk Size State
        local  pb-work-a1       50   24   running
        local  pb-home-b2       50   24   stopped
        local  other-vm         50   24   running
        oci    ghcr.io/x:latest 50   24   stopped
        """
        XCTAssertEqual(TartOutput.runningVMNames(out), ["pb-work-a1", "other-vm"])
        XCTAssertEqual(TartOutput.runningVMNames(out, prefix: "pb-"), ["pb-work-a1"])
        XCTAssertEqual(TartOutput.runningVMNames("Source Name Disk Size State\n", prefix: "pb-"), [])
    }
}

final class URLInputTests: XCTestCase {
    func testNormalizes() {
        XCTAssertEqual(URLInput.normalize("  https://browserleaks.com  "), "https://browserleaks.com")
        XCTAssertEqual(URLInput.normalize("example.com/path?q=1"), "https://example.com/path?q=1")
        XCTAssertEqual(URLInput.normalize("HTTP://Example.com"), "http://Example.com")
    }

    func testRejects() {
        for bad in ["", "   ", "javascript:alert(1)", "file:///etc/passwd", "ftp://host/",
                    "https://exa mple.com", "https://x\nHost: y", "https://"] {
            XCTAssertNil(URLInput.normalize(bad), bad)
        }
    }
}

final class LaunchProgressTests: XCTestCase {
    func testStartingAStageCompletesEarlierOnes() {
        var progress = LaunchProgress()
        progress.start(.tart, detail: "checking")
        progress.start(.agent, detail: "installing")
        XCTAssertEqual(progress[.tart], .done(detail: "checking"))
        XCTAssertEqual(progress[.image], .done(detail: ""))
        XCTAssertEqual(progress[.vm], .done(detail: ""))
        XCTAssertEqual(progress.current, .agent)
        XCTAssertEqual(progress[.safari], .pending)
    }

    func testUpdateKeepsDeterminateProgress() {
        var progress = LaunchProgress()
        progress.start(.image, detail: "pulling", progress: 0.3)
        progress.update(.image, detail: "pulling disk")
        XCTAssertEqual(progress[.image], .running(detail: "pulling disk", progress: 0.3))
        progress.update(.image, progress: 1.7)
        XCTAssertEqual(progress[.image].progress, 1.0, "clamped")
    }

    func testFraction() {
        var progress = LaunchProgress()
        XCTAssertEqual(progress.fraction, 0)
        progress.start(.image, detail: "", progress: 0.5) // tart done (1) + half of image
        XCTAssertEqual(progress.fraction, 1.5 / 5, accuracy: 1e-9)
        progress.finish(.done, detail: "ok")
        XCTAssertEqual(progress.fraction, 1)
    }

    func testFailAndCancel() {
        var progress = LaunchProgress()
        progress.start(.vm, detail: "booting")
        progress.fail(detail: "no IP")
        XCTAssertEqual(progress[.vm], .failed(detail: "no IP"))
        XCTAssertNil(progress.current)

        var other = LaunchProgress()
        other.start(.safari, detail: "opening")
        other.attention(.tart, detail: "x")
        other.cancelOpenStages()
        XCTAssertEqual(other[.safari], .cancelled)
        XCTAssertEqual(other[.tart], .cancelled)
        XCTAssertTrue(other[.vm].isDone)
    }
}

final class LauncherEnvironmentTests: XCTestCase {
    func testSearchPathAddsHomebrewOnceAndKeepsOrder() {
        let path = LauncherEnvironment.searchPath("/usr/bin:/opt/homebrew/bin:/custom", prepending: ["/tart/dir"])
        XCTAssertEqual(path.split(separator: ":").map(String.init),
                       ["/tart/dir", "/usr/bin", "/opt/homebrew/bin", "/custom", "/usr/local/bin", "/bin", "/usr/sbin", "/sbin"])
        XCTAssertTrue(LauncherEnvironment.searchPath(nil).hasPrefix("/opt/homebrew/bin:/usr/local/bin"))
    }

    func testScriptCandidates() {
        let candidates = LauncherEnvironment.scriptCandidates(
            environment: ["PB_TART_SCRIPT": "/override/t.sh"],
            resourceDirectory: URL(fileURLWithPath: "/App.app/Contents/Resources"),
            currentDirectory: "/repo/vm/controller-app",
            executablePath: ".build/debug/VMLauncher")
        XCTAssertEqual(candidates, [
            "/override/t.sh",
            "/App.app/Contents/Resources/vm/controller/tart-prototype.sh",
            "/repo/vm/controller-app/vm/controller/tart-prototype.sh",
            "/repo/vm/controller/tart-prototype.sh",
        ], "the executable-relative path equals the cwd-relative one here and is deduplicated")
    }

    func testRepositoryLayoutHasScriptAndAgent() throws {
        let script = TestPaths.script.path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script))
        XCTAssertEqual(LauncherEnvironment.missingAgentFiles(forScript: script), [])
    }

    func testFreeLocalPort() throws {
        let port = try XCTUnwrap(LauncherEnvironment.freeLocalPort())
        XCTAssertGreaterThan(port, 0)
    }

    func testAskPassPrintsSSHPASS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let askPass = try LauncherEnvironment.writeAskPass(in: directory)
        let result = try await GroupProcess.run(askPass.path, ["admin@vm's password: "],
                                                environment: ["SSHPASS": "s3cret"], timeout: 10)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.lines, ["s3cret"])
        let fallback = try await GroupProcess.run(askPass.path, environment: [:], timeout: 10)
        XCTAssertEqual(fallback.lines, ["admin"])
    }

    func testScriptEnvironment() {
        let environment = LauncherEnvironment.scriptEnvironment(
            base: ["PATH": "/usr/bin", "KEEP_VM": "1", "HOME": "/Users/me"],
            tartPath: "/Apps/tart.app/Contents/MacOS/tart",
            askPass: URL(fileURLWithPath: "/tmp/askpass.sh"), localPort: 50123)
        XCTAssertTrue(environment["PATH"]!.hasPrefix("/Apps/tart.app/Contents/MacOS:/usr/bin"))
        XCTAssertEqual(environment["TART_NET"], "shared")
        XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/askpass.sh")
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment["LOCAL_PORT"], "50123")
        XCTAssertNil(environment["KEEP_VM"])
        XCTAssertEqual(environment["HOME"], "/Users/me")
        XCTAssertEqual(environment["VM_HEADLESS"], "1", "no VM window unless asked")
    }

    func testScriptEnvironmentProfileExtras() {
        let profile = Profile(id: "abc12345", name: "Работа", timeZone: "Europe/Berlin", language: "de-DE")
        let environment = LauncherEnvironment.scriptEnvironment(
            base: ["KIOSK": "1", "VM_EXTERNAL": "1", "IDENTITY_PROFILE": "stale"], tartPath: "/bin/tart",
            askPass: URL(fileURLWithPath: "/tmp/a.sh"), localPort: nil,
            identity: .init(profile: profile), kiosk: true, externalVM: true)
        XCTAssertEqual(environment["IDENTITY_PROFILE"], "abc12345", "the id, not the (personal) name")
        XCTAssertEqual(environment["IDENTITY_TIMEZONE"], "Europe/Berlin")
        XCTAssertEqual(environment["IDENTITY_LANGUAGE"], "de-DE")
        XCTAssertEqual(environment["KIOSK"], "1")
        XCTAssertEqual(environment["VM_EXTERNAL"], "1")
        let plain = LauncherEnvironment.scriptEnvironment(
            base: ["KIOSK": "1", "VM_EXTERNAL": "1", "IDENTITY_PROFILE": "stale"], tartPath: "/bin/tart",
            askPass: URL(fileURLWithPath: "/tmp/a.sh"), localPort: nil)
        XCTAssertNil(plain["KIOSK"])
        XCTAssertNil(plain["VM_EXTERNAL"])
        XCTAssertNil(plain["IDENTITY_PROFILE"], "never inherited from the app's environment")
    }

    func testScriptEnvironmentShowWindow() {
        let environment = LauncherEnvironment.scriptEnvironment(
            base: ["VM_HEADLESS": "1"], tartPath: "/bin/tart", askPass: URL(fileURLWithPath: "/tmp/a.sh"),
            localPort: nil, showWindow: true)
        XCTAssertEqual(environment["VM_HEADLESS"], "0")
    }

    func testScriptEnvironmentFailClosedAndCookies() {
        let environment = LauncherEnvironment.scriptEnvironment(
            base: ["PATH": "/usr/bin"], tartPath: "/bin/tart",
            askPass: URL(fileURLWithPath: "/tmp/a.sh"), localPort: nil,
            network: .proxyOnly(allowCIDR: "10.0.0.9/32"), cookiesFile: "/tmp/cookies.json")
        XCTAssertEqual(environment["TART_NET"], "softnet")
        XCTAssertEqual(environment["SOFTNET_ALLOW"], "10.0.0.9/32")
        XCTAssertEqual(environment["COOKIES_FILE"], "/tmp/cookies.json")

        let isolated = LauncherEnvironment.scriptEnvironment(
            base: [:], tartPath: "/bin/tart", askPass: URL(fileURLWithPath: "/tmp/a.sh"),
            localPort: nil, network: .isolated)
        XCTAssertEqual(isolated["TART_NET"], "softnet")
        XCTAssertNil(isolated["SOFTNET_ALLOW"], "nothing to allow; the script adds deny-all + in @host")
        XCTAssertNil(isolated["COOKIES_FILE"])
        XCTAssertNil(isolated["PROXY_URL"])

        let proxied = LauncherEnvironment.scriptEnvironment(
            base: ["PROXY_URL": "http://stale:1", "SOFTNET_FAIL_CLOSED": "0"], tartPath: "/bin/tart",
            askPass: URL(fileURLWithPath: "/tmp/a.sh"), localPort: nil,
            network: .proxyOnly(allowCIDR: "10.0.0.9/32"), proxyURL: "socks5://u:p@10.0.0.9:1080")
        XCTAssertEqual(proxied["PROXY_URL"], "socks5://u:p@10.0.0.9:1080")
        XCTAssertNil(proxied["SOFTNET_FAIL_CLOSED"], "the app never runs softnet open")
        let inherited = LauncherEnvironment.scriptEnvironment(
            base: ["PROXY_URL": "http://stale:1"], tartPath: "/bin/tart",
            askPass: URL(fileURLWithPath: "/tmp/a.sh"), localPort: nil)
        XCTAssertNil(inherited["PROXY_URL"])
    }
}

enum TestPaths {
    /// vm/ in the repository (this file is vm/controller-app/Tests/VMControllerCoreTests/…).
    static let vmDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let script = vmDirectory.appendingPathComponent("controller/tart-prototype.sh")
    static let identityScript = vmDirectory.appendingPathComponent("identity.sh")
}
