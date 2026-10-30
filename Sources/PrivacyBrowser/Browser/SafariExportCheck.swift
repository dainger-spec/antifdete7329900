import AppKit
import BrowserCore

/// `PrivacyBrowser --export-check`: what Safari's File › Export › Bookmarks… does in a profile's
/// process. On the owner's Mac its save panel opened, Save was pressed, and no file appeared, with
/// no word of an error.
///
/// A profile's process has a home of its own (`CFFIXED_USER_HOME` and `HOME`), so the folder a save
/// panel starts in — Documents, Desktop — can be the profile's home's and not the account's; or
/// Safari's exporter may write nothing at all. This runs Safari's own menu action in a process like
/// a profile's (a home of its own, held to a closed proxy, Safari's chrome, menu and window up) and
/// answers every save panel Safari asks for as a person would, without showing it: Save where the
/// panel opened, then, the second time, Save in a folder outside the home. It prints where each
/// panel opened, what Safari's exporter was given, any alert Safari raised, and which files were
/// written where. A measurement: the fix is decided from it.
@MainActor
enum SafariExportCheck {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard SafariChrome.prepareForCheck(arguments: arguments),
              let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            print("EXPORT-CHECK Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        // The folder a person would pick outside the profile's home: beside it, not in it.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyBrowser-export-check-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let answers = ExportAnswers(home: home, outside: outside.path, account: SafariPaths.realHome)
        ExportAnswers.shared = answers
        let probe = NSSavePanel()
        print("EXPORT-CHECK a save panel made in this process opens in: \(answers.place(probe.directoryURL))")
        print("EXPORT-CHECK this process's Documents: \(answers.place(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)); "
              + "Desktop: \(answers.place(FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first))")
        let panelClasses: [AnyClass?] = [NSSavePanel.self, object_getClass(probe)]
        answers.answerSavePanels(of: panelClasses.compactMap { $0 })
        answers.answerAlerts()
        answers.watchExporter()
        ExceptionLog.onCaughtInRunLoop = { exception, _ in
            print("EXPORT-CHECK threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
        }
        // A step that waits for ever must not keep CI waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("EXPORT-CHECK did not finish")
            exit(3)
        }
        SafariChrome.installMainMenu()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let controller = SafariChrome.openWindow(address: nil)
                controller?.showWindow(nil)
                controller?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                print("EXPORT-CHECK Safari's window \(controller == nil ? "did not open" : "is open")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { exportBookmarks(answers, saving: .whereItOpened) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            MainActor.assumeIsolated {
                answers.reportFiles()
                exportBookmarks(answers, saving: .outsideTheHome)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            MainActor.assumeIsolated {
                answers.reportFiles()
                print("EXPORT-CHECK exceptions: \(ExceptionLog.reported)")
                try? FileManager.default.removeItem(at: outside)
                SafariChrome.removeCheckHome()
                exit(0)
            }
        }
        application.run()
        exit(0)
    }

    /// File › Export › Bookmarks…, sent as the menu sends it.
    private static func exportBookmarks(_ answers: ExportAnswers, saving: ExportAnswers.Choice) {
        answers.begin(saving)
        let action = NSSelectorFromString("exportBookmarks:")
        guard let item = NSApp.mainMenu.flatMap({ find(action, in: $0) }) else {
            print("EXPORT-CHECK no item with exportBookmarks: in Safari's menu")
            return
        }
        let target = item.target.map { String(describing: type(of: $0)) } ?? "the first responder"
        print("EXPORT-CHECK [\(saving.rawValue)] File › Export › \(item.title), sent to \(target)")
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func find(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = find(action, in: submenu) { return found }
        }
        return nil
    }
}

/// The check's answers to Safari's save panels and alerts, and what it saw. Used on the main thread
/// only: AppKit asks for panels and alerts there.
private final class ExportAnswers: @unchecked Sendable {
    enum Choice: String {
        case whereItOpened = "Save where the panel opened"
        case outsideTheHome = "Save in a folder outside the profile's home"
    }

