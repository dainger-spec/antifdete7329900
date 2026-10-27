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
                // Lumen's chrome is always dark (Theme); web content follows the system (WebContentAppearance).
                .preferredColorScheme(.dark)
                .background(WindowReader { window in
                    appDelegate.model = model
                    model.profilesWindow = window
                    Theme.applyChrome(to: window)
                })
        }
        // The sidebar runs to the top of the window, under the traffic lights.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 740)
        .windowResizability(.contentMinSize)
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
    private lazy var quitCoordinator = QuitCoordinator(
        hasActivity: { [weak self] in self?.model?.hasActivity ?? false },
        lockForQuit: { [weak self] in await self?.model?.lock(forQuit: true) },
        // Closing the profile windows reveals the Profiles window, whose rows show "Encrypting…".
        willSeal: { [weak self] in self?.model?.activateProfilesWindow() },
        terminate: { NSApp.terminate(nil) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Such a run has no icon file either: the Dock gets the icon drawn (the .app carries AppIcon.icns).
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil, let icon = AppIcon.image() {
            NSApp.applicationIconImage = icon
        }
        // `NSApp.appearance` stays unset: each window of the app is made dark itself (Theme.applyChrome),
        // and web content keeps following the system's setting, as in Safari (see
        // docs/ISOLATION_AND_LIMITATIONS §11).
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing a profile window (or any window) must never quit the app — only ⌘Q or Lock do.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the dock icon with no visible window brings the Profiles window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.activateProfilesWindow() }
        return true
    }

    /// Running profiles must be sealed (WebKit data encrypted) before the process exits — also
    /// while a profile is still launching or sealing, or a Lock is under way. See `QuitCoordinator`
    /// for why the seal runs after this returns instead of inside it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitCoordinator.shouldTerminate(sender)
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
