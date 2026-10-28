import AppKit
import WebKit

/// Wrapper that attempts to open a real Safari BrowserWindowController via the
/// path recovered from sample: AppController._newWindowWithFrontmostProfile: →
/// _createNewWindowWithFrontmostProfile: → BrowserWindowController showWindow:.
/// Falls back to nil if creation fails; caller should use the existing custom path.
@MainActor
final class SafariBrowserWindowController: NSObject {
    private var safariController: NSObject?
    let profileID: UUID
    
    init(profileID: UUID) {
        self.profileID = profileID
        super.init()
    }
    
    /// Returns the Safari window if the controller was created, otherwise nil.
    func open(dataStore: WKWebsiteDataStore?) -> NSWindow? {
        guard SafariLoader.load() else { return nil }
        SafariHooks.install()
        
        // Prefer the real creation path recovered from sample.
        if let window = openViaAppController(dataStore: dataStore) {
            return window
        }
        
        // Fallback: direct init (rarely works without private entitlements).
        guard let cls = SafariLoader.browserWindowControllerClass as? NSObject.Type else {
            NSLog("SafariBrowserWindowController: class not found")
            return nil
        }
        let controller = cls.init()
        self.safariController = controller
        if let dataStore {
            controller.setValue(dataStore, forKey: "websiteDataStore")
        }
        controller.setValue(profileID.uuidString, forKey: "profileIdentifier")
        if let window = controller.value(forKey: "window") as? NSWindow {
            window.title = "PrivacyBrowser"
            applyShell(to: window)
            return window
        }
        return nil
    }
    
    /// Uses the sample-recovered path: AppController._newWindowWithFrontmostProfile:
    private func openViaAppController(dataStore: WKWebsiteDataStore?) -> NSWindow? {
        guard let appControllerClass = NSClassFromString("AppController") as? NSObject.Type else {
            NSLog("SafariBrowserWindowController: AppController not found")
            return nil
        }
        // Shared instance is the usual pattern for AppController.
        let shared = appControllerClass.perform(#selector(NSObject.value(forKey:)), with: "sharedController")?.takeUnretainedValue() as? NSObject
            ?? appControllerClass.init()
        
        // _newWindowWithFrontmostProfile: returns the BrowserWindowController.
        let sel = NSSelectorFromString("_newWindowWithFrontmostProfile:")
        guard shared.responds(to: sel) else {
            NSLog("SafariBrowserWindowController: _newWindowWithFrontmostProfile: not found")
            return nil
        }
        guard let controller = shared.perform(sel)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        self.safariController = controller
        
        if let dataStore {
            controller.setValue(dataStore, forKey: "websiteDataStore")
        }
        controller.setValue(profileID.uuidString, forKey: "profileIdentifier")
        
        // Force show if not already visible.
        controller.perform(#selector(NSWindowController.showWindow(_:)), with: nil)
        
        if let window = controller.value(forKey: "window") as? NSWindow {
            window.title = "PrivacyBrowser"
            applyShell(to: window)
            return window
        }
        return nil
    }
    
    private func applyShell(to window: NSWindow) {
        // Hide dock and menu bar so the window reads as a pure browser shell.
        NSApp.setActivationPolicy(.accessory)
        window.styleMask.remove(.titled)
        window.styleMask.insert(.borderless)
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Hide the system menu bar and dock for this process.
        if let dock = NSClassFromString("NSApplication") as? NSObject.Type {
            dock.perform(#selector(NSObject.setValue(_:forKey:)), with: false, with: "presentationOptions")
        }
        NSLog("SafariBrowserWindowController: shell applied to window")
    }
    
    func close() {
        safariController?.perform(#selector(NSWindowController.close))
    }
}