    nonisolated(unsafe) static var shared: ExportAnswers?

    let home: String
    let outside: String
    let account: String?
    private var choice = Choice.whereItOpened
    /// When this export began, and what its save panel was answered with.
    private var started = Date()
    private var saved: URL?

    init(home: String, outside: String, account: String?) {
        self.home = home
        self.outside = outside
        self.account = account
    }

    /// A new export, whose save panel `choice` answers.
    func begin(_ choice: Choice) {
        self.choice = choice
        started = Date()
        saved = nil
    }

    // MARK: Save panels

    /// Every way AppKit shows a save panel, answered at once: Save, where `choice` says.
    func answerSavePanels(of classes: [AnyClass]) {
        let runModal: @convention(block) (NSSavePanel) -> Int = { panel in
            ExportAnswers.shared?.answer(panel, shownBy: "runModal") ?? 0
        }
        let sheet: @convention(block) (NSSavePanel, NSWindow?, (@convention(block) (Int) -> Void)?) -> Void = { panel, _, handler in
            let response = ExportAnswers.shared?.answer(panel, shownBy: "a sheet") ?? 0
            DispatchQueue.main.async { handler?(response) }
        }
        let begin: @convention(block) (NSSavePanel, (@convention(block) (Int) -> Void)?) -> Void = { panel, handler in
            let response = ExportAnswers.shared?.answer(panel, shownBy: "beginWithCompletionHandler") ?? 0
            DispatchQueue.main.async { handler?(response) }
        }
        // What a person's Save gives Safari: the folder and the name in the panel, as a URL or,
        // to code from before URLs, as a path.
        let chosen: (NSSavePanel) -> URL? = { panel in
            guard let folder = panel.directoryURL, !panel.nameFieldStringValue.isEmpty else { return nil }
            return folder.appendingPathComponent(panel.nameFieldStringValue)
        }
        let url: @convention(block) (NSSavePanel) -> NSURL? = { panel in chosen(panel) as NSURL? }
        let filename: @convention(block) (NSSavePanel) -> NSString? = { panel in chosen(panel)?.path as NSString? }
        for panelClass in classes {
            for (name, block) in [("runModal", runModal as Any), ("beginSheetModalForWindow:completionHandler:", sheet as Any),
                                  ("beginWithCompletionHandler:", begin as Any), ("URL", url as Any), ("filename", filename as Any)] {
                if let method = class_getInstanceMethod(panelClass, NSSelectorFromString(name)) {
                    method_setImplementation(method, imp_implementationWithBlock(block))
                }
            }
        }
    }

    private func answer(_ panel: NSSavePanel, shownBy how: String) -> Int {
        let opened = panel.directoryURL
        let exists = opened.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        print("EXPORT-CHECK a save panel (\(how)) opened in: \(place(opened)) (exists: \(exists)); its name: \(panel.nameFieldStringValue)")
        switch choice {
        case .whereItOpened:
            guard opened != nil else {
                print("EXPORT-CHECK the panel names no folder before it is shown: answered Cancel")
                return NSApplication.ModalResponse.cancel.rawValue
            }
        case .outsideTheHome:
            panel.directoryURL = URL(fileURLWithPath: outside, isDirectory: true)
        }
        saved = panel.url
        print("EXPORT-CHECK answered Save: \(place(saved))")
        return NSApplication.ModalResponse.OK.rawValue
    }

    // MARK: Alerts

