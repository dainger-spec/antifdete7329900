import Foundation

/// A scenario's text read as steps (docs/AUTOMATION.md, "Steps"): the editor shows them beside the
/// code, and the run's table names the step a run failed at.
///
/// Nothing is parsed "into" a model and written "back". The text is cut into whole lines — a
/// lossless partition: the pieces joined are the text, byte for byte — and each piece that is a
/// statement is a step. A step of a known one-line shape (`await page.click('#buy');`) is read
/// for its words; any other is a step "own code", shown as it is. Every change a person makes in
/// the steps is a move, a removal or a rewrite of whole lines, so what is not understood is
/// never touched. A text that cannot be cut safely (a bracket left open) is one step: the code.
public struct ScenarioSteps: Equatable, Sendable {
    /// What a command is given: text written out, one of the scenario's settings (a `const` of
    /// its head), a profile's own value (`params.name`), or anything else, as it is written.
    public enum Argument: Equatable, Sendable {
        case text(String)
        case setting(String)
        case profile(String)
        case raw(String)

        /// As the scenario's line has it.
        public var code: String {
            switch self {
            case .text(let text): return ScenarioRecording.quoted(text)
            case .setting(let name): return name
            case .profile(let name): return "params.\(name) || ''"
            case .raw(let code): return code
            }
        }
    }

    public enum Kind: String, Equatable, Sendable {
        case open, click, type, press, waitFor, waitLoad, waitURL, scroll, pause, select, hover, result, log
        /// `for (let i = 0; i < N; i++) { … }`: its steps, so many times.
        case repeatTimes
        /// `if (await page.isVisible(…)) { … }`: its steps, when the element shows.
        case ifVisible
        /// Anything else: shown as the code it is.
        case code
    }

    public struct Step: Equatable, Sendable {
        public var kind: Kind
        /// The comment above the statement, which names the step in the person's words.
        public var title: String?
        public var arguments: [Argument]
        /// Switched off: its lines are comments (`//- `) until it is switched on again.
        public var isOff: Bool
        /// The statement's code, without the comment above it (and without the marks of one switched off).
        public var code: String
        /// The lines it takes in the scenario, from 1: an error's "(line N)" finds its step by them.
        public var lines: ClosedRange<Int>
        /// The steps inside a block.
        public var children: [Step]

        public func contains(line: Int) -> Bool { lines.contains(line) }
    }

