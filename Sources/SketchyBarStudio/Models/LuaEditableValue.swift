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
    /// Identity that survives line shifts: the key path plus the ordinal
    /// occurrence of that key path inside the file. The ordinal moves when a
    /// new block with the same option is added, so a stable key on its own
    /// does not prove that two values are the same value.
    var stableKey: String = ""
    /// True when the key no longer exists in the file on disk. The draft is
    /// kept so the user can see it, but it cannot be written back.
    var isMissingFromFile: Bool = false

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

extension LuaEditableValue {
    /// Compares identity only. The source snapshot holds the whole file, so
    /// comparing it would walk every byte of the file on every check.
    static func == (lhs: LuaEditableValue, rhs: LuaEditableValue) -> Bool {
        lhs.id == rhs.id &&
        lhs.fileURL == rhs.fileURL &&
        lhs.lineNumber == rhs.lineNumber &&
        lhs.keyPath == rhs.keyPath &&
        lhs.draftValue == rhs.draftValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fileURL)
        hasher.combine(lineNumber)
        hasher.combine(keyPath)
        hasher.combine(draftValue)
    }
}

extension LuaEditableValue {
    /// Assigns every value a stable key: its key path plus the ordinal
    /// occurrence of that key path inside the file. Line shifts do not
    /// change the key, so drafts survive edits made above them.
    static func assigningStableKeys(_ values: [LuaEditableValue]) -> [LuaEditableValue] {
        var occurrences: [String: Int] = [:]
        return values.map { value in
            var updated = value
            let index = occurrences[value.keyPath, default: 0]
            occurrences[value.keyPath] = index + 1
            updated.stableKey = "\(value.keyPath)#\(index)"
            return updated
        }
    }
}
