@testable import BrowserCore
import XCTest

/// The interface's language (the owner, 1 November): the command line and the Mac's own language
/// count, the person's choice counts, and none of it is ever the websites' language.
final class InterfaceLanguageTests: XCTestCase {
    func testTheOwnersCommandLineWins() {
        // `open Lumen.app --args -AppleLanguages "(en)"` on a Russian Mac, with Russian chosen before.
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: ["en"], choice: .ru, system: ["ru-RU"]), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: ["de-DE", "ru"], choice: .en, system: ["en-US"]), "ru")
        // A command line in a language the app is not translated into says nothing.
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: ["de-DE"], choice: .ru, system: ["en-US"]), "ru")
        // The tests' variable before everything.
        XCTAssertEqual(InterfaceLanguage.resolve(environment: "EN", commandLine: ["ru"], choice: .ru, system: ["ru"]), "en")
    }

    func testTheChoiceThenTheSystem() {
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: nil, choice: .ru, system: ["en-US"]), "ru")
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: nil, choice: .en, system: ["ru-RU"]), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: nil, choice: .system, system: ["en-GB", "ru"]), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: nil, choice: nil, system: ["uk-UA", "ru-RU"]), "ru")
        // No language the app has: English, never Russian by default (the bug of 1 November).
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: nil, choice: .system, system: ["de-DE", "fr"]), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(environment: nil, commandLine: nil, choice: nil, system: []), "en")
    }

    func testOnlyWhatEarlierVersionsWroteIsTakenOut() {
        XCTAssertTrue(InterfaceLanguage.isEarlierVersionsWrite(["ru", "en"]))
        XCTAssertTrue(InterfaceLanguage.isEarlierVersionsWrite(["en", "en"]))
        XCTAssertFalse(InterfaceLanguage.isEarlierVersionsWrite(["ru"]))
        XCTAssertFalse(InterfaceLanguage.isEarlierVersionsWrite(["en", "ru"]))
        XCTAssertFalse(InterfaceLanguage.isEarlierVersionsWrite("ru"))
        XCTAssertFalse(InterfaceLanguage.isEarlierVersionsWrite(nil))
    }
}