    /// A piece of the text: a step, or what lies between steps (empty lines, a comment that
    /// stands alone, the settings at the head).
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var step: Step?
    }

    public private(set) var pieces: [Piece]
    /// False: the text could not be cut safely, and is one step of its own code.
    public private(set) var isCut: Bool

    public var steps: [Step] { pieces.compactMap(\.step) }
    public var source: String { pieces.map(\.text).joined() }

    /// The mark of a line of a step that is switched off.
    public static let offMark = "//- "

    /// How deep blocks (and steps switched off within steps switched off) are read for the steps
    /// inside them; one deeper is a step of its own code. Each level reads its lines once more, so
    /// a text from outside nested thousands deep is read in a moment, not for minutes.
    public static let maximumDepth = 16

    public init(_ source: String) {
        let lines = Self.lines(of: source)
        if let pieces = Self.cut(lines, firstLine: 1) {
            self.pieces = pieces
            isCut = true
        } else {
            let step = Step(kind: .code, title: nil, arguments: [], isOff: false, code: source, lines: 1...max(1, lines.count), children: [])
            pieces = source.isEmpty ? [] : [Piece(text: source, step: step)]
            isCut = false
        }
    }

    /// The step an error's line is in — a block's inner step before the block; nil when the line
    /// is no step's.
    public func step(atLine line: Int) -> (index: Int, step: Step)? {
        for (index, step) in steps.enumerated() where step.contains(line: line) { return (index, step) }
        return nil
    }

    // MARK: Changes: whole lines only

    /// The step at `index` (among the steps) before the one at `destination`, or last.
    public func moving(_ index: Int, to destination: Int) -> ScenarioSteps {
        let places = stepPlaces
        guard isCut, places.indices.contains(index), destination >= 0, destination <= places.count, destination != index, destination != index + 1 else { return self }
        var list = closed
        let piece = list.remove(at: places[index])
        let target: Int
        if destination >= places.count {
            target = list.count
        } else {
            let place = places[destination]
            target = place > places[index] ? place - 1 : place
        }
        list.insert(piece, at: target)
        return ScenarioSteps(list.map(\.text).joined())
    }

    public func removing(_ index: Int) -> ScenarioSteps {
        let places = stepPlaces
        guard isCut, places.indices.contains(index) else { return self }
        var list = closed
        list.remove(at: places[index])
        return ScenarioSteps(list.map(\.text).joined())
    }

    /// Switches the step off (its lines become comments with `offMark`) or on again.
    public func toggling(_ index: Int) -> ScenarioSteps {
        let places = stepPlaces
        guard isCut, places.indices.contains(index), let step = pieces[places[index]].step else { return self }
        var list = closed
        let lines = Self.lines(of: list[places[index]].text)
        let changed: [String] = lines.map { line in
            if step.isOff {
                guard let range = line.range(of: Self.offMark), line[line.startIndex..<range.lowerBound].allSatisfy({ $0 == " " || $0 == "\t" }) else { return line }
                return String(line[line.startIndex..<range.lowerBound]) + String(line[range.upperBound...])
            }
            let body = line.drop { $0 == " " || $0 == "\t" }
            return String(line.prefix(line.count - body.count)) + Self.offMark + String(body)
        }
        list[places[index]].text = changed.joined()
        return ScenarioSteps(list.map(\.text).joined())
    }

    /// `code` (whole lines) after the step at `index`; nil: at the end.
    public func inserting(_ code: String, after index: Int?) -> ScenarioSteps {
        let ending = preferredLineEnding
        let text = Self.lineEnding(of: code).isEmpty ? code + ending : code
        guard isCut else { return ScenarioSteps((source.isEmpty || !Self.lineEnding(of: source).isEmpty ? source : source + ending) + text) }
        var list = closed
        let places = stepPlaces
        if let index, places.indices.contains(index) {
            list.insert(Piece(text: text, step: nil), at: places[index] + 1)
        } else {
            list.append(Piece(text: text, step: nil))
        }
        return ScenarioSteps(list.map(\.text).joined())
    }

    /// The statement of the step at `index` written anew (`statement`: one line of code); its
    /// title and its indentation stay.
    public func rewriting(_ index: Int, statement: String) -> ScenarioSteps {
        let places = stepPlaces
        guard isCut, places.indices.contains(index), let step = pieces[places[index]].step, !step.isOff else { return self }
        var list = closed
        let lines = Self.lines(of: list[places[index]].text)
        let titleCount = lines.prefix { Self.isComment($0) }.count
        let indent = lines.dropFirst(titleCount).first.map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? ""
        list[places[index]].text = lines.prefix(titleCount).joined() + indent + statement + Self.lineEnding(of: list[places[index]].text)
        return ScenarioSteps(list.map(\.text).joined())
    }

    /// Preserve the recorder's select-all gesture and any inline note when a field is edited.
    public static func statement(editing step: Step, arguments: [Argument]) -> String? {
        guard var updated = statement(step.kind, arguments) else { return nil }
        let parts = split(step.code)
        if step.kind == .type, trimmed(parts.code).hasPrefix("await page.click(") {
            guard let oldField = step.arguments.first, let newField = arguments.first,
                  let oldType = statement(.type, step.arguments) else { return nil }
            func selectAll(_ field: Argument) -> String { "await page.click(\(field.code)); await page.press('Meta+a'); " }
            guard trimmed(parts.code) == selectAll(oldField) + oldType else { return nil }
            updated = selectAll(newField) + updated
        }
        let comment = trimmed(parts.rest)
        return comment.isEmpty ? updated : updated + " " + comment
    }

    /// The line of a command, as the recorder writes them.
    public static func statement(_ kind: Kind, _ arguments: [Argument]) -> String? {
        func argument(_ index: Int) -> String { arguments.indices.contains(index) ? arguments[index].code : "''" }
        switch kind {
        case .open: return "await page.goto(\(argument(0)));"
        case .click: return "await page.click(\(argument(0)));"
        case .hover: return "await page.hover(\(argument(0)));"
        case .type: return "await page.type(\(argument(0)), \(argument(1)));"
        case .press: return "await page.press(\(argument(0)));"
        case .waitFor: return arguments.count > 1 ? "await page.waitFor(\(argument(0)), { timeout: \(argument(1)) });" : "await page.waitFor(\(argument(0)));"
        case .waitLoad: return "await page.waitForLoadState();"
        case .waitURL: return "await page.waitForURL(\(argument(0)));"
        case .scroll: return "await page.scroll(\(arguments.first?.code ?? "600"));"
        case .pause: return "await sleep(\(arguments.first?.code ?? "1000"));"
        case .select: return "await page.selectOption(\(argument(0)), \(argument(1)));"
        case .result: return "return \(argument(0));"
        case .log: return "log(\(argument(0)));"
        case .repeatTimes, .ifVisible, .code: return nil
        }
    }

    // MARK: The cut

    /// Where each step is among the pieces.
    private var stepPlaces: [Int] { pieces.indices.filter { pieces[$0].step != nil } }

    fileprivate static func lineEnding(of text: String) -> String {
        guard let last = text.last, isLineEnding(last) else { return "" }
        return String(last)
    }

    private static func isLineEnding(_ character: Character) -> Bool {
        // JavaScript has four line terminators. Swift treats CRLF as one Character.
        switch character {
        case "\n", "\r\n", "\r", "\u{2028}", "\u{2029}": return true
        default: return false
        }
    }

    private var preferredLineEnding: String {
        pieces.lazy.map { Self.lineEnding(of: $0.text) }.first { !$0.isEmpty } ?? "\n"
    }

    /// The pieces, each ending its line: the last may not (a text without a newline at its end).
    private var closed: [Piece] {
        var list = pieces
        if let last = list.indices.last, Self.lineEnding(of: list[last].text).isEmpty { list[last].text += preferredLineEnding }
        return list
    }

    /// The text's lines, each with its newline (the last without, when the text has none there).
    static func lines(of source: String) -> [String] {
        var lines: [String] = []
        var start = source.startIndex
        for index in source.indices where isLineEnding(source[index]) {
            let end = source.index(after: index)
            lines.append(String(source[start..<end]))
            start = end
        }
        if start < source.endIndex { lines.append(String(source[start...])) }
        return lines
    }

    private static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    /// The text with its comments blanked out — and, with `blankingTexts`, the insides of its
    /// quoted texts (a template's `${…}` stays code) — each character a space: its line breaks are
    /// kept, and as many UTF-16 units as it had, so an offset in it is the same place in the text.
    /// What the import's review reads for what the code does (`ScenarioValues.readsByBuiltNames`,
    /// `ScenarioFile.buildsAddresses`). One pass. A regular expression's literal is not known: a
    /// quote in one is read as a text's beginning, which ends with the line.
    static func withoutComments(_ source: String, blankingTexts: Bool = false) -> String {
        let scalars = Array(source.unicodeScalars)
        let space: Unicode.Scalar = " "
        var out = String.UnicodeScalarView()
        func blank(_ scalar: Unicode.Scalar) {
            if isLineTerminator(scalar) {
                out.append(scalar)
                return
            }
            out.append(space)
            if scalar.value > 0xFFFF { out.append(space) }
        }
        var quote: Unicode.Scalar?
        var escaped = false
        var inTemplate = false
        // The brace depth each open template's `${` began at.
        var templates: [Int] = []
        var depth = 0
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            index += 1
            if let open = quote {
                if escaped {
                    escaped = scalar == "\r" && next == "\n"
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == open || scalar == "\n" || scalar == "\r" {
                    quote = nil
                    out.append(scalar)
                    continue
                }
                if blankingTexts { blank(scalar) } else { out.append(scalar) }
                continue
            }
            if inTemplate {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "`" {
                    inTemplate = false
                    out.append(scalar)
                    continue
                } else if scalar == "$", next == "{" {
                    inTemplate = false
                    templates.append(depth)
                    depth += 1
                    out.append(scalar)
                    out.append("{")
                    index += 1
                    continue
                }
                if blankingTexts { blank(scalar) } else { out.append(scalar) }
                continue
            }
            if scalar == "/", next == "/" {
                blank(scalar)
                while index < scalars.count, !isLineTerminator(scalars[index]) {
                    blank(scalars[index])
                    index += 1
                }
                continue
            }
            if scalar == "/", next == "*" {
                blank(scalar)
                blank(space)
                index += 1
                while index < scalars.count, !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") {
                    blank(scalars[index])
                    index += 1
                }
                if index < scalars.count {
                    blank(space)
                    blank(space)
                    index += 2
                }
                continue
            }
            out.append(scalar)
            switch scalar {
            case "'", "\"": quote = scalar
            case "`": inTemplate = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if let began = templates.last, began == depth {
                    templates.removeLast()
                    inTemplate = true
                }
            default: break
            }
        }
        return String(out)
    }

    private static func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func isComment(_ line: String) -> Bool { trimmed(line).hasPrefix("//") }
    private static func isOff(_ line: String) -> Bool { trimmed(line).hasPrefix("//-") }

    /// What a line leaves open for the next: brackets, a template's text, a comment in `/* */`.
    private struct Scan {
        var depth = 0
        var inBlockComment = false
        /// The brace depth each open template's `${` began at; a template's own text is on top
        /// when `inTemplate`.
        var templates: [Int] = []
        var inTemplate = false
        /// The last character of code on the line (not a comment's, not a space).
        var last: Unicode.Scalar?
        var isOpen: Bool { depth != 0 || inBlockComment || inTemplate || !templates.isEmpty }

        mutating func take(_ line: String) {
            last = nil
            var quote: Unicode.Scalar?
            var escaped = false
            let scalars = Array(line.unicodeScalars)
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
                defer { index += 1 }
                if inBlockComment {
                    if scalar == "*", next == "/" { inBlockComment = false; index += 1 }
                    continue
                }
                if let open = quote {
                    if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == open { quote = nil }
                    last = scalar
                    continue
                }
                if inTemplate {
                    if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "`" {
                        inTemplate = false
                    } else if scalar == "$", next == "{" {
                        inTemplate = false
                        templates.append(depth)
                        depth += 1
                        index += 1
                    }
                    last = scalar
                    continue
                }
                if scalar == "/", next == "/" { break }
                if scalar == "/", next == "*" { inBlockComment = true; index += 1; continue }
                if scalar == " " || scalar == "\t" || isLineTerminator(scalar) { continue }
                last = scalar
                switch scalar {
                case "'", "\"": quote = scalar
                case "`": inTemplate = true
                case "(", "[", "{": depth += 1
                case ")", "]": depth -= 1
                case "}":
                    depth -= 1
                    if let began = templates.last, began == depth {
                        templates.removeLast()
                        inTemplate = true
                    }
                default: break
                }
            }
            // A quoted text ends with its line (one continued with `\` is not cut apart: `escaped`).
            if quote != nil, escaped { depth += 1_000 }
        }
    }

    /// The lines as pieces; nil when they cannot be cut safely, or lie deeper than `maximumDepth`.
    private static func cut(_ lines: [String], firstLine: Int, depth: Int = 0) -> [Piece]? {
        guard depth <= maximumDepth else { return nil }
        var pieces: [Piece] = []
        var index = 0
        while index < lines.count {
            // A gap: empty lines.
            if trimmed(lines[index]).isEmpty {
                pieces.append(Piece(text: lines[index], step: nil))
                index += 1
                continue
            }
            // A step switched off: its marked lines.
            if isOff(lines[index]) {
                var end = index
                while end + 1 < lines.count, isOff(lines[end + 1]) { end += 1 }
                let text = lines[index...end].joined()
                let inner = lines[index...end].map { line -> String in
                    guard let range = line.range(of: offMark) else { return line.replacingOccurrences(of: "//-", with: "") }
                    return String(line[line.startIndex..<range.lowerBound]) + String(line[range.upperBound...])
                }
                var step = (cut(inner, firstLine: firstLine + index, depth: depth + 1)?.compactMap(\.step).first)
                    ?? Step(kind: .code, title: nil, arguments: [], isOff: true, code: inner.joined(), lines: (firstLine + index)...(firstLine + end), children: [])
                step.isOff = true
                step.lines = (firstLine + index)...(firstLine + end)
                pieces.append(Piece(text: text, step: step))
                index = end + 1
                continue
            }
            // Comments, then a statement: the comments are its title. Comments alone are a gap.
            let start = index
            while index < lines.count, isComment(lines[index]), !isOff(lines[index]) { index += 1 }
            if index >= lines.count || trimmed(lines[index]).isEmpty || isOff(lines[index]) {
                pieces.append(Piece(text: lines[start..<index].joined(), step: nil))
                continue
            }
            let codeStart = index
            var scan = Scan()
            var ended = false
            while index < lines.count {
                scan.take(lines[index])
                index += 1
                guard !scan.isOpen else { continue }
                // A comment inside a statement that goes on, or a line that ends nothing yet.
                guard let last = scan.last else { continue }
                guard last == ";" || last == "}" else { continue }
                // `} else {`, `} catch`, a chain's next `.call()` on the line after: the same statement.
                if index < lines.count {
                    let next = trimmed(lines[index])
                    if next.hasPrefix("else") || next.hasPrefix("catch") || next.hasPrefix("finally") || next.hasPrefix(".") || next.hasPrefix("?") || next.hasPrefix(":") { continue }
                }
                ended = true
                break
            }
            guard ended || !scan.isOpen else { return nil }
            let codeLines = Array(lines[codeStart..<index])
            // A setting of the head (`const NAME = …;`) is not a step: the form above the steps has it.
            if codeLines.count == 1, ScenarioSettings.setting(inLine: codeLines[0]) != nil {
                pieces.append(Piece(text: lines[start..<index].joined(), step: nil))
                continue
            }
            let title = lines[start..<codeStart].map { line -> String in
                var text = trimmed(line)
                text.removeFirst(2)
                return text.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }.joined(separator: " ")
            var step = read(codeLines, firstLine: firstLine + codeStart, depth: depth)
            step.title = title.isEmpty ? nil : title
            step.lines = (firstLine + start)...(firstLine + index - 1)
            pieces.append(Piece(text: lines[start..<index].joined(), step: step))
        }
        return pieces
    }

    // MARK: Reading a statement

    /// `depth`: the cut's the statement is in.
    private static func read(_ codeLines: [String], firstLine: Int, depth: Int) -> Step {
        let code = codeLines.joined()
        var step = Step(kind: .code, title: nil, arguments: [], isOff: false, code: code, lines: firstLine...(firstLine + codeLines.count - 1), children: [])
        // A comment at the line's end (the recorder's note beside a password) is not the command's.
        let text = trimmed(split(code).code)
        if codeLines.count == 1 {
            if let (kind, arguments) = command(text) {
                step.kind = kind
                step.arguments = arguments
            }
            return step
        }
        // A block of one of the two shapes, its body cut again — one level deeper. Any other block
        // is its own code, and is not cut again: its lines are read once.
        let head = trimmed(codeLines[0])
        guard trimmed(codeLines[codeLines.count - 1]) == "}", head.hasSuffix("{") else { return step }
        let kind: Kind, given: String
        if let match = firstMatch(#"^for \(let (\w+) = 0; \1 < ([^;]+); \1\+\+\) \{$"#, head), match.count == 3 {
            (kind, given) = (.repeatTimes, match[2])
        } else if let match = firstMatch(#"^if \(await page\.isVisible\((.+)\)\) \{$"#, head), match.count == 2 {
            (kind, given) = (.ifVisible, match[1])
        } else {
            return step
        }
        let body = Array(codeLines[1..<(codeLines.count - 1)])
        guard let inner = cut(body, firstLine: firstLine + 1, depth: depth + 1) else { return step }
        step.kind = kind
        step.arguments = [argument(given)]
        step.children = inner.compactMap(\.step)
        return step
    }

    /// A one-line command and what it is given; nil for any other line.
    static func command(_ text: String) -> (Kind, [Argument])? {
        // The recorder's "type over what was there": a click, select all, then the typing. Found
        // by its first joint, not by a pattern that tries every one (a long line of them took minutes).
        let click = "await page.click(", joint = "); await page.press('Meta+a'); await page.type("
        if text.count > click.count + 2, text.hasPrefix(click), text.hasSuffix(");") {
            // What is clicked is one character at least; what is typed too, before the last `);`.
            let selector = text.index(text.startIndex, offsetBy: click.count + 1)
            let end = text.index(text.endIndex, offsetBy: -2)
            if selector < end, let middle = text.range(of: joint, range: selector..<text.endIndex), middle.upperBound < end,
               let parts = arguments(String(text[middle.upperBound..<end])), parts.count == 2 {
                return (.type, parts)
            }
        }
        let shapes: [(String, Kind, Int)] = [
            (#"^await page\.goto\((.+)\);$"#, .open, 1), (#"^await page\.click\((.+)\);$"#, .click, 1),
            (#"^await page\.hover\((.+)\);$"#, .hover, 1), (#"^await page\.type\((.+)\);$"#, .type, 2),
            (#"^await page\.press\((.+)\);$"#, .press, 1), (#"^await page\.waitForLoadState\(\s*\);$"#, .waitLoad, 0),
            (#"^await page\.waitForURL\((.+)\);$"#, .waitURL, 1), (#"^await page\.scroll\((.+)\);$"#, .scroll, 1),
            (#"^await sleep\((.+)\);$"#, .pause, 1), (#"^await page\.selectOption\((.+)\);$"#, .select, 2),
            (#"^return (.+);$"#, .result, 1), (#"^log\((.+)\);$"#, .log, 1),
        ]
        if let match = firstMatch(#"^await page\.waitFor\((.+?)(?:, \{ ?timeout: ?([^,}]+?) ?\})?\);$"#, text), match.count >= 2 {
            guard let parts = arguments(match[1]), parts.count == 1 else { return nil }
            return (.waitFor, match.count > 2 && !match[2].isEmpty ? parts + [argument(match[2])] : parts)
        }
        for (pattern, kind, count) in shapes {
            guard let match = firstMatch(pattern, text) else { continue }
            if count == 0 { return (kind, []) }
            // `return` and `log` take what is written, whatever it is.
            if kind == .result || kind == .log { return (kind, [argument(match[1])]) }
            guard let parts = arguments(match[1]), parts.count == count else { return nil }
            return (kind, parts)
        }
        return nil
    }

    /// A line as its code and what follows it: the code ends before a `//` that is not inside a
    /// quoted text. `statementEnd`: the code ends at its first `;` outside quotes and brackets.
    static func split(_ line: String, atStatementEnd: Bool = false) -> (code: String, rest: String) {
        var quote: Character?
        var escaped = false
        var depth = 0
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                depth -= 1
            } else if atStatementEnd, character == ";", depth == 0 {
                let after = line.index(after: index)
                return (String(line[line.startIndex..<after]), String(line[after...]))
            } else if character == "/", previous == "/" {
                let slash = line.index(before: index)
                return (String(line[line.startIndex..<slash]), String(line[slash...]))
            }
            previous = quote == nil ? character : nil
            index = line.index(after: index)
        }
        return (line, "")
    }

    /// What is between a call's brackets, cut at the commas that are not inside a text or a
    /// bracket; nil when it does not end where it should (more than one statement on the line).
    static func arguments(_ text: String) -> [Argument]? {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                current.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"", "`":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                guard depth >= 0 else { return nil }
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            case ";" where depth == 0:
                return nil
            default:
                current.append(character)
            }
        }
        guard quote == nil, depth == 0 else { return nil }
        parts.append(current)
        return parts.map { argument($0) }
    }

    static func argument(_ code: String) -> Argument {
        let text = code.trimmingCharacters(in: .whitespaces)
        if let value = ScenarioSettings.unquoted(text) { return .text(value) }
        if let match = firstMatch(#"^params\.([A-Za-z_][A-Za-z0-9_]*)(?: \|\| '')?$"#, text), match.count == 2 { return .profile(match[1]) }
        if firstMatch(#"^[A-Z][A-Z0-9_]*$"#, text) != nil { return .setting(text) }
        return .raw(text)
    }

    /// The whole match and its groups (an unmatched group is empty); nil when there is none.
    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: whole.length)) else { return nil }
        return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : whole.substring(with: match.range(at: $0)) }
    }
}

