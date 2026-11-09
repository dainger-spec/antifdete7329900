import XCTest

/// A proxy check ends with an answer the person can read, within the check's own deadline — never a
/// spinner for ever. The owner's iPhone, 9 November: a working proxy's row said "Проверяется…" and
/// nothing else, so the network-switch run behind his proxy could not be made. The red is the check
/// as it was, with no clock of its own (checkWithoutDeadline).
final class ProxyCheckTests: LumenUITestCase {
    func testACheckEndsWithAnAnswer() {
        // A check that never gets an answer and does not stop when cancelled (the app's test hook,
        // LUMEN_TEST_CHECK_HANG), with a deadline of 6 s. Proxy A itself is alive.
        launch(reset: true, environment: ["LUMEN_TEST_CHECK_HANG": "1", "LUMEN_TEST_CHECK_DEADLINE": "6"])
        app.buttons["proxiesButton"].tap()
        addProxy(name: "Зависший", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Зависший", says: "прокси не ответил за 6 с", timeout: 20)
        shot("50 a check that got no answer")

        // A proxy that takes the connection and never answers a byte (the testbed's proxy E).
        relaunch(environment: ["LUMEN_TEST_CHECK_DEADLINE": "6"])
        app.buttons["proxiesButton"].tap()
        addProxy(name: "Молчун", kind: "HTTP", port: "28391", user: "ue", password: "pe")
        waitRow("Молчун", says: "Недоступен", timeout: 20)
        shot("51 a proxy that never answers")
        // A live proxy is still found alive: the deadline cuts no working check short.
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает", timeout: 20)
    }
}
