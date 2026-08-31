import Foundation

enum LuaValueKind: String, Codable, CaseIterable {
    case string = "String"
    case number = "Number"
    case boolean = "Boolean"
    case color = "Color"
}

enum ConfigSourceSaveError: LocalizedError {
    case sourceChanged(URL)

    var errorDescription: String? {
        switch self {
        case .sourceChanged(let fileURL):
            return "\(fileURL.lastPathComponent) changed on disk. Reload it before saving so external edits are not overwritten."
        }
    }
}

struct LuaEditableValue: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let keyPath: String
    let lineNumber: Int
    let kind: LuaValueKind
    let originalValue: String
    var draftValue: String
    let suggestedValues: [String]
    let valueStartOffset: Int
    let valueEndOffset: Int
    let sourceSnapshot: String

    var displayLine: String {
        "Line \(lineNumber)"
    }

    var hasSuggestedValues: Bool {
        !suggestedValues.isEmpty
    }

    var isFontValue: Bool {
        let key = keyPath.lowercased()
        return key == "font" ||
            key.hasSuffix(".font") ||
            key.hasSuffix(".font.family") ||
            key.hasSuffix(".font.style") ||
            key.hasSuffix(".font.size")
    }

    var isWidthValue: Bool {
        let leaf = keyPath.lowercased().split(separator: ".").last.map(String.init) ?? keyPath.lowercased()
        return leaf == "width"
    }
}
