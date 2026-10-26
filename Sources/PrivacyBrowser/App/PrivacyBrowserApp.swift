import AppKit
import SwiftUI

/// Started from `main.swift` (which also dispatches `--self-test`).
struct PrivacyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window(L("window.profiles.title"), id: "profiles") {
            RootView()
                .environmentObject(model)
                // Clean light theme by default (see docs); the browser content itself follows the site.
                .preferredColorScheme(.light)
                .background(WindowReader { window in
                    appDelegate.model = model
                    model.profilesWindow = window
                })
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.newTab")) { keyBrowserWindow?.newTab() }
                    .keyboardShortcut("t")
                Button(L("menu.reopenClosedTab")) { keyBrowserWindow?.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu(L("menu.browser")) {
                Button(L("menu.openLocation")) { keyBrowserWindow?.focusAddressBar() }
                    .keyboardShortcut("l")
                Button(L("menu.reload")) { keyBrowserWindow?.reload() }
                    .keyboardShortcut("r")
                Button(L("menu.back")) { keyBrowserWindow?.goBack() }
                    .keyboardShortcut("[")
                Button(L("menu.forward")) { keyBrowserWindow?.goForward() }
                    .keyboardShortcut("]")
                Divider()
                Button(L("menu.showNextTab")) { keyBrowserWindow?.selectNextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button(L("menu.showPreviousTab")) { keyBrowserWindow?.selectPreviousTab() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? L("menu.selectLastTab") : String(format: L("menu.selectTabN"), number)) {
                        keyBrowserWindow?.selectTab(number: number)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
            CommandMenu(L("menu.bookmarks")) {
                Button(L("menu.bookmarkThisPage")) { keyBrowserWindow?.toggleBookmark() }
                    .keyboardShortcut("d")
                Button(L("menu.showAllBookmarks")) { keyBrowserWindow?.showBookmarks() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button(L("menu.showHistory")) { keyBrowserWindow?.showHistory() }
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
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Clean light theme regardless of the system setting (see docs/ISOLATION_AND_LIMITATIONS §11).
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing a profile window (or any window) must never quit the app — only ⌘Q or Lock do.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the dock icon with no visible window brings the Profiles window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.activateProfilesWindow() }
        return true
    }

    /// Running profiles must be sealed (WebKit data encrypted) before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Also while a profile is still launching or sealing, or a Lock is under way: quitting
        // then would leave its WebKit data decrypted on disk.
        guard let model, model.hasActivity else { return .terminateNow }
        guard !isTerminating else { return .terminateLater } // ⌘Q pressed twice: don't start a second lock
        isTerminating = true
        Task { @MainActor in
            await model.lock()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Reports the `NSWindow` that hosts this SwiftUI view, once it is attached. Used to find the
/// Profiles window so it can be brought back to the front.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onResolve(window) }
        }
    }
}
