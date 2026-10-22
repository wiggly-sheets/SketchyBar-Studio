import Foundation

struct ShellConfigScanner {
    private static let assignmentRegex = try? NSRegularExpression(
        pattern: #"(?:^|[ \t])([A-Za-z_][A-Za-z0-9_\.]*)=("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:\\.|[^ \t\\])*)"#
    )

    /// Keywords that declare a variable inside a function instead of setting
    /// a SketchyBar option.
    private static let localKeywords: Set<String> = ["local", "declare", "readonly", "typeset"]
    /// Words the shell reads as keywords, so they are never written unquoted.
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "fi", "do", "done", "case", "esac",
        "function", "export", "local", "return"
    ]
    /// A value that can be written without quotes.
    private static let safeTokenRegex = try? NSRegularExpression(
        pattern: #"^[A-Za-z0-9_@%+=:,./-]+$"#
    )
    /// The first segment of a key path, such as `icon` in `icon.font.size`.
    private static let optionKeys: Set<String> = Set(
        SketchyBarOptionDocs.all.map { $0.key.lowercased() }
    )

    private let optionCatalog = SketchyBarOptionCatalog()

    func scan(fileURL: URL) -> [LuaEditableValue] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return scan(fileURL: fileURL, contents: contents)
    }

    /// Scans values from contents that were read elsewhere, so the file is
    /// not read twice.
    func scan(fileURL: URL, contents: String) -> [LuaEditableValue] {
        // A `sketchybarrc` can hold Lua code. The Lua scanner knows the Lua
        // syntax, so the shell quoting never touches it.
        if LuaSourceDetection.isLua(contents) {
            return LuaConfigScanner().scan(fileURL: fileURL, contents: contents)
        }

        guard let regex = Self.assignmentRegex else {
            return []
        }

        let ignoredRegions = SourceRegions.shellIgnoredRegions(in: contents)
        var results: [LuaEditableValue] = []
        var lineNumber = 1

        contents.enumerateSubstrings(in: contents.startIndex..<contents.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = String(contents[lineRange])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else {
                lineNumber += 1
                return
            }

            let nsLine = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = regex.matches(in: line, range: nsLine)
            let lineStart = contents.distance(from: contents.startIndex, to: lineRange.lowerBound)
            let barFlag = Self.barFlagRange(in: line)
            var lineValues: [LuaEditableValue] = []

            for match in matches {
                guard let keyRange = Range(match.range(at: 1), in: line),
                      let valueRange = Range(match.range(at: 2), in: line) else {
                    continue
                }

                let rawValue = String(line[valueRange])
                let valueStart = lineStart + line.distance(from: line.startIndex, to: valueRange.lowerBound)
                let valueEnd = lineStart + line.distance(from: line.startIndex, to: valueRange.upperBound)
                guard !ignoredRegions.contains(where: { $0.intersects(valueStart, valueEnd) }) else {
                    continue
                }
                guard !rawValue.hasPrefix("("), !rawValue.hasPrefix("["), !rawValue.hasPrefix("{") else {
                    lineValues.removeAll()
                    break
                }

                // The properties after the `--bar` flag belong to the bar,
                // so they get the key paths of the bar level.
                let isBarProperty = barFlag.map { keyRange.lowerBound > $0.upperBound } ?? false
                let keyPath = isBarProperty
                    ? SketchyBarOptionCatalog.barKeyPath(for: String(line[keyRange]))
                    : String(line[keyRange])
                // The word in front of the key says what the assignment is:
                // `local result=5` is a variable of a function, `export FOO=1`
                // exports a variable, and everything else sets an option.
                let word = Self.lastWord(in: String(line[line.startIndex..<keyRange.lowerBound]))
                if let word, Self.localKeywords.contains(word) {
                    continue
                }
                guard word == "export" || Self.isKnownOption(keyPath) else {
                    continue
                }

                let displayValue = SketchyBarValueRules.normalizedDisplayValue(
                    SketchyBarValueRules.displayValue(for: rawValue, keyPath: keyPath),
                    keyPath: keyPath
                )

                lineValues.append(
                    LuaEditableValue(
                        id: "\(fileURL.path):\(lineNumber):\(keyPath):\(valueStart)",
                        fileURL: fileURL,
                        keyPath: keyPath,
                        lineNumber: lineNumber,
                        kind: SketchyBarValueRules.kind(for: rawValue, keyPath: keyPath),
                        originalValue: displayValue,
                        draftValue: displayValue,
                        suggestedValues: optionCatalog.suggestedValues(for: keyPath, currentValue: displayValue),
                        valueStartOffset: valueStart,
                        valueEndOffset: valueEnd,
                        sourceSnapshot: contents
                    )
                )
            }

            results.append(contentsOf: lineValues)

            lineNumber += 1
        }

        return LuaEditableValue.assigningStableKeys(results)
    }

    func save(values: [LuaEditableValue], to fileURL: URL, rootURL: URL) throws {
        let changedValues = values.filter { $0.draftValue != $0.originalValue && !$0.isMissingFromFile }
        guard !changedValues.isEmpty else { return }
        var contents = try String(contentsOf: fileURL, encoding: .utf8)
        if LuaSourceDetection.isLua(contents) {
            try LuaConfigScanner().save(values: values, to: fileURL, rootURL: rootURL)
            return
        }
        guard changedValues.allSatisfy({
            $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL && $0.sourceSnapshot == contents
        }) else {
            throw ConfigSourceSaveError.sourceChanged(fileURL)
        }

        let originalContents = contents
        contents = updatedContents(values: values, originalContents: contents)

        // Re-read right before the write so an external edit is not lost.
        let latestContents = try String(contentsOf: fileURL, encoding: .utf8)
        guard latestContents == originalContents else {
            throw ConfigSourceSaveError.sourceChanged(fileURL)
        }

        try SafeFileReplacer().writeAtomicallyPreservingSymlinks(contents, to: fileURL)
    }

    /// The contents the file would have with the drafts applied. This is the
    /// exact text the save writes.
    func updatedContents(values: [LuaEditableValue], originalContents: String) -> String {
        if LuaSourceDetection.isLua(originalContents) {
            return LuaConfigScanner().updatedContents(values: values, originalContents: originalContents)
        }

        let changedValues = values.filter { $0.draftValue != $0.originalValue && !$0.isMissingFromFile }
        var contents = originalContents
        for value in changedValues.sorted(by: { $0.valueStartOffset > $1.valueStartOffset }) {
            let start = contents.index(contents.startIndex, offsetBy: value.valueStartOffset)
            let end = contents.index(contents.startIndex, offsetBy: value.valueEndOffset)
            contents.replaceSubrange(start..<end, with: serializedValue(value))
        }
        return contents
    }

    private func serializedValue(_ value: LuaEditableValue) -> String {
        let original = String(originalSerializedValue(for: value))

        switch value.kind {
        case .string:
            guard !SketchyBarValueRules.containsLineBreak(value.draftValue) else { return original }
            return Self.serializedShellString(value.draftValue, original: original)
        case .number:
            return SketchyBarValueRules.serializedNumber(value.draftValue, original: original)
        case .color:
            return SketchyBarValueRules.serializedColor(value.draftValue, original: original)
        case .boolean:
            return SketchyBarValueRules.serializedBoolean(value.draftValue, original: original)
        }
    }

    private func originalSerializedValue(for value: LuaEditableValue) -> Substring {
        let start = value.sourceSnapshot.index(value.sourceSnapshot.startIndex, offsetBy: value.valueStartOffset)
        let end = value.sourceSnapshot.index(value.sourceSnapshot.startIndex, offsetBy: value.valueEndOffset)
        return value.sourceSnapshot[start..<end]
    }

    // MARK: - Shell quoting

    /// Writes the value with the quoting the file already uses, so the
    /// expansion of the original line is preserved.
    private static func serializedShellString(_ draft: String, original: String) -> String {
        if original.hasPrefix("'") {
            return "'" + escapeSingleQuoted(draft) + "'"
        }
        if original.hasPrefix("\"") {
            return "\"" + escapeDoubleQuoted(draft) + "\""
        }
        if isSafeUnquotedToken(draft) {
            return draft
        }
        return "\"" + escapeLiteral(draft) + "\""
    }

    /// Escapes a value for a single quoted string. Only the single quote
    /// itself needs escaping, everything else stays literal.
    private static func escapeSingleQuoted(_ string: String) -> String {
        string.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Escapes a value for a double quoted string. `$` and the backtick stay
    /// live, so the expansion of the original line is preserved.
    ///
    /// A backslash that already escapes a special character is kept as it is:
    /// doubling it would turn an escaped `\$` into a live `$` and run a
    /// command the original file never ran.
    private static func escapeDoubleQuoted(_ string: String) -> String {
        var escaped = ""
        var index = string.startIndex

        while index < string.endIndex {
            let character = string[index]
            if character == "\"" {
                escaped.append("\\\"")
                index = string.index(after: index)
                continue
            }
            if character == "\\" {
                let next = string.index(after: index)
                if next < string.endIndex, isDoubleQuotedEscape(string[next]) {
                    escaped.append("\\")
                    escaped.append(string[next])
                    index = string.index(after: next)
                } else {
                    escaped.append("\\\\")
                    index = next
                }
                continue
            }
            escaped.append(character)
            index = string.index(after: index)
        }

        return escaped
    }

    /// The characters a backslash escapes inside a double quoted string.
    private static func isDoubleQuotedEscape(_ character: Character) -> Bool {
        character == "$" || character == "`" || character == "\"" || character == "\\" || character == "\n"
    }

    /// Escapes a value so the shell reads it literally.
    static func escapeLiteral(_ string: String) -> String {
        var escaped = ""

        for character in string {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }

        return escaped
    }

    /// True when the value can be written without quotes.
    static func isSafeUnquotedToken(_ value: String) -> Bool {
        guard !value.isEmpty, let regex = safeTokenRegex else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard regex.firstMatch(in: value, range: range) != nil else { return false }
        return !shellKeywords.contains(value.lowercased())
    }

    // MARK: - Assignments

    /// The last word in front of the key, such as `local` in `local result=5`.
    private static func lastWord(in prefix: String) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)
    }

    /// The range of the `--bar` flag of the line, when the line has one.
    ///
    /// The flag sets the properties of the bar that follow it, such as
    /// `sketchybar --bar position=top margin=4`.
    private static func barFlagRange(in line: String) -> Range<String.Index>? {
        var search = line.startIndex..<line.endIndex

        while let range = line.range(of: "--bar", range: search) {
            let before = line[line.startIndex..<range.lowerBound]
            let after = line[range.upperBound...]
            let startsWord = before.isEmpty || before.last == " " || before.last == "\t"
            let endsWord = after.isEmpty || after.first == " " || after.first == "\t"
            if startsWord, endsWord { return range }
            search = range.upperBound..<line.endIndex
        }

        return nil
    }

    /// True when the key is a SketchyBar option.
    private static func isKnownOption(_ keyPath: String) -> Bool {
        let key = keyPath.lowercased()
        guard !key.isEmpty else { return false }
        if let first = key.split(separator: ".").first.map(String.init), optionKeys.contains(first) {
            return true
        }
        return SketchyBarOptionDocs.doc(for: key) != nil
    }
}

