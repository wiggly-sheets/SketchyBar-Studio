import Foundation

/// A character range inside a Lua source file.
///
/// The offsets count characters, the same way the rest of the app counts
/// them, so a range can be used to cut the text out of the file.
struct LuaSourceRange: Hashable {
    let start: Int
    let end: Int

    var length: Int { end - start }

    func intersects(_ other: LuaSourceRange) -> Bool {
        start < other.end && other.start < end
    }
}

/// The kind of the value of a table field.
enum LuaLiteralKind: Equatable {
    /// A quoted string, such as `"left"`.
    case string
    /// A number, such as `12` or `0xff0000`.
    case number
    /// `true` or `false`.
    case boolean
    /// `nil`.
    case nilLiteral
    /// A long string, such as `[[ text ]]`.
    case longString
    /// Anything that is not a literal, such as `colors.red`.
    case expression
}

/// A literal value of a Lua file.
enum LuaLiteralValue: Equatable {
    case string(String)
    case number(String)
    case boolean(Bool)
    case longString(String)
    case expression(String)
}

/// One field of a table constructor.
struct LuaTableEntry {
    /// The key path inside the table, such as `icon.font.size`.
    let path: [String]
    /// The range of the key in the file.
    let keyRange: LuaSourceRange
    /// The range of the value in the file.
    let valueRange: LuaSourceRange
    /// The kind of the value.
    let kind: LuaLiteralKind
    /// The raw text of the value, including the quotes of a string.
    let text: String
}

/// A table constructor of a Lua file.
struct LuaTable {
    /// The range of the whole constructor, including the braces.
    let range: LuaSourceRange
    /// The fields of the table. The fields of a nested table are flattened
    /// into the path, so `icon = { font = { size = 12 } }` gives the path
    /// `icon.font.size`.
    let entries: [LuaTableEntry]
}

/// One argument of a call.
enum LuaCallArgument {
    case literal(LuaLiteralValue)
    case table(LuaTable)
    case other(String)
}

/// A call expression of a Lua file.
struct LuaCall {
    /// The name of the called function, such as `sbar.add`.
    let path: [String]
    /// The range of the call in the file.
    let range: LuaSourceRange
    /// The arguments of the call.
    let arguments: [LuaCallArgument]
}

/// Everything the parser found in a Lua file.
struct LuaParseResult {
    let tables: [LuaTable]
    let calls: [LuaCall]
}

/// A small Lua parser that reads the table constructors of a file.
///
/// The parser exists for the config files of SketchyBar, so it reads
/// tables, calls and literals. It never throws and never loops forever:
/// malformed input gives the values that could be read.
enum LuaTableParser {
    static func parse(source: String) -> LuaParseResult {
        let characters = Array(source)
        let tokens = LuaTokenizer.tokenize(characters)
        var parser = LuaParser(characters: characters, tokens: tokens)
        return parser.run()
    }
}

// MARK: - Tokens

private struct LuaToken {
    enum Kind {
        case name
        case number
        case string
        case longString
        case symbol
    }

    let kind: Kind
    let start: Int
    let end: Int
    let text: String
}

private enum LuaTokenizer {
    static func tokenize(_ characters: [Character]) -> [LuaToken] {
        var tokens: [LuaToken] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }

