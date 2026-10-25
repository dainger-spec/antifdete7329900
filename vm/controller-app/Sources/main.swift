import Foundation

@main
enum VMController {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: VMController <url>")
            print("Example: VMController https://browserleaks.com")
            exit(1)
        }
        let url = args[1]
        let controller = Controller()
        do {
            try controller.run(url: url)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}

final class Controller {
    let vmName = "safari-profile"
    let baseImage = "ghcr.io/cirruslabs/macos-sonoma-base:latest"

    func run(url: String) throws {
        print("==> VM Controller")
        print("    Target: \(url)")

        try ensureTart()
        try ensureImage()
        try launchAndNavigate(url: url)
    }

    func ensureTart() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tart"]
        process.environment = augmentedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ControllerError.tartNotFound
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControllerError.tartNotFound
        }
        print("==> Tart found")
    }

    func ensureImage() throws {
        print("==> Checking for VM '\(vmName)'")
        let list = try runTartCapturing(["list"])
        if vmListContains(list, name: vmName) {
            print("    VM exists")
            return
        }
        print("==> Cloning base image (this may take a while)...")
        print("    \(baseImage)")
        // Inherit stdio so the (large, streaming) pull progress is shown and,
        // crucially, is NOT buffered into a pipe we only drain after exit — that
        // deadlocks once the pipe fills. See runTartCapturing for the small case.
        try runTartStreaming(["clone", baseImage, vmName])
        print("    Done")
    }

    /// True iff a `tart list` table has a row whose Name column equals `name`.
    /// Avoids substring false positives (e.g. "safari-profile-2", the header).
    func vmListContains(_ output: String, name: String) -> Bool {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            // Columns: Source Name Disk Size State → Name is index 1.
            if fields.count >= 2 && String(fields[1]) == name {
                return true
            }
        }
        return false
    }

    func launchAndNavigate(url: String) throws {
        // Delegate the boot → install agent → tunnel → navigate flow to the
        // tested bash prototype rather than reimplementing it here. Stdio is
        // inherited so progress is live and Ctrl+C reaches the script (its own
        // trap stops the VM and tears down the tunnel).
        let script = try locateTartScript()
        print("==> Launching VM and opening Safari (via \(script))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, vmName, url]
        process.environment = augmentedEnvironment()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControllerError.scriptFailed(Int(process.terminationStatus))
        }
    }

    /// Find vm/controller/tart-prototype.sh. Honors $PB_TART_SCRIPT, then tries
    /// locations relative to the working directory and to this executable
    /// (.build/<config>/VMController → ../../../controller/…).
    func locateTartScript() throws -> String {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["PB_TART_SCRIPT"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(cwd + "/vm/controller/tart-prototype.sh")
        candidates.append(cwd + "/../controller/tart-prototype.sh")
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0],
                         relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
        candidates.append(exeURL.deletingLastPathComponent()
            .appendingPathComponent("../../../controller/tart-prototype.sh")
            .standardizedFileURL.path)

        for path in candidates where fm.isReadableFile(atPath: path) {
            return path
        }
        throw ControllerError.scriptNotFound(candidates)
    }

    /// Run `tart` and return combined stdout+stderr. For small output only
    /// (e.g. `list`): reads to EOF before waiting, so it is safe, but a very
    /// large stream should use runTartStreaming to avoid a pipe-buffer deadlock.
    @discardableResult
    func runTartCapturing(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tart"] + args
        process.environment = augmentedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting so a filled pipe can't block the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run `tart` with inherited stdio (no capture). Use for long/streaming
    /// commands like `clone`.
    func runTartStreaming(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tart"] + args
        process.environment = augmentedEnvironment()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControllerError.tartCommandFailed(args.first ?? "", Int(process.terminationStatus))
        }
    }

    /// Current environment with Homebrew bin dirs prepended to PATH, so a GUI- or
    /// minimal-PATH launch still finds `tart` (typically /opt/homebrew/bin).
    func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + existing
        return env
    }
}

enum ControllerError: Error, CustomStringConvertible {
    case tartNotFound
    case tartCommandFailed(String, Int)
    case scriptNotFound([String])
    case scriptFailed(Int)

    var description: String {
        switch self {
        case .tartNotFound:
            return "tart not found. Install: brew install cirruslabs/cli/tart"
        case .tartCommandFailed(let cmd, let code):
            return "tart \(cmd) failed (exit \(code))"
        case .scriptNotFound(let tried):
            return "tart-prototype.sh not found. Set $PB_TART_SCRIPT or run from the repo root. Tried:\n  "
                + tried.joined(separator: "\n  ")
        case .scriptFailed(let code):
            return "tart-prototype.sh failed (exit \(code))"
        }
    }
}
