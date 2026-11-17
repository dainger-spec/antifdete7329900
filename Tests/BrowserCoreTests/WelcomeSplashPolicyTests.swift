@testable import BrowserCore
import XCTest

/// The launch screen (the owner, 16 November): only at the first start of the app, once — unless
/// the setting "Greet with the welcome window at every start" is on; never for the executable's
/// other runs; its greeting is the English one.
final class WelcomeSplashPolicyTests: XCTestCase {
    func testOnlyTheFirstStartShowsItByDefault() {
        // No vault yet, never shown: it ends with the button that leads to the setup.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false, shownBefore: false), .firstLaunch)
        // A Mac that has a vault — a start after a full quit, an update's first start: none.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: false), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: true), .none)
    }

    func testItIsShownOnce() {
        // Met, then the app quit before a vault was made: the next start goes straight to the setup.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false, shownBefore: true), .none)
    }

    func testTheSettingGreetsAtEveryStart() {
        // With a vault it leads to the lock screen by itself.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: true, everyStart: true), .returning)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: false, everyStart: true), .returning)
        // Without one, to the setup by its button.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false, shownBefore: true, everyStart: true), .firstLaunch)
        // Off is the default.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: true),
                       WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: true, everyStart: false))
    }

    func testTheExecutablesOtherRunsNeverShowIt() {
        // A profile's process, the self-test, the snapshots, a CI check — whatever the setting says.
        for vault in [false, true] {
            for shown in [false, true] {
                for every in [false, true] {
                    XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, vaultExists: vault, shownBefore: shown, everyStart: every), .none)
                }
            }
        }
    }
}