            // A comment. The body of a comment is never code.
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                index = endOfComment(characters, from: index)
                continue
            }

            // A long string. The body of a long string is never code.
            if character == "[", let end = endOfLongString(characters, from: index) {
                tokens.append(LuaToken(kind: .longString, start: index, end: end, text: text(characters, from: index, to: end)))
                index = end
                continue
            }

            if character == "\"" || character == "'" {
                let end = endOfQuotedString(characters, from: index, quote: character)
                tokens.append(LuaToken(kind: .string, start: index, end: end, text: text(characters, from: index, to: end)))
                index = end
                continue
            }

            if character.isNumber {
                let end = endOfNumber(characters, from: index)
                tokens.append(LuaToken(kind: .number, start: index, end: end, text: text(characters, from: index, to: end)))
                index = end
                continue
            }

            if isNameStart(character) {
                var end = index + 1
                while end < characters.count, isNamePart(characters[end]) {
                    end += 1
                }
                tokens.append(LuaToken(kind: .name, start: index, end: end, text: text(characters, from: index, to: end)))
                index = end
                continue
            }

            tokens.append(LuaToken(kind: .symbol, start: index, end: index + 1, text: String(character)))
            index += 1
        }

        return tokens
    }

    private static func text(_ characters: [Character], from start: Int, to end: Int) -> String {
        guard start < end, end <= characters.count else { return "" }
        return String(characters[start..<end])
    }

    private static func isNameStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isNamePart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// The index after a comment. A block comment that is never closed
    /// covers the rest of the file.
    private static func endOfComment(_ characters: [Character], from start: Int) -> Int {
        var index = start + 2
        if index < characters.count, characters[index] == "[" {
            return endOfLongString(characters, from: index) ?? characters.count
        }
        while index < characters.count, !characters[index].isNewline {
            index += 1
        }
        return index
    }

    /// The index after a long string, or nil when the bracket does not open
    /// one. A long string that is never closed covers the rest of the file.
    private static func endOfLongString(_ characters: [Character], from start: Int) -> Int? {
        var index = start + 1
        var level = 0
        while index < characters.count, characters[index] == "=" {
            level += 1
            index += 1
        }
        guard index < characters.count, characters[index] == "[" else { return nil }
        index += 1

        while index < characters.count {
            guard characters[index] == "]" else {
                index += 1
                continue
            }
            var close = index + 1
            var count = 0
            while close < characters.count, characters[close] == "=" {
                count += 1
                close += 1
            }
            if count == level, close < characters.count, characters[close] == "]" {
                return close + 1
            }
            index += 1
        }
        return characters.count
    }

    private static func endOfQuotedString(_ characters: [Character], from start: Int, quote: Character) -> Int {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == quote {
                return index + 1
            }
            index += 1
        }
        return characters.count
    }

    private static func endOfNumber(_ characters: [Character], from start: Int) -> Int {
        var index = start

        if characters[index] == "0", index + 1 < characters.count,
           characters[index + 1] == "x" || characters[index + 1] == "X" {
            index += 2
            while index < characters.count, characters[index].isHexDigit {
                index += 1
            }
            return index
        }

        while index < characters.count, characters[index].isNumber {
            index += 1
        }
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
        }
        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            var exponent = index + 1
            if exponent < characters.count, characters[exponent] == "+" || characters[exponent] == "-" {
                exponent += 1
            }
            if exponent < characters.count, characters[exponent].isNumber {
                index = exponent
                while index < characters.count, characters[index].isNumber {
                    index += 1
                }
            }
        }
        return index
    }
}

// MARK: - Parser

private struct LuaParser {
    /// A value that was read from the file.
    private struct ParsedValue {
        enum Kind {
            case literal(LuaLiteralKind)
            case table
        }

        let kind: Kind
        let range: LuaSourceRange
        let text: String
        let table: LuaTable?
        let endIndex: Int
    }

    let characters: [Character]
    let tokens: [LuaToken]
    /// How deep a table may nest. A file that nests deeper is broken, and
    /// the parser reads the rest as one expression instead of going deeper.
    private static let maximumDepth = 32
    private var tablesByOpenIndex: [Int: LuaTable] = [:]
    private var allTables: [(openIndex: Int, table: LuaTable)] = []
    private var bracePairs: [Int: Int] = [:]
    private var bracketPairs: [Int: Int] = [:]
    private var parenPairs: [Int: Int] = [:]

    init(characters: [Character], tokens: [LuaToken]) {
        self.characters = characters
        self.tokens = tokens
        computePairs()
    }

