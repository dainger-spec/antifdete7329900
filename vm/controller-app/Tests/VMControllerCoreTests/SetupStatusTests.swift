import Foundation
import XCTest
@testable import VMControllerCore

final class SetupStatusCacheTests: XCTestCase {
    var cache: SetupStatusCache!
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        cache = SetupStatusCache(url: dir.appendingPathComponent("setup-status.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testMissingIsNil() {
        XCTAssertNil(cache.load())
    }

    func testRoundTrip() {
        // Whole-second date: ISO8601 encoding doesn't keep sub-second precision.
        let status = SetupStatus(tartPath: "/opt/homebrew/bin/tart", tartVersion: "2.0.0",
                                 baseImage: "ghcr.io/x/base:latest", baseImagePresent: true,
                                 checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        cache.save(status)
        XCTAssertEqual(cache.load(), status)
        cache.clear()
        XCTAssertNil(cache.load())
    }

    func testFreshness() {
        let now = Date()
        let recent = SetupStatus(checkedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(recent.isFresh(within: 3600, now: now))
        let old = SetupStatus(checkedAt: now.addingTimeInterval(-7200))
        XCTAssertFalse(old.isFresh(within: 3600, now: now))
    }

    func testCanFastPath() {
        let now = Date()
        let good = SetupStatus(tartPath: "/bin/tart", baseImage: "img:1", baseImagePresent: true,
                               checkedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(good.canFastPath(for: "img:1", ttl: 3600, now: now))
        XCTAssertFalse(good.canFastPath(for: "img:2", ttl: 3600, now: now), "different base image")

        let noImage = SetupStatus(tartPath: "/bin/tart", baseImage: "img:1", baseImagePresent: false,
                                  checkedAt: now)
        XCTAssertFalse(noImage.canFastPath(for: "img:1", ttl: 3600, now: now))

        let noTart = SetupStatus(tartPath: nil, baseImage: "img:1", baseImagePresent: true, checkedAt: now)
        XCTAssertFalse(noTart.canFastPath(for: "img:1", ttl: 3600, now: now))

        let stale = SetupStatus(tartPath: "/bin/tart", baseImage: "img:1", baseImagePresent: true,
                                checkedAt: now.addingTimeInterval(-99999))
        XCTAssertFalse(stale.canFastPath(for: "img:1", ttl: 3600, now: now))
    }
}

final class CarouselDeckTests: XCTestCase {
    func testCardsPresent() {
        XCTAssertEqual(CarouselDeck.cards.count, 4)
        XCTAssertEqual(CarouselDeck.cards.map(\.id), [0, 1, 2, 3])
        XCTAssertTrue(CarouselDeck.cards.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty && !$0.symbol.isEmpty })
    }

    func testNextWrapsAround() {
        XCTAssertEqual(CarouselDeck.next(after: 0), 1)
        XCTAssertEqual(CarouselDeck.next(after: 3), 0)
        XCTAssertEqual(CarouselDeck.next(after: 0, count: 0), 0, "empty deck stays put")
        XCTAssertEqual(CarouselDeck.next(after: 2, count: 3), 0)
    }
}
