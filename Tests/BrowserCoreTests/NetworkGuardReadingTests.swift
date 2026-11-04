import XCTest
@testable import BrowserCore

/// The owner's Mac, 0.1.2 (3), macOS 27.0.1, 4 November: after the update macOS kept the earlier
/// guard "terminated waiting to uninstall on reboot" beside the new one "activated enabled"; the new
/// one did not answer at all until the Mac was restarted, and the app said only "not answering".
final class NetworkGuardReadingTests: XCTestCase {
    func testASilentGuardWithAnEarlierCopyAwaitingRemovalNeedsARestart() {
        XCTAssertEqual(NetworkGuardReading.silent(earlierCopyAwaitsRestart: true), .restartNeeded)
    }

    func testASilentGuardWithoutOneIsNotAnswering() {
        XCTAssertEqual(NetworkGuardReading.silent(earlierCopyAwaitsRestart: false), .notAnswering)
    }

    func testARestartKeepsWebRTCOffInProxiedProfilesAndSaysWhy() {
        let socks = ProxySettings(kind: .socks5, host: "proxy.example", port: 1080)
        XCTAssertEqual(WebRTCGate.decide(policy: .unrestricted, proxy: socks, ownProcess: true, guardState: .restartNeeded, udp: .supported),
                       .off(.guardRestartNeeded))
    }
}
