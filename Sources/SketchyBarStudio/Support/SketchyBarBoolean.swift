import Foundation

enum SketchyBarBoolean {
    static func normalized(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on", "1":
            return "true"
        case "false", "no", "off", "0":
            return "false"
        default:
            return nil
        }
    }

    /// The properties that SketchyBar reads with `evaluate_boolean_state`.
    ///
    /// The list follows the SketchyBar sources. `topmost` is not in it,
    /// because the bar level of that property also takes the value
    /// `window`. `clip` is not in it either, because it is a number.
    static let booleanLeaves: Set<String> = [
        "clockwise",
        "drawing",
        "fill_row",
        "font_smoothing",
        "font_typographical_width",
        "highlight",
        "horizontal",
        "ignore_association",
        "line_break",
        "scroll_texts",
        "shadow",
        "show_in_fullscreen",
        "sticky"
    ]

    static func isBooleanKey(_ keyPath: String) -> Bool {
        let key = keyPath.lowercased()
        let leaf = key.split(separator: ".").last.map(String.init) ?? key

        return booleanLeaves.contains(leaf) || key.hasSuffix(".drawing")
    }
}