/// The commands of a shell config.
///
/// A shell config calls the `sketchybar` binary, so the item a value
/// belongs to is in the command line and not in the value:
/// `sketchybar --set clock label="10:00"`. The scanner of the app reads
/// the values of a line, but it does not know the item they belong to.
/// This parser reads the commands, so the bridge knows the alias of every
/// value.
///
/// The values are the text the shell passes on, so the quotes of a value
/// are not part of it. The ranges of the values point at the value in the
/// file, so a quoted value covers its quotes.
struct ShellConfigCommandParser {
    /// The result of the parse.
    struct Result {
        /// The items of the bar, one per declaration.
        let items: [StructuredItem]
        /// The declarations of the bar.
        let bar: [StructuredItem]
        /// The declarations of the default item.
        let defaults: [StructuredItem]
        /// The problems of the config that the parser found.
        let warnings: [String]
    }

    /// One command of a shell config.
    ///
    /// The line is the line of the call of the binary, so a diagnostic can
    /// name the line of an add or a set without re-parsing the file.
    private enum Command {
        /// `--add <type> <alias> <position>`
        case add(type: String, alias: String, position: Word?, line: Int)
        /// `--set <alias> <property>=<value> …`
        case set(alias: String, properties: [Property], line: Int)
        /// `--default <property>=<value> …`
        case defaultItem(properties: [Property], line: Int)
        /// `--bar <property>=<value> …`
        case bar(properties: [Property], line: Int)
    }

