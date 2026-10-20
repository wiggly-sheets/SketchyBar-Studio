import Foundation

struct SketchyBarOptionCatalog {
    private let booleanValues = ["true", "false"]

    /// The key path of a value that belongs to the bar, such as
    /// `bar.position`.
    ///
    /// The `bar.` prefix makes the option reference resolve the bar level
    /// of a property, so the validator, the picker and the option
    /// reference read the same property. A property that has no `bar.`
    /// entry falls back to the entry of its leaf.
    static func barKeyPath(for keyPath: String) -> String {
        let key = keyPath.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.hasPrefix("bar.") else { return key }
        return "bar." + key
    }

    func suggestedValues(for keyPath: String, currentValue: String) -> [String] {
        let key = keyPath.lowercased()
        let leaf = key.split(separator: ".").last.map(String.init) ?? key

        if SketchyBarBoolean.isBooleanKey(keyPath) {
            return booleanValues
        }

        if key == "position" {
            var values = ["left", "right", "center", "q", "e"]
            if currentValue.hasPrefix("popup.") {
                values.insert(currentValue, at: 0)
            }
            return options(values, keeping: currentValue)
        }

        if key == "bar.position" {
            return options(["top", "bottom"], keeping: currentValue)
        }

        if leaf == "width" {
            return []
        }

        if leaf == "image" || leaf == "string" {
            if currentValue.hasPrefix("app.") {
                return options([currentValue, "app.<bundle-id>", "app.<name>", "media.artwork"], keeping: currentValue)
            }
            if currentValue == "media.artwork" {
                return options(["media.artwork", "app.<bundle-id>", "app.<name>"], keeping: currentValue)
            }
        }

        if let doc = SketchyBarOptionDocs.doc(for: keyPath), !doc.values.isEmpty {
            return options(doc.values, keeping: currentValue)
        }

        return []
    }

    /// The values of the option, with the value of the file always in the
    /// list. The picker needs a tag for the value it shows, so an empty
    /// value is kept as an empty entry.
    private func options(_ values: [String], keeping currentValue: String) -> [String] {
        guard !values.contains(currentValue) else { return values }
        return [currentValue] + values
    }
}
