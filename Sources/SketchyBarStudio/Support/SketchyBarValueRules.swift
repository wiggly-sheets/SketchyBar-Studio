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

    /// Keeps the original text when the draft is not a number.
    static func serializedNumber(_ draft: String, original: String) -> String {
        guard draft == "dynamic" || Double(draft) != nil else { return original }
        return draft
    }

    /// True when the draft is a number that can be written to the file.
    static func isValidNumber(_ draft: String) -> Bool {
        Double(draft.trimmingCharacters(in: .whitespaces)) != nil
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

    /// Keeps the original text when the draft is not a boolean.
    static func serializedBoolean(_ draft: String, original: String) -> String {
        SketchyBarBoolean.normalized(draft) ?? original
    }
}
