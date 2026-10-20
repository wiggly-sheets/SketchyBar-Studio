import Foundation

struct LuaConfigScanner {
    private static let assignmentRegex = try? NSRegularExpression(
        pattern: #"(?:^|[,{;])\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_\.]*)\s*=\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|0[xX][0-9A-Fa-f]+\b|#[0-9A-Fa-f]{6,8}\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|true\b|false\b|dynamic\b|on\b|off\b|when_shown\b)"#
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
        // A file with SbarLua items is read with the Lua parser, so the keys
        // of a nested table keep their path. The plain scan fills in the rest
        // of the file and skips the values the parser already found.
        let structured = structuredValues(fileURL: fileURL, contents: contents)
        let claimed = (structured.values.map { LuaSourceRange(start: $0.valueStartOffset, end: $0.valueEndOffset) }
            + structured.excludedRanges)
            .sorted { $0.start < $1.start }
        let plain = scannedValues(fileURL: fileURL, contents: contents, claiming: claimed)
        let results = (structured.values + plain).sorted { $0.valueStartOffset < $1.valueStartOffset }
        return LuaEditableValue.assigningStableKeys(results)
    }

    /// The values of the SbarLua items of the file, with the key path of
    /// every value relative to the table of its item. The values of the bar
    /// have their own key paths, such as `bar.position`. The ranges of the
    /// values that are not a single literal are returned as well, so the
    /// plain scan does not match a literal inside them.
    private func structuredValues(fileURL: URL, contents: String) -> (values: [LuaEditableValue], excludedRanges: [LuaSourceRange]) {
        guard contents.contains("sbar") else { return ([], []) }

        let items = SbarLuaItemParser.items(in: contents)
        let bar = SbarLuaItemParser.bar(in: contents)
        guard !items.isEmpty || bar != nil else { return ([], []) }

        let lineStarts = Self.lineStarts(in: contents)
        var results: [LuaEditableValue] = []

        for value in items.flatMap(\.values) + (bar?.values ?? []) {
            let lineNumber = Self.lineNumber(for: value.valueStartOffset, lineStarts: lineStarts)
            let displayValue = SketchyBarValueRules.normalizedDisplayValue(
                SketchyBarValueRules.displayValue(for: value.rawValue, keyPath: value.keyPath),
                keyPath: value.keyPath
            )

            results.append(
                LuaEditableValue(
                    id: "\(fileURL.path):\(lineNumber):\(value.keyPath):\(value.valueStartOffset)",
                    fileURL: fileURL,
                    keyPath: value.keyPath,
                    lineNumber: lineNumber,
                    kind: SketchyBarValueRules.kind(for: value.rawValue, keyPath: value.keyPath),
                    originalValue: displayValue,
                    draftValue: displayValue,
                    suggestedValues: optionCatalog.suggestedValues(for: value.keyPath, currentValue: displayValue),
                    valueStartOffset: value.valueStartOffset,
                    valueEndOffset: value.valueEndOffset,
                    sourceSnapshot: contents
                )
            )
        }

        let excludedRanges = items.flatMap(\.excludedRanges) + (bar?.excludedRanges ?? [])
        return (results, excludedRanges)
    }

