import Foundation
import XCTest
@testable import VMControllerCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The parser against the script's real texts.
final class ScriptOutputParserTests: XCTestCase {
    func testEveryHeadingInTheScriptIsKnown() throws {
        let script = try String(contentsOf: TestPaths.script, encoding: .utf8)
        let headings = script.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "echo \"==> ") else { return nil }
            return String(line[range.upperBound...])
        }
        XCTAssertGreaterThanOrEqual(headings.count, 8)
        for heading in headings {
            let known = ScriptOutputParser.stageRules.contains { heading.hasPrefix($0.prefix) }
                || ScriptOutputParser.ignoredHeadings.contains { heading.hasPrefix($0) }
                || heading.hasPrefix("Stopping VM")
            XCTAssertTrue(known, "tart-prototype.sh prints an unmapped heading: ==> \(heading)")
        }
    }

    func testEveryErrorRuleStillMatchesTheScript() throws {
        let script = try String(contentsOf: TestPaths.script, encoding: .utf8)
        for rule in ScriptOutputParser.errorRules {
            XCTAssertTrue(script.contains("echo \"\(rule.prefix)"), "no longer printed by the script: \(rule.prefix)")
        }
    }

    func testTranscript() {
        var parser = ScriptOutputParser()
        let events = """
        ==> Checking VM 'safari-profile'
        ==> Starting VM 'safari-profile'
        ==> Waiting for VM IP...
        VM IP: 192.168.64.5
        ==> Waiting for SSH...
        ==> Installing in-VM agent
            agent installed; token captured
        ==> Opening SSH tunnel localhost:8777 -> VM 127.0.0.1:8777
        ==> Waiting for agent...
        ==> Navigating Safari to https://example.com
        {"navigated_to":"https://example.com"}
        ==> Status:
        VM is up at 192.168.64.5, Safari pointed at the target.
        ==> Stopping VM 'safari-profile'
        """.components(separatedBy: "\n").compactMap { parser.consume($0) }
        XCTAssertEqual(events, [
            .stage(.vm, detail: "Проверка VM…"),
            .stage(.vm, detail: "Запуск VM…"),
            .stage(.vm, detail: "Ожидание IP-адреса VM…"),
            .detail(.vm, "IP-адрес VM: 192.168.64.5"),
            .stage(.vm, detail: "Ожидание SSH…"),
            .stage(.agent, detail: "Копирование и установка агента…"),
            .detail(.agent, "Агент установлен"),
            .stage(.agent, detail: "Открытие SSH-туннеля…"),
            .stage(.agent, detail: "Ожидание ответа агента…"),
            .stage(.safari, detail: "Открытие https://example.com…"),
            .ready(ip: "192.168.64.5"),
            .stopping,
        ])
    }

    func testErrors() {
        var parser = ScriptOutputParser()
        XCTAssertEqual(parser.consume("ssh not found"), .error("На Mac не найдена программа «ssh»."))
        XCTAssertNil(parser.consume("python not found"))
        guard case .error = parser.consume("SSH did not come up") else { return XCTFail() }
        guard case .error = parser.consume("curl: (22) The requested URL returned error: 502") else { return XCTFail() }
    }
}

