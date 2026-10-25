import Foundation
import VMControllerCore

/// Command-line controller: ensures tart and the base image, then runs the
/// bash prototype with the terminal's stdio (so Ctrl+C works as usual).
/// The SwiftUI app (VMLauncher) does the same with progress UI.
@main
enum VMControllerCLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: VMController <url>")
            print("Example: VMController https://browserleaks.com")
            exit(1)
        }
        guard let url = URLInput.normalize(args[1]) else {
            print("Error: not an http(s) URL: \(args[1])")
            exit(1)
        }
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
    let vmName = LauncherDefaults.vmName
    let baseImage = LauncherDefaults.baseImage

    /// PATH with Homebrew's bin dirs added, so a GUI/minimal-PATH launch still
    /// finds tart (typically /opt/homebrew/bin).
    let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LauncherEnvironment.searchPath(environment["PATH"])
        return environment
    }()

    func run(url: String) throws {
        print("==> VM Controller")
        print("    Target: \(url)")

        let tart = try ensureTart()
        try ensureImage(tart: tart)
        try launchAndNavigate(url: url)
    }

    func ensureTart() throws -> String {
        guard let tart = LauncherEnvironment.findExecutable("tart", searchPath: environment["PATH"] ?? "") else {
            throw ControllerError.tartNotFound
        }
        print("==> Tart found: \(tart)")
        return tart
    }

    func ensureImage(tart: String) throws {
        print("==> Checking for VM '\(vmName)'")
        let list = try runCapturing(tart, ["list"])
        if TartOutput.vmListContains(list, name: vmName) {
            print("    VM exists")
            return
        }
        print("==> Cloning base image (this may take a while)...")
        print("    \(baseImage)")
        // Inherit stdio: the pull streams GBs of progress, which must not be
        // buffered into a pipe that is only drained after exit (deadlock).
        try runStreaming(tart, ["clone", baseImage, vmName])
        print("    Done")
    }

    func launchAndNavigate(url: String) throws {
        // Delegate boot → install agent → tunnel → navigate to the tested bash
        // prototype. Stdio is inherited so Ctrl+C reaches the script, whose
        // trap stops the VM and tears down the tunnel.
        let candidates = LauncherEnvironment.scriptCandidates(
            environment: environment, resourceDirectory: nil,
            currentDirectory: FileManager.default.currentDirectoryPath,
            executablePath: CommandLine.arguments[0])
        guard let script = LauncherEnvironment.locateScript(in: candidates) else {
            throw ControllerError.scriptNotFound(candidates)
        }
        print("==> Launching VM and opening Safari (via \(script))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, vmName, url]
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControllerError.scriptFailed(Int(process.terminationStatus))
        }
    }

    /// Small output only (e.g. `list`): drains the pipe before waiting.
    func runCapturing(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func runStreaming(_ executable: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControllerError.tartCommandFailed(args.first ?? "", Int(process.terminationStatus))
        }
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
