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
        Window(Brand.name, id: "launcher") {
            ContentView(model: appDelegate.model)
                .task { await appDelegate.menuBar.refresh() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // The profile's Safari (its VM's screen), one at a time.
        Window("Браузер", id: BrowserWindow.id) {
            BrowserWindowView(model: appDelegate.model)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: appDelegate.model)
        }

        MenuBarExtra {
            MenuBarContent(launcher: appDelegate.model, menu: appDelegate.menuBar)
        } label: {
            MenuBarLabel(menu: appDelegate.menuBar)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()
    let menuBar = MenuBarModel()
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