    mutating func run() -> LuaParseResult {
        var coveredUntil = -1
        for (index, token) in tokens.enumerated() where token.kind == .symbol && token.text == "{" {
            // A table inside another table is read with its parent.
            guard index > coveredUntil else { continue }
            _ = parseTable(at: index, depth: 0)
            coveredUntil = bracePairs[index] ?? tokens.count - 1
        }

        var calls: [LuaCall] = []
        for (index, token) in tokens.enumerated() where token.kind == .symbol && token.text == "(" {
            guard let call = parseCall(at: index) else { continue }
            calls.append(call)
        }

        let tables = allTables
            .sorted { $0.openIndex < $1.openIndex }
            .map(\.table)

        return LuaParseResult(tables: tables, calls: calls)
    }

    // MARK: Tables

    private mutating func parseTable(at openIndex: Int, depth: Int) -> LuaTable {
        if let cached = tablesByOpenIndex[openIndex] { return cached }

        let closeIndex = bracePairs[openIndex] ?? tokens.count
        var entries: [LuaTableEntry] = []
        var index = openIndex + 1

        while index < closeIndex {
            let token = tokens[index]

            if token.kind == .symbol, token.text == "," || token.text == ";" {
                index += 1
                continue
            }

            var field: (key: [String], keyRange: LuaSourceRange)?

            if token.kind == .name, index + 1 < closeIndex,
               tokens[index + 1].kind == .symbol, tokens[index + 1].text == "=" {
                field = ([token.text], LuaSourceRange(start: token.start, end: token.end))
                index += 2
            } else if token.kind == .symbol, token.text == "[" {
                guard let bracketEnd = bracketPairs[index] else {
                    index = expressionValue(at: index, limit: closeIndex).endIndex
                    continue
                }
                let isPlainName = bracketEnd == index + 2 && tokens[index + 1].kind == .string
                let hasEquals = bracketEnd + 1 < closeIndex && tokens[bracketEnd + 1].kind == .symbol && tokens[bracketEnd + 1].text == "="
                guard isPlainName, hasEquals else {
                    // A key that is not a plain name cannot be part of a path.
                    index = bracketEnd + 1
                    if index < closeIndex, tokens[index].kind == .symbol, tokens[index].text == "=" {
                        index += 1
                    }
                    index = expressionValue(at: index, limit: closeIndex).endIndex
                    continue
                }
                field = (
                    [stringContent(of: tokens[index + 1])],
                    LuaSourceRange(start: tokens[index + 1].start, end: tokens[index + 1].end)
                )
                index = bracketEnd + 2
            } else {
                // A field without a plain name cannot be part of a path.
                index = expressionValue(at: index, limit: closeIndex).endIndex
                continue
            }

            guard let field else {
                index = expressionValue(at: index, limit: closeIndex).endIndex
                continue
            }

            let value = parseValue(at: index, limit: closeIndex, depth: depth)
            index = value.endIndex

            switch value.kind {
            case .table:
                guard let nested = value.table else { break }
                for entry in nested.entries {
                    entries.append(
                        LuaTableEntry(
                            path: field.key + entry.path,
                            keyRange: entry.keyRange,
                            valueRange: entry.valueRange,
                            kind: entry.kind,
                            text: entry.text
                        )
                    )
                }
            case .literal(let kind):
                entries.append(
                    LuaTableEntry(
                        path: field.key,
                        keyRange: field.keyRange,
                        valueRange: value.range,
                        kind: kind,
                        text: value.text
                    )
                )
            }
        }

        let range = LuaSourceRange(
            start: tokens[openIndex].start,
            end: closeIndex < tokens.count ? tokens[closeIndex].end : characters.count
        )
        let table = LuaTable(range: range, entries: entries)
        tablesByOpenIndex[openIndex] = table
        allTables.append((openIndex: openIndex, table: table))
        return table
    }

    // MARK: Values

