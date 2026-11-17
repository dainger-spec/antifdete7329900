import XCTest

/// Measurements, not checks: run on their own (the workflow's suite input), never in the usual runs.
/// What they find is printed ("MEASURE …") and shot, for a decision made from it.
final class MeasureTests: LumenUITestCase {
    /// Does WebKit on the iPhone start its processes in the time zone the app's environment names
    /// (`__XPC_TZ`, as the Mac app starts a profile's)? Then the engine itself would give the zone to
    /// the page and to workers loaded from a URL — dedicated, shared and service — which no page
    /// script reaches. The session has no proxy and the device's own zone: the shim replaces nothing.
    /// The control is the runner's own zone, printed beside it.
    func testEngineZoneFromTheAppsEnvironment() {
        launch(reset: true, environment: ["__XPC_TZ": "Asia/Tokyo"])
        createSession(name: "Замер")
        openSession("Замер")
        openPage("http://127.0.0.1:28380/zone")
        let lines = ["page zone: ", "worker zone: ", "shared zone: ", "service zone: "].map { pageLine($0) }
        print("MEASURE runner zone: \(TimeZone.current.identifier); asked: Asia/Tokyo; " + lines.joined(separator: "; "))
        let note = XCTAttachment(string: lines.joined(separator: "\n"))
        note.name = "MEASURE zone"
        note.lifetime = .keepAlways
        add(note)
        shot("90 the engine's zone, from the launch")

        // The same set by the app itself as a session opens (setenv, DEBUG hook in SessionRuntime): a
        // process WebKit starts after it — if WebKit reads it then — would be in Berlin.
        relaunch(environment: ["LUMEN_TEST_SESSION_XPC_TZ": "Europe/Berlin"])
        createSession(name: "Замер 2")
        openSession("Замер 2")
        openPage("http://127.0.0.1:28380/zone?second=1")
        let second = ["page zone: ", "worker zone: ", "shared zone: ", "service zone: "].map { pageLine($0) }
        print("MEASURE set as a session opens: Europe/Berlin; " + second.joined(separator: "; "))
        shot("91 the engine's zone, set as a session opens")
    }
}
