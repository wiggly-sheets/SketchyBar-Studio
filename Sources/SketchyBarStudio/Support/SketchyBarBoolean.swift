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

    static func isBooleanKey(_ keyPath: String) -> Bool {
        let key = keyPath.lowercased()
        let leaf = key.split(separator: ".").last.map(String.init) ?? key
        let booleanLeaves: Set<String> = [
            "drawing",
            "highlight",
            "ignore_association",
            "scroll_texts",
            "sticky",
            "font_smoothing",
            "shadow",
            "horizontal"
        ]

        return booleanLeaves.contains(leaf) || key.hasSuffix(".drawing")
    }
}