    /// One declaration of an item: the add that creates it and the values
    /// that are set on it.
    private struct Declaration {
        /// The alias of the item.
        let alias: String
        /// The position of the add command.
        var addPosition: String?
        /// The values that are set on the item.
        var properties: [StructuredItemValue]
    }

    /// One property of a command.
    private struct Property {
        /// The name of the property, such as `label.string`.
        let key: String
        /// The value of the property, as the shell passes it on.
        let value: String
        /// The range of the value in the file.
        let range: Range<Int>
        /// True when the shell builds the value, so it is not a literal.
        let dynamic: Bool
    }

    /// One word of a shell config.
    private struct Word {
        /// The text of the word, with the quotes removed.
        let text: String
        /// The text of the word as the file holds it, with the quotes.
        let raw: String
        /// The line of the word in the file. A command ends at the newline.
        let line: Int
        /// The range of the word in the file.
        let range: Range<Int>
    }

    /// Returns the add commands with their aliases and line numbers.
    static func addCommands(in source: String) -> [(alias: String, line: Int)] {
        let commands = Self.commands(in: source)
        return commands.commands.compactMap { command in
            if case .add(_, let alias, _, let line) = command, !alias.isEmpty {
                return (alias, line)
            }
            return nil
        }
    }

    /// The range of the alias of the first item of the shell config.
    ///
    /// The range covers the quoted alias, such as `"clock"`. It is nil
    /// when the file has no item, or when the item has no name.
    static func aliasRange(in source: String) -> LuaSourceRange? {
        let words = Self.words(in: source)
        var index = 0

        while index < words.count {
            guard Self.isBinary(words[index].text) else {
                index += 1
                continue
            }

            var cursor = index + 1
            while cursor < words.count,
                  words[cursor].line == words[index].line,
                  !Self.isBinary(words[cursor].text) {
                cursor += 1
            }

            let arguments = Array(words[(index + 1)..<cursor])
            index = cursor

            if let flag = arguments.first, flag.text == "--add", arguments.count >= 3 {
                let aliasWord = arguments[2]
                if !aliasWord.text.isEmpty {
                    return LuaSourceRange(start: aliasWord.range.lowerBound, end: aliasWord.range.upperBound)
                }
            }
        }

        return nil
    }

