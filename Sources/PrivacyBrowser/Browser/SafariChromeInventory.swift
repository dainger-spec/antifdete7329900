import AppKit
import CoreServices
import os

/// `PrivacyBrowser --safari-inventory`: what Safari's chrome brings into a profile's process, as
/// facts to decide from rather than guesses.
///
///   * MENU: every item of Safari's menu bar as a profile's window has it — its path, its action,
///     its key, its target, and whether it is enabled with a window of Safari's open.
///   * LS: what LaunchServices answers in a process with a home of its own about Safari and the
///     default browser (Safari's General pane threw on a nil from that corner).
///   * AUTOFILL, HISTORY, EXPORT, BOOKMARKS, SETTINGS: the classes of Safari's frameworks around
///     saving passwords and AutoFill, its history, exporting and importing browser data, the
///     Bookmarks sidebar and its settings, with their methods.
///   * WAITING: every method of Safari's frameworks whose name says it waits for an answer
///     ("Blocking", "WaitUntil", "UntilResponse", "Synchronous", "WaitFor").
///   * BOOKMARKS-FILE: what a new profile's Safari keeps as bookmarks.
///
/// In a home of its own and held to a closed proxy (`SafariChrome.prepareForCheck`): nothing here
/// is the user's, and nothing reaches the network. CI prints it into the job's log (ci.yml).
@MainActor
enum SafariChromeInventory {
    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard SafariChrome.prepareForCheck(arguments: arguments) else {
            print("INVENTORY Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        print("INVENTORY macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")
        // A step that waits forever (a service that never answers) must not keep CI waiting.
        inventoryStep = "start"
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            print("INVENTORY did not finish: stuck at \(inventoryStep)")
            exit(3)
        }
        SafariChrome.installMainMenu()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                inventoryStep = "opening Safari's window"
                let controller = SafariChrome.openWindow(address: nil)
                controller?.showWindow(nil)
                controller?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                print("INVENTORY Safari's window \(controller == nil ? "did not open" : "is open")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                launchServices()
                menu()
                classes()
                bookmarksFile()
                print("INVENTORY done")
                SafariChrome.removeCheckHome()
                exit(0)
            }
        }
        application.run()
    }

    // MARK: The menu

    private static func menu() {
        inventoryStep = "the menu"
        guard let bar = NSApp.mainMenu else {
            print("MENU none")
            return
        }
        walk(bar, path: [])
    }

    private static func walk(_ menu: NSMenu, path: [String]) {
        inventoryStep = "the menu: " + path.joined(separator: " › ")
        // Validates the items against their targets and the window in front, as opening it would;
        // the menus Safari fills only as they open (History, Bookmarks) are left as they are.
        menu.update()
        for item in menu.items where !item.isSeparatorItem {
            let here = path + [item.title]
            if let submenu = item.submenu {
                walk(submenu, path: here)
                continue
            }
            let action = item.action.map(NSStringFromSelector) ?? "-"
            let target = item.target.map { String(describing: type(of: $0)) } ?? "first responder"
            print("MENU \(here.joined(separator: " › ")) | \(action) | \(keys(of: item)) | \(target) | "
                  + "\(item.isEnabled ? "enabled" : "disabled")\(item.isHidden ? ", hidden" : "")")
        }
    }

    private static func keys(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "-" }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        // An upper-case key equivalent is typed with Shift.
        if mask.contains(.shift) || key != key.lowercased() { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    // MARK: LaunchServices

    private static func launchServices() {
        inventoryStep = "LaunchServices"
        let page = URL(string: "https://example.com")!
        let workspace = NSWorkspace.shared
        print("LS main bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        print("LS application for com.apple.Safari: \(workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari")?.path ?? "nil")")
        print("LS default application for https: \(workspace.urlForApplication(toOpen: page)?.path ?? "nil")")
        print("LS applications for https: \(workspace.urlsForApplications(toOpen: page).count)")
        let handler = LSCopyDefaultHandlerForURLScheme("https" as CFString).map { $0.takeRetainedValue() as String }
        print("LS default handler for https: \(handler ?? "nil")")
    }

    // MARK: Safari's classes

    private static let topics: [(label: String, classes: String, methods: String?)] = [
        ("AUTOFILL", "(?i)password|autofill|credential|savedaccount|keychain|formfill|passkey|creditcard|formdata",
         "(?i)save|offer|prompt|banner|present|show|should|enabled|store|submit|did|will"),
        ("HISTORY", "(?i)^(WBS)?History", nil),
        ("EXPORT", "(?i)export|import", "(?i)export|import|write|save|url|path|directory|finish|complete"),
        ("BOOKMARKS", "(?i)annotatedbookmarks|bookmarkssidebar|bookmarkstable", nil),
        ("SETTINGS", "(?i)^General(Preferences|Settings)|PreferencesUIController", nil),
    ]
    private static let waiting = "(?i)blocking|waituntil|untilresponse|synchronous|waitfor"

    private static func classes() {
        let images = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
            .filter { $0.contains(".framework/") && $0.contains("/Safari") }
        for image in images {
            inventoryStep = "the classes of \(image)"
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(image, &count) else { continue }
            defer { free(names) }
            print("IMAGE \(image): \(count) classes")
            for index in 0..<Int(count) {
                let name = String(cString: names[index])
                guard let cls = NSClassFromString(name) else { continue }
                let methods = methodList(cls, prefix: "-") + (object_getClass(cls).map { methodList($0, prefix: "+") } ?? [])
                for method in methods where method.name.range(of: waiting, options: .regularExpression) != nil {
                    print("WAITING \(name) \(method.prefix)\(method.name) \(method.types)")
                }
                for topic in topics where name.range(of: topic.classes, options: .regularExpression) != nil {
                    let shown = methods.filter { topic.methods == nil || $0.name.range(of: topic.methods!, options: .regularExpression) != nil }
                    print("\(topic.label) \(name): \(methods.count) methods, \(shown.count) shown")
                    for method in shown.prefix(80) {
                        print("\(topic.label) \(name) \(method.prefix)\(method.name) \(method.types)")
                    }
                }
            }
        }
    }

    private static func methodList(_ cls: AnyClass, prefix: String) -> [(prefix: String, name: String, types: String)] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { index in
            let method = list[index]
            let types = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            return (prefix, NSStringFromSelector(method_getName(method)), types)
        }
    }

    // MARK: A new profile's bookmarks

    private static func bookmarksFile() {
        inventoryStep = "the bookmarks file"
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { return }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            print("BOOKMARKS-FILE none in a new profile's Safari home (so far)")
            return
        }
        var leaves = 0
        func visit(_ node: Any, _ path: [String]) {
            guard let entry = node as? [String: Any] else { return }
            let title = (entry["Title"] as? String) ?? ((entry["URIDictionary"] as? [String: Any])?["title"] as? String) ?? ""
            if let children = entry["Children"] as? [Any] {
                for child in children { visit(child, path + [title]) }
            } else if let address = entry["URLString"] as? String {
                leaves += 1
                let place = (path + [title]).filter { !$0.isEmpty }.joined(separator: " › ")
                print("BOOKMARKS-FILE \(place) → \(URL(string: address)?.host ?? address)")
            }
        }
        visit(root, [])
        print("BOOKMARKS-FILE \(leaves) bookmark(s)")
    }
}

/// What the inventory is doing, for the watchdog's line when it does not finish.
nonisolated(unsafe) private var inventoryStep = ""
