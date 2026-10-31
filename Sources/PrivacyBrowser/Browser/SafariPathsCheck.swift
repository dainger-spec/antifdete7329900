import AppKit
import BrowserCore
import OSLog

/// `Lumen --paths-check`: where Safari's code in a profile's process finds no path.
///
/// The owner's Mac, 31 October: Safari's bookmarks database "at (null)" (SQLite error 11, "Couldn't
/// create bookmarks database at (null)", "Failed to instantiate tab collection") from a profile's
/// first launch, and Safari's `WBSBannerTracker` handing an empty path to `-[NSURL
/// initFileURLWithPath:isDirectory:]` on a background queue, which ended the process. In a process
/// like a profile's — a home of its own, held to a closed proxy, Safari's chrome prepared — with
/// Safari's window open, this prints every file URL asked for with an empty or missing path, with
/// the frames that asked (and answers nil instead of throwing, so that the run goes on), every app
/// group container asked for and what it answered, and the lines of this process's own log about
/// bookmarks, Safari's tab collection, downloads and paths that are "(null)". A measurement.
@MainActor
enum SafariPathsCheck {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard SafariChrome.prepareForCheck(arguments: arguments) else {
            print("PATHS-CHECK Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        let started = Date()
        watchEmptyFilePaths()
        watchGroupContainers()
        // As --export-check opens it (CI run 530: with no menu and the activation policy
        // .prohibited, Safari's window factory gave nothing, and this measured nothing).
        SafariChrome.installMainMenu()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        ExceptionLog.onCaughtInRunLoop = { exception, _ in
            print("PATHS-CHECK threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
        }
        ExceptionLog.onNotCaught = { name, thread in print("PATHS-CHECK not caught, on \(thread): \(name)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let controller = SafariChrome.openWindow(address: URL(string: "about:blank"))
                controller?.showWindow(nil)
                controller?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                windowOpened = controller != nil
                print("PATHS-CHECK Safari's window \(windowOpened ? "is open" : "did not open")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated {
                printOwnLog(since: started)
                print("PATHS-CHECK file URLs asked for with no path: \(emptyPaths); app group containers asked for: \(groupRequests)")
                SafariChrome.removeCheckHome()
                // Without Safari's window, nothing of what it asks for was seen: never a clean result.
                if !windowOpened {
                    print("PATHS-CHECK SKIPPED: Safari's window did not open, so what its code asks for in a profile's process was not seen")
                    exit(1)
                }
                exit(0)
            }
        }
        application.run()
        exit(0)
    }

    nonisolated(unsafe) private static var emptyPaths = 0
    private static var windowOpened = false
    nonisolated(unsafe) private static var groupRequests = 0
    nonisolated private static let lock = NSLock()

    /// `-[NSURL initFileURLWithPath:]` and `-[NSURL initFileURLWithPath:isDirectory:]` given nil or
    /// "": printed with the frames below them, and answered with nil — as a nil URL, which callers
    /// may handle — instead of the exception that ended the owner's profile.
    private static func watchEmptyFilePaths() {
        typealias WithFlag = @convention(c) (AnyObject, Selector, NSString?, Bool) -> AnyObject?
        typealias Plain = @convention(c) (AnyObject, Selector, NSString?) -> AnyObject?
        let flagged = NSSelectorFromString("initFileURLWithPath:isDirectory:")
        if let method = class_getInstanceMethod(NSURL.self, flagged) {
            let original = unsafeBitCast(method_getImplementation(method), to: WithFlag.self)
            let replacement: @convention(block) (AnyObject, NSString?, Bool) -> AnyObject? = { url, path, isDirectory in
                if path == nil || path?.length == 0 {
                    report(emptyPath: path, in: "initFileURLWithPath:isDirectory:")
                    return nil
                }
                return original(url, flagged, path, isDirectory)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let plain = NSSelectorFromString("initFileURLWithPath:")
        if let method = class_getInstanceMethod(NSURL.self, plain) {
            let original = unsafeBitCast(method_getImplementation(method), to: Plain.self)
            let replacement: @convention(block) (AnyObject, NSString?) -> AnyObject? = { url, path in
                if path == nil || path?.length == 0 {
                    report(emptyPath: path, in: "initFileURLWithPath:")
                    return nil
                }
                return original(url, plain, path)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    nonisolated private static func report(emptyPath path: NSString?, in method: String) {
        lock.withLock { emptyPaths += 1 }
        let thread = Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(cString: __dispatch_queue_get_label(nil))
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(14).map { line in
            // "4   SafariShared   0x… -[WBSBannerTracker load] + 120": the image and the symbol.
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().filter { !$0.hasPrefix("0x") }.joined(separator: " ")
        }
        print("PATHS-CHECK -[NSURL \(method)] given \(path == nil ? "nil" : "\"\"") on \(thread), from: \(frames.joined(separator: " | "))")
    }

    /// `-[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]`: each group asked for,
    /// and what this process was answered.
    private static func watchGroupContainers() {
        typealias Container = @convention(c) (AnyObject, Selector, NSString?) -> NSURL?
        let selector = NSSelectorFromString("containerURLForSecurityApplicationGroupIdentifier:")
        guard let method = class_getInstanceMethod(FileManager.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Container.self)
        let replacement: @convention(block) (AnyObject, NSString?) -> NSURL? = { manager, group in
            let answer = original(manager, selector, group)
            lock.withLock { groupRequests += 1 }
            let caller = Thread.callStackSymbols.dropFirst(2).first.map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().filter { !$0.hasPrefix("0x") }.joined(separator: " ")
            } ?? "?"
            print("PATHS-CHECK app group \(group.map { $0 as String } ?? "nil") answered \(answer?.path ?? "nil"), asked by \(caller)")
            return answer
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// This process's own log since the start, the lines about bookmarks, Safari's tab collection,
    /// downloads, and paths that are "(null)".
    private static func printOwnLog(since start: Date) {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: start)) else {
            print("PATHS-CHECK this process's log could not be read")
            return
        }
        // And Safari's window factory's own lines (SafariChrome), which say why a window did not open.
        let words = ["bookmark", "tab collection", "download", "(null)", "sqlite", "window factory", "safari's chrome is up"]
        var shown = 0
        for case let entry as OSLogEntryLog in entries where shown < 80 {
            let message = entry.composedMessage
            guard words.contains(where: { message.lowercased().contains($0) }) else { continue }
            shown += 1
            print("PATHS-CHECK log [\(entry.subsystem) \(entry.category)] \(message.prefix(300))")
        }
        print("PATHS-CHECK log lines shown: \(shown)")
    }
}