    /// An alert Safari raises (an export that failed would say so in one), printed and answered
    /// with its first button, so that none waits for a click.
    func answerAlerts() {
        let runModal: @convention(block) (NSAlert) -> Int = { alert in
            print("EXPORT-CHECK Safari's alert: \(alert.messageText) | \(alert.informativeText)")
            return NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        }
        let sheet: @convention(block) (NSAlert, NSWindow?, (@convention(block) (Int) -> Void)?) -> Void = { alert, _, handler in
            print("EXPORT-CHECK Safari's alert (a sheet): \(alert.messageText) | \(alert.informativeText)")
            DispatchQueue.main.async { handler?(NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        }
        for (name, block) in [("runModal", runModal as Any), ("beginSheetModalForWindow:completionHandler:", sheet as Any)] {
            if let method = class_getInstanceMethod(NSAlert.self, NSSelectorFromString(name)) {
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
        }
    }

    // MARK: Safari's exporter

    /// `-[WebBookmarkExporter initWithRootBookmark:path:hideExtension:]`, printed as it is called:
    /// whether it was given bookmarks and where it was told to write.
    func watchExporter() {
        typealias Initializer = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeRawPointer?, UnsafeRawPointer?, Bool) -> UnsafeMutableRawPointer?
        let selector = NSSelectorFromString("initWithRootBookmark:path:hideExtension:")
        guard let exporterClass = NSClassFromString("WebBookmarkExporter"),
              let method = class_getInstanceMethod(exporterClass, selector) else {
            print("EXPORT-CHECK not in this Safari: -[WebBookmarkExporter initWithRootBookmark:path:hideExtension:]")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: @convention(block) (UnsafeMutableRawPointer, UnsafeRawPointer?, UnsafeRawPointer?, Bool) -> UnsafeMutableRawPointer? = { exporter, root, path, hide in
            let given = path.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
            let location = (given as? String) ?? (given as? URL)?.path
            print("EXPORT-CHECK Safari's exporter was given \(root == nil ? "no bookmarks" : "bookmarks") to write to "
                  + "\(ExportAnswers.shared?.place(location.map { URL(fileURLWithPath: $0) }) ?? "?")")
            let made = original(exporter, selector, root, path, hide)
            // Whether the exporter writes as it is made: then a failure can be told at once.
            let there = location.map { FileManager.default.fileExists(atPath: $0) } ?? false
            print("EXPORT-CHECK Safari's exporter \(made == nil ? "was not made" : "was made"); the file there as it returns: \(there)")
            return made
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    // MARK: What was written

    /// The file this export's Save named, and every HTML file written since it began in the
    /// profile's home or the folder outside it.
    func reportFiles() {
        if let saved {
            let size = (try? FileManager.default.attributesOfItem(atPath: saved.path))?[.size] as? Int
            print("EXPORT-CHECK the file Save named: \(size.map { "written, \($0) bytes" } ?? "not there") — \(place(saved))")
        }
        var written: [String] = []
        for root in [home, outside] {
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys) else { continue }
            for case let file as URL in files where ["html", "htm"].contains(file.pathExtension.lowercased()) {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= started else { continue }
                written.append("\(place(file)) (\(values.fileSize ?? 0) bytes)")
            }
        }
        print("EXPORT-CHECK HTML files written since the start: \(written.isEmpty ? "none" : written.sorted().joined(separator: "; "))")
    }

    /// Where `url` is: in the profile's home, in the folder outside it, in the account's home, or
    /// elsewhere — the place, not the user's (every path here is CI's).
    func place(_ url: URL?) -> String {
        guard let url else { return "nil" }
        let path = Self.withoutPrivate(url.standardizedFileURL.path)
        let roots: [(String?, String)] = [(outside, "the folder outside the home"), (home, "the profile's home"), (account, "the account's home")]
        for (root, name) in roots {
            guard let root else { continue }
            let base = Self.withoutPrivate(URL(fileURLWithPath: root).standardizedFileURL.path)
            if path == base { return name }
            if path.hasPrefix(base + "/") { return name + ": " + path.dropFirst(base.count + 1) }
        }
        return "elsewhere: " + path
    }

    /// `/private/var/…` as `/var/…`: the same folder, by either path.
    private static func withoutPrivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
