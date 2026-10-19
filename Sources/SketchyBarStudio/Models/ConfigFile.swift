import Foundation

enum ConfigFileKind: String, Hashable {
    case lua = "Lua"
    case shell = "Shell"
    case sketchybarRC = "sketchybarrc"
}

/// One loader line that references a config file.
struct ActivationMatch: Hashable {
    let entrypointURL: URL
    let lineNumber: Int
    let isActive: Bool
}

struct ActivationReference: Hashable {
    let entrypointURL: URL
    let lineNumber: Int
    let isActive: Bool
    /// Every loader line that references the file, across all entrypoints.
    var matches: [ActivationMatch] = []

    /// The primary reference plus every additional loader line.
    var allMatches: [ActivationMatch] {
        matches.isEmpty
            ? [ActivationMatch(entrypointURL: entrypointURL, lineNumber: lineNumber, isActive: isActive)]
            : matches
    }
}

struct ConfigFile: Identifiable, Hashable {
    let url: URL
    let rootURL: URL
    let kind: ConfigFileKind
    let values: [LuaEditableValue]
    let activationReference: ActivationReference?
    /// True when the file disappeared from disk. The session (and any draft)
    /// is kept so the work is not lost.
    var isMissingFromDisk: Bool = false

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