    private mutating func parseValue(at index: Int, limit: Int, depth: Int) -> ParsedValue {
        guard index < limit else {
            // The field has no value. The range points at the place where
            // the value would start, counted in characters.
            let offset = index < tokens.count ? tokens[index].start : characters.count
            return ParsedValue(
                kind: .literal(.expression),
                range: LuaSourceRange(start: offset, end: offset),
                text: "",
                table: nil,
                endIndex: index
            )
        }

        let token = tokens[index]

        if token.kind == .symbol, token.text == "{" {
            // A file that nests deeper than this is broken. The rest of the
            // table is read as one expression, so the parser stays fast and
            // never runs out of stack.
            guard depth < Self.maximumDepth else {
                return expressionValue(at: index, limit: limit)
            }
            let table = parseTable(at: index, depth: depth + 1)
            let close = bracePairs[index]
            let end = close.map { tokens[$0].end } ?? characters.count
            return ParsedValue(
                kind: .table,
                range: LuaSourceRange(start: token.start, end: end),
                text: text(in: LuaSourceRange(start: token.start, end: end)),
                table: table,
                endIndex: close.map { $0 + 1 } ?? limit
            )
        }

        // A negative number, such as `-2`.
        if token.kind == .symbol, token.text == "-", index + 1 < limit,
           tokens[index + 1].kind == .number, token.end == tokens[index + 1].start {
            let number = tokens[index + 1]
            let range = LuaSourceRange(start: token.start, end: number.end)
            return ParsedValue(
                kind: .literal(.number),
                range: range,
                text: text(in: range),
                table: nil,
                endIndex: index + 2
            )
        }

        if let kind = literalKind(of: token) {
            // A literal that is followed by an operator is an expression.
            if index + 1 < limit, isOperator(tokens[index + 1]) {
                return expressionValue(at: index, limit: limit)
            }
            return ParsedValue(
                kind: .literal(kind),
                range: LuaSourceRange(start: token.start, end: token.end),
                text: token.text,
                table: nil,
                endIndex: index + 1
            )
        }

        return expressionValue(at: index, limit: limit)
    }

    /// Reads everything up to the next separator, such as `colors.red` or
    /// `require("colors")`.
    ///
    /// The scan always takes at least one token, so a malformed file cannot
    /// make the parser loop.
    private func expressionValue(at start: Int, limit: Int) -> ParsedValue {
        var index = start
        var depth = 0
        var end = tokens[start].end
        var consumed = 0

        while index < limit {
            let token = tokens[index]
            var stop = false

            if token.kind == .symbol {
                switch token.text {
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    if depth == 0 { stop = true } else { depth -= 1 }
                case ",", ";", "=":
                    if depth == 0 { stop = true }
                default:
                    break
                }
            }

            if stop, consumed > 0 {
                return expression(start: start, end: end, endIndex: index)
            }

            end = token.end
            index += 1
            consumed += 1

            if stop {
                return expression(start: start, end: end, endIndex: index)
            }
        }

        return expression(start: start, end: end, endIndex: index)
    }

    private func expression(start: Int, end: Int, endIndex: Int) -> ParsedValue {
        let range = LuaSourceRange(start: tokens[start].start, end: end)
        return ParsedValue(
            kind: .literal(.expression),
            range: range,
            text: text(in: range),
            table: nil,
            endIndex: endIndex
        )
    }

    private func literalKind(of token: LuaToken) -> LuaLiteralKind? {
        switch token.kind {
        case .string:
            return .string
        case .number:
            return .number
        case .longString:
            return .longString
        case .name:
            switch token.text {
            case "true", "false": return .boolean
            case "nil": return .nilLiteral
            default: return nil
            }
        case .symbol:
            return nil
        }
    }

    /// True for a token that continues a value, such as an operator.
    private func isOperator(_ token: LuaToken) -> Bool {
        guard token.kind == .symbol else { return false }
        return !",;)]}=".contains(token.text)
    }

    // MARK: Calls

