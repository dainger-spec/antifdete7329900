@testable import BrowserCore
import XCTest

/// The launch screen (the owner, 16 November): at every start a person makes of the app — after a
/// full quit too — and never for the executable's other runs; its greeting is the English one.
final class WelcomeSplashPolicyTests: XCTestCase {
    func testEveryStartAPersonMakesShowsIt() {
        // No vault yet: it ends with the button that leads to the setup.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false), .firstLaunch)
        // A Mac that has a vault — a start after a full quit, an update's first start: it leads to
        // the lock screen by itself.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true), .returning)
    }

    func testTheExecutablesOtherRunsNeverShowIt() {
        // A profile's process, the self-test, the snapshots, a CI check.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, vaultExists: false), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, vaultExists: true), .none)
    }

    func testTheGreetingIsTheEnglishOne() {
        XCTAssertEqual(WelcomeSplashPolicy.greetingLanguage, "en")
    }
}
