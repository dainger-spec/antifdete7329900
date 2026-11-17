import Foundation

/// Finding a text by what a person types into a search field over the app's own texts — the
/// Settings window's search over its settings, Help's over its pages.
///
/// Stricter than the command palette's match (`CommandSearch`), which also takes a word's letters
/// in order: a setting's description is a sentence or three, and letters in order are found in
/// nearly every one of them. Here every word typed must be in the text: as the start of a word,
/// inside a word (four letters or more: "fill" in "AutoFill", "driver" in "WebDriver" — in a name;
/// a sentence is searched by its words' starts alone, or «темн» would find «системное»), or — for a
/// word of seven letters or more — by all but its last two, so that another form of the same word
/// finds it ("updates" finds "update", «загрузок» finds «загрузки»). Case is ignored, and «ё» is «е».
public enum TextSearch {
    /// The words of `text`, lowercased: runs of letters and digits.
    public static func words(_ text: String) -> [String] {
        folded(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// How well `text` answers `query`; nil: a word of the query is not in it, or nothing was
    /// typed. A word that starts a word of the text counts 4, one inside a word 2 (`insideWords`:
    /// for a name or a title, not for sentences), one found by its stem 1.
    public static func score(_ query: String, in text: String, insideWords: Bool = true) -> Int? {
        let wanted = words(query)
        guard !wanted.isEmpty else { return nil }
        let present = words(text)
        var total = 0
        for word in wanted {
            guard let found = score(ofWord: word, in: present, insideWords: insideWords) else { return nil }
            total += found
        }
        return total
    }

    /// True when `text` answers `query` at all.
    public static func finds(_ query: String, in text: String) -> Bool {
        score(query, in: text) != nil
    }

    private static func score(ofWord word: String, in present: [String], insideWords: Bool) -> Int? {
        if present.contains(where: { $0.hasPrefix(word) }) { return 4 }
        if insideWords, word.count >= 4, present.contains(where: { $0.contains(word) }) { return 2 }
        if word.count >= 7 {
            let stem = String(word.dropLast(2))
            if present.contains(where: { $0.hasPrefix(stem) }) { return 1 }
        }
        return nil
    }

    private static func folded(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
