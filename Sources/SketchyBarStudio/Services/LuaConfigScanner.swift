import Foundation

struct LuaConfigScanner {
    private static let assignmentRegex = try? NSRegularExpression(
        pattern: #"(?:^|[,{;])\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_\.]*)\s*=\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|0[xX][0-9A-Fa-f]+\b|#[0-9A-Fa-f]{6,8}\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|true\b|false\b|dynamic\b|on\b|off\b|when_shown\b)"#
    )

    private let optionCatalog = SketchyBarOptionCatalog()

    func scan(fileURL: URL) -> [LuaEditableValue] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8),
              let regex = Self.assignmentRegex else {
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

    func save(values: [LuaEditableValue], to fileURL: URL, rootURL: URL) throws {
        let changedValues = values.filter { $0.draftValue != $0.originalValue }
        guard !changedValues.isEmpty else { return }
        var contents = try String(contentsOf: fileURL, encoding: .utf8)
        guard changedValues.allSatisfy({
            $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL && $0.sourceSnapshot == contents
        }) else {
            throw ConfigSourceSaveError.sourceChanged(fileURL)
        }

        for value in changedValues.sorted(by: { $0.valueStartOffset > $1.valueStartOffset }) {
            let start = contents.index(contents.startIndex, offsetBy: value.valueStartOffset)
            let end = contents.index(contents.startIndex, offsetBy: value.valueEndOffset)
            contents.replaceSubrange(start..<end, with: serializedValue(value))
        }

        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
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
