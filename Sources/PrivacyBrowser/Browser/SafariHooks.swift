import Foundation
import ObjectiveC

/// Installs no-op swizzles on Safari methods that crash without private entitlements.
/// Add selectors as crash logs / sample reveal them.
enum SafariHooks {
    static func install() {
        guard let cls = NSClassFromString("BrowserWindowController") else { return }
        // Placeholder: real selectors recovered from sample stacks.
        // Example: swizzle(cls, "updateSidebarVisibility", "swizzled_updateSidebarVisibility")
        NSLog("SafariHooks: ready (no selectors installed yet)")
    }
    
    private static func swizzle(_ cls: AnyClass, _ original: String, _ replacement: String) {
        let origSel = NSSelectorFromString(original)
        let replSel = NSSelectorFromString(replacement)
        guard let orig = class_getInstanceMethod(cls, origSel),
              let repl = class_getInstanceMethod(cls, replSel) else { return }
        method_exchangeImplementations(orig, repl)
    }
}
