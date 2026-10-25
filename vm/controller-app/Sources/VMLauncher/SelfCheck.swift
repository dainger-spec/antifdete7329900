import Foundation
import VMControllerCore

/// `VMLauncher --self-check`: checks, without UI, that this build can run a
/// launch — the bundled script and agent files, the askpass helper, a free
/// tunnel port. Tart itself is only reported: CI machines don't have it.
enum SelfCheck {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func report(_ ok: Bool, _ name: String, _ detail: String) {
            print("\(ok ? "ok  " : "FAIL") \(name): \(detail)")
            if !ok { failures += 1 }
        }

        let environment = ProcessInfo.processInfo.environment
        let candidates = LauncherEnvironment.scriptCandidates(
            environment: environment, resourceDirectory: Bundle.main.resourceURL,
            currentDirectory: FileManager.default.currentDirectoryPath,
            executablePath: CommandLine.arguments[0])
        if let script = LauncherEnvironment.locateScript(in: candidates) {
            report(true, "tart-prototype.sh", script)
            report(FileManager.default.isExecutableFile(atPath: script), "script is executable", script)
            let missing = LauncherEnvironment.missingAgentFiles(forScript: script)
            report(missing.isEmpty, "agent files", missing.isEmpty ? "all present" : "missing \(missing.joined(separator: ", "))")
            let status = runQuietly("/bin/bash", ["-n", script])
            report(status == 0, "bash -n", "exit \(status)")
        } else {
            report(false, "tart-prototype.sh", "not found; tried \(candidates.joined(separator: ", "))")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlauncher-selfcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let askPass = try LauncherEnvironment.writeAskPass(in: directory)
            let output = capture(askPass.path, environment: ["SSHPASS": "selfcheck"])
            report(output == "selfcheck\n", "ssh askpass helper", askPass.lastPathComponent)
        } catch {
            report(false, "ssh askpass helper", "\(error)")
        }

        let port = LauncherEnvironment.freeLocalPort()
        report(port != nil, "free local port", port.map { String($0) } ?? "none")

        let tart = TartSetup.locate(searchPath: LauncherEnvironment.searchPath(environment["PATH"]))
        print("info tart: \(tart ?? "not installed (the app offers to download it)")")
        print("info Apple Silicon: \(HostInfo.isAppleSilicon)")
        print(failures == 0 ? "self-check passed" : "self-check FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    private static func runQuietly(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func capture(_ executable: String, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
