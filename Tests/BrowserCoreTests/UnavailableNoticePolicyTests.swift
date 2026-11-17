import Foundation
import XCTest
@testable import BrowserCore

/// When a profile's window says one of Safari's features failed (`UnavailableNoticePolicy`): a
/// customer's address bar put the notice up at every key press, and nothing could be typed.
final class UnavailableNoticePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTypingIsNeverInterrupted() {
        var policy = UnavailableNoticePolicy()
        // "google", one exception per key press, as the customer's address bar threw.
        for index in 0..<6 {
            XCTAssertEqual(policy.decide(.key(intoText: true), now: start.addingTimeInterval(Double(index) * 0.2)), .logOnly(.typing))
        }
        // Hours of typing later: still nothing.
        XCTAssertEqual(policy.decide(.key(intoText: true), now: start.addingTimeInterval(36_000)), .logOnly(.typing))
    }

    func testTypingLeavesTheOneNoticeForSomethingElse() {
        var policy = UnavailableNoticePolicy()
        for _ in 0..<20 { _ = policy.decide(.key(intoText: true), now: start) }
        XCTAssertEqual(policy.decide(.click, now: start.addingTimeInterval(1)), .show(menuItem: nil))
    }

    func testNothingAskedForIsNeverTold() {
        var policy = UnavailableNoticePolicy()
        XCTAssertEqual(policy.decide(.other, now: start), .logOnly(.notAskedFor))
    }

    func testAClickOrAKeyOutsideTextIsToldOncePerProcess() {
        var policy = UnavailableNoticePolicy(cooldown: 10)
        XCTAssertEqual(policy.decide(.click, now: start), .show(menuItem: nil))
        XCTAssertEqual(policy.decide(.click, now: start.addingTimeInterval(1)), .logOnly(.alreadyToldOnce))
        XCTAssertEqual(policy.decide(.key(intoText: false), now: start.addingTimeInterval(3_600)), .logOnly(.alreadyToldOnce))
    }

    func testEachMenuItemIsToldOnce() {
        var policy = UnavailableNoticePolicy(cooldown: 10)
        XCTAssertEqual(policy.decide(.menuItem("Bookmarks"), now: start), .show(menuItem: "Bookmarks"))
        XCTAssertEqual(policy.decide(.menuItem("Bookmarks"), now: start.addingTimeInterval(100)), .logOnly(.itemAlreadyTold))
        XCTAssertEqual(policy.decide(.menuItem("Share"), now: start.addingTimeInterval(100)), .show(menuItem: "Share"))
    }

    func testNoTwoNoticesWithinTheCooldown() {
        var policy = UnavailableNoticePolicy(cooldown: 10)
        XCTAssertEqual(policy.decide(.menuItem("Bookmarks"), now: start), .show(menuItem: "Bookmarks"))
        XCTAssertEqual(policy.decide(.menuItem("Share"), now: start.addingTimeInterval(2)), .logOnly(.coolingDown))
        XCTAssertEqual(policy.decide(.click, now: start.addingTimeInterval(5)), .logOnly(.coolingDown))
        // Neither was counted as told: each can be told once the cooldown is over.
        XCTAssertEqual(policy.decide(.menuItem("Share"), now: start.addingTimeInterval(11)), .show(menuItem: "Share"))
        XCTAssertEqual(policy.decide(.click, now: start.addingTimeInterval(22)), .show(menuItem: nil))
    }

    func testAtMostOneNoticePerItemAndOneOtherInAnyRun() {
        var policy = UnavailableNoticePolicy(cooldown: 0)
        var shown = 0
        let causes: [UnavailableNoticePolicy.Cause] = [.key(intoText: true), .click, .key(intoText: false), .menuItem("A"),
                                                       .menuItem("A"), .other, .menuItem("B"), .click]
        for round in 0..<50 {
            for (index, cause) in causes.enumerated() {
                if case .show = policy.decide(cause, now: start.addingTimeInterval(Double(round * 10 + index))) { shown += 1 }
            }
        }
        XCTAssertEqual(shown, 3)
    }
}