final class GroupProcessTests: XCTestCase {
    func testCollectsStdoutAndStderrAndExitCode() async throws {
        let result = try await GroupProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"],
                                                environment: [:], timeout: 10)
        XCTAssertEqual(result.code, 3)
        XCTAssertEqual(Set(result.lines), ["out", "err"])
    }

    func testTimeoutKillsTheGroup() async throws {
        let started = Date()
        let result = try await GroupProcess.run("/bin/sh", ["-c", "sleep 30"], environment: [:], timeout: 0.5)
        XCTAssertNil(result.code)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testSpawnFailureThrows() {
        let process = GroupProcess(executable: "/nonexistent/tool", environment: [:]) { _ in }
        XCTAssertThrowsError(try process.start())
    }

    func testSignalReachesBackgroundGrandchildren() async throws {
        // The grandchild keeps the output pipe open; only a group signal ends it promptly.
        let lines = LineCollector()
        let process = GroupProcess(executable: "/bin/sh", arguments: ["-c", "sleep 300 & echo started; wait"],
                                   environment: [:]) { lines.append($0) }
        try process.start()
        try await waitUntil { lines.lines.contains("started") }
        let started = Date()
        process.signalGroup(SIGTERM)
        let code = await process.waitForExit(timeout: 10)
        XCTAssertEqual(code, 128 + SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSigintIsDeliveredEvenIfTheSpawningThreadBlocksIt() async throws {
        let lines = LineCollector()
        let process = GroupProcess(
            executable: "/bin/bash",
            arguments: ["-c", "trap 'echo got-int; exit 7' INT; echo ready; while :; do sleep 0.1; done"],
            environment: ["PATH": "/usr/bin:/bin"]) { lines.append($0) }
        let thread = Thread {
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGINT)
            pthread_sigmask(SIG_BLOCK, &blocked, nil)
            try? process.start()
        }
        thread.start()
        // "ready" proves the spawn from the blocking thread succeeded.
        try await waitUntil { lines.lines.contains("ready") }
        process.signalGroup(SIGINT)
        let code = await process.waitForExit(timeout: 10)
        XCTAssertEqual(code, 7, "SIGINT must not stay blocked in the child")
        XCTAssertTrue(lines.lines.contains("got-int"))
    }
}

/// Runs the real vm/controller/tart-prototype.sh against stub tart/ssh/scp/curl.
final class ScriptIntegrationTests: XCTestCase {
    var host: FakeHost!

    override func setUpWithError() throws {
        host = try FakeHost()
    }

    override func tearDown() {
        host.cleanUp()
    }

    func testFullRunReachesReadyThenSigintStopsTheVM() async throws {
        let run = try host.launch(url: "https://example.com/a\"b", extraEnvironment: ["TART_NET": "shared"])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }

        let stages = run.events.compactMap { event -> LaunchStage? in
            if case .stage(let stage, _) = event { return stage }
            return nil
        }
        XCTAssertEqual(stages.first, .vm)
        XCTAssertEqual(stages.last, .safari)
        XCTAssertEqual(stages, stages.sorted(), "stages only move forward")
        XCTAssertTrue(run.events.contains(.ready(ip: "192.168.64.5")))
        XCTAssertFalse(run.events.contains { if case .error = $0 { return true }; return false })

        let calls = host.calls
        XCTAssertTrue(calls.contains("tart run safari-profile"), "shared networking passes no --net flag")
        XCTAssertTrue(calls.contains("tart ip safari-profile"))
        XCTAssertTrue(calls.contains { $0.contains(#"-d {"url":"https://example.com/a\"b"}"#) },
                      "the navigate body is valid JSON even with a quote in the URL")
        XCTAssertTrue(calls.contains { $0.hasPrefix("ssh ") && $0.contains("ExitOnForwardFailure=yes") && $0.contains("-N") })

        let started = Date()
        run.process.signalGroup(SIGINT)
        let code = await run.process.waitForExit(timeout: 15)
        XCTAssertEqual(code, 130)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(host.calls.contains("tart stop safari-profile"), "cleanup stops the VM")
        XCTAssertFalse(host.isRunning(pidFile: "run.pid"), "the VM process is gone")
    }

    func testBridgedModeAndCancelWhileWaitingForIP() async throws {
        try host.setFlag("no-ip") // the VM never gets an address
        let run = try host.launch(url: "https://example.com", extraEnvironment: [:])
        try await waitUntil { run.events.contains(.stage(.vm, detail: "Ожидание IP-адреса VM…")) }
        try await Task.sleep(nanoseconds: 300_000_000)

        let started = Date()
        run.process.signalGroup(SIGINT)
        let code = await run.process.waitForExit(timeout: 15)
        XCTAssertEqual(code, 130)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the group signal interrupts the poll at once")

        let calls = host.calls
        XCTAssertTrue(calls.contains("tart run safari-profile --net-bridged=en0"))
        XCTAssertTrue(calls.contains("tart ip --resolver=arp safari-profile"))
        XCTAssertTrue(calls.contains("tart stop safari-profile"))
    }

    func testSizingAndHeadlessEnvReachTart() async throws {
        let run = try host.launch(url: "https://example.com",
                                  extraEnvironment: ["TART_NET": "shared", "VM_MEMORY": "1536",
                                                     "VM_CPU": "2", "VM_HEADLESS": "1",
                                                     "VM_RUN_ARGS": "--no-audio"])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }
        let calls = host.calls
        XCTAssertTrue(calls.contains("tart set safari-profile --memory 1536 --cpu 2"),
                      "RAM/CPU caps are applied with tart set while stopped")
        XCTAssertTrue(calls.contains("tart run safari-profile --no-graphics --no-audio"),
                      "VM_HEADLESS adds --no-graphics and VM_RUN_ARGS is appended")
        // tart set must come before tart run (set requires a stopped VM).
        XCTAssertLessThan(calls.firstIndex { $0.hasPrefix("tart set") } ?? .max,
                          calls.firstIndex { $0.hasPrefix("tart run") } ?? .min)
        run.process.signalGroup(SIGINT)
        _ = await run.process.waitForExit(timeout: 15)
    }

    func testSoftnetFailClosedNetworking() async throws {
        let run = try host.launch(url: "https://example.com",
                                  extraEnvironment: ["TART_NET": "softnet", "SOFTNET_ALLOW": "10.0.0.9/32"])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }
        XCTAssertTrue(host.calls.contains("tart run safari-profile --net-softnet --net-softnet-allow 10.0.0.9/32"),
                      "softnet with an allowlist restricts egress to the proxy")
        run.process.signalGroup(SIGINT)
        _ = await run.process.waitForExit(timeout: 15)
    }

    func testReuseInstalledAgentSkipsInstall() async throws {
        try host.markInstalled(token: "reused-tok")
        let run = try host.launch(url: "https://example.com", extraEnvironment: ["TART_NET": "shared"])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }
        let calls = host.calls
        XCTAssertTrue(calls.contains { $0.contains("cat ~/.pbagent/token") }, "controller checks for an installed agent")
        XCTAssertFalse(calls.contains { $0.contains("install.sh") }, "an installed agent is not reinstalled")
        XCTAssertFalse(calls.contains { $0.hasPrefix("scp ") }, "nothing is copied when reusing")
        XCTAssertTrue(calls.contains { $0.contains("/navigate") && $0.contains("Bearer reused-tok") },
                      "the reused token is used")
        run.process.signalGroup(SIGINT)
        _ = await run.process.waitForExit(timeout: 15)
    }

    func testForceInstallReinstallsEvenIfInstalled() async throws {
        try host.markInstalled(token: "old")
        let run = try host.launch(url: "https://example.com",
                                  extraEnvironment: ["TART_NET": "shared", "FORCE_INSTALL": "1"])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }
        XCTAssertTrue(host.calls.contains { $0.contains("install.sh") }, "FORCE_INSTALL reinstalls")
        XCTAssertTrue(host.calls.contains { $0.contains("/navigate") && $0.contains("Bearer tok123") },
                      "uses the freshly installed token")
        run.process.signalGroup(SIGINT)
        _ = await run.process.waitForExit(timeout: 15)
    }

    func testCookiesPushedWhenFileGiven() async throws {
        let cookiesFile = host.root.appendingPathComponent("cookies.json")
        try #"[{"domain":"x.com","name":"a","value":"1"}]"#.write(to: cookiesFile, atomically: true, encoding: .utf8)
        let run = try host.launch(url: "https://example.com",
                                  extraEnvironment: ["TART_NET": "shared", "COOKIES_FILE": cookiesFile.path])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }
        XCTAssertTrue(host.calls.contains { $0.contains("/cookies") && $0.contains("Bearer") },
                      "cookies are POSTed to the agent before navigating")
        run.process.signalGroup(SIGINT)
        _ = await run.process.waitForExit(timeout: 15)
    }

    func testNoSizingWhenUnset() async throws {
        let run = try host.launch(url: "https://example.com", extraEnvironment: ["TART_NET": "shared"])
        try await waitUntil(timeout: 20) { run.events.contains { if case .ready = $0 { return true }; return false } }
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("tart set") }, "no tart set without VM_MEMORY/VM_CPU")
        XCTAssertTrue(host.calls.contains("tart run safari-profile"), "no --no-graphics without VM_HEADLESS")
        run.process.signalGroup(SIGINT)
        _ = await run.process.waitForExit(timeout: 15)
    }

    func testSigintToBashAloneNoLongerResumesTheScript() async throws {
        // Regression: `trap cleanup INT` used to run cleanup and then continue
        // polling for the IP for two minutes.
        try host.setFlag("no-ip")
        let run = try host.launch(url: "https://example.com", extraEnvironment: ["TART_NET": "shared"])
        try await waitUntil { run.events.contains(.stage(.vm, detail: "Ожидание IP-адреса VM…")) }
        kill(run.process.processIdentifier, SIGINT) // bash only, not the group
        let code = await run.process.waitForExit(timeout: 10)
        XCTAssertEqual(code, 130)
    }
}

