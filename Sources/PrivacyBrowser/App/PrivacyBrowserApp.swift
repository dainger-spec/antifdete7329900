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
                    Theme.applyAppWindow(to: window)
                    model.startUpdates()
                })
        }
        // The sidebar runs to the top of the window, under the traffic lights.
        .windowStyle(.hiddenTitleBar)
        // Room for the list and the inspector side by side (ProfilesScreen), within a 13-inch
        // MacBook Air's screen.
        .defaultSize(width: 1400, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.newTab")) { keyBrowserWindow?.newTab() }
                    .keyboardShortcut("t")
                Button(L("menu.reopenClosedTab")) { keyBrowserWindow?.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                CommandPaletteButton(model: model)
                ScenariosMenuButton(model: model)
            }
            CommandGroup(after: .pasteboard) {
                Button(L("menu.pasteAsTyped")) { HumanPaste.pasteIntoKeyWindow() }
                    .keyboardShortcut("v", modifiers: [.command, .control])
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
            CommandGroup(replacing: .help) {
                HelpMenuButton()
            }
        }
        // The scenario editor (docs/AUTOMATION.md): File › Scenarios.
        Window(L("window.scenarios.title"), id: "scenarios") {
            ScenariosView()
                .saysModelErrors()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .background(WindowReader { window in
                    Theme.applyAppWindow(to: window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        // The app's own help (HelpView): Help › Lumen Help (⌘?), and Help in the Profiles window.
        Window(L("window.help.title"), id: "help") {
            HelpView(topic: $model.helpTopic)
                .preferredColorScheme(.dark)
                .background(WindowReader { window in
                    Theme.applyAppWindow(to: window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 760)
        // ⌘, and the app menu's Settings…; also ⋯ → Settings… in the Profiles window.
        Settings {
            SettingsView()
                .saysModelErrors()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .modifier(SettingsTitleBar())
                .background(WindowReader { window in
                    Theme.applyAppWindow(to: window)
                    // The design's settings: the sidebar runs to the top, under the traffic lights.
                    window.styleMask.insert(.fullSizeContentView)
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                })
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
        terminate: { NSApp.terminate(nil) },
        // An update goes to its installer only at the end of a quit that sealed every profile.
        hasUpdate: { [weak self] in self?.model?.updater?.isReady ?? false },
        installUpdate: { [weak self] in await self?.model?.installUpdateAtQuit() },
        confirm: { [weak self] in
            let quits = self?.confirmQuit() ?? true
            // A restart asked for (Settings › Language) and declined here: no reopening later.
            if !quits { SystemOpen.cancelRelaunch() }
            return quits
        })

    /// Settings → Startup → confirm quit: asked when profiles run, before any of them is stopped.
    private func confirmQuit() -> Bool {
        guard let model, model.settings.confirmQuit else { return true }
        let running = model.updateStopsList()
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = L("quit.confirm.title")
        alert.informativeText = L("quit.confirm.message") + "\n" + running.map { "• " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: L("quit.confirm.quit"))
        alert.addButton(withTitle: L("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

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
        // `--settings-window-check` (CI): nothing otherwise.
        SettingsWindowCheck.start()
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

/// File › Scenarios (⇧⌘E): the scenario editor's window, with the vault unlocked.
private struct ScenariosMenuButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("menu.scenarios")) { openWindow(id: "scenarios") }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.phase != .unlocked)
    }
}

/// Help › Lumen Help (⌘?): the app's own help, with the vault locked or open.
private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("menu.help")) { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}

/// ⌘K: the command palette, in the Profiles window — brought to the front, or opened again if it
/// was closed.
private struct CommandPaletteButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("menu.commandPalette")) {
            if model.profilesWindow == nil { openWindow(id: "profiles") }
            model.activateProfilesWindow()
            model.showingPalette = true
        }
        .keyboardShortcut("k")
        .disabled(model.phase != .unlocked)
    }
}

/// The Settings window's title bar is the content's: no band of the system's grey above the sidebar
/// and the page (the owner, 1 and 2 November). SwiftUI's Settings scene keeps its window's title bar
/// opaque: it set `titlebarAppearsTransparent` back to false after the window reader above made it
/// true, and the window server drew the bar in a neutral grey — #1E1E1E on macOS 26, #262626 on
/// macOS 27, 30 points tall (CI run 596, the real window captured). Told by SwiftUI itself that the
/// window's toolbar has no background, the scene leaves the bar transparent, on both. Hiding the
/// toolbar instead (`.toolbar(.hidden, for: .windowToolbar)`) left the band on macOS 27.
///
/// `SettingsWindowCheck`'s control takes this back, and its check must then fail.
private struct SettingsTitleBar: ViewModifier {
    func body(content: Content) -> some View {
        if SettingsWindowCheck.breaksTheFix {
            content
        } else if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
