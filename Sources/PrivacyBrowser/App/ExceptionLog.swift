import AppKit
import BrowserCore
import ObjCExceptions
import os
import OSLog

/// Every Objective-C exception of this process, in the log as it happens, readable.
///
/// Three places see an exception, and each writes it down: the runtime's exception preprocessor
/// at the throw itself (where the frames below the throw can still be read, before AppKit's run
/// loop or anything else catches it), `-[NSApplication reportException:]` when the run loop has
/// caught one, and the uncaught-exception handler when nothing did and the process is about to
/// die. Each line has the exception's name, its reason cut of whatever can be the user's
/// (`LogRedaction`) in clear, the full reason privately, and the frames.
///
/// THE PREPROCESSOR IS A CHAIN. CoreFoundation installs one of its own, and that one is what
/// writes the call stack into an `NSException` (`callStackReturnAddresses`). An earlier version
/// of this hook (in SafariChrome) replaced it instead of calling it: every exception then went on
/// without its call stack, and when AppKit's run loop caught one it aborted in
/// `-[NSException hashString]` (`_HIE_CaptureExceptionTelltaleOnce`) — a crash with an empty
/// "Application Specific Information", where AppKit otherwise logs the exception and goes on. A
/// profile's process then died unsealed (⌘, in Safari's chrome, the owner's Mac, 2026-10-30). This
/// one calls the previous preprocessor first; `--exception-check` shows both sides (`runCheck`).
enum ExceptionLog {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "Exception")

    /// Installs the three hooks. Idempotent; call as early as possible, in every process.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        // AppKit's own default, said in so many words for this process (the argument domain is
        // never written anywhere): an exception its run loop catches is reported, and the loop
        // goes on. Safari runs with it on; a profile's process must not.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSApplicationCrashOnExceptions"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        installPreprocessor(chained: true)
        previousUncaughtHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            ExceptionLog.write(exception, when: "uncaught: the process ends", frames: exception.callStackSymbols)
            previousUncaughtHandler?(exception)
        }
        watchReportException(of: NSApplication.self)
    }

    /// `-[NSApplication reportException:]` of `applicationClass` too, when it has an
    /// implementation of its own: Safari's `BrowserApplication`, once it is `NSApp`.
    ///
    /// AppKit's run loop hands this every exception it catches while it handles an event — a key,
    /// a click, a menu item's action, a timer — which makes it the one place where all of them,
    /// those of menu items nobody has tried yet included, are written down and survived. AppKit's
    /// own implementation logs and returns. A subclass's is not called: Safari's application object
    /// is built for Safari, which may well end the process there to get its crash report; here the
    /// exception is written down and AppKit's implementation runs instead, so the loop goes on.
    static func watchReportException(of applicationClass: AnyClass) {
        let selector = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(applicationClass, selector) else { return }
        let key = UInt(bitPattern: method_getImplementation(method))
        guard !watchedImplementations.contains(key) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Report.self)
        let isAppKits = applicationClass == NSApplication.self
        if isAppKits { appKitReport = original }
        let replacement: @convention(block) (AnyObject, NSException) -> Void = { application, exception in
            ExceptionLog.reported += 1
            ExceptionLog.write(exception, when: "caught by the run loop, which goes on", frames: exception.callStackSymbols)
            // What the user was doing, read now (the run loop calls this on the main thread, in the
            // event that threw); what to tell them, after this event is over.
            let event = MainActor.assumeIsolated { NSApplication.shared.currentEvent?.type }
            DispatchQueue.main.async { ExceptionLog.onCaughtInRunLoop?(exception, event) }
            if isAppKits {
                original(application, selector, exception)
            } else {
                ExceptionLog.appKitReport?(application, selector, exception)
            }
        }
        let installed = imp_implementationWithBlock(replacement)
        method_setImplementation(method, installed)
        watchedImplementations.insert(key)
        watchedImplementations.insert(UInt(bitPattern: installed))
    }

    /// Whether an exception passed through this process's preprocessor comes out with its call
    /// stack — CoreFoundation's own preprocessor still ran — which is what AppKit needs of an
    /// exception it catches. Asked by the self-test, here and in a profile's process.
    static func preprocessorKeepsCallStacks() -> Bool {
        guard let set = setPreprocessor else { return false }
        // Read the current preprocessor by putting it back at once.
        let current = set(passThrough)
        _ = set(current)
        guard let current else { return false }
        let probe = NSException(name: NSExceptionName("PBPreprocessorProbe"), reason: "a probe, not thrown", userInfo: nil)
        isProbing = true
        defer { isProbing = false }
        let processed = current(probe)
        return !((processed as? NSException) ?? probe).callStackReturnAddresses.isEmpty
    }

    // MARK: Writing one down

    fileprivate static func write(_ thrown: AnyObject, when: String, frames: [String]) {
        let exception = thrown as? NSException
        // The exception's name and the classes and methods in its reason are this build's and the
        // system's; what the reason quotes of the user is cut out (`LogRedaction`).
        let exceptionName = exception?.name.rawValue ?? String(describing: type(of: thrown))
        let reason = exception?.reason ?? String(describing: thrown)
        let redactedReason = LogRedaction.exceptionReason(reason)
        log.error("\(exceptionName, privacy: .public) (\(when, privacy: .public)): \(redactedReason, privacy: .public)")
        log.error("  in full: \(reason, privacy: .private)")
        // One line per frame: os_log truncates a long message, and the frames that matter are the
        // ones at the end of it.
        for frame in frames.prefix(48) { log.error("  \(frame, privacy: .public)") }
    }

    /// The frames of the thread that is throwing, as the preprocessor sees them.
    fileprivate static func liveFrames() -> [String] {
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
        let count = backtrace(&addresses, 48)
        guard let symbols = backtrace_symbols(&addresses, count) else { return [] }
        defer { free(symbols) }
        // The first two are this hook and the runtime's call of it.
        return (0..<Int(count)).dropFirst(2).compactMap { symbols[$0].map { String(cString: $0) } }
    }

    // MARK: The preprocessor

    fileprivate typealias Preprocessor = @convention(c) (AnyObject) -> AnyObject
    private typealias SetPreprocessor = @convention(c) (Preprocessor?) -> Preprocessor?

    private static let setPreprocessor: SetPreprocessor? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else { return nil }
        return unsafeBitCast(symbol, to: SetPreprocessor.self)
    }()

    /// `chained` false is the earlier hook's mistake, kept for `--exception-check`'s control only.
    fileprivate static func installPreprocessor(chained: Bool) {
        guard let set = setPreprocessor else {
            log.error("No objc_setExceptionPreprocessor: exceptions are logged when caught, not when thrown")
            return
        }
        let previous = set(chained ? loggingPreprocessor : replacingPreprocessor)
        if chained { previousPreprocessor = previous }
    }

    private typealias Report = @convention(c) (AnyObject, Selector, NSException) -> Void
    /// AppKit's own `-[NSApplication reportException:]`, as it was before it was watched.
    private static var appKitReport: Report?
    private static var isInstalled = false
    private static var watchedImplementations: Set<UInt> = []
    fileprivate static var isProbing = false
    /// Exceptions `reportException:` has been handed in this process.
    private(set) static var reported = 0
    /// Called after the event in which the run loop caught an exception, with that event's type: a
    /// profile's process tells the user (`SafariChrome.installUnavailableNotice`).
    static var onCaughtInRunLoop: ((NSException, NSEvent.EventType?) -> Void)?
    /// Every exception as it is thrown — its name, its reason cut as the log has it, and the frames
    /// of the throw — for the menu walk, which says which item threw (`SafariMenuWalk`).
    static var onThrown: ((String, String, [String]) -> Void)?

    // MARK: The check

    /// `PrivacyBrowser --exception-check [--replacing]`: an exception thrown from a timer of
    /// AppKit's run loop — as one thrown handling a key or a click is — in a process with this
    /// file's hooks as every process has them, or with `--replacing` as the earlier hook had them
    /// (the preprocessor before it replaced, not called). Prints `EXCEPTION-CHECK` lines: whether
    /// the process lived through it, how often `reportException:` saw it, and what the log says of
    /// it. Exit 0 when it lived; the earlier way is expected to die in `-[NSException hashString]`
    /// as the profile's process did, which is what the self-test compares.
    @MainActor
    static func runCheck(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let replacing = arguments.contains("--replacing")
        if replacing {
            isInstalled = true
            installPreprocessor(chained: false)
            watchReportException(of: NSApplication.self)
        } else {
            install()
        }
        // `--safari`: in a process like a profile's, whose NSApp is Safari's own application
        // object, with Safari's frameworks loaded and prepared — in a home of its own, held to a
        // closed proxy, as `--check-safari-chrome` runs.
        if arguments.contains("--safari") {
            guard SafariChrome.prepareForCheck(arguments: arguments) else {
                print("EXCEPTION-CHECK Safari's chrome cannot be hosted in this build")
                exit(2)
            }
            print("EXCEPTION-CHECK NSApp is \(String(describing: type(of: NSApplication.shared)))")
            // What the profile's window would tell the user, printed rather than shown.
            SafariChrome.presentNotice = { title, text in print("EXCEPTION-CHECK the user is told: \(title) — \(text)") }
        }
        print("EXCEPTION-CHECK preprocessor: \(replacing ? "replacing the one before it" : "chained"); "
              + "an exception passed through it keeps its call stack: \(preprocessorKeepsCallStacks())")
        // `--in-task`: thrown by Objective-C code called from a Swift task, as Safari's code is when
        // a profile's window opens, and caught where it is called (PBCatchException).
        if arguments.contains("--in-task") {
            Task { @MainActor in
                let caught = PBCatchException { Thrower().throwOne() }
                print("EXCEPTION-CHECK caught in a Swift task: \(caught?.name.rawValue ?? "nothing")")
                try? await Task.sleep(nanoseconds: 300_000_000)
                print("EXCEPTION-CHECK the task went on")
                exit(0)
            }
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let thrower = Thrower()
        // In Safari's case from a menu item's action, as Bookmarks and ⌘, were.
        thrower.perform(arguments.contains("--safari") ? #selector(Thrower.throwFromMenuItem) : #selector(Thrower.throwOne),
                        with: nil, afterDelay: 0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("EXCEPTION-CHECK lived through it; reportException: saw \(ExceptionLog.reported)")
            for line in ExceptionLog.loggedLines(containing: Thrower.name.rawValue) {
                print("EXCEPTION-CHECK logged: \(line)")
            }
            MainActor.assumeIsolated { SafariChrome.removeCheckHome() }
            exit(0)
        }
        application.run()
    }

    /// This process's own log lines of this file that mention `text`.
    private static func loggedLines(containing text: String) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                                        "PrivacyBrowser", "Exception")) else { return [] }
        return entries.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }.filter { $0.contains(text) }
    }
}

