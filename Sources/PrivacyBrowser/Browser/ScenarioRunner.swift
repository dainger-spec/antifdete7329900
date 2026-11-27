import BrowserCore
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
/// the script may catch; one left uncaught ends the run with it. An error names the scenario's
/// line it came from ("… (line 12)"); what the script returns is the run's result (`Line.Kind.result`).
@MainActor
final class ScenarioRunner {
    enum StopReason: String, Equatable, Codable {
        case byUser
        /// The plan no longer has automation: the step under way finishes, then the run stops.
        case rightsEnded
        case profileStopped
    }

    enum Outcome: Equatable, Codable {
        case finished
        case failed(String)
        case stopped(StopReason)
    }

    struct Line: Equatable, Codable {
        enum Kind: String, Codable {
            case command, script, error, outcome
            /// What the script returned, as JSON text: the run's result (the API gives it as `result`).
            case result
        }
        var at: Date
        var kind: Kind
        var text: String
    }

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "Scenario")
    /// The longest result a run keeps, in UTF-8 bytes of its JSON: it crosses to the app with the
    /// log, and is given whole by the API.
    static let maximumResultBytes = 512 * 1024

    let driver: PageDriver
    private(set) var lines: [Line] = []
    private(set) var outcome: Outcome?
    var isRunning: Bool { thread != nil && outcome == nil }
    /// The script's thread has not ended yet. It ends with the run, unless the script loops without
    /// calling anything of the run's (`stop`); the self-test reads it.
    var scriptThreadIsAlive: Bool { thread.map { !$0.isFinished } ?? false }
    /// Told of each line of the run's log, and of its end.
    var onLine: ((Line) -> Void)?
    var onEnd: ((Outcome) -> Void)?
    /// Asked before each command: false stops the run there (the plan lost automation).
    var allowed: () -> Bool = { true }

    private var thread: ScriptThread?
    private var stopRequest: StopReason?
    private var commandsInFlight = 0
    /// Between the script's thread and this one: closed by Stop and by the run's end, after which
    /// every command and `log` the script calls throws at once; and the commands asked for and not
    /// answered yet, held to `ScriptGate.commandLimit`.
    private let gate = ScriptGate()

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
        let gate = self.gate
        thread.perform { [weak self] in
            Self.run(source, parametersJSON: parametersJSON, on: thread, gate: gate, runner: self)
        }
    }

    /// Stops the run: a command under way finishes (a button pressed is let go), then the run
    /// ends; a script between commands ends at once. From here on every command, `sleep` and `log`
    /// the script calls throws "stopped" on its own thread, without reaching this one: a loop that
    /// never awaits them ends with the run (it went on after Stop, each call a hop to the main
    /// thread). A loop that calls none of them (`while (true) {}`) cannot be interrupted: its thread
    /// stays busy until the profile's process ends.
    ///
    /// A command that is waiting — `sleep`, `waitFor`, a page still loading — stops waiting: it
    /// was let run to its end, and a script sleeping an hour kept its run "running", and its
    /// profile closed to another run, for that hour. The plan's end (`rightsEnded`) still lets the
    /// step under way finish, as it says.
    func stop(_ reason: StopReason = .byUser) {
        guard outcome == nil, thread != nil else { return }
        stopRequest = reason
        gate.close()
        if reason != .rightsEnded { inFlight.values.forEach { $0.cancel() } }
        if commandsInFlight == 0 { end(.stopped(reason)) }
    }

    /// The commands under way, to be cancelled by Stop (`stop`); each takes itself out when it ends.
    fileprivate var inFlight: [UUID: Task<Void, Never>] = [:]
    /// The command asked for last: the next waits for it. A script's commands act one at a time
    /// whatever it awaits — two at once (a forgotten `await`, `Promise.all`) moved one pointer two
    /// ways and mixed their keys.
    fileprivate var lastCommand: Task<Void, Never>?

    private func add(_ kind: Line.Kind, _ text: String) {
        let line = Line(at: Date(), kind: kind, text: text)
        // The last lines of a long run are what matter.
        if lines.count >= 5000 { lines.removeFirst(lines.count - 4999) }
        lines.append(line)
        onLine?(line)
    }

    private func end(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        gate.close()
        switch outcome {
        case .finished: add(.outcome, "Finished")
        case .failed(let message): add(.outcome, "Failed: \(message)")
        case .stopped(.byUser): add(.outcome, "Stopped")
        case .stopped(.rightsEnded): add(.outcome, "Stopped after its current step: automation is no longer in this plan")
        case .stopped(.profileStopped): add(.outcome, "Stopped: the profile stopped")
        }
        // What the script left under way — a command it did not await — ends with the run.
        inFlight.values.forEach { $0.cancel() }
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
            gate.close()
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
        } catch is CancellationError {
            // Its wait was ended by Stop.
            return .failure(Stopped())
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
        case "waitForURL":
            guard let pattern = ScenarioURLPattern(arguments.first), pattern.isReadable else {
                throw PageDriver.Failure.script("waitForURL takes an address as text ('**/account': * within a part of the path, ** for any run) or a regular expression")
            }
            let state = PageDriver.LoadState(rawValue: options(1)["waitUntil"] as? String ?? "load") ?? .load
            try await driver.waitForURL(pattern, waitUntil: state, timeout: timeout(1))
            return nil
        case "selectOption":
            // One choice or several: each an option's value or label as text, or {value}, {label}, {index}.
            let given: Any = arguments.count > 1 ? arguments[1] : NSNull()
            var choices: [Any] = []
            for choice in given as? [Any] ?? [given] {
                if choice is String || choice is [String: Any] {
                    choices.append(choice)
                } else if let number = choice as? NSNumber {
                    choices.append(number.stringValue)
                } else {
                    throw PageDriver.Failure.script("selectOption takes what to choose: an option's value or label as text, or {value: …}, {label: …}, {index: …}")
                }
            }
            return try await driver.selectOption(try string(0), choices, timeout: timeout(2))
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
            let delay = (options(2)["delay"] as? NSNumber)?.doubleValue
            try await driver.type(try string(0), try string(1), delay: ScenarioWait.keyDelay(milliseconds: delay), insertUnmappedText: true)
            return nil
        case "press": try await driver.press(try string(0)); return nil
        case "scroll":
            guard let delta = (arguments.first as? NSNumber)?.doubleValue, delta.isFinite else {
                throw PageDriver.Failure.script("scroll takes a number of points")
            }
            // Far past any page; within what a whole number holds (its log line counts the points).
            try await driver.scroll(by: min(max(delta, -1_000_000_000), 1_000_000_000))
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
            // `sleep(Infinity)`, or longer than a year: until Stop, which cancels the wait.
            let nanoseconds = ScenarioWait.nanoseconds(milliseconds: (arguments.first as? NSNumber)?.doubleValue ?? 0)
            repeat {
                try await Task.sleep(nanoseconds: nanoseconds ?? 3_600_000_000_000)
            } while nanoseconds == nil
            return nil
        default:
            throw PageDriver.Failure.script("no command \(name)")
        }
    }

    // MARK: The script's side (its own thread)

    /// The commands the script's `page` has, by their names.
    private static let pageCommands = ["goto", "back", "forward", "reload", "waitForLoadState", "waitFor", "waitForURL", "click", "dblclick",
                                       "hover", "selectOption", "type", "press", "scroll", "textContent", "innerText", "inputValue",
                                       "getAttribute", "count", "isVisible", "url", "title", "screenshot", "pause"]

    /// Builds the script's world and runs `source` in it, on `thread`.
    nonisolated private static func run(_ source: String, parametersJSON: String, on thread: ScriptThread, gate commands: ScriptGate,
                                        runner owner: ScenarioRunner?) {
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
                        // What the script returned (JSON text; none for nothing returned) is the
                        // run's result — unless the run was stopped meanwhile, or it is too large
                        // to carry, which the log says.
                        if !message.isEmpty, runner.stopRequest == nil, runner.outcome == nil {
                            if message.utf8.count <= Self.maximumResultBytes {
                                runner.add(.result, message)
                            } else {
                                runner.add(.error, "The result is larger than \(Self.maximumResultBytes / 1024) KB and is left out: return less")
                            }
                        }
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
        // A script that logs in a loop without awaiting made a line a hop to the main thread, without
        // end: the profile's windows hung and Stop waited behind them. Past `LogGate.limit` lines
        // waiting, the rest are counted, not queued, and the log says how many it left out.
        let gate = LogGate()
        let logged: @convention(block) (String) -> Void = { text in
            // Stopped, or ended: said to the script, not to the log.
            guard !commands.isClosed else {
                Self.throwInScript("stopped")
                return
            }
            guard gate.take() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let leftOut = gate.shown()
                    if leftOut > 0 {
                        runner?.add(.script, "… \(leftOut) lines left out: the script logs faster than they can be shown")
                    }
                    runner?.add(.script, text)
                }
            }
        }
        // A script that asks for commands in a loop without awaiting them queued a hop to the main
        // thread, a task and a promise for each, without end: the process's memory grew until the
        // profile stopped. Past `ScriptGate.commandLimit` asked for and not answered, the call
        // throws, saying to await them; after Stop, or once the run has ended, every call throws
        // "stopped" at once — on this thread, so that such a loop ends with the run.
        let command: @convention(block) (String, JSValue) -> JSValue = { [weak context] name, arguments in
            switch commands.takeCommand() {
            case .closed:
                return Self.throwInScript("stopped")
            case .full:
                return Self.throwInScript("\(ScriptGate.commandLimit) page commands are waiting to run: write await before each one, as in await page.click('#login')")
            case .taken:
                break
            }
            let values = arguments.toArray() ?? []
            guard let context else {
                commands.commandAnswered()
                return JSValue(undefinedIn: JSContext.current())
            }
            return JSValue(newPromiseIn: context) { resolve, reject in
                let resolve = resolve, reject = reject
                DispatchQueue.main.async {
                    let id = UUID()
                    let previous = MainActor.assumeIsolated { runner?.lastCommand }
                    let task = Task { @MainActor in
                        // One at a time, in the order asked.
                        await previous?.value
                        guard let runner else { return }
                        let result = await runner.perform(name, values)
                        runner.inFlight[id] = nil
                        thread.perform {
                            commands.commandAnswered()
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
                    MainActor.assumeIsolated {
                        runner?.inFlight[id] = task
                        runner?.lastCommand = task
                    }
                }
            }
        }
        context.setObject(ended, forKeyedSubscript: "__ended" as NSString)
        context.setObject(logged, forKeyedSubscript: "__log" as NSString)
        context.setObject(command, forKeyedSubscript: "__command" as NSString)
        context.exceptionHandler = { _, exception in
            var message = exception?.toString() ?? "error"
            // A script that does not parse: the line the reading stopped at.
            if let line = exception?.forProperty("line"), line.isNumber, line.toInt32() > 0 { message += " (line \(line.toInt32()))" }
            ended(false, message)
        }
        let names = pageCommands.map { "'\($0)'" }.joined(separator: ", ")
        let prelude = """
            const params = Object.freeze(\(parametersJSON));
            const log = (...parts) => __log(parts.map((p) => typeof p === 'string' ? p : JSON.stringify(p)).join(' '));
            \(Self.lineSupport)
            const page = {};
            for (const name of [\(names)]) page[name] = (...args) => __at(__line(), () => __command(name, args));
            page.waitForSelector = page.waitFor;
            page.waitForURL = (url, options) => __at(__line(), () => __command('waitForURL', [
              url instanceof RegExp ? {regex: url.source, flags: url.flags} : url, options === undefined ? null : options]));
            page.evaluate = (body, arg, options) => __at(__line(), () => __command('evaluate', [
              typeof body === 'function' ? 'return await (' + body.toString() + ')(__arg);' : String(body),
              arg === undefined ? null : arg, (options && options.world) || 'isolated']));
            const sleep = (ms) => __at(__line(), () => __command('pause', [ms]));
            """
        context.evaluateScript(prelude)
        // The script's first line is line 1 of what runs: its line numbers stay its own.
        let script = "(async () => {" + source + "\n})().then((value) => __ended(true, __result(value)), (e) => __ended(false, __failure(e)));"
        context.evaluateScript(script, withSourceURL: URL(string: "scenario.js"))
    }

    /// The script's side of "which line": part of the prelude, in JavaScript, kept apart so that
    /// scripts/test-shims.mjs runs this very text (in JavaScriptCore under Bun, in V8 under Node).
    ///
    /// A command that fails is rejected from this code, outside any call of the script, so its
    /// error knows nothing of the scenario's lines: a script of a hundred lines with five
    /// `page.click` failed with "no element matches #next" and no word of which. `__line()` reads
    /// the line of the scenario a command is called from — the first frame of `scenario.js` (the
    /// name the script is run under) in a stack made there; `__at` adds it to the error of a
    /// command that fails, once ("… (line 12)", and `scenarioLine` on the error; "stopped" stays as
    /// it is: a script may compare it). `__failure` is the
    /// run's end by an error nobody caught: the script's own errors get their line the same way,
    /// from their own stack. `__result` is what the script returned, as JSON text ('' for nothing).
    static let lineSupport = #"""
const __lineIn = (stack) => { const m = /scenario\.js:(\d+)/.exec(String(stack || '')); return m ? Number(m[1]) : 0; };
const __line = () => __lineIn(new Error().stack);
const __mark = (e, line) => {
  try {
    if (line > 0 && e && typeof e === 'object' && typeof e.message === 'string' && e.message !== 'stopped' && e.scenarioLine === undefined) {
      e.scenarioLine = line;
      e.message += ' (line ' + line + ')';
    }
  } catch (ignored) {}
  return e;
};
const __at = (line, call) => {
  let promise;
  try { promise = call(); } catch (e) { throw __mark(e, line); }
  return promise && typeof promise.then === 'function' ? promise.then(undefined, (e) => { throw __mark(e, line); }) : promise;
};
const __failure = (e) => {
  __mark(e, __lineIn(e && e.stack));
  return String(e && e.stack ? e + '\n' + e.stack : e);
};
const __result = (value) => {
  if (value === undefined) { return ''; }
  try { const text = JSON.stringify(value); return text === undefined ? '' : text; } catch (e) { return JSON.stringify(String(value)); }
};
"""#

    /// Throws an error with `message` in the script, from inside a call of it into this code
    /// (`__command`, `__log`): JavaScriptCore throws the context's exception set during the call
    /// when the call returns.
    @discardableResult
    nonisolated private static func throwInScript(_ message: String) -> JSValue {
        let context = JSContext.current()
        context?.exception = JSValue(newErrorFromMessage: message, in: context)
        return JSValue(undefinedIn: context)
    }
}

/// A thread with a run loop, for one scenario's JavaScript: work is handed to it in order.
///
/// Work comes through a run-loop source of its own (version 0), signalled for each block: a source
/// handled makes `RunLoop.run(mode:before:)` return, and the loop then sees a cancellation. Blocks
/// given with `CFRunLoopPerformBlock` did not: run, they are no source handled, so `run` went on
/// waiting and the thread never looked at `isCancelled` again — every run's thread, and its
/// JavaScript context, stayed until the profile's process ended, a finished run's too (the
/// self-test's "after Stop … its thread ends" found it).
private final class ScriptThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?
    /// The blocks given and not run yet, in order.
    private var work: [() -> Void] = []
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    /// The run's JavaScript; let go when the thread ends.
    var context: JSContext?

    override func main() {
        var sourceContext = CFRunLoopSourceContext()
        sourceContext.info = Unmanaged.passUnretained(self).toOpaque()
        sourceContext.perform = { info in
            guard let info else { return }
            Unmanaged<ScriptThread>.fromOpaque(info).takeUnretainedValue().runWork()
        }
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode)
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        self.source = source
        lock.unlock()
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        lock.lock()
        self.source = nil
        runLoop = nil
        work.removeAll()
        lock.unlock()
        if let source { CFRunLoopSourceInvalidate(source) }
        context = nil
    }

    func waitUntilReady() { ready.wait() }

    /// The blocks given so far, in order; one given while they run is the next signal's.
    private func runWork() {
        lock.lock()
        let blocks = work
        work.removeAll()
        lock.unlock()
        for block in blocks { block() }
    }

    func perform(_ block: @escaping () -> Void) {
        lock.lock()
        guard let loop = runLoop, let source else {
            lock.unlock()
            return
        }
        work.append(block)
        lock.unlock()
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(loop)
    }
}

/// A run's commands, between its script's thread and the main one: whether the run still takes any
/// (Stop and the run's end close it, from the main thread; the script's thread reads it at each
/// call), and how many the script has asked for that have not been answered on its thread yet — at
/// most `commandLimit`: a script that awaits its commands has one, `Promise.all` over a page's
/// elements a few hundred at most.
private final class ScriptGate: @unchecked Sendable {
    static let commandLimit = 1000
    enum Answer { case taken, closed, full }
    private let lock = NSLock()
    private var closed = false
    private var waiting = 0

    /// Stop, or the run's end: no command or log line is taken any more.
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// One more command asked for: `.taken` counts it until `commandAnswered`.
    func takeCommand() -> Answer {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        guard waiting < Self.commandLimit else { return .full }
        waiting += 1
        return .taken
    }

    /// A command taken has its answer on the script's thread (or was never sent).
    func commandAnswered() {
        lock.lock()
        waiting = max(0, waiting - 1)
        lock.unlock()
    }
}

/// Lines a script logs, between its thread and the main one: at most `limit` wait to be shown; the
/// rest are counted and said as one line when the log catches up.
private final class LogGate: @unchecked Sendable {
    static let limit = 500
    private let lock = NSLock()
    private var waiting = 0
    private var leftOut = 0

    /// False when too many wait already: this one is counted as left out.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard waiting < Self.limit else {
            leftOut += 1
            return false
        }
        waiting += 1
        return true
    }

    /// One is being shown: how many were left out before it.
    func shown() -> Int {
        lock.lock()
        defer { lock.unlock() }
        waiting -= 1
        let count = leftOut
        leftOut = 0
        return count
    }
}

extension ProfileManager.ScenarioRunState {
    /// How long the run has taken: to its end's line, or to its last line so far.
    var length: TimeInterval { max(0, (lines.last?.at ?? startedAt).timeIntervalSince(startedAt)) }

    /// What the script returned, as JSON text; nil when it returned nothing, or has not ended.
    var result: String? { lines.last(where: { $0.kind == .result })?.text }

    /// The run's log as text, to copy or keep: the scenario's name and when it started, then each
    /// line after the seconds since the start — where a run's time went is read off them.
    var transcript: String {
        var out = ["\(name) — \(ISO8601DateFormatter().string(from: startedAt))"]
        for line in lines {
            let seconds = String(format: "%9.3f", max(0, line.at.timeIntervalSince(startedAt)))
            out.append("\(seconds)  \(line.kind == .result ? "result " : "")\(line.text)")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
