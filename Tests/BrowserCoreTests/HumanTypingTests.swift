import XCTest
@testable import BrowserCore

/// Paste as Typed: each character on its key, with a person's timing; and the palette's search.
final class HumanTypingTests: XCTestCase {
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

    func testEachCharacterOnItsKey() {
        var generator = Seeded(state: 1)
        let plan = HumanTyping.plan("Hi, Мир 1!\n", using: &generator)
        XCTAssertEqual(plan.map(\.text).joined(), "Hi, Мир 1!\n")
        XCTAssertEqual(plan[0].keyCode, 0x04)
        XCTAssertTrue(plan[0].shift)
        XCTAssertEqual(plan[1].keyCode, 0x22)
        XCTAssertEqual(plan[2].keyCode, 0x2B, "a comma on its own key")
        XCTAssertEqual(plan[3].keyCode, 0x31, "space")
        XCTAssertEqual(plan[4].keyCode, 0x09, "М is on V's key")
        XCTAssertTrue(plan[4].shift)
        XCTAssertEqual(plan[5].keyCode, 0x0B, "и is on B's key")
        XCTAssertEqual(plan[6].keyCode, 0x04, "р is on H's key")
        XCTAssertEqual(plan[8].keyCode, 0x12)
        XCTAssertEqual(plan[9].keyCode, 0x12, "! is Shift-1")
        XCTAssertTrue(plan[9].shift)
        XCTAssertNil(plan[10].keyCode, "a new line has no key here: Return would send a form")
        XCTAssertNil(HumanTyping.plan("中", using: &generator)[0].keyCode, "typed as text input")
    }

    func testAPersonsTiming() {
        var generator = Seeded(state: 9)
        let plan = HumanTyping.plan(String(repeating: "lorem ipsum, dolor sit amet. ", count: 20), using: &generator)
        XCTAssertEqual(plan[0].pauseBefore, 0)
        for stroke in plan.dropFirst() {
            XCTAssertGreaterThanOrEqual(stroke.pauseBefore, 0.06)
            XCTAssertLessThanOrEqual(stroke.pauseBefore, 1.43, "0.18 between keys, 0.25 after a mark, 1.0 to think")
            XCTAssertTrue((0.03...0.11).contains(stroke.hold))
        }
        let pauses = plan.dropFirst().map(\.pauseBefore)
        XCTAssertGreaterThan(Set(pauses.map { Int($0 * 1000) }).count, 100, "no two people type with one rhythm")
        let average = pauses.reduce(0, +) / Double(pauses.count)
        XCTAssertTrue((0.1...0.3).contains(average), "about four to ten keys a second: \(average)")
    }

    func testThePalettesSearch() {
        XCTAssertNotNil(CommandSearch.score("north", "Launch Northwind"))
        XCTAssertNotNil(CommandSearch.score("ln nw", "Launch Northwind"), "letters in order")
        XCTAssertNil(CommandSearch.score("zzz", "Launch Northwind"))
        let start = CommandSearch.score("set", "Settings: Startup") ?? 0
        let inside = CommandSearch.score("set", "Reset the window size") ?? 0
        XCTAssertGreaterThan(start, inside, "the start of a word first")
        XCTAssertEqual(CommandSearch.score("", "Anything"), 0)
        XCTAssertNotNil(CommandSearch.score("прокси", "Проверить все прокси"))
    }
}
