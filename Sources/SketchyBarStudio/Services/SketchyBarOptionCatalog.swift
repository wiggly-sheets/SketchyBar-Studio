import Foundation

struct SketchyBarOptionCatalog {
    private let booleanValues = ["true", "false"]

    func suggestedValues(for keyPath: String, currentValue: String) -> [String] {
        let key = keyPath.lowercased()
        let leaf = key.split(separator: ".").last.map(String.init) ?? key

        if SketchyBarBoolean.isBooleanKey(keyPath) {
            return booleanValues
        }

        if key == "position" {
            if currentValue == "top" || currentValue == "bottom" {
                return ["top", "bottom"]
            }

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