    /// The commands of a config, read into the model of the app.
    static func parse(in source: String) -> Result {
        var declarations: [Declaration] = []
        var barValues: [StructuredItemValue] = []
        var defaultValues: [StructuredItemValue] = []
        var warnings: [String] = []
        let commands = Self.commands(in: source)

        for command in commands.commands {
            switch command {
            case .add(let type, let alias, let position, _):
                guard type == "item" else {
                    // The preview only knows plain items. The other types
                    // need the window server or their own setup.
                    warnings.append(PreviewWarning.unsupportedType(type, alias: alias))
                    continue
                }
                guard !alias.isEmpty else {
                    warnings.append(PreviewWarning.unnamedItem(generated: false))
                    continue
                }
                guard let position else {
                    // The daemon creates the item and removes it again
                    // (src/message.c:202-208).
                    warnings.append(PreviewWarning.addWithoutPosition(alias))
                    continue
                }
                declarations.append(Declaration(alias: alias, addPosition: position.text, properties: []))
            case .set(let alias, let properties, _):
                let literal = properties.filter { !$0.dynamic }
                let dynamic = properties.filter(\.dynamic)
                guard let index = declarations.lastIndex(where: { $0.alias == alias }) else {
                    // The daemon sets nothing when the item does not exist
                    // (src/message.c:635).
                    warnings.append(PreviewWarning.setWithoutAdd(alias))
                    continue
                }
                warnings.append(contentsOf: dynamic.map { PreviewWarning.dynamicValue($0.key) })
                declarations[index].properties.append(contentsOf: literal.map {
                    value(alias: alias, key: $0.key, text: $0.value, range: $0.range)
                })
            case .defaultItem(let properties, _):
                warnings.append(contentsOf: properties.filter(\.dynamic).map { PreviewWarning.dynamicValue($0.key) })
                defaultValues.append(contentsOf: properties.filter { !$0.dynamic }.map { value(alias: "default", key: $0.key, text: $0.value, range: $0.range) })
            case .bar(let properties, _):
                warnings.append(contentsOf: properties.filter(\.dynamic).map { PreviewWarning.dynamicValue($0.key) })
                barValues.append(contentsOf: properties.filter { !$0.dynamic }.map { value(alias: "bar", key: $0.key, text: $0.value, range: $0.range) })
            }
        }

        if commands.calls == 0 {
            warnings.append(PreviewWarning.noSketchyBarCommand())
        }

        let items = declarations.map {
            StructuredItem(kind: .item,
                           alias: $0.alias,
                           values: $0.properties,
                           excludedRanges: [],
                           addPosition: $0.addPosition)
        }

        return Result(
            items: items,
            bar: barValues.isEmpty ? [] : [StructuredItem(kind: .bar, alias: "bar", values: barValues, excludedRanges: [])],
            defaults: defaultValues.isEmpty ? [] : [StructuredItem(kind: .defaultItem, alias: "default", values: defaultValues, excludedRanges: [])],
            warnings: warnings
        )
    }

