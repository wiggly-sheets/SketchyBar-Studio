import Foundation

/// The language of a config source file.
enum SourceLanguage: String, Hashable {
    case lua
    case shell
}

/// The meaning of one range of a config source file.
enum SourceTokenKind: String, Hashable {
    case keyword
    case type
    case string
    case comment
    case number
    case `operator`
    case variable
    case plain
    case flag
}

/// One classified range of a config source file.
struct SourceToken: Equatable {
    let kind: SourceTokenKind
    let range: NSRange
}

/// A pure tokenizer for Lua and shell configs.
///
/// The tokenizer reads the whole source, so a block comment or a long string
/// keeps its kind across lines. Every token touches the next one and the
/// tokens cover the input without loss.
enum SourceSyntaxHighlighter {
    /// The language of a file. The extension decides unless the file is a
    /// `sketchybarrc`, where the contents decide.
    static func language(for url: URL, contents: String) -> SourceLanguage {
        switch url.pathExtension.lowercased() {
        case "lua":
            return .lua
        case "sh", "bash", "zsh", "dash", "ksh":
            return .shell
        default:
            let name = url.lastPathComponent.lowercased()
            if name == "sketchybarrc" || name == ".sketchybarrc" {
                return LuaSourceDetection.isLua(contents) ? .lua : .shell
            }
            return LuaSourceDetection.isLua(contents) ? .lua : .shell
        }
    }

    static func tokens(in source: String, language: SourceLanguage) -> [SourceToken] {
        let text = source as NSString
        let length = text.length
        var tokens: [SourceToken] = []
        var index = 0

        while index < length {
            let start = index
            let character = text.character(at: index)

            if isWhitespace(character) {
                index += 1
                while index < length, isWhitespace(text.character(at: index)) {
                    index += 1
                }
                tokens.append(SourceToken(kind: .plain, range: NSRange(location: start, length: index - start)))
                continue
            }

            switch language {
            case .lua:
                index = scanLua(text, from: index, into: &tokens)
            case .shell:
                index = scanShell(text, from: index, into: &tokens)
            }
        }

        return tokens
    }

    // MARK: - Lua

