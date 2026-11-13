import BrowserCore
import Foundation
import os

/// One run of the machines' helper (`LumenVM`, `VMHelperRequest`): started with its request on its
/// standard input, its events read from its standard output in the order it said them, and its
/// end told last. The helper is the only code of the app that holds Apple's virtualization right;
/// the app itself never loads the framework.
@MainActor
final class VMHelperProcess {
    /// Its name in `Contents/MacOS`, beside the app's own executable (`VM=1 scripts/build-app.sh`).
    static let name = "LumenVM"

    /// Where the helper is in this build; nil when the build carries none.
    static var executableURL: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let url = bundle.appendingPathComponent("Contents/MacOS/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    enum Failure: LocalizedError {
        case noHelper

        var errorDescription: String? { L("vm.error.noHelper") }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let onEvent: (VMHelperEvent) -> Void
    /// The helper has ended; `failure` is what it said went wrong (a `failed` event), or that it
    /// ended without saying how.
    private let onEnd: (_ failure: String?) -> Void
    private var failure: String?
    /// The helper said how its work ended: `stopped`, `installed`, `catalog` — or `failed`.
    private var concluded = false
    private(set) var hasEnded = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "VirtualMachines")

    init(onEvent: @escaping (VMHelperEvent) -> Void, onEnd: @escaping (_ failure: String?) -> Void) {
        self.onEvent = onEvent
        self.onEnd = onEnd
    }

    func start(_ request: VMHelperRequest) throws {
        guard let url = Self.executableURL else { throw Failure.noHelper }
        process.executableURL = url
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A helper that has ended is written to at most once more: an error, not a signal that
        // ends the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((try request.line() + "\n").utf8))

        // What the helper says beside its events — what a machine's network did, in kinds and
        // counts (never a name or an address) — goes where this app's own words go: its standard
        // error (the terminal it was started from, if any) and the system's log.
        let said = errors.fileHandleForReading
        let log = self.log
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = said.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                    // The system's log keeps the helper's own lines only (`HelperIO.log`), not
                    // what a framework may have printed beside them.
                    guard line.hasPrefix("LumenVM: ") else { continue }
                    let helperLine = String(line.prefix(400))
                    log.notice("\(helperLine, privacy: .public)")
                }
                if buffer.count > 1 << 20 { buffer.removeAll() }
            }
        }

        // One thread reads to the end and hands everything to the main queue in order: the events,
        // then the end.
        let reader = output.fileHandleForReading
        let process = self.process
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let event = VMHelperEvent.parse(line) else { continue }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(event) } }
                }
                // A line that never ends is not an event.
                if buffer.count > 1 << 20 { buffer.removeAll() }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(status: status) } }
        }
    }

    private func take(_ event: VMHelperEvent) {
        switch event.kind {
        case .failed:
            failure = event.message ?? L("vm.error.unknown")
            concluded = true
        case .stopped, .installed, .catalog:
            concluded = true
        case .progress, .started, .traffic:
            break
        }
        onEvent(event)
    }

    private func ended(status: Int32) {
        guard !hasEnded else { return }
        hasEnded = true
        if !concluded, failure == nil {
            // Ended without a word (killed, or it crashed): never taken for a clean end.
            failure = String(format: L("vm.error.helperEnded"), Int(status))
            log.error("The machines' helper ended without saying how: status \(Int(status), privacy: .public)")
        }
        onEnd(failure)
    }

    /// Asks the guest's macOS to shut down, as its own menu would (the helper then ends).
    func stop() { send("stop") }

    /// Ends the machine now, as pulling a Mac's plug would.
    func kill() {
        send("kill")
        let process = self.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if process.isRunning { process.terminate() }
        }
    }

    /// Ends the helper at once: for an installation or a question to Apple the person called off.
    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func send(_ command: String) {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }
}