/// A scenario's settings: the `const NAME = value; // what it is` lines at its head, before its
/// first step. A template's form writes them, the editor shows them as fields above the steps,
/// and any scenario written that way gets the same form — the code stays what is true.
public struct ScenarioSettings: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case text(String)
        case number(Double)
        case flag(Bool)
        /// Lines of text: `['one', 'two']`.
        case list([String])

        public var code: String {
            switch self {
            case .text(let text): return ScenarioRecording.quoted(text)
            case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
            case .flag(let flag): return flag ? "true" : "false"
            case .list(let items): return "[" + items.map { ScenarioRecording.quoted($0) }.joined(separator: ", ") + "]"
            }
        }
    }

    public struct Setting: Equatable, Sendable {
        public var name: String
        public var value: Value
        /// The comment at the line's end: what the setting is, in the person's words.
        public var label: String
        /// The line it is on, from 1.
        public var line: Int
    }

    public private(set) var settings: [Setting]

    public init(_ source: String) {
        var found: [Setting] = []
        for (index, line) in ScenarioSteps.lines(of: source).enumerated() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || (text.hasPrefix("//") && !text.hasPrefix("//-")) { continue }
            guard var setting = Self.setting(inLine: line) else { break }
            setting.line = index + 1
            found.append(setting)
        }
        settings = found
    }

    public func value(of name: String) -> Value? { settings.first { $0.name == name }?.value }

    /// The text with the setting `name` given `value`; as it was when there is no such setting.
    public static func setting(_ name: String, to value: Value, in source: String) -> String {
        var lines = ScenarioSteps.lines(of: source)
        guard let setting = ScenarioSettings(source).settings.first(where: { $0.name == name }), lines.indices.contains(setting.line - 1) else { return source }
        let line = lines[setting.line - 1]
        let ending = ScenarioSteps.lineEnding(of: line)
        lines[setting.line - 1] = "const \(name) = \(value.code);" + (setting.label.isEmpty ? "" : " // \(setting.label)") + ending
        return lines.joined()
    }

    /// The setting a line is, if it is one.
    static func setting(inLine line: String) -> Setting? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = ScenarioSteps.firstMatch(#"^const ([A-Z][A-Z0-9_]*) = (.+)$"#, text), match.count == 3 else { return nil }
        // The value ends at its own `;` — one inside its text is the text's.
        let parts = ScenarioSteps.split(match[2], atStatementEnd: true)
        guard parts.code.hasSuffix(";"), let value = value(String(parts.code.dropLast())) else { return nil }
        let rest = parts.rest.trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("//") else { return nil }
        return Setting(name: match[1], value: value, label: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces), line: 0)
    }

    static func value(_ code: String) -> Value? {
        let text = code.trimmingCharacters(in: .whitespaces)
        if text == "true" { return .flag(true) }
        if text == "false" { return .flag(false) }
        if let number = Double(text), number.isFinite, ScenarioSteps.firstMatch(#"^-?[0-9]+(\.[0-9]+)?$"#, text) != nil { return .number(number) }
        if let string = unquoted(text) { return .text(string) }
        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return .list([]) }
        guard let parts = ScenarioSteps.arguments(inner) else { return nil }
        var items: [String] = []
        for part in parts {
            guard case .text(let item) = part else { return nil }
            items.append(item)
        }
        return .list(items)
    }

    /// The text a single-quoted JavaScript string holds; nil when `code` is not one whole string.
    static func unquoted(_ code: String) -> String? {
        guard code.count >= 2, code.hasPrefix("'"), code.hasSuffix("'") else { return nil }
        var out = ""
        var escaped = false
        let inner = Array(code.dropFirst().dropLast())
        var index = 0
        while index < inner.count {
            let character = inner[index]
            index += 1
            if escaped {
                escaped = false
                switch character {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard index + 4 <= inner.count, let value = UInt32(String(inner[index..<(index + 4)]), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                    out.unicodeScalars.append(scalar)
                    index += 4
                case "x":
                    guard index + 2 <= inner.count, let value = UInt32(String(inner[index..<(index + 2)]), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                    out.unicodeScalars.append(scalar)
                    index += 2
                default: out.append(character)
                }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" {
                return nil
            } else {
                out.append(character)
            }
        }
        return escaped ? nil : out
    }
}