/// Throws one exception whose reason quotes what a page could: an address and a name in quotes.
private final class Thrower: NSObject {
    static let name = NSExceptionName("PBExceptionCheck")

    @objc func throwOne() {
        NSException(name: Self.name, reason: "a check of this build at https://bank.example.test/login for \"Alice\"",
                    userInfo: nil).raise()
    }

    /// The same, from the action of a menu item, chosen as a key equivalent or a click would.
    @objc func throwFromMenuItem() {
        let menu = NSMenu()
        let item = NSMenuItem(title: Self.itemTitle, action: #selector(throwOne), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.performActionForItem(at: 0)
    }

    static let itemTitle = "PB check item" // l10n: not text

}

// Global, not captured: a C function pointer cannot carry context.
private var previousPreprocessor: ExceptionLog.Preprocessor?
private var previousUncaughtHandler: (@convention(c) (NSException) -> Void)?

/// CoreFoundation's preprocessor first — it writes the call stack into the exception — then the
/// log, with the frames of the throw.
private let loggingPreprocessor: ExceptionLog.Preprocessor = { thrown in
    let exception = previousPreprocessor?(thrown) ?? thrown
    if !ExceptionLog.isProbing {
        let frames = ExceptionLog.liveFrames()
        ExceptionLog.write(exception, when: "thrown", frames: frames)
        if let onThrown = ExceptionLog.onThrown {
            let thrownException = exception as? NSException
            onThrown(thrownException?.name.rawValue ?? String(describing: type(of: exception)),
                     LogRedaction.exceptionReason(thrownException?.reason ?? ""), frames)
        }
    }
    return exception
}

/// The earlier hook's way: logs and returns without calling the preprocessor before it.
private let replacingPreprocessor: ExceptionLog.Preprocessor = { thrown in
    ExceptionLog.write(thrown, when: "thrown (the preprocessor before this one was replaced)", frames: ExceptionLog.liveFrames())
    return thrown
}

/// Hands an exception back untouched: only used to read which preprocessor is installed.
private let passThrough: ExceptionLog.Preprocessor = { $0 }
