import AppKit
import WebKit

/// Wrapper that attempts to open a real Safari BrowserWindowController.
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
        
        guard let cls = SafariLoader.browserWindowControllerClass as? NSObject.Type else {
            NSLog("SafariBrowserWindowController: class not found")
            return nil
        }
        
        // BrowserWindowController init is private. Common patterns:
        // - initWithBrowsingMode:
        // - initWithWindowNibName:
        // Recover exact signature from class-dump / sample.
        let controller = cls.init()
        self.safariController = controller
        
        // Inject data store / profile if a known setter exists.
        if let dataStore {
            controller.setValue(dataStore, forKey: "websiteDataStore")
        }
        controller.setValue(profileID.uuidString, forKey: "profileIdentifier")
        
        if let window = controller.value(forKey: "window") as? NSWindow {
            window.title = "PrivacyBrowser"
            return window
        }
        return nil
    }
    
    func close() {
        safariController?.perform(#selector(NSWindowController.close))
    }
}