    private static let luaKeywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
        "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
        "true", "until", "while", "require", "dofile", "loadfile"
    ]

    private static let luaBuiltins: Set<String> = [
        "assert", "collectgarbage", "coroutine", "debug", "error", "getmetatable",
        "io", "ipairs", "load", "math", "next", "os", "package", "pairs", "pcall",
        "print", "rawequal", "rawget", "rawset", "select", "setmetatable", "string",
        "table", "tonumber", "tostring", "type", "utf8", "xpcall"
    ]

    private static let luaOperators = ["...", "..", "==", "~=", "<=", ">=", "//", "::", "<<", ">>"]

    private static func scanLua(_ text: NSString, from start: Int, into tokens: inout [SourceToken]) -> Int {
        let length = text.length
        let character = text.character(at: start)

        if character == 45, start + 1 < length, text.character(at: start + 1) == 45 {
            if let bracket = longBracketStart(text, at: start + 2) {
                let end = longBracketEnd(text, from: bracket.openEnd, equals: bracket.equals)
                tokens.append(SourceToken(kind: .comment, range: NSRange(location: start, length: end - start)))
                return end
            }
            let end = lineEnd(text, from: start)
            tokens.append(SourceToken(kind: .comment, range: NSRange(location: start, length: end - start)))
            return end
        }

        if character == 34 || character == 39 {
            let end = quotedEnd(text, from: start, quote: character, allowsEscapes: true)
            tokens.append(SourceToken(kind: .string, range: NSRange(location: start, length: end - start)))
            return end
        }

        if character == 91, let bracket = longBracketStart(text, at: start) {
            let end = longBracketEnd(text, from: bracket.openEnd, equals: bracket.equals)
            tokens.append(SourceToken(kind: .string, range: NSRange(location: start, length: end - start)))
            return end
        }

        if isDigit(character) || (character == 46 && start + 1 < length && isDigit(text.character(at: start + 1))) {
            let end = numberEnd(text, from: start)
            tokens.append(SourceToken(kind: .number, range: NSRange(location: start, length: end - start)))
            return end
        }

        if isIdentifierStart(character) {
            var end = start + 1
            while end < length, isIdentifierPart(text.character(at: end)) {
                end += 1
            }
            let word = text.substring(with: NSRange(location: start, length: end - start)).lowercased()
            let kind: SourceTokenKind
            if luaKeywords.contains(word) {
                kind = .keyword
            } else if luaBuiltins.contains(word) {
                kind = .type
            } else {
                kind = .plain
            }
            tokens.append(SourceToken(kind: kind, range: NSRange(location: start, length: end - start)))
            return end
        }

        let end = operatorEnd(text, from: start, candidates: luaOperators)
        tokens.append(SourceToken(kind: .operator, range: NSRange(location: start, length: end - start)))
        return end
    }

    // MARK: - Shell

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
        "function", "case", "esac", "in", "select", "time", "coproc",
        "sketchybar", "source", "export", "bash", "zsh", "sh"
    ]

    private static let shellBuiltins: Set<String> = [
        "alias", "builtin", "cd", "command", "echo", "eval", "exec", "exit",
        "local", "printf", "read", "return", "set", "shift", "test", "trap",
        "type", "ulimit", "umask", "unalias", "unset", "wait"
    ]

    private static let shellOperators = ["&&", "||", ">>", "<<", "==", "!=", ">=", "<=", "|&", "&>"]

    private static func scanShell(_ text: NSString, from start: Int, into tokens: inout [SourceToken]) -> Int {
        let length = text.length
        let character = text.character(at: start)

        if character == 35, startsShellComment(text, at: start) {
            let end = lineEnd(text, from: start)
            tokens.append(SourceToken(kind: .comment, range: NSRange(location: start, length: end - start)))
            return end
        }

        if character == 34 {
            let end = quotedEnd(text, from: start, quote: character, allowsEscapes: true)
            tokens.append(SourceToken(kind: .string, range: NSRange(location: start, length: end - start)))
            return end
        }

        if character == 39 {
            let end = quotedEnd(text, from: start, quote: character, allowsEscapes: false)
            tokens.append(SourceToken(kind: .string, range: NSRange(location: start, length: end - start)))
            return end
        }

        if character == 36 {
            let end = shellVariableEnd(text, from: start)
            if end > start + 1 {
                tokens.append(SourceToken(kind: .variable, range: NSRange(location: start, length: end - start)))
                return end
            }
        }

        if isDigit(character) {
            let end = numberEnd(text, from: start)
            tokens.append(SourceToken(kind: .number, range: NSRange(location: start, length: end - start)))
            return end
        }

        if character == 45, start + 1 < length {
            let next = text.character(at: start + 1)
            if !isWhitespace(next) {
                let end = shellWordEnd(text, from: start)
                tokens.append(SourceToken(kind: .flag, range: NSRange(location: start, length: end - start)))
                return end
            }
        }

        if isIdentifierStart(character) {
            let end = shellWordEnd(text, from: start)
            let word = text.substring(with: NSRange(location: start, length: end - start)).lowercased()
            let kind: SourceTokenKind
            if shellKeywords.contains(word) {
                kind = .keyword
            } else if shellBuiltins.contains(word) {
                kind = .type
            } else {
                kind = .plain
            }
            tokens.append(SourceToken(kind: kind, range: NSRange(location: start, length: end - start)))
            return end
        }

        let end = operatorEnd(text, from: start, candidates: shellOperators)
        tokens.append(SourceToken(kind: .operator, range: NSRange(location: start, length: end - start)))
        return end
    }

    // MARK: - Shared scanning

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13 || character == 12
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }

    private static func isIdentifierStart(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90)
            || (character >= 97 && character <= 122)
            || character == 95
            || character >= 128
    }

    private static func isIdentifierPart(_ character: unichar) -> Bool {
        isIdentifierStart(character) || isDigit(character)
    }

    private static func lineEnd(_ text: NSString, from start: Int) -> Int {
        var end = start
        while end < text.length {
            let character = text.character(at: end)
            if character == 10 || character == 13 { break }
            end += 1
        }
        return end
    }

    private static func quotedEnd(_ text: NSString, from start: Int, quote: unichar, allowsEscapes: Bool) -> Int {
        var index = start + 1
        var escaped = false
        while index < text.length {
            let character = text.character(at: index)
            if character == quote && !escaped {
                return index + 1
            }
            if allowsEscapes {
                escaped = character == 92 && !escaped
                if character != 92 { escaped = false }
            }
            index += 1
        }
        return text.length
    }

    private static func numberEnd(_ text: NSString, from start: Int) -> Int {
        let length = text.length
        var index = start

        if index + 1 < length,
           text.character(at: index) == 48,
           text.character(at: index + 1) == 120 || text.character(at: index + 1) == 88 {
            index += 2
            while index < length, isHexDigit(text.character(at: index)) {
                index += 1
            }
            return index
        }

        while index < length, isDigit(text.character(at: index)) {
            index += 1
        }
        if index < length, text.character(at: index) == 46 {
            index += 1
            while index < length, isDigit(text.character(at: index)) {
                index += 1
            }
        }
        if index < length, text.character(at: index) == 101 || text.character(at: index) == 69 {
            let exponentStart = index
            index += 1
            if index < length, text.character(at: index) == 43 || text.character(at: index) == 45 {
                index += 1
            }
            var digits = 0
            while index < length, isDigit(text.character(at: index)) {
                index += 1
                digits += 1
            }
            if digits == 0 { index = exponentStart }
        }
        return index
    }

    private static func isHexDigit(_ character: unichar) -> Bool {
        isDigit(character)
            || (character >= 65 && character <= 70)
            || (character >= 97 && character <= 102)
    }

    private static func longBracketStart(_ text: NSString, at index: Int) -> (openEnd: Int, equals: Int)? {
        guard index < text.length, text.character(at: index) == 91 else { return nil }
        var cursor = index + 1
        var equals = 0
        while cursor < text.length, text.character(at: cursor) == 61 {
            equals += 1
            cursor += 1
        }
        guard cursor < text.length, text.character(at: cursor) == 91 else { return nil }
        return (cursor + 1, equals)
    }

    private static func longBracketEnd(_ text: NSString, from start: Int, equals: Int) -> Int {
        var index = start
        while index < text.length {
            guard text.character(at: index) == 93 else {
                index += 1
                continue
            }
            var cursor = index + 1
            while cursor < text.length, text.character(at: cursor) == 61 {
                cursor += 1
            }
            if cursor - index - 1 == equals, cursor < text.length, text.character(at: cursor) == 93 {
                return cursor + 1
            }
            index += 1
        }
        return text.length
    }

    private static func startsShellComment(_ text: NSString, at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = text.character(at: index - 1)
        if isWhitespace(previous) { return true }
        switch previous {
        case 59, 124, 38, 40, 41, 123, 125, 96:
            return true
        default:
            return false
        }
    }

    private static func shellVariableEnd(_ text: NSString, from start: Int) -> Int {
        let length = text.length
        var index = start + 1
        guard index < length else { return start + 1 }
        let next = text.character(at: index)

        if next == 123 {
            index += 1
            while index < length, text.character(at: index) != 125 {
                index += 1
            }
            if index < length { index += 1 }
            return index
        }

        if isIdentifierStart(next) || isDigit(next) {
            index += 1
            while index < length, isIdentifierPart(text.character(at: index)) {
                index += 1
            }
            return index
        }

        switch next {
        case 63, 64, 42, 35, 36, 33, 45:
            return start + 2
        default:
            return start + 1
        }
    }

    private static func shellWordEnd(_ text: NSString, from start: Int) -> Int {
        var index = start
        while index < text.length {
            let character = text.character(at: index)
            if isIdentifierPart(character) || character == 45 {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    private static func operatorEnd(_ text: NSString, from start: Int, candidates: [String]) -> Int {
        for candidate in candidates {
            let length = candidate.utf16.count
            guard start + length <= text.length else { continue }
            if text.substring(with: NSRange(location: start, length: length)) == candidate {
                return start + length
            }
        }
        return start + 1
    }
}
