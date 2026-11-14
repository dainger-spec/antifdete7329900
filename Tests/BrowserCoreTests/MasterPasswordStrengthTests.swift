import XCTest
@testable import BrowserCore

/// A new master password: at least 10 characters and at least "fair" (APP-06).
final class MasterPasswordStrengthTests: XCTestCase {
    func testTheStepsOfTheMeter() {
        XCTAssertEqual(MasterPasswordStrength.score(""), 0)
        XCTAssertEqual(MasterPasswordStrength.score("abc"), 1)
        XCTAssertEqual(MasterPasswordStrength.score("lowercase1"), 1, "10 characters of two kinds: weak")
        XCTAssertEqual(MasterPasswordStrength.score("Lowercase1"), 2, "10 characters of three kinds: fair")
        XCTAssertEqual(MasterPasswordStrength.score("correct horse b"), 2, "14 characters or more: fair")
        XCTAssertEqual(MasterPasswordStrength.score("correct horse battery"), 3)
        XCTAssertEqual(MasterPasswordStrength.score("Correct horse battery 9"), 4)
        XCTAssertEqual(MasterPasswordStrength.score("aaaaaaaaaaaaaaaaaaaaaaaa"), 1, "one character repeated is weak at any length")
        XCTAssertEqual(MasterPasswordStrength.score("1212121212121212Aa!"), 1, "five different characters are weak")
    }

    func testANewMasterPasswordMustBeLongAndAtLeastFair() {
        for weak in ["", "short", "Sh0rt!pw", "password12", "qwertyuiop", "aaaaaaaaaaaaaaaaaaaa", "1234512345123451234"] {
            XCTAssertFalse(MasterPasswordStrength.isAcceptable(weak), weak)
        }
        for fair in ["Password12", "correct horse b", "tr0ub4dor&3x", "мой длинный пароль"] {
            XCTAssertTrue(MasterPasswordStrength.isAcceptable(fair), fair)
        }
        XCTAssertFalse(MasterPasswordStrength.isLongEnough("Ab1!xyz"))
        XCTAssertFalse(MasterPasswordStrength.isStrongEnough("password12"))
        XCTAssertTrue(MasterPasswordStrength.isStrongEnough("Password12"))
    }
}
