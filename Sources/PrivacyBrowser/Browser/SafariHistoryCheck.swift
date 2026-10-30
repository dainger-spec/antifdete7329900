import AppKit
import BrowserCore
import os

/// `PrivacyBrowser --history-check`: can Safari's history run inside a profile's process?
///
/// Safari's own history store asks Safari's History service, an XPC service of Safari.app that
/// no other process can start, so in a profile's window it waits for it for ever: the History
/// menu stays empty and an export of browsing data spins. Safari's frameworks hold the service's
/// own code (`WBSHistoryService`, `WBSHistoryServiceDatabase`) and a connection that talks to a
/// service in the same process (`-[WBSHistoryConnection initWithHistoryService:]`), and Safari's
/// shared history takes its connection from a holder (`+[HistoryConnectionProxyHolder
/// storeAndPreWarmProxy:]`). This makes the service and the connection in a process like a
/// profile's (a home of its own, held to a closed proxy, Safari's chrome prepared), hands the
/// connection to the holder, makes Safari's shared history and asks it to load — then prints what
/// came back, where the service's database is, and what is in the home's `Library/Safari`. A
/// measurement: the History menu is decided from it.
@MainActor
enum SafariHistoryCheck {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard SafariChrome.prepareForCheck(arguments: arguments) else {
            print("HISTORY-CHECK Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        ExceptionLog.onCaughtInRunLoop = { exception, _ in
            print("HISTORY-CHECK threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
        }
        let steps = HistorySteps()
        steps.perform(#selector(HistorySteps.makeService), with: nil, afterDelay: 0.3)
        steps.perform(#selector(HistorySteps.loadHistory), with: nil, afterDelay: 1.5)
        steps.perform(#selector(HistorySteps.report), with: nil, afterDelay: 9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated {
                print("HISTORY-CHECK exceptions: \(ExceptionLog.reported)")
                SafariChrome.removeCheckHome()
                exit(0)
            }
        }
        application.run()
        exit(0)
    }

    /// The in-process connection, kept for the run.
    fileprivate static var connection: AnyObject?
    fileprivate static var history: AnyObject?
}

/// The check's steps, each from a timer of AppKit's run loop (an exception there is lived through).
private final class HistorySteps: NSObject {
    @objc func makeService() {
        MainActor.assumeIsolated {
            guard let serviceClass = NSClassFromString("WBSHistoryService"),
                  let connectionClass = NSClassFromString("WBSHistoryConnection") else {
                print("HISTORY-CHECK not in this Safari: WBSHistoryService or WBSHistoryConnection")
                return
            }
            // The service asks whether a connecting process may use the user's database, by the
            // entitlements an XPC client has; in one process there is no client to ask.
            let entitled = NSSelectorFromString("_connectionIsEntitledToUseUserDatabase:")
            if let method = class_getInstanceMethod(serviceClass, entitled) {
                let yes: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, _ in true }
                method_setImplementation(method, imp_implementationWithBlock(yes))
            }
            guard let service = Self.make(serviceClass, "init", nil) else {
                print("HISTORY-CHECK WBSHistoryService was not made")
                return
            }
            print("HISTORY-CHECK WBSHistoryService made; its database: \(Self.object(service, "databaseURL").map { String(describing: $0) } ?? "nil")")
            guard let connection = Self.make(connectionClass, "initWithHistoryService:", service) else {
                print("HISTORY-CHECK WBSHistoryConnection was not made")
                return
            }
            SafariHistoryCheck.connection = connection
            print("HISTORY-CHECK WBSHistoryConnection made in this process")
            if let holder = NSClassFromString("HistoryConnectionProxyHolder"),
               let method = class_getClassMethod(holder, NSSelectorFromString("storeAndPreWarmProxy:")) {
                typealias Store = @convention(c) (AnyClass, Selector, AnyObject?) -> Void
                unsafeBitCast(method_getImplementation(method), to: Store.self)(holder, NSSelectorFromString("storeAndPreWarmProxy:"), connection)
                print("HISTORY-CHECK the holder has the in-process connection")
            } else {
                print("HISTORY-CHECK not in this Safari: +[HistoryConnectionProxyHolder storeAndPreWarmProxy:]")
            }
        }
    }

    @objc func loadHistory() {
        MainActor.assumeIsolated {
            guard let historyClass = NSClassFromString("History"),
                  let method = class_getClassMethod(historyClass, NSSelectorFromString("sharedHistory")) else {
                print("HISTORY-CHECK not in this Safari: +[History sharedHistory]")
                return
            }
            typealias Shared = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            guard let history = unsafeBitCast(method_getImplementation(method), to: Shared.self)(historyClass, NSSelectorFromString("sharedHistory"))?
                .takeUnretainedValue() else {
                print("HISTORY-CHECK +[History sharedHistory] gave nothing")
                return
            }
            SafariHistoryCheck.history = history
            print("HISTORY-CHECK Safari's shared history: \(String(describing: type(of: history)))")
            Self.call(history, "_loadHistory")
            print("HISTORY-CHECK asked it to load")
        }
    }

    @objc func report() {
        MainActor.assumeIsolated {
            if let history = SafariHistoryCheck.history {
                let items = (Self.object(history, "allItems") as? NSArray)?.count
                print("HISTORY-CHECK after 7 s: items \(items.map(String.init) ?? "nil"), any \(Self.bool(history, "hasAnyHistoryItems"))")
            }
            guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { return }
            let safari = URL(fileURLWithPath: home).appendingPathComponent("Library/Safari")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: safari.path)) ?? []
            print("HISTORY-CHECK the home's Library/Safari: \(files.isEmpty ? "empty" : files.sorted().joined(separator: ", "))")
            print("HISTORY-CHECK History.db in the home: \(files.contains("History.db"))")
        }
    }

    // MARK: Calls into Safari's classes

    /// `[[cls alloc] <initializer>]`, with one object argument when the initializer takes one.
    private static func make(_ cls: AnyClass, _ initializer: String, _ argument: AnyObject?) -> AnyObject? {
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Init0 = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias Init1 = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject?) -> UnsafeMutableRawPointer?
        let alloc = NSSelectorFromString("alloc"), selector = NSSelectorFromString(initializer)
        guard let allocMethod = class_getClassMethod(cls, alloc), let initMethod = class_getInstanceMethod(cls, selector),
              let raw = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(cls, alloc) else { return nil }
        let made = initializer.hasSuffix(":")
            ? unsafeBitCast(method_getImplementation(initMethod), to: Init1.self)(raw, selector, argument)
            : unsafeBitCast(method_getImplementation(initMethod), to: Init0.self)(raw, selector)
        return made.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
    }

    private static func object(_ receiver: AnyObject, _ name: String) -> AnyObject? {
        typealias Get = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(receiver), selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Get.self)(receiver, selector)?.takeUnretainedValue()
    }

    private static func bool(_ receiver: AnyObject, _ name: String) -> String {
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(receiver), selector) else { return "no \(name)" }
        return String(unsafeBitCast(method_getImplementation(method), to: Get.self)(receiver, selector))
    }

    private static func call(_ receiver: AnyObject, _ name: String) {
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(receiver), selector) else {
            print("HISTORY-CHECK no -\(name)")
            return
        }
        unsafeBitCast(method_getImplementation(method), to: Call.self)(receiver, selector)
    }
}
