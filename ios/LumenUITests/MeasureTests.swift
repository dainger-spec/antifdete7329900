import XCTest

/// Measurements, not checks: run on their own (the workflow's suite input), never in the usual runs.
/// What they find is printed ("MEASURE …") and shot, for a decision made from it.
final class MeasureTests: LumenUITestCase {
    private let lines = ["page zone: ", "worker zone: ", "shared zone: ", "service zone: "]

    /// Does WebKit on the iPhone start its processes in the time zone the app's environment names
    /// (`__XPC_TZ`, as the Mac app starts a profile's)? Then the engine itself gives the zone to the
    /// page and to workers loaded from a URL — dedicated, shared and service — which no page script
    /// reaches. Each session has no proxy and the device's own zone: the shim replaces nothing.
    /// Run 173: from the launch's environment, yes (page, worker and shared worker in Tokyo; no
    /// service worker at all). Now: the control, and the zone and languages set by the app itself as a
    /// session opens, which is what a session of its own needs.
    func testEngineZoneFromTheAppsEnvironment() {
        continueAfterFailure = true

        // The control: nothing set.
        launch(reset: true)
        measure("control, nothing set", session: "Замер 0", shot: "89 the engine's zone, nothing set")

        // In the launch's environment (run 173: the processes took it).
        relaunch(environment: ["__XPC_TZ": "Asia/Tokyo"])
        measure("from the launch: Asia/Tokyo", session: "Замер 1", shot: "90 the engine's zone, from the launch")

        // Set by the app as a session opens (DEBUG hook in SessionRuntime: setenv, and the languages in
        // the app's defaults): do the processes WebKit starts after it take them?
        relaunch(environment: ["LUMEN_TEST_SESSION_XPC_TZ": "Europe/Berlin", "LUMEN_TEST_SESSION_LANGS": "de-DE"])
        measure("set as a session opens: Europe/Berlin, de-DE", session: "Замер 2", shot: "91 the engine's zone, set as a session opens")

        // A second session set otherwise in the same run: does it get a process of its own, in its zone?
        relaunchless(env: "Asia/Kolkata")
    }

    /// A second session in the same run, its zone named before it opens (LUMEN_TEST_SESSION_XPC_TZ is
    /// the first session's; the hook takes the zone from the session's name after "@").
    private func relaunchless(env zone: String) {
        measure("second session of the run: \(zone)", session: "Замер 3 @\(zone)", shot: "92 the engine's zone, a second session")
    }

    private func measure(_ what: String, session: String, shot name: String) {
        createSession(name: session)
        openSession(session)
        openPage("http://127.0.0.1:28380/zone?\(name.prefix(2))")
        let found = lines.map { pageLine($0) }
        print("MEASURE \(what) (runner: \(TimeZone.current.identifier)); " + found.joined(separator: "; "))
        let note = XCTAttachment(string: "\(what)\n" + found.joined(separator: "\n"))
        note.name = "MEASURE \(name)"
        note.lifetime = .keepAlways
        add(note)
        shot(name)
        backToList()
    }
}
