import Foundation
import JavaScriptCore
import os
import WebKit

/// Runs a scenario (docs/AUTOMATION.md): its JavaScript in a JavaScriptCore of its own, on a thread
/// of its own — a script that loops without end never holds up the app, and Stop ends the run at
/// once — and each of its commands (`await page.click('#login')`) through `PageDriver` on the main
/// thread, one at a time. Nothing of the script runs in the page.
///
/// What the script has: `page` (the core commands, each a promise), `log(...)`, `sleep(ms)` and
/// `params` (the run's parameters). A command that fails rejects its promise with the reason, which
/// the script may catch; one left uncaught ends the run with it.
@MainActor
final class ScenarioRunner {
    enum StopReason: String, Equatable {
        case byUser
        /// The plan no longer has automation: the step under way finishes, then the run stops.
        case rightsEnded
        case profileStopped
    }

    enum Outcome: Equatable {
        case finished
        case failed(String)
        case stopped(StopReason)
    }

    struct Line: Equatable {
        enum Kind: String { case command, script, error, outcome }
        var at: Date
        var kind: Kind
        var text: String
    }

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "Scenario")

    let driver: PageDriver
    private(set) var lines: [Line] = []
    private(set) var outcome: Outcome?
    var isRunning: Bool { thread != nil && outcome == nil }
    /// Told of each line of the run's log, and of its end.
    var onLine: ((Line) -> Void)?
    var onEnd: ((Outcome) -> Void)?
    /// Asked before each command: false stops the run there (the plan lost automation).
    var allowed: () -> Bool = { true }

    private var thread: ScriptThread?
    private var stopRequest: StopReason?
    private var commandsInFlight = 0

    init(driver: PageDriver) {
        self.driver = driver
        driver.onLog = { [weak self] text in self?.add(.command, text) }
    }

    /// Starts `source` with `parameters` (JSON values). A run at a time.
    func start(_ source: String, parameters: [String: Any] = [:]) {
        guard thread == nil else { return }
        guard allowed() else {
            add(.outcome, "Not started: automation is not in this plan")
            end(.stopped(.rightsEnded))
            return
        }
        let thread = ScriptThread()
        self.thread = thread
        thread.start()
        thread.waitUntilReady()
        let parametersJSON = (try? JSONSerialization.data(withJSONObject: parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        thread.perform { [weak self] in
            Self.run(source, parametersJSON: parametersJSON, on: thread, runner: self)
        }
    }

    /// Stops the run: a command under way finishes (a button pressed is let go), then the run
    /// ends; a script between commands ends at once.
    func stop(_ reason: StopReason = .byUser) {
        guard outcome == nil, thread != nil else { return }
        stopRequest = reason
        if commandsInFlight == 0 { end(.stopped(reason)) }
    }

    private func add(_ kind: Line.Kind, _ text: String) {
        let line = Line(at: Date(), kind: kind, text: text)
        lines.append(line)
        onLine?(line)
    }

    private func end(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        switch outcome {
        case .finished: add(.outcome, "Finished")
        case .failed(let message): add(.outcome, "Failed: \(message)")
        case .stopped(.byUser): add(.outcome, "Stopped")
        case .stopped(.rightsEnded): add(.outcome, "Stopped after its current step: automation is no longer in this plan")
        case .stopped(.profileStopped): add(.outcome, "Stopped: the profile stopped")
        }
        driver.finish()
        thread?.cancel()
        thread?.perform {}
        onEnd?(outcome)
    }

    // MARK: Commands

    private struct Stopped: Error {}

    /// One command of the script, on the main thread; its result as JSON-able values.
    fileprivate func perform(_ name: String, _ arguments: [Any]) async -> Result<Any?, Error> {
        if stopRequest != nil || outcome != nil { return .failure(Stopped()) }
        guard allowed() else {
            stopRequest = .rightsEnded
            if commandsInFlight == 0 { end(.stopped(.rightsEnded)) }
            return .failure(Stopped())
        }
        commandsInFlight += 1
        defer {
            commandsInFlight -= 1
            if let stopRequest, commandsInFlight == 0 { end(.stopped(stopRequest)) }
        }
        do {
            return .success(try await command(name, arguments))
        } catch {
            return .failure(error)
        }
    }

    private func command(_ name: String, _ arguments: [Any]) async throws -> Any? {
        func string(_ index: Int) throws -> String {
            guard index < arguments.count, let value = arguments[index] as? String else {
                throw PageDriver.Failure.script("\(name): argument \(index + 1) must be text")
            }
            return value
        }
        func options(_ index: Int) -> [String: Any] { index < arguments.count ? arguments[index] as? [String: Any] ?? [:] : [:] }
        func timeout(_ index: Int) -> TimeInterval? { (options(index)["timeout"] as? NSNumber).map { $0.doubleValue / 1000 } }
        switch name {
        case "goto":
            guard let url = URL(string: try string(0)), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw PageDriver.Failure.navigation("goto takes an http or https address")
            }
            let state = PageDriver.LoadState(rawValue: options(1)["waitUntil"] as? String ?? "load") ?? .load
            try await driver.goto(url, waitUntil: state, timeout: timeout(1))
            return nil
        case "back": try await driver.back(timeout: timeout(0)); return nil
        case "forward": try await driver.forward(timeout: timeout(0)); return nil
        case "reload": try await driver.reload(timeout: timeout(0)); return nil
        case "waitForLoadState":
            let state = PageDriver.LoadState(rawValue: arguments.first as? String ?? "load") ?? .load
            try await driver.waitForLoadState(state, timeout: timeout(1))
            return nil
        case "waitFor":
            let state = PageDriver.ElementState(rawValue: options(1)["state"] as? String ?? "visible") ?? .visible
            try await driver.waitFor(try string(0), state: state, timeout: timeout(1))
            return nil
        case "click":
            let count = (options(1)["clickCount"] as? NSNumber)?.intValue ?? 1
            try await driver.click(try string(0), clickCount: count, timeout: timeout(1))
            return nil
        case "dblclick": try await driver.click(try string(0), clickCount: 2, timeout: timeout(1)); return nil
        case "hover": try await driver.hover(try string(0), timeout: timeout(1)); return nil
        case "type":
            let delay = (options(2)["delay"] as? NSNumber).map { $0.doubleValue / 1000 }
            try await driver.type(try string(0), try string(1), delay: delay.map { max(0, $0 * 0.6)...max(0.01, $0 * 1.4) } ?? 0.06...0.18)
            return nil
        case "press": try await driver.press(try string(0)); return nil
        case "scroll":
            guard let delta = (arguments.first as? NSNumber)?.doubleValue else { throw PageDriver.Failure.script("scroll takes a number of points") }
            try await driver.scroll(by: delta)
            return nil
        case "textContent": return try await driver.textContent(try string(0))
        case "innerText": return try await driver.innerText(try string(0))
        case "inputValue": return try await driver.inputValue(try string(0))
        case "getAttribute": return try await driver.getAttribute(try string(0), try string(1))
        case "count": return try await driver.count(try string(0))
        case "isVisible": return try await driver.isVisible(try string(0))
        case "url": return driver.url?.absoluteString
        case "title": return driver.title
        case "evaluate":
            let world: PageDriver.World = (arguments.count > 2 ? arguments[2] as? String : nil) == "page" ? .page : .isolated
            let argument = arguments.count > 1 ? arguments[1] : NSNull()
            return try await driver.evaluate(try string(0), ["__arg": argument], world: world)
        case "screenshot":
            let selector = arguments.first as? String
            return try await driver.screenshot(selector).base64EncodedString()
        case "pause":
            let milliseconds = (arguments.first as? NSNumber)?.doubleValue ?? 0
            try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds) * 1_000_000))
            return nil
        default:
            throw PageDriver.Failure.script("no command \(name)")
        }
    }

    // MARK: The script's side (its own thread)

    /// The commands the script's `page` has, by their names.
    private static let pageCommands = ["goto", "back", "forward", "reload", "waitForLoadState", "waitFor", "click", "dblclick", "hover",
                                       "type", "press", "scroll", "textContent", "innerText", "inputValue", "getAttribute", "count",
                                       "isVisible", "url", "title", "screenshot", "pause"]

    /// Builds the script's world and runs `source` in it, on `thread`.
    nonisolated private static func run(_ source: String, parametersJSON: String, on thread: ScriptThread, runner owner: ScenarioRunner?) {
        weak var runner = owner
        let context = JSContext()!
        // Held by its thread, for as long as the run's thread lives; the script's functions hold it
        // only weakly, so that it goes with the thread.
        thread.context = context
        context.name = "Scenario"
        let ended: @convention(block) (Bool, String) -> Void = { ok, message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let runner else { return }
                    if ok {
                        runner.end(.finished)
                    } else if let reason = runner.stopRequest {
                        runner.end(.stopped(reason))
                    } else {
                        runner.add(.error, message)
                        runner.end(.failed(message.components(separatedBy: "\n").first ?? message))
                    }
                }
            }
        }
        let logged: @convention(block) (String) -> Void = { text in
            DispatchQueue.main.async { MainActor.assumeIsolated { runner?.add(.script, text) } }
        }
        let command: @convention(block) (String, JSValue) -> JSValue = { [weak context] name, arguments in
            let values = arguments.toArray() ?? []
            guard let context else { return JSValue(undefinedIn: JSContext.current()) }
            return JSValue(newPromiseIn: context) { resolve, reject in
                let resolve = resolve, reject = reject
                DispatchQueue.main.async {
                    Task { @MainActor in
                        guard let runner else { return }
                        let result = await runner.perform(name, values)
                        thread.perform {
                            switch result {
                            case .success(let value):
                                resolve?.call(withArguments: [value ?? NSNull()])
                            case .failure(let error):
                                let message = error is Stopped ? "stopped" : String(describing: error)
                                guard let context = reject?.context else { return }
                                reject?.call(withArguments: [JSValue(newErrorFromMessage: message, in: context) as Any])
                            }
                        }
                    }
                }
            }
        }
        context.setObject(ended, forKeyedSubscript: "__ended" as NSString)
        context.setObject(logged, forKeyedSubscript: "__log" as NSString)
        context.setObject(command, forKeyedSubscript: "__command" as NSString)
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "error"
            ended(false, message)
        }
        let names = pageCommands.map { "'\($0)'" }.joined(separator: ", ")
        let prelude = """
            const params = Object.freeze(\(parametersJSON));
            const log = (...parts) => __log(parts.map((p) => typeof p === 'string' ? p : JSON.stringify(p)).join(' '));
            const page = {};
            for (const name of [\(names)]) page[name] = (...args) => __command(name, args);
            page.waitForSelector = page.waitFor;
            page.evaluate = (body, arg, options) => __command('evaluate', [
              typeof body === 'function' ? 'return await (' + body.toString() + ')(__arg);' : String(body),
              arg === undefined ? null : arg, (options && options.world) || 'isolated']);
            const sleep = (ms) => __command('pause', [ms]);
            """
        context.evaluateScript(prelude)
        // The script's first line is line 1 of what runs: its line numbers stay its own.
        let script = "(async () => {" + source + "\n})().then(() => __ended(true, ''), (e) => __ended(false, String(e && e.stack ? e + '\\n' + e.stack : e)));"
        context.evaluateScript(script, withSourceURL: URL(string: "scenario.js"))
    }
}

/// A thread with a run loop, for one scenario's JavaScript: work is handed to it in order.
private final class ScriptThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    /// The run's JavaScript; let go when the thread ends.
    var context: JSContext?

    override func main() {
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        lock.unlock()
        // A source keeps the run loop waiting for work.
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        context = nil
    }

    func waitUntilReady() { ready.wait() }

    func perform(_ block: @escaping () -> Void) {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}
