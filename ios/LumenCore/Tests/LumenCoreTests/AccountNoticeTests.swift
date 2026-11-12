@testable import LumenCore
import XCTest

/// The account's notices of the release: the period's end said twice, the clock off the server's.
final class AccountNoticeTests: XCTestCase {
    func document(endsIn seconds: TimeInterval?, status: Entitlement.Status = .active, now: Date) -> Entitlement {
        Entitlement(deviceID: "d", machineID: "m", plan: "pro", status: status, profiles: 50,
                    periodEndsAt: seconds.map { now.addingTimeInterval($0) }, issuedAt: now, refreshAfter: now,
                    expiresAt: now.addingTimeInterval(86400), graceEndsAt: now.addingTimeInterval(3 * 86400))
    }

    func testThePeriodsEndIsSaidTwice() {
        let now = Date()
        XCTAssertNil(AccountNotices.periodEnding(document(endsIn: 8 * 86400, now: now), now: now), "eight days before: nothing yet")
        XCTAssertEqual(AccountNotices.periodEnding(document(endsIn: 6 * 86400, now: now), now: now), .week, "seven days before: said")
        XCTAssertEqual(AccountNotices.periodEnding(document(endsIn: 12 * 3600, now: now), now: now), .day, "and again in the last day")
        XCTAssertNil(AccountNotices.periodEnding(document(endsIn: -60, now: now), now: now), "over: the period-ended notice's, not this one")
        XCTAssertNil(AccountNotices.periodEnding(document(endsIn: 6 * 86400, status: .exportOnly, now: now), now: now))
        XCTAssertNil(AccountNotices.periodEnding(document(endsIn: nil, now: now), now: now), "no period, nothing to end")
        XCTAssertNil(AccountNotices.periodEnding(nil, now: now))
        let text = AccountNotices.periodEndingText(now) { _ in "1 декабря 2026 г." }
        XCTAssertEqual(text, "Оплаченный период заканчивается 1 декабря 2026 г.")
    }

    func testTheClockOffTheServers() {
        XCTAssertNil(AccountNotices.clockSkew(9 * 60), "within ten minutes: nothing")
        XCTAssertNil(AccountNotices.clockSkew(-9 * 60))
        XCTAssertEqual(AccountNotices.clockSkew(-2 * 3600 - 300),
                       "Часы iPhone расходятся со временем сервера на 2 ч. Исправьте дату и время в Настройках.")
        XCTAssertEqual(AccountNotices.duration(15 * 60), "15 мин")
        XCTAssertEqual(AccountNotices.duration(3 * 86400 + 5), "3 дн.")
    }
}
