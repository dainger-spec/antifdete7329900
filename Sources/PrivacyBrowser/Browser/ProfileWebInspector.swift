import AppKit
import ObjCExceptions
import WebKit

/// Local Web Inspector for a hosted profile. Each profile runs in its own process.
@MainActor
final class ProfileWebInspector: NSObject, NSMenuItemValidation {
    static let shared = ProfileWebInspector()
    private var menuItem: NSMenuItem?
    private let inspected = NSHashTable<WKWebView>.weakObjects()

    private let changedPreferences = NSHashTable<WKPreferences>.weakObjects()
    private let setExtras = NSSelectorFromString("_setDeveloperExtrasEnabled:")

    private func setLocalExtras(_ enabled: Bool, on prefs: WKPreferences) {
        typealias Setter = @convention(c) (WKPreferences, Selector, Bool) -> Void
        let set = unsafeBitCast(prefs.method(for: setExtras), to: Setter.self)
        set(prefs, setExtras, enabled)
    }

    private var page: WKWebView? {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && SafariChromeHost.isBrowserWindow($0) }) else { return nil }
        return SafariChromeHost.frontPage(in: window)
    }

    private func inspector(for page: WKWebView) -> NSObject? {
        let getter = NSSelectorFromString("_inspector")
        guard page.responds(to: getter),
              let object = page.perform(getter)?.takeUnretainedValue() as? NSObject,
              ["show", "close", "isVisible"].allSatisfy({ object.responds(to: NSSelectorFromString($0)) })
        else { return nil }
        return object
    }

    private var allowed: Bool {
        if UserDefaults(suiteName: "com.apple.applicationaccess")?.object(forKey: "allowWebInspector") as? Bool == false { return false }
        let safari = UserDefaults(suiteName: "com.apple.Safari")
        if UserDefaults.standard.bool(forKey: "WebKitDeveloperExtrasDisabledByOverride") ||
            safari?.bool(forKey: "WebKitDeveloperExtrasDisabledByOverride") == true { return false }
        return !["IncludeDevelopMenu", "WebKitDeveloperExtras"].contains {
            UserDefaults.standard.objectIsForced(forKey: $0) || safari?.objectIsForced(forKey: $0) == true
        }
    }

    func configure(_ button: NSButton) {
        let fallback = button.target === self || (!button.isEnabled && button.action == nil)
        guard fallback else { return }
        guard allowed, WKWebView.instancesRespond(to: NSSelectorFromString("_inspector")),
              WKPreferences.instancesRespond(to: setExtras) else { return }
        button.title = L("profile.inspector.switch")
        button.toolTip = L("profile.inspector.help")
        button.setAccessibilityHelp(button.toolTip)
        button.state = menuItem == nil ? .off : .on
        button.target = self
        button.action = #selector(toggle(_:))
        button.isEnabled = true
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let bar = NSApp.mainMenu else { sender.state = .off; return }
        if sender.state == .on, menuItem == nil {
            guard allowed else { sender.state = .off; return }
            let title = L("profile.inspector.menu")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            let open = menu.addItem(withTitle: L("profile.inspector.open"), action: #selector(openInspector), keyEquivalent: "i")
            open.keyEquivalentModifierMask = [.command, .option]
            open.target = self
            item.submenu = menu
            bar.insertItem(item, at: max(0, bar.items.count - 1))
            menuItem = item
        } else if sender.state == .off, let item = menuItem {
            item.menu?.removeItem(item)
            menuItem = nil
            for page in inspected.allObjects {
                _ = PBCatchException { _ = inspector(for: page)?.perform(NSSelectorFromString("close")) }
            }
            inspected.removeAllObjects()
            for prefs in changedPreferences.allObjects { setLocalExtras(false, on: prefs) }
            changedPreferences.removeAllObjects()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        self.menuItem != nil && allowed && page != nil
    }

    @objc func openInspector() {
        guard menuItem != nil, allowed, let page, let inspector = inspector(for: page) else { return }
        let prefs = page.configuration.preferences
        guard prefs.responds(to: setExtras), prefs.responds(to: NSSelectorFromString("_developerExtrasEnabled")) else { return }
        if prefs.value(forKey: "_developerExtrasEnabled") as? Bool == false {
            changedPreferences.add(prefs)
            setLocalExtras(true, on: prefs)
        }
        inspected.add(page)
        if PBCatchException({ _ = inspector.perform(NSSelectorFromString("show")) }) != nil {
            SafariChrome.presentNotice(L("safari.unavailable.title"), L("safari.unavailable.action"))
        }
    }
}