    /// The values of the file that the plain scan finds. The values that the
    /// Lua parser already found are skipped, so a value is never listed
    /// twice.
    private func scannedValues(fileURL: URL, contents: String, claiming claimed: [LuaSourceRange]) -> [LuaEditableValue] {
        guard let regex = Self.assignmentRegex else {
            return []
        }

        let ignoredRegions = SourceRegions.luaIgnoredRegions(in: contents)
        var results: [LuaEditableValue] = []
        var lineNumber = 1

        contents.enumerateSubstrings(in: contents.startIndex..<contents.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = String(contents[lineRange])
            let nsLine = NSRange(line.startIndex..<line.endIndex, in: line)
            let lineStart = contents.distance(from: contents.startIndex, to: lineRange.lowerBound)
            for match in regex.matches(in: line, range: nsLine) {
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
                guard !isClaimed(start: valueStart, end: valueEnd, in: claimed) else {
                    continue
                }
                // A value that is only a part of an expression, such as the
                // `"a"` of `"a" .. "b"`, is not a value of its own. Writing
                // it back would keep only the part that is a literal and
                // break the file.
                guard !isPartOfExpression(line: line, valueRange: valueRange) else {
                    continue
                }

                let keyPath = String(line[keyRange])
                let id = "\(fileURL.path):\(lineNumber):\(keyPath):\(valueStart)"
                let displayValue = SketchyBarValueRules.normalizedDisplayValue(
                    SketchyBarValueRules.displayValue(for: rawValue, keyPath: keyPath),
                    keyPath: keyPath
                )

                results.append(
                    LuaEditableValue(
                        id: id,
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

            lineNumber += 1
        }

        return results
    }

    /// The character offset of the start of every line.
    private static func lineStarts(in contents: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for character in contents {
            offset += 1
            if character.isNewline {
                starts.append(offset)
            }
        }
        return starts
    }

    /// True when a range is already covered by one of the claimed ranges.
    ///
    /// The claimed ranges are sorted by their start and never overlap, so
    /// only the range at the found place and the one before it can touch
    /// the given range.
    private func isClaimed(start: Int, end: Int, in claimed: [LuaSourceRange]) -> Bool {
        var low = 0
        var high = claimed.count - 1
        var index = -1
        while low <= high {
            let middle = (low + high) / 2
            if claimed[middle].start <= start {
                index = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        guard index >= 0 else { return false }
        if claimed[index].intersects(LuaSourceRange(start: start, end: end)) { return true }
        if index > 0, claimed[index - 1].intersects(LuaSourceRange(start: start, end: end)) { return true }
        return false
    }

    /// The operators of Lua that are made of two characters.
    private static let twoCharacterOperators = ["..", "==", "~=", "<=", ">=", "<<", ">>"]

    /// The operators of Lua that are made of one character.
    private static let oneCharacterOperators: Set<Character> = ["+", "-", "*", "/", "%", "^", "#", "&", "|", "~", "<", ">"]

    /// True when the value is only a part of a larger expression, such as
    /// the `"a"` of `"a" .. "b"`. Such a value is not a value of its own,
    /// so it must not be offered as an editable value.
    private func isPartOfExpression(line: String, valueRange: Range<String.Index>) -> Bool {
        let before = line[line.startIndex..<valueRange.lowerBound]
        let after = line[valueRange.upperBound...]
        return Self.operatorAtEnd(of: before) != nil || Self.operatorAtStart(of: after) != nil
    }

    /// The operator at the start of the text, when the text starts with an
    /// operator of Lua. A comment is not an operator.
    private static func operatorAtStart(of text: Substring) -> String? {
        var text = text
        while let first = text.first, first.isWhitespace { text = text.dropFirst() }
        guard let first = text.first else { return nil }
        if first == "-", text.dropFirst().first == "-" { return nil }
        for op in twoCharacterOperators where text.hasPrefix(op) { return op }
        guard oneCharacterOperators.contains(first) else { return nil }
        return String(first)
    }

    /// The operator at the end of the text, when the text ends with an
    /// operator of Lua. A single `=` is an assignment, so it is not one.
    private static func operatorAtEnd(of text: Substring) -> String? {
        var text = text
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        guard let last = text.last else { return nil }
        guard oneCharacterOperators.contains(last) || last == "." || last == "=" else { return nil }
        for op in twoCharacterOperators where op.hasSuffix(String(last)) && text.hasSuffix(op) {
            return op
        }
        if last == "=" { return nil }
        return String(last)
    }

    /// The line a character offset belongs to.
    private static func lineNumber(for offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        var line = 0
        while low <= high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset {
                line = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return line + 1
    }

    func save(values: [LuaEditableValue], to fileURL: URL, rootURL: URL) throws {
        let changedValues = values.filter { $0.draftValue != $0.originalValue && !$0.isMissingFromFile }
        guard !changedValues.isEmpty else { return }
        var contents = try String(contentsOf: fileURL, encoding: .utf8)
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
            let delimiter: Character = SketchyBarValueRules.isUpdatesKey(value.keyPath) || original.first != "'" ? "\"" : "'"
            return "\(delimiter)\(escapeLexicalString(value.draftValue, delimiter: delimiter))\(delimiter)"
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

    private func escapeLexicalString(_ string: String, delimiter: Character) -> String {
        var escaped = ""
        var index = string.startIndex

        while index < string.endIndex {
            let character = string[index]
            if character == "\\" {
                escaped.append(character)
                let nextIndex = string.index(after: index)
                if nextIndex < string.endIndex {
                    escaped.append(string[nextIndex])
                    index = string.index(after: nextIndex)
                } else {
                    escaped.append("\\")
                    index = nextIndex
                }
                continue
            }

            if character == delimiter {
                escaped.append("\\")
            }
            escaped.append(character)
            index = string.index(after: index)
        }

        return escaped
    }
}
