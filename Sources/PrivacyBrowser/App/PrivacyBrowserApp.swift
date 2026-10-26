import AppKit
import BrowserCore
import SwiftUI

/// Started from `main.swift` (which also dispatches `--self-test`).
struct PrivacyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @ObservedObject private var preferences = AppPreferences.shared

    var body: some Scene {
        Window(L("window.profiles.title"), id: "profiles") {
            RootView(preferences: preferences)
                .environmentObject(model)
                .preferredColorScheme(preferences.appearance.colorScheme)
                .background(WindowReader { window in
                    appDelegate.model = model
                    model.profilesWindow = window
                })
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.newTab")) { keyBrowserWindow?.newTab() }
                    .keyboardShortcut("t")
                Button(L("menu.reopenClosedTab")) { keyBrowserWindow?.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button(L("profiles.action.new")) {
                    model.activateProfilesWindow()
                    model.sheet = .newProfile
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.phase != .unlocked)
                Button(L("profiles.action.importProfile")) {
                    model.activateProfilesWindow()
                    ProfileActions.importProfile(model)
                }
                .disabled(model.phase != .unlocked)
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
            CommandMenu(L("menu.profile")) {
                Button(L("menu.showDownloads")) { keyBrowserWindow?.showDownloadsFromMenu() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button(L("proxy.check")) {
                    if let id = model.manager?.keyWindowProfileID { Task { await model.checkProxy(id) } }
                }
                Divider()
                Button(L("profiles.row.importCookies")) {
                    if let id = model.manager?.keyWindowProfileID { ProfileActions.importCookies(model, id) }
                }
                Button(L("menu.exportCookiesNetscape")) {
                    if let id = model.manager?.keyWindowProfileID { ProfileActions.exportCookies(model, id, format: .netscape) }
                }
                Button(L("menu.exportCookiesJSON")) {
                    if let id = model.manager?.keyWindowProfileID { ProfileActions.exportCookies(model, id, format: .json) }
                }
                Divider()
                Button(L("menu.showProfiles")) { model.activateProfilesWindow() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandMenu(L("menu.bookmarks")) {
                Button(L("menu.bookmarkThisPage")) { keyBrowserWindow?.toggleBookmark() }
                    .keyboardShortcut("d")
                Button(L("menu.showAllBookmarks")) { keyBrowserWindow?.showBookmarks() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button(L("menu.showHistory")) { keyBrowserWindow?.showHistory() }
                    .keyboardShortcut("y")
            }
            CommandGroup(replacing: .help) {
                ShowLogButton()
            }
        }

        Window(L("window.log.title"), id: "log") {
            LogView()
                .frame(minWidth: 560, minHeight: 360)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView(preferences: preferences)
                .environmentObject(model)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
    }

    @MainActor
    private var keyBrowserWindow: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
    }
}

/// Help ▸ Show Log.
private struct ShowLogButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("menu.showLog")) { openWindow(id: "log") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Light by default; dark or "as the system" from Settings ▸ General.
        AppPreferences.shared.applyAppearance()
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
        guard let model, model.hasRunningProfiles else {
            Log.info("app", "quit")
            return .terminateNow
        }
        guard !isTerminating else { return .terminateLater } // ⌘Q pressed twice: don't start a second lock
        isTerminating = true
        Task { @MainActor in
            await model.lock()
            Log.info("app", "quit after encrypting running profiles")
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
