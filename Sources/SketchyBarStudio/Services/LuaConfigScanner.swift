import Foundation

struct LuaConfigScanner {
    private let assignmentPattern = #"^\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_\.]*)\s*=\s*("[^"]*"|'[^']*'|true|false|-?\d+(?:\.\d+)?|0x[0-9A-Fa-f]+|#[0-9A-Fa-f]{6,8})\s*(?:,|--.*)?$"#
    private let optionCatalog = SketchyBarOptionCatalog()

    func scan(fileURL: URL) -> [LuaEditableValue] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: assignmentPattern) else {
            return []
        }

        var results: [LuaEditableValue] = []
        var lineNumber = 1

        contents.enumerateSubstrings(in: contents.startIndex..<contents.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = String(contents[lineRange])
            let nsLine = NSRange(line.startIndex..<line.endIndex, in: line)

            guard let match = regex.firstMatch(in: line, range: nsLine),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else {
                lineNumber += 1
                return
            }

            let rawValue = String(line[valueRange])
            let lineStart = contents.distance(from: contents.startIndex, to: lineRange.lowerBound)
            let valueStart = lineStart + line.distance(from: line.startIndex, to: valueRange.lowerBound)
            let valueEnd = lineStart + line.distance(from: line.startIndex, to: valueRange.upperBound)
            let keyPath = String(line[keyRange])
            let id = "\(fileURL.path):\(lineNumber):\(keyPath)"
            let displayValue = displayValue(for: rawValue, keyPath: keyPath)

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
                    valueEndOffset: valueEnd
                )
            )

            lineNumber += 1
        }

        return results
    }

    func save(values: [LuaEditableValue], to fileURL: URL) throws {
        var contents = try String(contentsOf: fileURL, encoding: .utf8)

        for value in values.sorted(by: { $0.valueStartOffset > $1.valueStartOffset }) {
            let start = contents.index(contents.startIndex, offsetBy: value.valueStartOffset)
            let end = contents.index(contents.startIndex, offsetBy: value.valueEndOffset)
            contents.replaceSubrange(start..<end, with: serializedValue(value))
        }

        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).studio-backup")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
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

    private func serializedValue(_ value: LuaEditableValue) -> String {
        switch value.kind {
        case .string:
            return "\"\(escapeLuaString(value.draftValue))\""
        case .number:
            return value.draftValue
        case .color:
            return SketchyBarColor.parse(value.draftValue)?.sketchyBarHex ?? value.draftValue
        case .boolean:
            return SketchyBarBoolean.normalized(value.draftValue) ?? "false"
        }
    }

    private func escapeLuaString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
