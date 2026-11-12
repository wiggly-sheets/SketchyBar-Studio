import Foundation

/// Shared rules for classifying, displaying and serializing SketchyBar config values.
enum SketchyBarValueRules {
    private static let colorLeaves: Set<String> = [
        "color",
        "border_color",
        "border_colour",
        "fill_color",
        "highlight_color",
        "background_color",
        "text_color",
        "icon_color",
        "label_color"
    ]

    static func leaf(of keyPath: String) -> String {
        let key = keyPath.lowercased()
        return key.split(separator: ".").last.map(String.init) ?? key
    }

    /// Keys that always hold a SketchyBar color, even when the value is a quoted string.
    static func isColorKey(_ keyPath: String) -> Bool {
        let key = keyPath.lowercased()
        return colorLeaves.contains(leaf(of: keyPath)) || key.hasSuffix(".color")
    }

    /// `updates` is an on/off/when_shown enum, not a boolean.
    static func isUpdatesKey(_ keyPath: String) -> Bool {
        leaf(of: keyPath) == "updates"
    }

    static func isQuoted(_ rawValue: String) -> Bool {
        (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) ||
            (rawValue.hasPrefix("'") && rawValue.hasSuffix("'"))
    }

    static func unquoted(_ rawValue: String) -> String {
        isQuoted(rawValue) ? String(rawValue.dropFirst().dropLast()) : rawValue
    }

    /// An unquoted `0x`/`0X` hex literal.
    static func isHexLiteral(_ rawValue: String) -> Bool {
        guard rawValue.lowercased().hasPrefix("0x") else { return false }
        let digits = rawValue.dropFirst(2)
        return !digits.isEmpty && digits.allSatisfy { $0.isHexDigit }
    }

    static func kind(for rawValue: String, keyPath: String) -> LuaValueKind {
        if isUpdatesKey(keyPath) {
            return .string
        }

        let value = unquoted(rawValue)
        if value.lowercased() == "true" || value.lowercased() == "false" {
            return .boolean
        }
        if SketchyBarBoolean.isBooleanKey(keyPath), SketchyBarBoolean.normalized(value) != nil {
            return .boolean
        }
        if isColorKey(keyPath) {
            return .color
        }
        if !isQuoted(rawValue), isHexLiteral(rawValue) {
            return .color
        }
        if isQuoted(rawValue) {
            return .string
        }
        return Double(value) != nil ? .number : .string
    }

    static func displayValue(for rawValue: String, keyPath: String) -> String {
        let value = unquoted(rawValue)
        if SketchyBarBoolean.isBooleanKey(keyPath), let normalized = SketchyBarBoolean.normalized(value) {
            return normalized
        }
        return value
    }

    static func normalizedDisplayValue(_ value: String, keyPath: String) -> String {
        guard isUpdatesKey(keyPath) else { return value }
        switch value.lowercased() {
        case "true", "yes", "1":
            return "on"
        case "false", "no", "0":
            return "off"
        default:
            return value
        }
    }

    static func containsLineBreak(_ value: String) -> Bool {
        value.contains { $0 == "\n" || $0 == "\r" }
    }

    /// Keeps the original text when the draft is not a finite number.
    ///
    /// The draft is trimmed, so the check of the editor and the write use
    /// the same rule. `inf` and `nan` are not numbers of a config: Lua reads
    /// them as globals.
    static func serializedNumber(_ draft: String, original: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed == "dynamic" { return trimmed }
        guard let number = Double(trimmed), number.isFinite else { return original }
        return trimmed
    }

    /// True when the draft is a number that can be written to the file.
    static func isValidNumber(_ draft: String) -> Bool {
        guard let number = Double(draft.trimmingCharacters(in: .whitespaces)) else { return false }
        return number.isFinite
    }

    /// True when the draft is a number that is still being typed, such as
    /// "-" or "12.". Such a draft must not be written to the file.
    static func isPartialNumber(_ draft: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed == "-" { return true }

        var body = Substring(trimmed)
        if body.first == "-" { body = body.dropFirst() }
        guard !body.isEmpty else { return false }

        var dots = 0
        for character in body {
            if character == "." {
                dots += 1
                continue
            }
            guard character.isNumber else { return false }
        }
        return dots <= 1
    }

