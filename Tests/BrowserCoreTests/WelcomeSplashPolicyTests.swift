@testable import BrowserCore
import XCTest

/// The launch screen (the owner, 15 November): only at the first launch of the app, once — never
/// for the executable's other runs, nor on a Mac that has a vault or has shown it already; its
/// greeting in the interface's language.
final class WelcomeSplashPolicyTests: XCTestCase {
    func testOnlyThePersonsFirstLaunchShowsIt() {
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false, shownBefore: false), .firstLaunch)
        // A Mac that has a vault — a start after a full quit, an update's first start: none.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: false), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: true), .none)
        // A profile's process, the self-test, the snapshots, a CI check: never.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, vaultExists: false, shownBefore: false), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, vaultExists: true, shownBefore: false), .none)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .other, vaultExists: false, shownBefore: false, asked: true), .none)
    }

    func testItIsShownOnce() {
        // Met, then the app quit before a vault was made: the next start goes straight to the setup.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false, shownBefore: true), .none)
    }

    func testAskedForItIsShownOnAnyMac() {
        // `--welcome`, to look at it: with a vault it leads to the lock screen by itself.
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: true, shownBefore: true, asked: true), .returning)
        XCTAssertEqual(WelcomeSplashPolicy.mode(start: .interactive, vaultExists: false, shownBefore: true, asked: true), .firstLaunch)
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

    func testAskedForAgainItTakesTheNextLanguageRoundTheList() {
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
