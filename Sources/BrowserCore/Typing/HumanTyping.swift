import Foundation

/// Paste as Typed (⌃⌘V): text put into a page as a person types it — a key down and a key up for
/// each character, on the key a US (Latin) or Russian (Cyrillic) Mac layout has for it, with a
/// person's pauses — so a site that refuses a field filled in all at once sees typing.
///
/// This is the plan: which key, which modifiers, how long before it and how long it is held. The
/// app sends it as real key events to the page's focused field (`HumanPaste`).
public enum HumanTyping {
    /// One character typed.
    public struct Keystroke: Equatable, Sendable {
        /// What the key types.
        public var text: String
        /// The Mac's virtual key; nil: no key types it on these layouts, so it is given to the
        /// field as text input (as an input method commits it), without a key down.
        public var keyCode: UInt16?
        public var shift: Bool
        /// Seconds before the key goes down, and while it is held.
        public var pauseBefore: TimeInterval
        public var hold: TimeInterval
    }

    /// Longer text is pasted the ordinary way (it would take minutes to type).
    public static let maximumLength = 2000

    /// The keystrokes for `text`, with a person's timing: 60–180 ms between keys, longer after a
    /// space or a punctuation mark, now and then a pause to think, each key held 30–110 ms.
    public static func plan<G: RandomNumberGenerator>(_ text: String, using generator: inout G) -> [Keystroke] {
        var strokes: [Keystroke] = []
        var previous: Character?
        for character in text {
            var pause = previous == nil ? 0 : Double.random(in: 0.06...0.18, using: &generator)
            if let previous, previous == " " || previous.isPunctuation {
                pause += Double.random(in: 0.05...0.25, using: &generator)
            }
            if previous != nil, Double.random(in: 0..<1, using: &generator) < 0.03 {
                pause += Double.random(in: 0.4...1.0, using: &generator)
            }
            let hold = Double.random(in: 0.03...0.11, using: &generator)
            let key = self.key(for: character)
            strokes.append(Keystroke(text: String(character), keyCode: key?.code, shift: key?.shift ?? false,
                                     pauseBefore: pause, hold: hold))
            previous = character
        }
        return strokes
    }

    /// The key that types `character`: on a US layout, else (a Cyrillic letter) on a Russian one.
    /// New lines and tabs have none here — Return would send a form, Tab would leave the field.
    static func key(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let key = us[character] { return key }
        if let key = russian[character] { return key }
        return nil
    }

    // Virtual key codes of the Mac's ANSI keyboard (kVK_ANSI_*).
    private static let letterCodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
    ]
    /// Unshifted, shifted, code: the keys that are not letters.
    private static let symbolKeys: [(Character, Character, UInt16)] = [
        ("1", "!", 0x12), ("2", "@", 0x13), ("3", "#", 0x14), ("4", "$", 0x15), ("5", "%", 0x17), ("6", "^", 0x16),
        ("7", "&", 0x1A), ("8", "*", 0x1C), ("9", "(", 0x19), ("0", ")", 0x1D), ("-", "_", 0x1B), ("=", "+", 0x18),
        ("[", "{", 0x21), ("]", "}", 0x1E), ("\\", "|", 0x2A), (";", ":", 0x29), ("'", "\"", 0x27), (",", "<", 0x2B),
        (".", ">", 0x2F), ("/", "?", 0x2C), ("`", "~", 0x32),
    ]

    static let us: [Character: (code: UInt16, shift: Bool)] = {
        var keys: [Character: (code: UInt16, shift: Bool)] = [" ": (0x31, false)]
        for (letter, code) in letterCodes {
            keys[letter] = (code, false)
            keys[Character(letter.uppercased())] = (code, true)
        }
        for (plain, shifted, code) in symbolKeys {
            keys[plain] = (code, false)
            keys[shifted] = (code, true)
        }
        return keys
    }()

    /// The Russian layout's letters, by the key they are on (ЙЦУКЕН).
    static let russian: [Character: (code: UInt16, shift: Bool)] = {
        let layout: [(Character, Character)] = [
            ("й", "q"), ("ц", "w"), ("у", "e"), ("к", "r"), ("е", "t"), ("н", "y"), ("г", "u"), ("ш", "i"), ("щ", "o"),
            ("з", "p"), ("х", "["), ("ъ", "]"), ("ф", "a"), ("ы", "s"), ("в", "d"), ("а", "f"), ("п", "g"), ("р", "h"),
            ("о", "j"), ("л", "k"), ("д", "l"), ("ж", ";"), ("э", "'"), ("я", "z"), ("ч", "x"), ("с", "c"), ("м", "v"),
            ("и", "b"), ("т", "n"), ("ь", "m"), ("б", ","), ("ю", "."), ("ё", "`"),
        ]
        var keys: [Character: (code: UInt16, shift: Bool)] = [:]
        for (letter, latin) in layout {
            guard let code = us[latin]?.code else { continue }
            keys[letter] = (code, false)
            keys[Character(letter.uppercased())] = (code, true)
        }
        return keys
    }()
}

/// How well a command of the palette (⌘K) matches what is typed: every word of the query in the
/// title, in order, as the start of a word, anywhere in a word, or its letters in order — better
/// in that order; nil: it does not match.
public enum CommandSearch {
    public static func score(_ query: String, _ title: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let target = title.lowercased()
        let titleWords = target.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0
        for word in words {
            if titleWords.contains(where: { $0.hasPrefix(word) }) {
                total += 30
            } else if target.contains(word) {
                total += 15
            } else if isSubsequence(word, of: target) {
                total += 5
            } else {
                return nil
            }
        }
        // A shorter title is the closer match, all else equal.
        return total * 100 - min(title.count, 99)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(haystack)
        for character in needle {
            guard let index = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: index)...]
        }
        return true
    }
}
