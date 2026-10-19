import Foundation

struct ShellConfigScanner {
    private static let assignmentRegex = try? NSRegularExpression(
        pattern: #"(?:^|[ \t])([A-Za-z_][A-Za-z0-9_\.]*)=("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:\\.|[^ \t\\])*)"#
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
            return "\"\(escapeDoubleQuotedString(value.draftValue))\""
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

    /// Escapes the characters that a double quoted shell string would still expand.
    private func escapeDoubleQuotedString(_ string: String) -> String {
        var escaped = ""

        for character in string {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }

        return escaped
    }
}
