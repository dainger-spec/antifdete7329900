import XCTest
@testable import BrowserCore

/// A profile's window size: a real window, its presets taken from Macs' screens, a random size
/// that always fits, and settings that keep it — or drop it when it cannot be a window.
final class WindowSizeTests: XCTestCase {
    /// A seeded generator (SplitMix64), so random sizes can be tested.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testAPresetIsThatMacsScreenBelowItsMenuBar() {
        XCTAssertEqual(MacScreen.allCases.map { "\($0.points.width)x\($0.points.height)" },
                       ["1470x956", "1512x982", "1710x1107", "1728x1117"])
        XCTAssertEqual(MacScreen.allCases.map(\.diagonal), ["13.6", "14.2", "15.3", "16.2"])
        let frame = WindowSize.mac(screen: .pro14).frame
        XCTAssertEqual(frame.width, 1512)
        XCTAssertEqual(frame.height, 982 - MacScreen.menuBarHeight)
        XCTAssertTrue(MacScreen.allCases.allSatisfy { WindowSize.mac(screen: $0).isValid })
    }

    func testACustomSizeIsAWindowOrNothing() {
        XCTAssertTrue(WindowSize.custom(width: 1280, height: 800).isValid)
        XCTAssertFalse(WindowSize.custom(width: 320, height: 800).isValid)
        XCTAssertFalse(WindowSize.custom(width: 1280, height: 99_999).isValid)
        XCTAssertThrowsError(try ProfileConfiguration(windowSize: .custom(width: 100, height: 100)).validate())
        XCTAssertNoThrow(try ProfileConfiguration(windowSize: .mac(screen: .air13)).validate())
    }

    func testARandomSizeAlwaysFitsAndVaries() {
        var generator = Seeded(state: 42)
        let screens = [(1470, 919), (1512, 944), (1920, 1055), (2560, 1415), (1024, 705)]
        var seen = Set<String>()
        for (width, height) in screens {
            for _ in 0..<200 {
                let size = WindowSize.randomSafe(fitting: (width, height), using: &generator)
                let frame = size.frame
                XCTAssertTrue(size.isValid, "\(frame)")
                XCTAssertGreaterThanOrEqual(frame.width, max(WindowSize.minimumWidth, width * 2 / 3))
                XCTAssertGreaterThanOrEqual(frame.height, max(WindowSize.minimumHeight, height * 2 / 3))
                if width * 9 / 10 >= WindowSize.minimumWidth { XCTAssertLessThanOrEqual(frame.width, width * 9 / 10) }
                if height * 9 / 10 >= WindowSize.minimumHeight { XCTAssertLessThanOrEqual(frame.height, height * 9 / 10) }
                seen.insert("\(frame.width)x\(frame.height)")
            }
        }
        XCTAssertGreaterThan(seen.count, 500, "profiles do not all get the same window")
    }

    func testKeptWithTheSettingsAndDroppedWhenItCannotBeAWindow() throws {
        for size in [WindowSize.mac(screen: .air15), .custom(width: 1384, height: 862)] {
            let written = try JSONCoding.encoder.encode(ProfileConfiguration(windowSize: size))
            XCTAssertEqual(try ProfileRepository.decodeConfiguration(written).windowSize, size)
        }
        let plain = String(decoding: try JSONCoding.encoder.encode(ProfileConfiguration()), as: UTF8.self)
        XCTAssertFalse(plain.contains("windowSize"), "none is written as before")
        for stored in [#"{"windowSize":{"mac":{"screen":"imac-24"}}}"#,
                       #"{"windowSize":{"custom":{"width":12,"height":34}}}"#,
                       #"{"windowSize":"big"}"#] {
            let read = try ProfileRepository.decodeConfiguration(Data(stored.utf8))
            XCTAssertNil(read.windowSize, stored)
        }
    }
}
