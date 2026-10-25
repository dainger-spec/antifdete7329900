import AppKit
import SwiftUI

@main
struct PrivacyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Profiles", id: "profiles") {
            RootView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Browser") {
                Button("Open Location") { keyBrowserWindow?.focusAddressBar() }
                    .keyboardShortcut("l")
                Button("Reload Page") { keyBrowserWindow?.reload() }
                    .keyboardShortcut("r")
                Button("Back") { keyBrowserWindow?.goBack() }
                    .keyboardShortcut("[")
                Button("Forward") { keyBrowserWindow?.goForward() }
                    .keyboardShortcut("]")
            }
        }
    }

    @MainActor
    private var keyBrowserWindow: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Running profiles must be sealed (WebKit data encrypted) before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasRunningProfiles else { return .terminateNow }
        Task { @MainActor in
            await model.lock()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
