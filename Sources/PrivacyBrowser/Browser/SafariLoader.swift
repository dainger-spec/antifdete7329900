import Foundation

/// Loads Safari.framework via dlopen.
/// Does not link at build time; loaded only when Safari mode is requested.
enum SafariLoader {
    private static var handle: UnsafeMutableRawPointer?
    
    static func load() -> Bool {
        if handle != nil { return true }
        let path = "/System/Library/PrivateFrameworks/Safari.framework/Safari"
        handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        if handle == nil {
            NSLog("SafariLoader: dlopen failed: \(String(cString: dlerror()))")
            return false
        }
        NSLog("SafariLoader: loaded")
        return true
    }
    
    static var browserWindowControllerClass: AnyClass? {
        guard load() else { return nil }
        return NSClassFromString("BrowserWindowController")
    }
    
    static var browserViewControllerClass: AnyClass? {
        guard load() else { return nil }
        return NSClassFromString("BrowserViewController")
    }
}