    /// One value of a command, in the model of the app.
    private static func value(alias: String, key: String, text: String, range: Range<Int>) -> StructuredItemValue {
        StructuredItemValue(
            alias: alias,
            keyPath: key,
            rawValue: text,
            value: text,
            valueStartOffset: range.lowerBound,
            valueEndOffset: range.upperBound
        )
    }

    // MARK: - The commands

    /// The commands of the config, in the order of the file, and the
    /// number of calls of the binary.
    ///
    /// A command ends at the newline, so the words of the next line are
    /// not read as the properties of the command before it. A call of the
    /// binary ends the command as well, so the commands of a config are
    /// read one after the other.
    private static func commands(in source: String) -> (commands: [Command], calls: Int) {
        let words = Self.words(in: source)
        var commands: [Command] = []
        var calls = 0
        var index = 0

        while index < words.count {
            guard Self.isBinary(words[index].text) else {
                index += 1
                continue
            }

            calls += 1
            let line = words[index].line
            var arguments: [Word] = []
            var cursor = index + 1
            while cursor < words.count,
                  words[cursor].line == line,
                  !Self.isBinary(words[cursor].text) {
                arguments.append(words[cursor])
                cursor += 1
            }
            index = cursor

            if let command = Self.command(from: arguments) {
                commands.append(command)
            }
        }

        return (commands, calls)
    }

    /// One command, read from the words that follow the call of the binary.
    private static func command(from arguments: [Word]) -> Command? {
        guard let flag = arguments.first else { return nil }
        let line = flag.line

        switch flag.text {
        case "--add":
            guard arguments.count >= 3 else { return nil }
            let position = arguments.count > 3 ? arguments[3] : nil
            return .add(type: arguments[1].text, alias: arguments[2].text, position: position, line: line)
        case "--set":
            guard arguments.count >= 2 else { return nil }
            return .set(alias: arguments[1].text, properties: Self.properties(in: Array(arguments.dropFirst(2))), line: line)
        case "--default":
            return .defaultItem(properties: Self.properties(in: Array(arguments.dropFirst())), line: line)
        case "--bar":
            return .bar(properties: Self.properties(in: Array(arguments.dropFirst())), line: line)
        default:
            return nil
        }
    }

