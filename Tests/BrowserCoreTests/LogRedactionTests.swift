import XCTest
@testable import BrowserCore

/// An exception's reason in the log: what went wrong stays readable, what was the user's does not.
final class LogRedactionTests: XCTestCase {
    func testWhatWentWrongStays() {
        let reason = "*** -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object from objects[1]"
        XCTAssertEqual(LogRedaction.exceptionReason(reason), reason)
        let kvc = "[<GeneralPreferences 0x6000039810c0> valueForUndefinedKey:]: this class is not key value coding-compliant for the key defaultBrowser."
        XCTAssertEqual(LogRedaction.exceptionReason(kvc), kvc)
        XCTAssertEqual(LogRedaction.exceptionReason("Connection to service named com.apple.Safari.History was invalidated"),
                       "Connection to service named com.apple.Safari.History was invalidated")
    }

    func testAddressesPathsAndQuotesGo() {
        let reason = "Could not load https://www.binance.com/en/login?ref=ALICE42 into \"Alice's wallet\" "
            + "at /Users/alice/Library/Safari/History.db for alice@example.org (www.binance.com, card 4111 1111 1111 1111)"
        let redacted = LogRedaction.exceptionReason(reason)
        for secret in ["binance", "ALICE42", "Alice", "alice", "History.db", "example.org", "4111"] {
            XCTAssertFalse(redacted.contains(secret), "\(secret) left in: \(redacted)")
        }
        XCTAssertTrue(redacted.hasPrefix("Could not load <url> into \"…\" at <path> for <email> (<host>, card <number>)"), redacted)
    }

    func testEveryKindOfQuote() {
        XCTAssertEqual(LogRedaction.exceptionReason("title 'Bank' “Bank” «Банк»"), "title '…' “…” «…»")
    }

    func testALongReasonIsCut() {
        let redacted = LogRedaction.exceptionReason(String(repeating: "nil ", count: 400), limit: 100)
        XCTAssertEqual(redacted.count, 101)
        XCTAssertTrue(redacted.hasSuffix("…"))
    }
}