    private mutating func parseCall(at openIndex: Int) -> LuaCall? {
        let path = calleePath(before: openIndex)
        guard !path.isEmpty, let closeIndex = parenPairs[openIndex] else { return nil }

        var arguments: [LuaCallArgument] = []
        var index = openIndex + 1
        while index < closeIndex {
            let argument = parseArgument(at: index, limit: closeIndex)
            arguments.append(argument.argument)
            index = argument.endIndex
        }

        let range = LuaSourceRange(start: tokens[openIndex].start, end: tokens[closeIndex].end)
        return LuaCall(path: path, range: range, arguments: arguments)
    }

    private mutating func parseArgument(at start: Int, limit: Int) -> (argument: LuaCallArgument, endIndex: Int) {
        var index = start
        var depth = 0

        while index < limit {
            let token = tokens[index]
            if token.kind == .symbol {
                switch token.text {
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    depth -= 1
                case ",":
                    if depth == 0 { return (makeArgument(start, index), index + 1) }
                default:
                    break
                }
            }
            index += 1
        }

        return (makeArgument(start, limit), limit)
    }

    private func makeArgument(_ start: Int, _ end: Int) -> LuaCallArgument {
        guard start < end else { return .other("") }
        let first = tokens[start]

        if first.kind == .symbol, first.text == "{",
           let braceEnd = bracePairs[start], braceEnd == end - 1,
           let table = tablesByOpenIndex[start] {
            return .table(table)
        }

        if end - start == 1 {
            switch first.kind {
            case .string:
                return .literal(.string(stringContent(of: first)))
            case .number:
                return .literal(.number(first.text))
            case .longString:
                return .literal(.longString(first.text))
            case .name where first.text == "true" || first.text == "false":
                return .literal(.boolean(first.text == "true"))
            default:
                break
            }
        }

        return .other(text(in: LuaSourceRange(start: first.start, end: tokens[end - 1].end)))
    }

    /// The dotted name of the called function, such as `sbar.add`.
    private func calleePath(before index: Int) -> [String] {
        var cursor = index - 1
        guard cursor >= 0, tokens[cursor].kind == .name else { return [] }

        var parts = [tokens[cursor].text]
        cursor -= 1
        while cursor >= 1, tokens[cursor].kind == .symbol, tokens[cursor].text == ".", tokens[cursor - 1].kind == .name {
            parts.append(tokens[cursor - 1].text)
            cursor -= 2
        }
        return parts.reversed()
    }

    // MARK: Helpers

    private mutating func computePairs() {
        var stack: [(index: Int, symbol: String)] = []

        for (index, token) in tokens.enumerated() where token.kind == .symbol {
            switch token.text {
            case "{", "[", "(":
                stack.append((index, token.text))
            case "}":
                guard let open = stack.last, open.symbol == "{" else { continue }
                stack.removeLast()
                bracePairs[open.index] = index
            case "]":
                guard let open = stack.last, open.symbol == "[" else { continue }
                stack.removeLast()
                bracketPairs[open.index] = index
            case ")":
                guard let open = stack.last, open.symbol == "(" else { continue }
                stack.removeLast()
                parenPairs[open.index] = index
            default:
                break
            }
        }
    }

    private func text(in range: LuaSourceRange) -> String {
        guard range.start < range.end, range.end <= characters.count else { return "" }
        return String(characters[range.start..<range.end])
    }

    /// The text of a string without its quotes and without the escapes.
    private func stringContent(of token: LuaToken) -> String {
        guard token.text.count >= 2 else { return token.text }
        var content = String(token.text.dropFirst().dropLast())
        content = content.replacingOccurrences(of: "\\n", with: "\n")
        content = content.replacingOccurrences(of: "\\t", with: "\t")
        content = content.replacingOccurrences(of: "\\r", with: "\r")
        content = content.replacingOccurrences(of: "\\\"", with: "\"")
        content = content.replacingOccurrences(of: "\\'", with: "'")
        content = content.replacingOccurrences(of: "\\\\", with: "\\")
        return content
    }
}
