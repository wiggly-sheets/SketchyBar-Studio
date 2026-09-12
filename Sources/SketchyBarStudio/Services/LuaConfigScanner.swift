import Foundation

struct LuaConfigScanner {
    private static let assignmentRegex = try? NSRegularExpression(
        pattern: #"(?:^|[,{;])\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_\.]*)\s*=\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|true|false|-?\d+(?:\.\d+)?|0x[0-9A-Fa-f]+|#[0-9A-Fa-f]{6,8}|dynamic)"#
    )

    private let optionCatalog = SketchyBarOptionCatalog()

    func scan(fileURL: URL) -> [LuaEditableValue] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8),
              let regex = Self.assignmentRegex else {
            return []
        }

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
                let keyPath = String(line[keyRange])
                let id = "\(fileURL.path):\(lineNumber):\(keyPath):\(valueStart)"
                let displayValue = normalizedDisplayValue(displayValue(for: rawValue, keyPath: keyPath), keyPath: keyPath)

                results.append(
                    LuaEditableValue(
                        id: id,
                        fileURL: fileURL,
                        keyPath: keyPath,
                        lineNumber: lineNumber,
                        kind: kind(for: rawValue, keyPath: keyPath),
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

    private func kind(for rawValue: String, keyPath: String) -> LuaValueKind {
        if SketchyBarBoolean.normalized(displayValue(for: rawValue)) != nil && SketchyBarBoolean.isBooleanKey(keyPath) {
            return .boolean
        }
        if rawValue.hasPrefix("#") || rawValue.hasPrefix("0x") {
            return .color
        }
        if rawValue.hasPrefix("\"") || rawValue.hasPrefix("'") {
            let unquoted = displayValue(for: rawValue)
            return unquoted.hasPrefix("#") ? .color : .string
        }
        return .number
    }

    private func displayValue(for rawValue: String, keyPath: String? = nil) -> String {
        if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) ||
            (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
            let unquoted = String(rawValue.dropFirst().dropLast())
            if let keyPath,
               SketchyBarBoolean.isBooleanKey(keyPath),
               let normalized = SketchyBarBoolean.normalized(unquoted) {
                return normalized
            }
            return unquoted
        }

        if let keyPath,
           SketchyBarBoolean.isBooleanKey(keyPath),
           let normalized = SketchyBarBoolean.normalized(rawValue) {
            return normalized
        }
        return rawValue
    }

    private func normalizedDisplayValue(_ value: String, keyPath: String) -> String {
        let leaf = keyPath.lowercased().split(separator: ".").last.map(String.init) ?? keyPath.lowercased()
        if leaf == "updates" {
            switch value.lowercased() {
            case "true", "yes", "1":
                return "on"
            case "false", "no", "0":
                return "off"
            default:
                return value
            }
        }
        return value
    }

    private func serializedValue(_ value: LuaEditableValue) -> String {
        switch value.kind {
        case .string:
            let delimiter: Character = originalSerializedValue(for: value).first == "'" ? "'" : "\""
            return "\(delimiter)\(escapeLexicalString(value.draftValue, delimiter: delimiter))\(delimiter)"
        case .number:
            return value.draftValue
        case .color:
            return SketchyBarColor.parse(value.draftValue)?.sketchyBarHex ?? value.draftValue
        case .boolean:
            return SketchyBarBoolean.normalized(value.draftValue) ?? "false"
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
