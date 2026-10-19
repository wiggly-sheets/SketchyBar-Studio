import Foundation

/// Character ranges inside a config file that must not be treated as editable values.
enum SourceRegions {
    struct Region {
        let start: Int
        let end: Int

        func intersects(_ start: Int, _ end: Int) -> Bool {
            self.start < end && start < self.end
        }
    }

    struct Heredoc {
        let delimiter: String
        let stripTabs: Bool
        let endIndex: Int
    }

    /// Lua comments (`--`) and long strings (`[[ ]]`).
    static func luaIgnoredRegions(in source: String) -> [Region] {
        let characters = Array(source)
        var regions: [Region] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                index = endOfQuoted(characters, from: index, quote: "\"")
            } else if character == "'" {
                index = endOfQuoted(characters, from: index, quote: "'")
            } else if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                // A block comment covers every line until its end.
                if index + 2 < characters.count, characters[index + 2] == "[",
                   let end = endOfLongBracket(characters, from: index + 2) {
                    regions.append(Region(start: index, end: end))
                    index = end
                    continue
                }
                let end = indexOfLineEnd(characters, from: index)
                regions.append(Region(start: index, end: end))
                index = end
            } else if character == "[", let end = endOfLongBracket(characters, from: index) {
                regions.append(Region(start: index, end: end))
                index = end
            } else {
                index += 1
            }
        }

        return regions
    }

    /// Shell comments (`#`) and heredoc bodies.
    static func shellIgnoredRegions(in source: String) -> [Region] {
        let characters = Array(source)
        var regions: [Region] = []
        var index = 0

        while index < characters.count {
            let lineEnd = indexOfLineEnd(characters, from: index)
            let line = Array(characters[index..<lineEnd])
            let commentStart = shellCommentStart(line)
            let heredoc = shellHeredocStart(line)

            if let commentStart {
                regions.append(Region(start: index + commentStart, end: lineEnd))
            }

            if let heredoc {
                let bodyStart = lineEnd + 1
                let terminatorEnd = indexOfHeredocTerminator(
                    characters,
                    from: bodyStart,
                    delimiter: heredoc.delimiter,
                    stripTabs: heredoc.stripTabs
                )
                regions.append(Region(start: bodyStart, end: terminatorEnd))
                index = terminatorEnd
                continue
            }

            index = lineEnd + 1
        }

        return regions
    }

    // MARK: - Helpers

    private static func endOfQuoted(_ characters: [Character], from start: Int, quote: Character) -> Int {
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

    private static func indexOfLineEnd(_ characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
        return index
    }

    /// The index after a long bracket, such as `]]` or `]==]`. The bracket
    /// must open a long bracket, otherwise the end of the file is returned.
    private static func endOfLongBracket(_ characters: [Character], from start: Int) -> Int? {
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

    /// A `#` outside quotes starts a comment when it begins a new word.
    private static func shellCommentStart(_ line: [Character]) -> Int? {
        var index = 0
        while index < line.count {
            let character = line[index]
            if character == "\"" {
                index = endOfQuoted(line, from: index, quote: "\"")
                continue
            }
            if character == "'" {
                index = endOfQuoted(line, from: index, quote: "'")
                continue
            }
            if character == "#" {
                let previous = index > 0 ? line[index - 1] : nil
                if previous == nil || previous!.isWhitespace || previous == "\"" || previous == "'" {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func shellHeredocStart(_ line: [Character]) -> Heredoc? {
        var index = 0
        while index < line.count {
            let character = line[index]
            if character == "\"" {
                index = endOfQuoted(line, from: index, quote: "\"")
                continue
            }
            if character == "'" {
                index = endOfQuoted(line, from: index, quote: "'")
                continue
            }
            if character == "<", index + 1 < line.count, line[index + 1] == "<" {
                if index + 2 < line.count, line[index + 2] == "<" {
                    index += 3
                    continue
                }
                if let heredoc = parseHeredoc(line, from: index + 2) {
                    return heredoc
                }
            }
            index += 1
        }
        return nil
    }

    private static func parseHeredoc(_ line: [Character], from start: Int) -> Heredoc? {
        var index = start
        var stripTabs = false
        if index < line.count, line[index] == "-" {
            stripTabs = true
            index += 1
        }
        while index < line.count, line[index].isWhitespace {
            index += 1
        }

        var delimiter = ""
        if index < line.count, line[index] == "\"" || line[index] == "'" {
            let quote = line[index]
            index += 1
            while index < line.count, line[index] != quote {
                delimiter.append(line[index])
                index += 1
            }
            if index < line.count {
                index += 1
            }
        } else {
            while index < line.count, !line[index].isWhitespace {
                delimiter.append(line[index])
                index += 1
            }
        }

        guard !delimiter.isEmpty else { return nil }
        return Heredoc(delimiter: delimiter, stripTabs: stripTabs, endIndex: index)
    }

    private static func indexOfHeredocTerminator(
        _ characters: [Character],
        from start: Int,
        delimiter: String,
        stripTabs: Bool
    ) -> Int {
        var index = start
        while index < characters.count {
            let lineEnd = indexOfLineEnd(characters, from: index)
            var content = Array(characters[index..<lineEnd])
            if stripTabs {
                while content.first == "\t" {
                    content.removeFirst()
                }
            }
            if String(content) == delimiter {
                return lineEnd
            }
            index = lineEnd + 1
        }
        return characters.count
    }
}
