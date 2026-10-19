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
            "cache_scripts",
            "clip",
            "drawing",
            "font_smoothing",
            "horizontal",
            "ignore_association",
            "lazy",
            "scroll_texts",
            "shadow",
            "show_in_fullscreen",
            "sticky"
        ]

        return booleanLeaves.contains(leaf) || key.hasSuffix(".drawing")
    }
}
