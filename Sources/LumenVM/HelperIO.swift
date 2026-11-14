import AppKit
import BrowserCore
import Foundation

/// The helper's side of its conversation with the app: events out, commands in.
enum HelperIO {
    private static let lock = NSLock()

    /// One event, one line. From any thread.
    static func emit(_ event: VMHelperEvent) {
        lock.lock()
        defer { lock.unlock() }
        // The app may be gone (it crashed, or was ended): its end of the pipe is then closed.
        // That is no reason for this process to end — it is shutting the machine down, as it
        // does when the app is gone — so the write is one that fails quietly (SIGPIPE is ignored
        // in main.swift, and this call throws where the older one raised an exception).
        try? FileHandle.standardOutput.write(contentsOf: Data((event.line() + "\n").utf8))
    }

    /// A line for whoever reads the helper's standard error (the app passes it on to its own and
    /// to the system's log): what the machine's network did, in kinds and counts — never a name
    /// or an address.
    static func log(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardError.write(contentsOf: Data(("LumenVM: " + line + "\n").utf8))
    }

    /// Says why and ends.
    static func fail(_ message: String) -> Never {
        emit(VMHelperEvent(kind: .failed, message: message))
        exit(1)
    }

    static func fail(_ error: Error) -> Never {
        fail((error as NSError).localizedDescription)
    }

    /// The app's lines after the request — `stop`, `kill` — and the end of its input (the app is
    /// gone), each given to `handler` on the main queue. The end of input reads as `stop`: a
    /// machine does not outlive the app that started it.
    static func readCommands(_ handler: @escaping (String) -> Void) {
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                let command = line.trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else { continue }
                DispatchQueue.main.async { handler(command) }
            }
            DispatchQueue.main.async { handler("stop") }
        }
        thread.name = "LumenVM commands"
        thread.start()
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let request: VMHelperRequest
    #if arch(arm64)
    private var installer: MachineInstaller?
    private var runner: MachineRunner?
    #endif
    private var signals: [DispatchSourceSignal] = []
    /// This Mac said it is about to power off (before its quit events reach the apps).
    private var poweringOff = false
    private var powerOffObserver: NSObjectProtocol?

    init(request: VMHelperRequest) {
        self.request = request
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            self?.poweringOff = true
        }
        #if arch(arm64)
        switch request.mode {
        case .catalog:
            // The app gone, or calling it off: nothing to finish.
            HelperIO.readCommands { _ in exit(1) }
            MachineCatalog.run()
        case .inspect:
            HelperIO.readCommands { _ in exit(1) }
            MachineCatalog.inspect(request.restoreImagePath)
        case .install:
            // An installation the app is not there to take is not one: it ends with the app, and
            // the next one starts over.
            HelperIO.readCommands { _ in exit(1) }
            let installer = MachineInstaller(request: request)
            self.installer = installer
            installer.run()
        case .run:
            let runner = MachineRunner(request: request)
            self.runner = runner
            // Quit, or the app ending this process: the machine is shut down, not cut off.
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak runner] in runner?.stop(asking: false) }
                source.resume()
                signals.append(source)
            }
            runner.run()
        }
        #else
        HelperIO.fail("macOS runs in a virtual machine only on a Mac with Apple silicon.")
        #endif
    }

    /// The quit Apple Event of a logout, restart or shutdown carries a quit reason; one from the
    /// Dock has none (as the app tells them apart, `QuitCoordinator`).
    private static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        // 'aevt', 'quit', 'why?' — kCoreEventClass, kAEQuitApplication, kAEQuitReason.
        guard let event, event.eventClass == 0x6165_7674, event.eventID == 0x7175_6974 else { return false }
        return event.attributeDescriptor(forKeyword: 0x7768_793F) != nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if arch(arm64)
        guard let runner, runner.isRunning else { return .terminateNow }
        if poweringOff || Self.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent) {
            // This Mac is logging out, restarting or shutting down: a question here, and "not
            // now" for an answer, would cancel that for the person — who would have to ask again
            // with Lumen already gone. The machine is shut down without a question; this process
            // ends when it has (the runner ends it), which is the answer the system waits for.
            runner.stop(asking: false)
            return .terminateLater
        }
        runner.stop(asking: true)
        return .terminateCancel
        #else
        return .terminateNow
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
