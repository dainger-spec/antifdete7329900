import AppKit
import SwiftUI

/// Started from `main.swift` (which also dispatches `--self-test`).
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
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { keyBrowserWindow?.newTab() }
                    .keyboardShortcut("t")
                Button("Reopen Closed Tab") { keyBrowserWindow?.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("Browser") {
                Button("Open Location") { keyBrowserWindow?.focusAddressBar() }
                    .keyboardShortcut("l")
                Button("Reload Page") { keyBrowserWindow?.reload() }
                    .keyboardShortcut("r")
                Button("Back") { keyBrowserWindow?.goBack() }
                    .keyboardShortcut("[")
                Button("Forward") { keyBrowserWindow?.goForward() }
                    .keyboardShortcut("]")
                Divider()
                Button("Show Next Tab") { keyBrowserWindow?.selectNextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") { keyBrowserWindow?.selectPreviousTab() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Select Last Tab" : "Select Tab \(number)") { keyBrowserWindow?.selectTab(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
            CommandMenu("Bookmarks") {
                Button("Bookmark This Page") { keyBrowserWindow?.toggleBookmark() }
                    .keyboardShortcut("d")
                Button("Show All Bookmarks") { keyBrowserWindow?.showBookmarks() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Show History") { keyBrowserWindow?.showHistory() }
                    .keyboardShortcut("y")
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
