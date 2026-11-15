@testable import BrowserCore
import XCTest

/// The launch screen (the owner, 15 November): at the first launch and after a full quit, never for
/// the executable's other runs or the app's own restarts; its greeting in the interface's language
/// first, then a different language each start.
final class WelcomeSplashPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyAPersonsStartShowsIt() {
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: true, vaultExists: false,
                                                seamlessRelaunchAt: nil, now: now), .firstLaunch)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: true, vaultExists: true,
                                                seamlessRelaunchAt: nil, now: now), .returning)
        // A profile's process, the self-test, the snapshots, a CI check: never.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, enabled: true, vaultExists: true,
                                                seamlessRelaunchAt: nil, now: now), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, enabled: true, vaultExists: false,
                                                seamlessRelaunchAt: nil, now: now), .none)
    }

    func testTheSettingTurnsItOff() {
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: false, vaultExists: true,
                                                seamlessRelaunchAt: nil, now: now), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: false, vaultExists: false,
                                                seamlessRelaunchAt: nil, now: now), .none)
    }

    func testTheAppsOwnRestartIsSeamless() {
        // Settings › Language's restart a few seconds ago, an update's installer some minutes ago.
        for ago in [3.0, 9 * 60.0, WelcomeSplashPolicy.seamlessWindow] {
            XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: true, vaultExists: true,
                                                    seamlessRelaunchAt: now.addingTimeInterval(-ago), now: now), .none, "\(ago) s")
        }
        // A mark older than the window is an earlier restart's: the person opened the app since.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: true, vaultExists: true,
                                                seamlessRelaunchAt: now.addingTimeInterval(-WelcomeSplashPolicy.seamlessWindow - 1),
                                                now: now), .returning)
        // A mark well in the future (the clock set back since) is not believed.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, enabled: true, vaultExists: true,
                                                seamlessRelaunchAt: now.addingTimeInterval(3_600), now: now), .returning)
    }

    func testTheFirstGreetingIsInTheInterfacesLanguage() {
        let languages = ["ru", "en", "de", "fr"]
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: languages, last: nil, interfaceLanguage: "ru"), 0)
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: languages, last: nil, interfaceLanguage: "en"), 1)
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: languages, last: nil, interfaceLanguage: "en-GB"), 1)
        // No greeting in that language: the list's first.
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: languages, last: nil, interfaceLanguage: "ja"), 0)
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: [], last: nil, interfaceLanguage: "ru"), -1)
    }

    func testEachLaterStartTakesTheNextLanguageRoundTheList() {
        let languages = ["ru", "en", "de"]
        var last: Int? = nil
        var seen: [String] = []
        for _ in 0..<7 {
            let index = WelcomeSplashPolicy.nextGreeting(languages: languages, last: last, interfaceLanguage: "en")
            seen.append(languages[index])
            last = index
        }
        XCTAssertEqual(seen, ["en", "de", "ru", "en", "de", "ru", "en"])
        // An index a longer list left behind starts over from the interface's language.
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: languages, last: 11, interfaceLanguage: "de"), 2)
        XCTAssertEqual(WelcomeSplashPolicy.nextGreeting(languages: languages, last: -3, interfaceLanguage: "ru"), 0)
    }
}
