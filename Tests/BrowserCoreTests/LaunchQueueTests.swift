import XCTest
@testable import BrowserCore

final class LaunchQueueTests: XCTestCase {
    /// What a run of the queue did: the order profiles were started in, and the most that were
    /// started at a time with their window not up yet.
    @MainActor
    private final class Record {
        var started: [Int] = []
        var starting = 0
        var most = 0
        var up: [Int] = []
    }

    /// Windows that come up after different times: never more than four starting at a time, four
    /// at the start, every profile started in its order and waited for.
    @MainActor
    func testAtMostFourStartAtATime() async {
        let record = Record()
        await LaunchQueue.run(Array(0..<11), start: { id in
            record.started.append(id)
            record.starting += 1
            record.most = max(record.most, record.starting)
        }, windowUp: { id in
            try? await Task.sleep(nanoseconds: UInt64(5 + (id * 7) % 4 * 6) * 1_000_000)
            record.starting -= 1
            record.up.append(id)
        })
        XCTAssertEqual(record.started, Array(0..<11))
        XCTAssertEqual(record.most, LaunchQueue.atOnce)
        XCTAssertEqual(record.up.sorted(), Array(0..<11))
        XCTAssertEqual(record.starting, 0)
    }

    /// One at a time is one after the other: each started once the one before it is up.
    @MainActor
    func testOneAtATimeWaitsForEachWindow() async {
        let record = Record()
        await LaunchQueue.run(Array(0..<5), atOnce: 1, start: { id in
            XCTAssertEqual(record.up, Array(0..<id), "started before the window before it was up")
            record.started.append(id)
        }, windowUp: { id in
            try? await Task.sleep(nanoseconds: 2_000_000)
            record.up.append(id)
        })
        XCTAssertEqual(record.started, Array(0..<5))
    }

    /// Nothing more is started once the queue is told to stop (the vault locked meanwhile); those
    /// started are still waited for.
    @MainActor
    func testStopsStartingWhenToldTo() async {
        let record = Record()
        await LaunchQueue.run(Array(0..<10), goesOn: { record.started.count < 6 }, start: { id in
            record.started.append(id)
        }, windowUp: { id in
            try? await Task.sleep(nanoseconds: 1_000_000)
            record.up.append(id)
        })
        XCTAssertEqual(record.started, Array(0..<6))
        XCTAssertEqual(record.up.sorted(), Array(0..<6))
    }
}
