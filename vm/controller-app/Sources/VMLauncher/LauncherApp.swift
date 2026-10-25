import AppKit
import SwiftUI

/// Entry point. `--self-check` verifies the bundle without opening a window
/// (CI and build-app.sh run it); otherwise the SwiftUI app starts.
@main
enum VMLauncherMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            exit(SelfCheck.run())
        }
        LauncherApp.main()
    }
}

struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Safari в VM", id: "launcher") {
            ContentView(model: appDelegate.model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare executable (`swift run`), the process would stay a
        // background app without Dock icon or key window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting stops the VM first, so no VM keeps running without its window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasActiveWork else { return .terminateNow }
        if !terminating {
            terminating = true
            Task { @MainActor in
                await self.model.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
