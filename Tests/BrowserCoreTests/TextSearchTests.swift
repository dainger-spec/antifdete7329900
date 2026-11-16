import XCTest
@testable import BrowserCore

/// The search over the app's own texts (Settings, Help): what a person types finds the text that
/// holds it, and a sentence that merely has the same letters somewhere is not found.
final class TextSearchTests: XCTestCase {
    func testAWordIsFoundAtTheStartOfAWordAndInsideOne() {
        XCTAssertEqual(TextSearch.score("zoom", in: "Page zoom"), 4)
        XCTAssertEqual(TextSearch.score("ZOOM", in: "page zoom"), 4, "case is ignored")
        XCTAssertEqual(TextSearch.score("fill", in: "Password AutoFill"), 2, "inside a word")
        XCTAssertNil(TextSearch.score("fi", in: "Password AutoFill"), "two letters inside a word are not a match")
        XCTAssertNil(TextSearch.score("rtc", in: "Keyboard Shortcuts"), "nor three: they are in too many words by chance")
        XCTAssertEqual(TextSearch.score("pa", in: "Password AutoFill"), 4, "two letters at a word's start are")
    }

    func testASentenceIsSearchedByItsWordsStartsAlone() {
        let sentence = "Lumen's system extension is a content filter"
        XCTAssertEqual(TextSearch.score("tens", in: sentence), 2, "a name is searched inside its words")
        XCTAssertNil(TextSearch.score("tens", in: sentence, insideWords: false))
        XCTAssertEqual(TextSearch.score("exten", in: sentence, insideWords: false), 4)
        // «темн» is inside «системное»: not what was looked for.
        XCTAssertNil(TextSearch.score("тёмн", in: "Системное расширение Lumen", insideWords: false))
    }

    func testEveryWordTypedMustBeThere() {
        XCTAssertEqual(TextSearch.score("download folder", in: "Save downloads to a folder"), 8)
        XCTAssertNil(TextSearch.score("download proxy", in: "Save downloads to a folder"))
    }

    func testLettersInOrderAreNotAMatch() {
        // The palette's match would take this ("p…r…x…y" in order); a description's would be found
        // in every page.
        XCTAssertNil(TextSearch.score("prxy", in: "What happens with a proxy that does not work"))
        XCTAssertNil(TextSearch.score("zoom", in: "Closing a window with more than one tab asks first"))
    }

    func testAnotherFormOfTheWordFindsIt() {
        XCTAssertEqual(TextSearch.score("updated", in: "Check for updates automatically"), 1)
        XCTAssertEqual(TextSearch.score("updates", in: "An update is ready"), 1)
        XCTAssertEqual(TextSearch.score("загрузок", in: "Сохранять загрузки в"), 1)
        XCTAssertEqual(TextSearch.score("паролей", in: "Автозаполнение паролей"), 4)
        XCTAssertNil(TextSearch.score("прокси", in: "Сохранять загрузки в"))
        // A short word is not cut: "tabs" does not become "ta", nor "driver" "driv" (a drive).
        XCTAssertNil(TextSearch.score("tabs", in: "The table of contents"))
        XCTAssertNil(TextSearch.score("driver", in: "A network drive or a disk"))
    }

    func testRussianIsFoundWhateverTheCaseAndTheLetterYo() {
        XCTAssertEqual(TextSearch.score("МАСШТАБ", in: "Масштаб страниц"), 4)
        XCTAssertEqual(TextSearch.score("отчет", in: "Скопировать краткий отчёт"), 4)
        XCTAssertEqual(TextSearch.score("отчёт", in: "Краткий отчет"), 4)
        XCTAssertEqual(TextSearch.score("пароль", in: "Мастер-пароль"), 4, "a hyphen parts two words")
    }

    func testNothingTypedFindsNothing() {
        XCTAssertNil(TextSearch.score("", in: "Anything"))
        XCTAssertNil(TextSearch.score("  — ", in: "Anything"))
        XCTAssertFalse(TextSearch.finds("", in: "Anything"))
        XCTAssertTrue(TextSearch.finds("any", in: "Anything"))
    }

    func testWords() {
        XCTAssertEqual(TextSearch.words("⌘K — the Command palette, v2"), ["k", "the", "command", "palette", "v2"])
    }
}
