import Foundation

struct SketchyBarOptionCatalog {
    private let booleanValues = ["true", "false"]

    func suggestedValues(for keyPath: String, currentValue: String) -> [String] {
        let key = keyPath.lowercased()
        let leaf = key.split(separator: ".").last.map(String.init) ?? key

        if SketchyBarBoolean.isBooleanKey(keyPath) {
            return booleanValues
        }

        if leaf == "position" {
            if currentValue == "top" || currentValue == "bottom" {
                return ["top", "bottom"]
            }

            var values = ["left", "right", "center", "q", "e"]
            if currentValue.hasPrefix("popup.") {
                values.insert(currentValue, at: 0)
            }
            return options(values, keeping: currentValue)
        }

        if leaf == "align" {
            return options(["left", "right", "center"], keeping: currentValue)
        }

        if leaf == "display" {
            return options(["all", "main", "active"], keeping: currentValue)
        }

        if leaf == "hidden" {
            return options(["off", "on", "current"], keeping: currentValue)
        }

        if leaf == "topmost" {
            return options(["off", "on", "window"], keeping: currentValue)
        }

        if leaf == "updates" {
            return ["on", "off", "when_shown"]
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

        return []
    }

    private func options(_ values: [String], keeping currentValue: String) -> [String] {
        guard !currentValue.isEmpty, !values.contains(currentValue) else {
            return values
        }
        return [currentValue] + values
    }
}
