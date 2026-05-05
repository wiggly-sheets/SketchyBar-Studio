import Foundation

enum ConfigFileKind: String, Hashable {
    case lua = "Lua"
    case shell = "Shell"
    case sketchybarRC = "sketchybarrc"
}

struct ActivationReference: Hashable {
    let entrypointURL: URL
    let lineNumber: Int
    let isActive: Bool
}

struct ConfigFile: Identifiable, Hashable {
    let url: URL
    let rootURL: URL
    let kind: ConfigFileKind
    let values: [LuaEditableValue]
    let activationReference: ActivationReference?

    var id: String { url.path }

    var displayName: String {
        let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    var editableCount: Int {
        values.count
    }

    var isActive: Bool {
        activationReference?.isActive ?? true
    }

    var hasUnsavedChanges: Bool {
        values.contains { $0.draftValue != $0.originalValue }
    }

    func matchesSearch(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return true
        }

        if displayName.lowercased().contains(trimmed) {
            return true
        }

        return values.contains { value in
            value.keyPath.lowercased().contains(trimmed) ||
                value.draftValue.lowercased().contains(trimmed)
        }
    }
}
