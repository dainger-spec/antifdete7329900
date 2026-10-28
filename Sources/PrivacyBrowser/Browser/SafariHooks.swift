import Foundation
import ObjectiveC
import AppKit

/// Installs swizzles on Safari methods recovered from sample stacks.
/// Hooks windowDidLoad and _didCompleteContentSetup to apply shell mode
/// (hide dock/menu bar, borderless window) immediately after creation.
enum SafariHooks {
    static func install() {
        guard let cls = NSClassFromString("BrowserWindowController") else { return }
        swizzle(cls, "windowDidLoad", "swizzled_windowDidLoad")
        swizzle(cls, "_didCompleteContentSetup", "swizzled_didCompleteContentSetup")
        NSLog("SafariHooks: installed windowDidLoad + _didCompleteContentSetup")
    }
    
    private static func swizzle(_ cls: AnyClass, _ original: String, _ replacement: String) {
        let origSel = NSSelectorFromString(original)
        let replSel = NSSelectorFromString(replacement)
        guard let orig = class_getInstanceMethod(cls, origSel) else {
            NSLog("SafariHooks: original \(original) not found")
            return
        }
        // Add the replacement method if it doesn't exist yet.
        if class_getInstanceMethod(cls, replSel) == nil {
            let imp = class_getMethodImplementation(cls, origSel)
            class_addMethod(cls, replSel, imp, method_getTypeEncoding(orig))
        }
        guard let repl = class_getInstanceMethod(cls, replSel) else { return }
        method_exchangeImplementations(orig, repl)
    }
}

// MARK: - Swizzled implementations (called via exchange)

extension NSObject {
    @objc func swizzled_windowDidLoad() {
        // Call original first.
        self.swizzled_windowDidLoad()
        // Apply shell after load.
        if let window = self.value(forKey: "window") as? NSWindow {
            SafariHooks.applyShell(to: window)
        }
    }
    
    @objc func swizzled_didCompleteContentSetup() {
        self.swizzled_didCompleteContentSetup()
        if let window = self.value(forKey: "window") as? NSWindow {
            SafariHooks.applyShell(to: window)
        }
    }
}

extension SafariHooks {
    static func applyShell(to window: NSWindow) {
        NSApp.setActivationPolicy(.accessory)
        window.styleMask.remove(.titled)
        window.styleMask.insert(.borderless)
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSLog("SafariHooks: shell applied")
    }
}
