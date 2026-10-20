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

                let keyPath = String(line[keyRange])
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
    private static func isSafeUnquotedToken(_ value: String) -> Bool {
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