// MARK: - Helpers

struct WaitTimeout: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "condition not met within \(seconds)s" }
}

/// Polls `condition`; throws (failing the test) if it stays false for `timeout`.
func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw WaitTimeout(seconds: timeout) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = ScriptOutputParser()
    private var storage: [ScriptEvent] = []

    func consume(_ line: String) {
        lock.lock()
        if let event = parser.consume(line) { storage.append(event) }
        lock.unlock()
    }

    var events: [ScriptEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct ScriptRun {
    let process: GroupProcess
    let log: EventLog
    var events: [ScriptEvent] { log.events }
}

/// A temp directory with stub tart/ssh/scp/curl/sshpass that log their calls.
final class FakeHost {
    let root: URL
    var bin: URL { root.appendingPathComponent("bin") }
    var state: URL { root.appendingPathComponent("state") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fakehost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let log = #"echo "$(basename "$0") $*" >> "$FAKE_STATE/calls.log""#
        try stub("tart", """
        \(log)
        case "$1" in
          list) printf 'Source Name           Disk Size State\\nlocal  safari-profile 50   24   stopped\\n' ;;
          run)  echo $$ > "$FAKE_STATE/run.pid"; exec sleep 300 ;;
          ip)   [ -f "$FAKE_STATE/no-ip" ] || echo 192.168.64.5 ;;
          stop) [ -f "$FAKE_STATE/run.pid" ] && kill "$(cat "$FAKE_STATE/run.pid")" 2>/dev/null; true ;;
        esac
        """)
        try stub("ssh", """
        \(log)
        for arg in "$@"; do [ "$arg" = "-N" ] && exec sleep 300; done
        case "$*" in
          *"cat ~/.pbagent/token"*) [ -f "$FAKE_STATE/installed-token" ] && cat "$FAKE_STATE/installed-token"; exit 0 ;;
          *install.sh*) echo "Installed." >&2; echo "PB_AGENT_TOKEN=tok123"; exit 0 ;;
        esac
        exit 0
        """)
        try stub("scp", log)
        try stub("curl", """
        cat >/dev/null 2>&1 || true   # drain any --data-binary @- so the pipe never SIGPIPEs
        \(log)
        case "$*" in
          *"/navigate"*) echo '{"navigated_to":"ok"}' ;;
          *"/cookies"*) echo '{"applied":0}' ;;
          *"/status"*) echo '{"safari_running":true}' ;;
        esac
        exit 0
        """)
        try stub("sshpass", "shift; exec \"$@\"") // in case a real one is installed
    }

    private func stub(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func setFlag(_ name: String) throws {
        try "".write(to: state.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Make the stub VM look like it already has the agent installed, with this token.
    func markInstalled(token: String) throws {
        try token.write(to: state.appendingPathComponent("installed-token"), atomically: true, encoding: .utf8)
    }

    var calls: [String] {
        ((try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    func isRunning(pidFile: String) -> Bool {
        guard let text = try? String(contentsOf: state.appendingPathComponent(pidFile), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    func launch(url: String, extraEnvironment: [String: String]) throws -> ScriptRun {
        var environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "HOME": root.path,
            "FAKE_STATE": state.path,
            "LOCAL_PORT": String(LauncherEnvironment.freeLocalPort() ?? 18777),
        ]
        environment.merge(extraEnvironment) { $1 }
        let log = EventLog()
        let process = GroupProcess(executable: "/bin/bash",
                                   arguments: [TestPaths.script.path, "safari-profile", url],
                                   environment: environment) { log.consume($0) }
        try process.start()
        return ScriptRun(process: process, log: log)
    }

    func cleanUp() {
        // Belt and braces: never leave stub sleepers behind.
        for file in ["run.pid"] where isRunning(pidFile: file) {
            if let text = try? String(contentsOf: state.appendingPathComponent(file), encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: root)
    }
}
