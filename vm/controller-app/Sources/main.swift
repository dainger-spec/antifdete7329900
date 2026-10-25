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
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControllerError.tartNotFound
        }
        print("==> Tart found")
    }

    func ensureImage() throws {
        print("==> Checking for VM '\(vmName)'")
        let list = try runTart(["list"])
        if list.contains(vmName) {
            print("    VM exists")
            return
        }
        print("==> Cloning base image (this may take a while)...")
        print("    \(baseImage)")
        _ = try runTart(["clone", baseImage, vmName])
        print("    Done")
    }

    func launchAndNavigate(url: String) throws {
        print("==> Launching VM")
        let script = """
        #!/bin/bash
        set -e
        tart run \(vmName) --net-bridged=en0 &
        TART_PID=$!
        echo "VM PID: $TART_PID"

        for i in $(seq 1 60); do
          IP=$(tart ip \(vmName) 2>/dev/null || true)
          if [ -n "$IP" ]; then
            echo "VM IP: $IP"
            break
          fi
          sleep 2
        done

        if [ -z "${IP:-}" ]; then
          echo "Failed to get IP"
          exit 1
        fi

        echo "TODO: install agent and navigate to \(url)"
        echo "VM is running. Press Ctrl+C to stop."
        wait $TART_PID
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
    }

    @discardableResult
    func runTart(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tart"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum ControllerError: Error, CustomStringConvertible {
    case tartNotFound

    var description: String {
        switch self {
        case .tartNotFound:
            return "tart not found. Install: brew install cirruslabs/cli/tart"
        }
    }
}