    /// The width to use when a width switches from "dynamic" to a number.
    /// The draft wins, then the original, then the last numeric width in
    /// the same file, then a default. It never returns "0", because a zero
    /// width makes the item invisible.
    static func numericWidthFallback(draft: String, original: String, siblingWidths: [String]) -> String {
        if let width = positiveWidth(draft) { return width }
        if let width = positiveWidth(original) { return width }
        for candidate in siblingWidths.reversed() {
            if let width = positiveWidth(candidate) { return width }
        }
        return "100"
    }

    /// A width that can be written: a number above zero.
    private static func positiveWidth(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), number > 0 else { return nil }
        return trimmed
    }

    /// Keeps the original text when the draft is not a color, and keeps the original quoting.
    static func serializedColor(_ draft: String, original: String) -> String {
        guard let color = SketchyBarColor.parse(draft) else { return original }
        let hex = color.sketchyBarHex
        if original.hasPrefix("\"") {
            return "\"\(hex)\""
        }
        if original.hasPrefix("'") {
            return "'\(hex)'"
        }
        return hex
    }

    /// Keeps the original text when the draft is not a boolean, and keeps
    /// the quotes of a quoted value, so `bar = "false"` stays a string of
    /// the config instead of becoming a bare Lua boolean.
    static func serializedBoolean(_ draft: String, original: String) -> String {
        guard let normalized = SketchyBarBoolean.normalized(draft) else { return original }
        if original.hasPrefix("\"") {
            return "\"\(normalized)\""
        }
        if original.hasPrefix("'") {
            return "'\(normalized)'"
        }
        return normalized
    }

    /// True when the draft of a value can be written into the file.
    ///
    /// A draft the scanner cannot serialize is not written silently: the
    /// save refuses it and keeps the draft, so a pasted multi-line label is
    /// reported instead of being dropped under a "Saved" message.
    static func canSerializeDraft(_ value: LuaEditableValue) -> Bool {
        switch value.kind {
        case .string:
            guard !containsLineBreak(value.draftValue) else { return false }
            if value.fileURL.pathExtension.lowercased() == "lua" {
                // The Lua scanner keeps the backslashes of the file and only
                // escapes the delimiter. A draft with an escape Lua cannot
                // read would make the whole file unloadable, so it is
                // refused instead of written.
                return hasValidLuaEscapes(value.draftValue)
            }
            return true
        case .number:
            let trimmed = value.draftValue.trimmingCharacters(in: .whitespaces)
            if trimmed == "dynamic" { return true }
            guard let number = Double(trimmed) else { return false }
            return number.isFinite
        case .color:
            return SketchyBarColor.parse(value.draftValue) != nil
        case .boolean:
            return SketchyBarBoolean.normalized(value.draftValue) != nil
        }
    }

    /// True when every backslash of a Lua string starts an escape Lua knows.
    ///
    /// A newline after the backslash is a line continuation, and a decimal
    /// or hexadecimal escape runs to its last digit. `\z` skips the
    /// whitespace that follows it.
    static func hasValidLuaEscapes(_ value: String) -> Bool {
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\" else {
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { return false }
            let escaped = characters[index]
            switch escaped {
            case "a", "b", "f", "n", "r", "t", "v", "\\", "\"", "'", "\n", "\r", "z":
                index += 1
            case "x":
                index += 1
                var digits = 0
                while index < characters.count, characters[index].isHexDigit {
                    digits += 1
                    index += 1
                }
                guard digits == 2 else { return false }
            case "u":
                index += 1
                guard index < characters.count, characters[index] == "{" else { return false }
                index += 1
                var digits = 0
                var value = 0
                while index < characters.count, characters[index] != "}" {
                    guard let digit = characters[index].hexDigitValue else { return false }
                    value = value * 16 + digit
                    digits += 1
                    index += 1
                }
                guard index < characters.count, characters[index] == "}", digits > 0 else { return false }
                guard value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return false }
                index += 1
            case "0"..."9":
                var value = 0
                var digits = 0
                while index < characters.count, let digit = characters[index].wholeNumberValue {
                    value = value * 10 + digit
                    digits += 1
                    index += 1
                }
                guard digits <= 3, value <= 255 else { return false }
            default:
                return false
            }
        }
        return true
    }
}