    /// The `property=value` pairs of a command.
    ///
    /// The pair is split at the first `=`, the way the daemon splits it
    /// (src/misc/helpers.h:126). A value that the shell builds, such as
    /// `$(date)` or `$HOME`, is not a literal, so it is marked as one the
    /// preview cannot read.
    private static func properties(in words: [Word]) -> [Property] {
        var properties: [Property] = []

        for word in words {
            guard let separator = word.text.firstIndex(of: "=") else { continue }
            let key = String(word.text[..<separator])
            guard !key.isEmpty else { continue }
            let value = String(word.text[word.text.index(after: separator)...])
            // The range is measured on the raw text of the word, so it
            // covers the quotes of a quoted value.
            guard let rawSeparator = word.raw.firstIndex(of: "=") else { continue }
            let offset = word.raw.distance(from: word.raw.startIndex, to: rawSeparator) + 1
            properties.append(Property(key: key,
                                       value: value,
                                       range: word.range.lowerBound + offset..<word.range.upperBound,
                                       dynamic: Self.isDynamic(value)))
        }

        return properties
    }

    /// True when the shell builds the value, so the value is not a literal.
    private static func isDynamic(_ value: String) -> Bool {
        value.contains("$") || value.contains("`")
    }

    /// True when the word calls the binary of SketchyBar.
    private static func isBinary(_ word: String) -> Bool {
        word == "sketchybar" || word.hasSuffix("/sketchybar")
    }

    // MARK: - The words

    /// The words of a shell config, the way the shell passes them on.
    ///
    /// The quotes of a word are removed, a backslash at the end of a line
    /// continues the line and a `#` that begins a word starts a comment.
    private static func words(in source: String) -> [Word] {
        let characters = Array(source)
        var words: [Word] = []
        var index = 0
        var line = 1

        while index < characters.count {
            // The whitespace and the line continuations separate the words.
            while index < characters.count {
                if characters[index].isWhitespace {
                    if characters[index] == "\n" { line += 1 }
                    index += 1
                    continue
                }
                if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 2
                    continue
                }
                break
            }
            guard index < characters.count else { break }
            if characters[index] == "#" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }

            let start = index
            let startLine = line
            var text = ""

            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace { break }

                if character == "\\" {
                    let next = index + 1
                    if next < characters.count, characters[next] == "\n" {
                        // The line continues on the next one.
                        index = next + 1
                        continue
                    }
                    if next < characters.count {
                        text.append(characters[next])
                        index = next + 1
                        continue
                    }
                }

                if character == "'" {
                    index += 1
                    while index < characters.count, characters[index] != "'" {
                        if characters[index] == "\n" { line += 1 }
                        text.append(characters[index])
                        index += 1
                    }
                    index += 1
                    continue
                }

                if character == "\"" {
                    index += 1
                    while index < characters.count {
                        let inner = characters[index]
                        if inner == "\\" {
                            let next = index + 1
                            // Inside double quotes the shell only escapes
                            // these four characters.
                            if next < characters.count,
                               characters[next] == "\"" || characters[next] == "\\"
                               || characters[next] == "$" || characters[next] == "`" {
                                text.append(characters[next])
                                index = next + 1
                                continue
                            }
                        }
                        if inner == "\"" {
                            index += 1
                            break
                        }
                        if inner == "\n" { line += 1 }
                        text.append(inner)
                        index += 1
                    }
                    continue
                }

                text.append(character)
                index += 1
            }

            let range = start..<index
            words.append(Word(text: text, raw: String(characters[range]), line: startLine, range: range))
        }

        return words
    }
}
