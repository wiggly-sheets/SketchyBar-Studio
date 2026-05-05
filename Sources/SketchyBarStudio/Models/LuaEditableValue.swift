import Foundation

enum LuaValueKind: String, Codable, CaseIterable {
    case string = "String"
    case number = "Number"
    case boolean = "Boolean"
    case color = "Color"
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
}
